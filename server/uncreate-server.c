/* uncreate-server.c — self-hosted "Team Create" relay for Roblox Studio.
 *
 * The server stores exactly one project as
 *   1) a snapshot: opaque base64 chunk files + a JSON manifest, uploaded by
 *      the Studio plugin (chunks are SerializationService rbxm blobs), and
 *   2) an append-only log of op batches: opaque JSON arrays, each stamped
 *      with a monotonic revision number.
 * Clients join by downloading the snapshot, then long-poll for batches whose
 * rev is newer than theirs. The server never parses Roblox data; it orders,
 * stores and relays. Periodically it asks one caught-up client to upload a
 * fresh snapshot so the log can be truncated (compaction).
 *
 * Presence (where each person's Studio camera is) is ephemeral: it lives
 * in memory only, never enters the log, and is exchanged via /presence.
 *
 * Single thread, one poll() loop, non-blocking sockets, HTTP/1.1 keep-alive.
 * Allocation failure is fatal (xrealloc aborts): a relay with no memory
 * cannot make progress, and every caller stays free of OOM branches.
 *
 * Build:  Linux/macOS  cc -O2 -std=c11 -o uncreate-server uncreate-server.c
 *         Windows      gcc -O2 -std=c11 -o uncreate-server.exe uncreate-server.c -lws2_32
 * [ @Claude | 23.10.2026 ]
 * edited [ @Claude | 23.10.2026 ]
 */

#ifdef _WIN32
#	ifndef _WIN32_WINNT
#		define _WIN32_WINNT 0x0600 /* WSAPoll */
#	endif
#	define WIN32_LEAN_AND_MEAN
#	define __USE_MINGW_ANSI_STDIO 1 /* %zu / PRIu64 regardless of CRT */
#	include <winsock2.h>
#	include <ws2tcpip.h>
#	include <windows.h>
#	include <direct.h>
#else
#	define _POSIX_C_SOURCE 200809L
#	define _DEFAULT_SOURCE /* getifaddrs */
#	include <arpa/inet.h>
#	include <ifaddrs.h>
#	include <errno.h>
#	include <fcntl.h>
#	include <netinet/in.h>
#	include <netinet/tcp.h>
#	include <poll.h>
#	include <signal.h>
#	include <sys/socket.h>
#	include <sys/stat.h>
#	include <time.h>
#	include <unistd.h>
#endif

#include <assert.h>
#include <signal.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------- limits */

enum {
	MAX_CONNS = 256,
	MAX_CLIENTS = 64,
	MAX_HEAD = 16 * 1024,
	MAX_NAME = 32,
	MAX_CAM = 160,
	MAX_CHUNKS = 1 << 16,
	POLL_MAX_WAIT_S = 25,
};

#define MAX_BODY ((size_t)256 * 1024 * 1024) /* one snapshot part / import file */
#define POLL_MAX_BYTES ((size_t)8 * 1024 * 1024) /* payload per poll reply      */
#define SNAP_WANT_BYTES ((size_t)16 * 1024 * 1024) /* log size that asks for a   */
#define SNAP_WANT_BATCHES ((size_t)20000)          /* fresh snapshot             */
#define CLIENT_TTL_MS ((uint64_t)45 * 1000)
#define CAM_TTL_MS ((uint64_t)6 * 1000) /* a camera not refreshed this long is hidden */
#define IDLE_TTL_MS ((uint64_t)90 * 1000)
#define READ_TTL_MS ((uint64_t)600 * 1000) /* slow uploads of big chunks         */
#define WRITE_TTL_MS ((uint64_t)600 * 1000) /* slow downloads of big replies     */
#define STAGE_TTL_MS ((uint64_t)15 * 60 * 1000)
#define WANT_RETRY_MS ((uint64_t)120 * 1000)

/* -------------------------------------------------------------- platform */

#ifdef _WIN32
typedef SOCKET sock_t;
#	define SOCK_BAD INVALID_SOCKET
#	define sock_close closesocket
#	define net_poll(f, n, t) WSAPoll((f), (ULONG)(n), (t))
#	define sock_would_block() (WSAGetLastError() == WSAEWOULDBLOCK)
#	define MKDIR(p) _mkdir(p)
#	define RMDIR(p) _rmdir(p)
#	define SEND_FLAGS 0
#else
typedef int sock_t;
#	define SOCK_BAD (-1)
#	define sock_close close
#	define net_poll(f, n, t) poll((f), (nfds_t)(n), (t))
#	define sock_would_block() (errno == EAGAIN || errno == EWOULDBLOCK)
#	define MKDIR(p) mkdir((p), 0755)
#	define RMDIR(p) rmdir(p)
#	ifdef MSG_NOSIGNAL
#		define SEND_FLAGS MSG_NOSIGNAL
#	else
#		define SEND_FLAGS 0
#	endif
#endif

static uint64_t now_ms(void) {
#ifdef _WIN32
	return (uint64_t)GetTickCount64();
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
#endif
}

/* Time since t. Timestamps taken inside a handler can be newer than the
 * loop's cached `now`; plain unsigned subtraction would wrap to "ages ago". */
static uint64_t elapsed(uint64_t now, uint64_t t) { return now > t ? now - t : 0; }

static bool set_nonblocking(sock_t s) {
#ifdef _WIN32
	u_long on = 1;
	return ioctlsocket(s, FIONBIO, &on) == 0;
#else
	int fl = fcntl(s, F_GETFL, 0);
	return fl >= 0 && fcntl(s, F_SETFL, fl | O_NONBLOCK) == 0;
#endif
}

/* Atomic replace. POSIX rename() already replaces; Windows needs the flag. */
static bool file_replace(const char *src, const char *dst) {
#ifdef _WIN32
	return MoveFileExA(src, dst, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
	return rename(src, dst) == 0;
#endif
}

static volatile sig_atomic_t g_stop = 0;
static void on_signal(int sig) {
	(void)sig;
	g_stop = 1;
}

/* ----------------------------------------------------------------- memory */

static void *xrealloc(void *p, size_t n) {
	void *q = realloc(p, n ? n : 1);
	if (!q) {
		fprintf(stderr, "uncreate-server: out of memory (%zu bytes)\n", n);
		abort();
	}
	return q;
}

/* Growable byte buffer. Owns p; buf_free releases it. */
typedef struct {
	char *p;
	size_t len, cap;
} Buf;

static void buf_reserve(Buf *b, size_t extra) {
	if (extra > SIZE_MAX - b->len) abort();
	size_t need = b->len + extra;
	if (need <= b->cap) return;
	size_t cap = b->cap ? b->cap : 256;
	while (cap < need) cap = cap > SIZE_MAX / 2 ? need : cap * 2;
	b->p = xrealloc(b->p, cap);
	b->cap = cap;
}
static void buf_put(Buf *b, const void *d, size_t n) {
	if (!n) return;
	buf_reserve(b, n);
	memcpy(b->p + b->len, d, n);
	b->len += n;
}
static void buf_puts(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }
#if defined(__MINGW32__)
__attribute__((format(gnu_printf, 2, 3)))
#elif defined(__GNUC__)
__attribute__((format(printf, 2, 3)))
#endif
static void buf_printf(Buf *b, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	char tmp[256];
	int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if ((size_t)n < sizeof tmp) {
		buf_put(b, tmp, (size_t)n);
		return;
	}
	buf_reserve(b, (size_t)n + 1);
	va_start(ap, fmt);
	vsnprintf(b->p + b->len, (size_t)n + 1, fmt, ap);
	va_end(ap);
	b->len += (size_t)n;
}
static void buf_consume(Buf *b, size_t n) {
	if (n >= b->len) {
		b->len = 0;
		return;
	}
	memmove(b->p, b->p + n, b->len - n);
	b->len -= n;
}
static void buf_free(Buf *b) {
	free(b->p);
	*b = (Buf){0};
}

/* JSON string body (no quotes). Input is UTF-8 already validated by caller. */
static void buf_json_str(Buf *b, const char *s) {
	for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
		if (*p == '"' || *p == '\\') {
			buf_put(b, "\\", 1);
			buf_put(b, p, 1);
		} else if (*p < 0x20) {
			buf_printf(b, "\\u%04x", *p);
		} else {
			buf_put(b, p, 1);
		}
	}
}

static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static void buf_base64(Buf *b, const unsigned char *d, size_t n) {
	buf_reserve(b, (n + 2) / 3 * 4);
	char *o = b->p + b->len;
	size_t i = 0;
	for (; i + 3 <= n; i += 3) {
		uint32_t v = (uint32_t)d[i] << 16 | (uint32_t)d[i + 1] << 8 | d[i + 2];
		*o++ = B64[v >> 18 & 63], *o++ = B64[v >> 12 & 63];
		*o++ = B64[v >> 6 & 63], *o++ = B64[v & 63];
	}
	if (i < n) {
		uint32_t v = (uint32_t)d[i] << 16 | (i + 1 < n ? (uint32_t)d[i + 1] << 8 : 0u);
		*o++ = B64[v >> 18 & 63], *o++ = B64[v >> 12 & 63];
		*o++ = i + 1 < n ? B64[v >> 6 & 63] : '=';
		*o++ = '=';
	}
	b->len = (size_t)(o - b->p);
}

/* ------------------------------------------------------------ file helpers */

static bool file_read_all(const char *path, Buf *out) {
	FILE *f = fopen(path, "rb");
	if (!f) return false;
	char tmp[1 << 16];
	size_t n;
	while ((n = fread(tmp, 1, sizeof tmp, f)) > 0) buf_put(out, tmp, n);
	bool ok = !ferror(f);
	fclose(f);
	return ok;
}

/* Writes path.tmp then renames over path: readers never see half a file. */
static bool file_write_atomic(const char *path, const void *d, size_t n) {
	char tmp[600];
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	FILE *f = fopen(tmp, "wb");
	if (!f) return false;
	bool ok = fwrite(d, 1, n, f) == n;
	ok = (fclose(f) == 0) && ok;
	return ok && file_replace(tmp, path);
}

static bool file_exists(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f) return false;
	fclose(f);
	return true;
}

/* -------------------------------------------------------------- the model */

/* One op batch in the log. Payload bytes live in Server.blob at [off, off+len). */
typedef struct {
	uint64_t rev;
	uint64_t off;
	uint32_t len;
	uint32_t client;
} Batch;
static_assert(sizeof(Batch) == 24, "Batch is bulk storage: keep it 24 bytes");

typedef struct {
	uint64_t last_seen_ms;
	uint64_t acked; /* `since` of the client's latest poll: it has applied all <= acked */
	uint32_t id;    /* 0 = free slot */
	char name[MAX_NAME + 1];
	char cam[MAX_CAM + 1]; /* latest camera as a JSON number array, "" = unknown */
	uint64_t cam_ms;       /* when cam was last refreshed */
} Client;

typedef struct {
	char dir[400];
	char name[MAX_NAME + 1]; /* project name shown in the plugin: the data folder's name */
	char key[128];

	uint64_t rev;       /* last assigned revision                          */
	uint64_t snap_rev;  /* state the snapshot represents                   */
	uint64_t log_start; /* batches with rev > log_start are retained       */
	uint32_t snap_chunks;
	bool has_snap;

	Batch *batches; /* sorted by rev, contiguous */
	size_t nbatches, capbatches;
	Buf blob;
	FILE *log_fp;

	Client clients[MAX_CLIENTS];
	uint32_t next_client_id;

	bool stage_active;
	uint32_t stage_token, stage_client, stage_parts;
	uint64_t stage_base, stage_started_ms;

	uint32_t want_client;
	uint64_t want_ms;
} Server;

static Server S;

static void path_join(char *out, size_t cap, const char *a) { snprintf(out, cap, "%s/%s", S.dir, a); }

static void snap_dir(char *out, size_t cap, uint64_t rev) {
	snprintf(out, cap, "%s/snap_%" PRIu64, S.dir, rev);
}

/* ------------------------------------------------------------ persistence */

/* meta.txt: tiny text file so a human can read it. Written atomically. */
static bool meta_save(void) {
	char path[600], text[256];
	path_join(path, sizeof path, "meta.txt");
	int n = snprintf(text, sizeof text,
		"uncreate 1\nsnap_rev %" PRIu64 "\nchunks %u\nlog_start %" PRIu64 "\nhas_snap %d\n",
		S.snap_rev, S.snap_chunks, S.log_start, S.has_snap ? 1 : 0);
	return file_write_atomic(path, text, (size_t)n);
}

static void meta_load(void) {
	char path[600];
	path_join(path, sizeof path, "meta.txt");
	FILE *f = fopen(path, "rb");
	if (!f) return;
	char magic[16] = "";
	unsigned long long snap = 0, start = 0;
	unsigned chunks = 0;
	int has = 0;
	/* "rbxsync" is the format tag written before the project was renamed. */
	if (fscanf(f, "%15s 1\nsnap_rev %llu\nchunks %u\nlog_start %llu\nhas_snap %d", magic, &snap, &chunks, &start,
		    &has) == 5 &&
		(!strcmp(magic, "uncreate") || !strcmp(magic, "rbxsync"))) {
		S.snap_rev = snap;
		S.snap_chunks = chunks;
		S.log_start = start;
		S.has_snap = has != 0;
	}
	fclose(f);
}

/* ops.log record: u64 rev | u32 client | u32 len | payload, little-endian. */
static void put_le(unsigned char *p, uint64_t v, int n) {
	for (int i = 0; i < n; i++) p[i] = (unsigned char)(v >> (8 * i));
}
static uint64_t get_le(const unsigned char *p, int n) {
	uint64_t v = 0;
	for (int i = n - 1; i >= 0; i--) v = v << 8 | p[i];
	return v;
}

static void batch_push(uint64_t rev, uint32_t client, const char *d, uint32_t len) {
	if (S.nbatches == S.capbatches) {
		S.capbatches = S.capbatches ? S.capbatches * 2 : 1024;
		S.batches = xrealloc(S.batches, S.capbatches * sizeof *S.batches);
	}
	S.batches[S.nbatches++] = (Batch){.rev = rev, .off = S.blob.len, .len = len, .client = client};
	buf_put(&S.blob, d, len);
}

static bool log_write_record(FILE *f, const Batch *b) {
	unsigned char h[16];
	put_le(h, b->rev, 8);
	put_le(h + 8, b->client, 4);
	put_le(h + 12, b->len, 4);
	return fwrite(h, 1, 16, f) == 16 && fwrite(S.blob.p + b->off, 1, b->len, f) == b->len;
}

/* Rewrites ops.log from memory (after compaction or a torn tail). */
static bool log_rewrite(void) {
	char path[600], tmp[620];
	path_join(path, sizeof path, "ops.log");
	snprintf(tmp, sizeof tmp, "%s.tmp", path);
	if (S.log_fp) fclose(S.log_fp), S.log_fp = NULL;
	FILE *f = fopen(tmp, "wb");
	bool ok = f != NULL;
	for (size_t i = 0; ok && i < S.nbatches; i++) ok = log_write_record(f, &S.batches[i]);
	if (f) ok = (fclose(f) == 0) && ok;
	ok = ok && file_replace(tmp, path);
	S.log_fp = fopen(path, "ab");
	return ok && S.log_fp;
}

static bool log_load(void) {
	char path[600];
	path_join(path, sizeof path, "ops.log");
	Buf raw = {0};
	bool torn = false;
	if (file_read_all(path, &raw)) {
		size_t p = 0;
		while (p + 16 <= raw.len) {
			const unsigned char *h = (const unsigned char *)raw.p + p;
			uint64_t rev = get_le(h, 8);
			uint32_t client = (uint32_t)get_le(h + 8, 4);
			uint32_t len = (uint32_t)get_le(h + 12, 4);
			if (len > raw.len - p - 16) break;
			bool ordered = S.nbatches == 0 || rev > S.batches[S.nbatches - 1].rev;
			if (!ordered) break;
			if (rev > S.log_start) batch_push(rev, client, raw.p + p + 16, len);
			/* Ids must never repeat an author still in the log, or a new
			 * client would mistake those batches for its own and skip them. */
			if (client > S.next_client_id) S.next_client_id = client;
			if (rev > S.rev) S.rev = rev;
			p += 16 + (size_t)len;
		}
		torn = p != raw.len;
	}
	buf_free(&raw);
	if (S.snap_rev > S.rev) S.rev = S.snap_rev;
	if (S.log_start > S.rev) S.rev = S.log_start;
	if (torn) {
		fprintf(stderr, "uncreate-server: ops.log had a torn tail; truncating to %zu batches\n", S.nbatches);
		return log_rewrite();
	}
	S.log_fp = fopen(path, "ab");
	return S.log_fp != NULL;
}

/* Appends one batch to memory and disk. The fflush is the durability point. */
static uint64_t log_append(uint32_t client, const char *d, size_t len) {
	if (len > UINT32_MAX) return 0;
	uint64_t rev = ++S.rev;
	batch_push(rev, client, d, (uint32_t)len);
	if (!S.log_fp || !log_write_record(S.log_fp, &S.batches[S.nbatches - 1]) || fflush(S.log_fp) != 0)
		fprintf(stderr, "uncreate-server: WARNING: failed to persist rev %" PRIu64 "\n", rev);
	return rev;
}

/* Drops batches with rev <= upto and repacks the blob. */
static void log_truncate(uint64_t upto) {
	size_t first = 0;
	while (first < S.nbatches && S.batches[first].rev <= upto) first++;
	if (first == 0) return;
	Buf nb = {0};
	size_t n = S.nbatches - first;
	for (size_t i = 0; i < n; i++) {
		Batch b = S.batches[first + i];
		uint64_t off = nb.len;
		buf_put(&nb, S.blob.p + b.off, b.len);
		b.off = off;
		S.batches[i] = b;
	}
	S.nbatches = n;
	buf_free(&S.blob);
	S.blob = nb;
	if (!log_rewrite()) fprintf(stderr, "uncreate-server: WARNING: ops.log rewrite failed\n");
}

/* Index of the first batch with rev > since (binary search). */
static size_t batch_after(uint64_t since) {
	size_t lo = 0, hi = S.nbatches;
	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;
		if (S.batches[mid].rev <= since) lo = mid + 1;
		else hi = mid;
	}
	return lo;
}

/* ---------------------------------------------------------------- clients */

static Client *client_find(uint32_t id) {
	if (!id) return NULL;
	for (int i = 0; i < MAX_CLIENTS; i++)
		if (S.clients[i].id == id) return &S.clients[i];
	return NULL;
}

/* Returns true when someone was dropped (presence changed). */
static bool clients_prune(uint64_t now) {
	bool changed = false;
	for (int i = 0; i < MAX_CLIENTS; i++) {
		Client *c = &S.clients[i];
		if (c->id && elapsed(now, c->last_seen_ms) > CLIENT_TTL_MS) {
			printf("[-] %s (#%u) left\n", c->name, c->id);
			c->id = 0;
			changed = true;
		}
	}
	return changed;
}

/* Keeps printable ASCII and well-formed UTF-8 multibyte runs (Cyrillic,
 * Vietnamese); anything else becomes '?'. Output is always valid UTF-8. */
static void sanitize_name(char *dst, const char *src) {
	size_t o = 0;
	const unsigned char *p = (const unsigned char *)src;
	while (*p && o < MAX_NAME) {
		unsigned c = *p;
		size_t n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 0;
		bool ok = n > 0 && (n > 1 || (c >= 0x20 && c != 0x7f));
		for (size_t k = 1; ok && k < n; k++) ok = (p[k] & 0xC0) == 0x80;
		if (!ok || o + n > MAX_NAME) {
			dst[o++] = '?';
			p++;
			continue;
		}
		memcpy(dst + o, p, n);
		o += n, p += n;
	}
	dst[o] = 0;
	if (!o) strcpy(dst, "anon");
}

/* ------------------------------------------------------------------- http */

typedef enum { C_FREE = 0, C_READ, C_PARKED, C_WRITE } ConnState;

typedef struct {
	sock_t fd;
	ConnState st;
	bool close_after;
	bool sent_continue;
	Buf in, out;
	size_t out_off;
	size_t req_len;  /* bytes of `in` that belong to the request being served */
	size_t req_need; /* known total size of a request whose body is still arriving */
	uint64_t deadline_ms;
	uint32_t poll_client;
	uint64_t poll_since;
} Conn;

static Conn g_conns[MAX_CONNS];

typedef struct {
	char head[MAX_HEAD + 1]; /* private copy of the request head, split in place */
	char method[8];
	char path[128];
	const char *query; /* points into head */
	const char *body;
	size_t body_len;
	bool key_ok;
	bool keep_alive;
	bool expect_continue;
} Req;

static int hexval(int c) {
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* Finds `name` in a query string and URL-decodes it into out (NUL-terminated). */
static bool q_get(const char *q, const char *name, char *out, size_t cap) {
	size_t nl = strlen(name);
	for (const char *p = q; p && *p;) {
		const char *amp = strchr(p, '&');
		const char *end = amp ? amp : p + strlen(p);
		if ((size_t)(end - p) > nl && !strncmp(p, name, nl) && p[nl] == '=') {
			size_t o = 0;
			for (const char *s = p + nl + 1; s < end && o + 1 < cap; s++) {
				int h1, h2;
				if (*s == '%' && s + 2 < end && (h1 = hexval(s[1])) >= 0 && (h2 = hexval(s[2])) >= 0) {
					out[o++] = (char)(h1 << 4 | h2);
					s += 2;
				} else out[o++] = *s == '+' ? ' ' : *s;
			}
			out[o] = 0;
			return true;
		}
		p = amp ? amp + 1 : NULL;
	}
	return false;
}

static bool q_u64(const char *q, const char *name, uint64_t *out) {
	char tmp[32];
	if (!q_get(q, name, tmp, sizeof tmp) || !tmp[0]) return false;
	char *end;
	unsigned long long v = strtoull(tmp, &end, 10);
	if (*end) return false;
	*out = v;
	return true;
}

static bool ieq_prefix(const char *line, const char *name) {
	for (; *name; line++, name++) {
		char a = *line, b = *name;
		if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
		if (a != b) return false;
	}
	return *line == ':';
}

static bool const_time_eq(const char *a, const char *b) {
	size_t la = strlen(a), lb = strlen(b);
	unsigned diff = (unsigned)(la ^ lb);
	for (size_t i = 0; i < la && i < lb; i++) diff |= (unsigned)(a[i] ^ b[i]);
	return diff == 0;
}

static const char *status_text(int code) {
	switch (code) {
	case 200: return "OK";
	case 400: return "Bad Request";
	case 401: return "Unauthorized";
	case 404: return "Not Found";
	case 409: return "Conflict";
	case 411: return "Length Required";
	case 413: return "Payload Too Large";
	case 500: return "Internal Server Error";
	default: return "Error";
	}
}

/* Queues a reply. A parked poll's request bytes stay in `in` while it waits;
 * they are released here, when its reply is finally queued. The main loop
 * sends every queued reply at the end of its iteration. */
static void conn_respond(Conn *c, int code, const char *ctype, const char *body, size_t len) {
	if (c->st == C_PARKED) {
		buf_consume(&c->in, c->req_len);
		c->req_len = 0;
	}
	c->deadline_ms = now_ms() + WRITE_TTL_MS;
	buf_printf(&c->out,
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-store\r\n"
		"Connection: %s\r\n\r\n",
		code, status_text(code), ctype, len, c->close_after ? "close" : "keep-alive");
	buf_put(&c->out, body, len);
	c->st = C_WRITE;
}

static void conn_json(Conn *c, int code, const Buf *b) { conn_respond(c, code, "application/json", b->p, b->len); }

static void conn_error(Conn *c, int code, const char *msg) {
	Buf b = {0};
	buf_puts(&b, "{\"error\":\"");
	buf_json_str(&b, msg);
	buf_puts(&b, "\"}");
	conn_json(c, code, &b);
	buf_free(&b);
}

/* ------------------------------------------------------------- handlers */

static void peers_json(Buf *b) {
	buf_puts(b, "[");
	bool first = true;
	for (int i = 0; i < MAX_CLIENTS; i++) {
		const Client *cl = &S.clients[i];
		if (!cl->id) continue;
		buf_printf(b, "%s{\"id\":%u,\"name\":\"", first ? "" : ",", cl->id);
		buf_json_str(b, cl->name);
		buf_puts(b, "\"");
		if (cl->cam[0] && elapsed(now_ms(), cl->cam_ms) <= CAM_TTL_MS) {
			buf_puts(b, ",\"cam\":");
			buf_puts(b, cl->cam); /* validated as a numeric array on the way in */
		}
		buf_puts(b, "}");
		first = false;
	}
	buf_puts(b, "]");
}

static bool log_wants_snapshot(void) {
	return S.nbatches >= SNAP_WANT_BATCHES || S.blob.len >= SNAP_WANT_BYTES;
}

/* Is a snapshot request free to hand to a caught-up client right now? At
 * most one client holds it, and it is told once per WANT_RETRY_MS (telling
 * it on every poll would turn its long-poll into a busy loop). */
static bool want_available(uint64_t since, uint64_t now) {
	if (since != S.rev || S.stage_active || !log_wants_snapshot()) return false;
	return S.want_client == 0 || elapsed(now, S.want_ms) > WANT_RETRY_MS || !client_find(S.want_client);
}

static bool want_take(uint32_t client_id, uint64_t since, uint64_t now) {
	if (!want_available(since, now)) return false;
	S.want_client = client_id;
	S.want_ms = now;
	return true;
}

/* Builds the poll reply for a client that has applied everything <= since. */
static void poll_reply(Conn *c, uint32_t client_id, uint64_t since) {
	Buf b = {0};
	if (since < S.log_start || since > S.rev) {
		buf_printf(&b, "{\"resync\":true,\"rev\":%" PRIu64 "}", S.rev);
		conn_json(c, 200, &b);
		buf_free(&b);
		return;
	}
	bool want = want_take(client_id, since, now_ms());
	buf_printf(&b, "{\"rev\":%" PRIu64 ",\"snapRev\":%" PRIu64 ",\"want\":%s,\"peers\":", S.rev, S.snap_rev,
		want ? "true" : "false");
	peers_json(&b);
	buf_puts(&b, ",\"b\":[");
	/* A client's own batches are not echoed back (it already has them);
	 * `upto` tells it how far this reply covers the log. */
	size_t bytes = 0;
	bool more = false, first = true;
	uint64_t upto = since;
	for (size_t i = batch_after(since); i < S.nbatches; i++) {
		const Batch *bt = &S.batches[i];
		if (bt->client == client_id) {
			upto = bt->rev;
			continue;
		}
		if (bytes && bytes + bt->len > POLL_MAX_BYTES) {
			more = true;
			break;
		}
		buf_printf(&b, "%s{\"r\":%" PRIu64 ",\"c\":%u,\"o\":", first ? "" : ",", bt->rev, bt->client);
		buf_put(&b, S.blob.p + bt->off, bt->len);
		buf_puts(&b, "}");
		bytes += bt->len + 1; /* +1 so empty payloads still count as "something sent" */
		upto = bt->rev;
		first = false;
	}
	buf_printf(&b, "],\"upto\":%" PRIu64 ",\"more\":%s}", upto, more ? "true" : "false");
	conn_json(c, 200, &b);
	buf_free(&b);
}

/* Answers parked polls: those with something newer than their rev, or all
 * of them when `everyone` (presence changed and peer lists must refresh). */
static void wake_parked_ex(bool everyone) {
	for (int i = 0; i < MAX_CONNS; i++) {
		Conn *c = &g_conns[i];
		if (c->st == C_PARKED && (everyone || c->poll_since < S.rev)) poll_reply(c, c->poll_client, c->poll_since);
	}
}
static void wake_parked(void) { wake_parked_ex(false); }

static void h_hello(Conn *c, const Req *r) {
	char raw[128] = "";
	q_get(r->query, "name", raw, sizeof raw);
	Client *slot = NULL;
	for (int i = 0; i < MAX_CLIENTS && !slot; i++)
		if (!S.clients[i].id) slot = &S.clients[i];
	if (!slot) {
		conn_error(c, 409, "server full");
		return;
	}
	/* A joiner loads the current snapshot, so it never needs batches at or
	 * below snap_rev: that is a safe compaction floor until it first polls. */
	*slot = (Client){.id = ++S.next_client_id, .last_seen_ms = now_ms(), .acked = S.has_snap ? S.snap_rev : S.log_start};
	sanitize_name(slot->name, raw);
	printf("[+] %s (#%u) joined\n", slot->name, slot->id);
	Buf b = {0};
	buf_printf(&b,
		"{\"proto\":1,\"client\":%u,\"rev\":%" PRIu64 ",\"snapRev\":%" PRIu64 ",\"logStart\":%" PRIu64
		",\"hasSnap\":%s,\"project\":\"",
		slot->id, S.rev, S.snap_rev, S.log_start, S.has_snap ? "true" : "false");
	buf_json_str(&b, S.name);
	buf_puts(&b, "\"}");
	conn_json(c, 200, &b);
	buf_free(&b);
	wake_parked_ex(true); /* everyone's peer list now includes the newcomer */
}

/* A client leaving on purpose: drop it now instead of after CLIENT_TTL_MS,
 * so its head disappears from everyone's viewport at once. */
static void h_bye(Conn *c, const Req *r) {
	uint64_t id = 0;
	Client *cl = q_u64(r->query, "client", &id) ? client_find((uint32_t)id) : NULL;
	if (cl) {
		printf("[-] %s (#%u) left\n", cl->name, cl->id);
		cl->id = 0;
		/* Its parked poll gets an empty reply rather than lingering. */
		for (int i = 0; i < MAX_CONNS; i++)
			if (g_conns[i].st == C_PARKED && g_conns[i].poll_client == (uint32_t)id)
				poll_reply(&g_conns[i], (uint32_t)id, g_conns[i].poll_since);
	}
	conn_respond(c, 200, "application/json", "{}", 2);
	wake_parked_ex(true);
}

static void h_poll(Conn *c, const Req *r) {
	uint64_t id = 0, since = 0, wait = 20;
	if (!q_u64(r->query, "client", &id) || !q_u64(r->query, "since", &since)) {
		conn_error(c, 400, "client and since required");
		return;
	}
	q_u64(r->query, "wait", &wait);
	Client *cl = client_find((uint32_t)id);
	if (!cl) {
		conn_error(c, 409, "unknown client");
		return;
	}
	cl->last_seen_ms = now_ms();
	cl->acked = since;
	/* Answer now if there is news or a snapshot request; otherwise park. */
	if (since != S.rev || wait == 0 || want_available(since, now_ms())) {
		poll_reply(c, cl->id, since);
		return;
	}
	if (wait > POLL_MAX_WAIT_S) wait = POLL_MAX_WAIT_S;
	c->st = C_PARKED;
	c->poll_client = cl->id;
	c->poll_since = since;
	c->deadline_ms = now_ms() + wait * 1000u;
}

static bool payload_is_array(const char *d, size_t n) {
	while (n && (*d == ' ' || *d == '\n' || *d == '\r' || *d == '\t')) d++, n--;
	while (n && (d[n - 1] == ' ' || d[n - 1] == '\n' || d[n - 1] == '\r' || d[n - 1] == '\t')) n--;
	return n >= 2 && d[0] == '[' && d[n - 1] == ']';
}

static void h_ops(Conn *c, const Req *r) {
	uint64_t id = 0;
	Client *cl = q_u64(r->query, "client", &id) ? client_find((uint32_t)id) : NULL;
	if (!cl) {
		conn_error(c, 409, "unknown client");
		return;
	}
	if (!payload_is_array(r->body, r->body_len)) {
		conn_error(c, 400, "body must be a JSON array of ops");
		return;
	}
	cl->last_seen_ms = now_ms();
	uint64_t rev = log_append(cl->id, r->body, r->body_len);
	Buf b = {0};
	buf_printf(&b, "{\"rev\":%" PRIu64 "}", rev);
	conn_json(c, 200, &b);
	buf_free(&b);
	wake_parked();
}

/* Raw .rbxm upload (curl --data-binary). Becomes one unstamped "new" op;
 * clients stamp its instances deterministically from the batch rev. */
/* A camera is a flat JSON array of numbers; anything else is refused, so it
 * can be spliced into replies verbatim. */
static bool cam_valid(const char *d, size_t n) {
	if (n < 2 || n > MAX_CAM || d[0] != '[' || d[n - 1] != ']') return false;
	for (size_t i = 1; i + 1 < n; i++) {
		char ch = d[i];
		bool ok = (ch >= '0' && ch <= '9') || ch == '-' || ch == '+' || ch == '.' || ch == ',' || ch == 'e' ||
			ch == 'E' || ch == ' ';
		if (!ok) return false;
	}
	return true;
}

/* Stores the caller's camera and answers with everyone's: one request does
 * both directions, so presence costs each client one call per tick. */
static void h_presence(Conn *c, const Req *r) {
	uint64_t id = 0;
	Client *cl = q_u64(r->query, "client", &id) ? client_find((uint32_t)id) : NULL;
	if (!cl) {
		conn_error(c, 409, "unknown client");
		return;
	}
	cl->last_seen_ms = now_ms();
	if (r->body_len == 0) cl->cam[0] = 0;
	else if (cam_valid(r->body, r->body_len)) {
		memcpy(cl->cam, r->body, r->body_len);
		cl->cam[r->body_len] = 0;
		cl->cam_ms = cl->last_seen_ms;
	}
	Buf b = {0};
	buf_puts(&b, "{\"peers\":");
	peers_json(&b);
	buf_puts(&b, "}");
	conn_json(c, 200, &b);
	buf_free(&b);
}

static void h_import(Conn *c, const Req *r) {
	char into[48] = "Workspace";
	q_get(r->query, "into", into, sizeof into);
	bool ok = into[0] != 0;
	for (const char *p = into; *p && ok; p++)
		ok = (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z');
	if (!ok || r->body_len < 8 || memcmp(r->body, "<roblox!", 8) != 0) {
		conn_error(c, 400, "need ?into=ServiceName and a binary .rbxm body");
		return;
	}
	Buf p = {0};
	buf_puts(&p, "[{\"t\":\"new\",\"p\":\"@");
	buf_puts(&p, into);
	buf_puts(&p, "\",\"b\":\"");
	buf_base64(&p, (const unsigned char *)r->body, r->body_len);
	buf_puts(&p, "\"}]");
	uint64_t rev = log_append(0, p.p, p.len);
	buf_free(&p);
	printf("[i] imported %zu bytes into %s as rev %" PRIu64 "\n", r->body_len, into, rev);
	Buf b = {0};
	buf_printf(&b, "{\"rev\":%" PRIu64 "}", rev);
	conn_json(c, 200, &b);
	buf_free(&b);
	wake_parked();
}

static void h_snap_manifest(Conn *c) {
	if (!S.has_snap) {
		conn_error(c, 404, "no snapshot");
		return;
	}
	char dir[520], path[600];
	snap_dir(dir, sizeof dir, S.snap_rev);
	snprintf(path, sizeof path, "%s/manifest.json", dir);
	Buf b = {0};
	buf_printf(&b, "{\"snapRev\":%" PRIu64 ",\"chunks\":%u,\"manifest\":", S.snap_rev, S.snap_chunks);
	if (!file_read_all(path, &b)) {
		buf_free(&b);
		conn_error(c, 500, "manifest unreadable");
		return;
	}
	buf_puts(&b, "}");
	conn_json(c, 200, &b);
	buf_free(&b);
}

static void h_snap_chunk(Conn *c, const Req *r) {
	uint64_t i = 0, rev = 0;
	if (q_u64(r->query, "rev", &rev) && rev != S.snap_rev) {
		conn_error(c, 409, "snapshot changed, restart join");
		return;
	}
	if (!S.has_snap || !q_u64(r->query, "i", &i) || i >= S.snap_chunks) {
		conn_error(c, 404, "no such chunk");
		return;
	}
	char dir[520], path[600];
	snap_dir(dir, sizeof dir, S.snap_rev);
	snprintf(path, sizeof path, "%s/%" PRIu64 ".b64", dir, i);
	Buf b = {0};
	if (!file_read_all(path, &b)) conn_error(c, 500, "chunk unreadable");
	else conn_respond(c, 200, "text/plain", b.p, b.len);
	buf_free(&b);
}

/* Deletes snap_<rev>/ with its `chunks` parts and manifest. */
static void snap_remove(uint64_t rev, uint32_t chunks) {
	char dir[520], path[600];
	snap_dir(dir, sizeof dir, rev);
	for (uint32_t i = 0; i < chunks; i++) {
		snprintf(path, sizeof path, "%s/%u.b64", dir, i);
		remove(path);
	}
	snprintf(path, sizeof path, "%s/manifest.json", dir);
	remove(path);
	RMDIR(dir);
}

static void stage_clear(void) {
	char dir[600], path[640];
	path_join(dir, sizeof dir, "stage");
	for (uint32_t i = 0; i < S.stage_parts; i++) {
		snprintf(path, sizeof path, "%s/%u.b64", dir, i);
		remove(path);
	}
	snprintf(path, sizeof path, "%s/manifest.json", dir);
	remove(path);
	S.stage_active = false;
	S.stage_parts = 0;
}

static void h_snap_begin(Conn *c, const Req *r) {
	uint64_t id = 0, base = 0;
	Client *cl = q_u64(r->query, "client", &id) ? client_find((uint32_t)id) : NULL;
	if (!cl || !q_u64(r->query, "base", &base)) {
		conn_error(c, 400, "client and base required");
		return;
	}
	if (base > S.rev || base < S.log_start) {
		conn_error(c, 409, "base rev out of range");
		return;
	}
	if (S.has_snap && base <= S.snap_rev) {
		conn_error(c, 409, "snapshot is already current");
		return;
	}
	uint64_t now = now_ms();
	if (S.stage_active && S.stage_client != cl->id && elapsed(now, S.stage_started_ms) < STAGE_TTL_MS) {
		conn_error(c, 409, "another snapshot upload is in progress");
		return;
	}
	stage_clear();
	char dir[600];
	path_join(dir, sizeof dir, "stage");
	MKDIR(dir);
	S.stage_active = true;
	S.stage_client = cl->id;
	S.stage_base = base;
	S.stage_started_ms = now;
	/* Not a secret (the key is); it only fences off a stale uploader. */
	static uint32_t seq = 0;
	S.stage_token = (uint32_t)(now * 2654435761u) ^ (++seq << 16) ^ cl->id;
	if (!S.stage_token) S.stage_token = 1;
	Buf b = {0};
	buf_printf(&b, "{\"token\":%u}", S.stage_token);
	conn_json(c, 200, &b);
	buf_free(&b);
}

static bool stage_token_ok(const Req *r) {
	uint64_t t = 0;
	return S.stage_active && q_u64(r->query, "token", &t) && t == S.stage_token;
}

static void h_snap_part(Conn *c, const Req *r) {
	uint64_t i = 0;
	if (!stage_token_ok(r) || !q_u64(r->query, "i", &i) || i >= MAX_CHUNKS) {
		conn_error(c, 409, "bad token or index");
		return;
	}
	char dir[600], path[640];
	path_join(dir, sizeof dir, "stage");
	snprintf(path, sizeof path, "%s/%" PRIu64 ".b64", dir, i);
	if (!file_write_atomic(path, r->body, r->body_len)) {
		conn_error(c, 500, "write failed");
		return;
	}
	if (i + 1 > S.stage_parts) S.stage_parts = (uint32_t)(i + 1);
	S.stage_started_ms = now_ms(); /* a live upload keeps its lease */
	conn_respond(c, 200, "application/json", "{}", 2);
}

static void h_snap_commit(Conn *c, const Req *r) {
	uint64_t chunks = 0;
	if (!stage_token_ok(r) || !q_u64(r->query, "chunks", &chunks) || chunks > MAX_CHUNKS) {
		conn_error(c, 409, "bad token");
		return;
	}
	if (!payload_is_array(r->body, r->body_len) && !(r->body_len && r->body[0] == '{')) {
		conn_error(c, 400, "manifest must be JSON");
		return;
	}
	char stage[600], path[640];
	path_join(stage, sizeof stage, "stage");
	for (uint64_t i = 0; i < chunks; i++) {
		snprintf(path, sizeof path, "%s/%" PRIu64 ".b64", stage, i);
		if (!file_exists(path)) {
			conn_error(c, 409, "missing chunk");
			return;
		}
	}
	snprintf(path, sizeof path, "%s/manifest.json", stage);
	if (!file_write_atomic(path, r->body, r->body_len)) {
		conn_error(c, 500, "write failed");
		return;
	}

	/* Promote: rename stage -> snap_<base>, flip meta, then delete the old
	 * snapshot. A crash at any point leaves meta pointing at a complete dir. */
	uint64_t base = S.stage_base, old_rev = S.snap_rev;
	uint32_t old_chunks = S.snap_chunks;
	bool had = S.has_snap;
	char ndir[520];
	snap_dir(ndir, sizeof ndir, base);
	if (rename(stage, ndir) != 0) {
		conn_error(c, 500, "promote failed");
		return;
	}
	S.stage_active = false;
	S.stage_parts = 0;
	S.snap_rev = base;
	S.snap_chunks = (uint32_t)chunks;
	S.has_snap = true;

	/* Never drop batches an active client has not applied yet. */
	uint64_t cut = base;
	for (int i = 0; i < MAX_CLIENTS; i++)
		if (S.clients[i].id && S.clients[i].acked < cut) cut = S.clients[i].acked;
	if (cut < S.log_start) cut = S.log_start;
	S.log_start = cut;
	if (!meta_save()) fprintf(stderr, "uncreate-server: WARNING: meta.txt write failed\n");
	log_truncate(cut);

	if (had) snap_remove(old_rev, old_chunks);
	S.want_client = 0;
	printf("[s] snapshot @%" PRIu64 " (%" PRIu64 " chunks), log keeps %zu batches\n", base, chunks, S.nbatches);
	Buf b = {0};
	buf_printf(&b, "{\"snapRev\":%" PRIu64 "}", base);
	conn_json(c, 200, &b);
	buf_free(&b);
}

static void h_status(Conn *c) {
	Buf b = {0};
	buf_printf(&b,
		"{\"rev\":%" PRIu64 ",\"snapRev\":%" PRIu64 ",\"hasSnap\":%s,\"logStart\":%" PRIu64
		",\"batches\":%zu,\"logBytes\":%zu,\"peers\":",
		S.rev, S.snap_rev, S.has_snap ? "true" : "false", S.log_start, S.nbatches, S.blob.len);
	peers_json(&b);
	buf_puts(&b, "}");
	conn_json(c, 200, &b);
	buf_free(&b);
}

static void dispatch(Conn *c, const Req *r) {
	bool get = !strcmp(r->method, "GET"), post = !strcmp(r->method, "POST");
	if (get && !strcmp(r->path, "/")) {
		static const char hi[] = "uncreate-server ok\n";
		conn_respond(c, 200, "text/plain", hi, sizeof hi - 1);
		return;
	}
	if (!r->key_ok) {
		conn_error(c, 401, "bad key");
		return;
	}
	if (post && !strcmp(r->path, "/hello")) h_hello(c, r);
	else if (get && !strcmp(r->path, "/poll")) h_poll(c, r);
	else if (post && !strcmp(r->path, "/ops")) h_ops(c, r);
	else if (post && !strcmp(r->path, "/presence")) h_presence(c, r);
	else if (post && !strcmp(r->path, "/bye")) h_bye(c, r);
	else if (post && !strcmp(r->path, "/import")) h_import(c, r);
	else if (get && !strcmp(r->path, "/snap/manifest")) h_snap_manifest(c);
	else if (get && !strcmp(r->path, "/snap/chunk")) h_snap_chunk(c, r);
	else if (post && !strcmp(r->path, "/snap/begin")) h_snap_begin(c, r);
	else if (post && !strcmp(r->path, "/snap/part")) h_snap_part(c, r);
	else if (post && !strcmp(r->path, "/snap/commit")) h_snap_commit(c, r);
	else if (get && !strcmp(r->path, "/status")) h_status(c);
	else conn_error(c, 404, "no such endpoint");
}

/* ------------------------------------------------------------ connection io */

static void conn_close(Conn *c) {
	if (c->st == C_FREE) return;
	sock_close(c->fd);
	buf_free(&c->in);
	buf_free(&c->out);
	*c = (Conn){.fd = SOCK_BAD};
}

/* Parses the head in c->in. Returns 1 when a full request is ready, 0 when
 * more bytes are needed, -1 after queueing an error response. The head is
 * copied into r->head and split there, so c->in is never modified and the
 * parse can simply be repeated as more body bytes arrive. */
static int conn_parse(Conn *c, Req *r) {
	if (c->req_need && c->in.len < c->req_need) return 0; /* body still arriving */
	size_t scan = c->in.len < MAX_HEAD ? c->in.len : MAX_HEAD;
	size_t head_len = 0;
	for (size_t i = 3; i < scan; i++)
		if (!memcmp(c->in.p + i - 3, "\r\n\r\n", 4)) {
			head_len = i + 1;
			break;
		}
	if (!head_len) {
		if (c->in.len >= MAX_HEAD) {
			c->close_after = true;
			conn_error(c, 413, "header too large");
			return -1;
		}
		return 0;
	}
	r->method[0] = r->path[0] = 0;
	r->query = "";
	r->body = NULL;
	r->body_len = 0;
	r->key_ok = false;
	r->keep_alive = true;
	r->expect_continue = false;
	memcpy(r->head, c->in.p, head_len - 4);
	r->head[head_len - 4] = 0;

	/* Request line: METHOD SP TARGET SP VERSION */
	char *line = r->head, *eol = strstr(line, "\r\n");
	if (eol) *eol = 0;
	char *sp1 = strchr(line, ' ');
	char *target = sp1 ? sp1 + 1 : NULL;
	char *sp2 = target ? strchr(target, ' ') : NULL;
	if (!sp1 || !sp2 || (size_t)(sp1 - line) >= sizeof r->method) {
		c->close_after = true;
		conn_error(c, 400, "bad request line");
		return -1;
	}
	*sp1 = *sp2 = 0;
	memcpy(r->method, line, (size_t)(sp1 - line) + 1);
	/* Absolute-form target (sent through proxies, RFC 9112 3.2.2):
	 * "http://host:port/path?q" -> "/path?q". */
	if (!strncmp(target, "http://", 7) || !strncmp(target, "https://", 8)) {
		char *slash = strchr(strstr(target, "//") + 2, '/');
		target = slash ? slash : (char *)"/";
	}
	char *qm = strchr(target, '?');
	if (qm) *qm = 0, r->query = qm + 1;
	snprintf(r->path, sizeof r->path, "%s", target);

	size_t content_length = 0;
	bool chunked = false;
	char hdr_key[128] = "";
	for (char *h = eol ? eol + 2 : NULL; h && *h;) {
		char *e = strstr(h, "\r\n");
		if (e) *e = 0;
		const char *v = strchr(h, ':');
		if (v) {
			v++;
			while (*v == ' ' || *v == '\t') v++;
			if (ieq_prefix(h, "content-length")) content_length = (size_t)strtoull(v, NULL, 10);
			else if (ieq_prefix(h, "transfer-encoding")) chunked = true;
			else if (ieq_prefix(h, "x-key")) snprintf(hdr_key, sizeof hdr_key, "%s", v);
			else if (ieq_prefix(h, "connection")) r->keep_alive = !(v[0] == 'c' || v[0] == 'C');
			else if (ieq_prefix(h, "expect")) r->expect_continue = true;
		}
		h = e ? e + 2 : NULL;
	}
	if (chunked) {
		c->close_after = true;
		conn_error(c, 411, "chunked bodies are not supported");
		return -1;
	}
	if (content_length > MAX_BODY) {
		c->close_after = true;
		conn_error(c, 413, "body too large");
		return -1;
	}
	if (S.key[0]) {
		char qkey[128] = "";
		q_get(r->query, "key", qkey, sizeof qkey);
		r->key_ok = const_time_eq(hdr_key, S.key) || const_time_eq(qkey, S.key);
	} else r->key_ok = true;

	if (c->in.len - head_len < content_length) {
		if (r->expect_continue && !c->sent_continue) {
			static const char cont[] = "HTTP/1.1 100 Continue\r\n\r\n";
			(void)send(c->fd, cont, (int)sizeof cont - 1, SEND_FLAGS);
			c->sent_continue = true;
		}
		c->req_need = head_len + content_length;
		return 0;
	}
	c->req_need = 0;
	r->body = c->in.p + head_len;
	r->body_len = content_length;
	c->req_len = head_len + content_length;
	c->close_after = !r->keep_alive;
	return 1;
}

static void conn_try_serve(Conn *c) {
	while (c->st == C_READ && c->in.len) {
		Req r;
		int st = conn_parse(c, &r);
		if (st == 0) return;
		if (st > 0) {
			c->sent_continue = false;
			dispatch(c, &r);
		}
		if (c->st == C_PARKED) return; /* keep `in` until the reply is sent */
		buf_consume(&c->in, c->req_len ? c->req_len : c->in.len);
		c->req_len = 0;
	}
}

static void conn_flush(Conn *c, uint64_t now) {
	while (c->out_off < c->out.len) {
		size_t left = c->out.len - c->out_off;
		int chunk = left > (1u << 30) ? (1 << 30) : (int)left;
		int n = (int)send(c->fd, c->out.p + c->out_off, chunk, SEND_FLAGS);
		if (n > 0) {
			c->out_off += (size_t)n;
			continue;
		}
		if (n < 0 && sock_would_block()) return;
		conn_close(c);
		return;
	}
	c->out.len = c->out_off = 0;
	if (c->close_after) {
		conn_close(c);
		return;
	}
	c->st = C_READ;
	c->deadline_ms = now + IDLE_TTL_MS;
	conn_try_serve(c); /* pipelined request already buffered? */
}

static void conn_read(Conn *c, uint64_t now) {
	for (;;) {
		buf_reserve(&c->in, 64 * 1024);
		int room = (int)(c->in.cap - c->in.len > (1u << 30) ? (1u << 30) : c->in.cap - c->in.len);
		int n = (int)recv(c->fd, c->in.p + c->in.len, room, 0);
		if (n > 0) {
			c->in.len += (size_t)n;
			c->deadline_ms = now + READ_TTL_MS;
			continue;
		}
		if (n < 0 && sock_would_block()) break;
		conn_close(c); /* EOF or error */
		return;
	}
	if (c->st == C_READ) conn_try_serve(c);
}

/* ------------------------------------------------------------------- main */

static sock_t listen_on(const char *bind_ip, int port) {
	sock_t s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (s == SOCK_BAD) return SOCK_BAD;
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, (const char *)&one, sizeof one);
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, bind_ip, &a.sin_addr) != 1 || bind(s, (struct sockaddr *)&a, sizeof a) != 0 ||
		listen(s, 64) != 0 || !set_nonblocking(s)) {
		sock_close(s);
		return SOCK_BAD;
	}
	return s;
}

static void accept_all(sock_t ls, uint64_t now) {
	for (;;) {
		sock_t fd = accept(ls, NULL, NULL);
		if (fd == SOCK_BAD) return;
		Conn *slot = NULL;
		for (int i = 0; i < MAX_CONNS && !slot; i++)
			if (g_conns[i].st == C_FREE) slot = &g_conns[i];
		if (!slot || !set_nonblocking(fd)) {
			sock_close(fd);
			continue;
		}
		int one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (const char *)&one, sizeof one);
		*slot = (Conn){.fd = fd, .st = C_READ, .deadline_ms = now + IDLE_TTL_MS};
	}
}

/* Prints the addresses other computers can use to reach this server, with
 * a hint for well-known VPN ranges. Best effort: failures print nothing. */
static void print_address(const char *ip, int port) {
	if (!strncmp(ip, "127.", 4) || !strncmp(ip, "169.254.", 8)) return;
	const char *hint = !strncmp(ip, "26.", 3)                                 ? "Radmin VPN"
		: !strncmp(ip, "100.", 4)                                         ? "Tailscale / CGNAT"
		: !strncmp(ip, "192.168.", 8) || !strncmp(ip, "10.", 3)           ? "local network / VPN"
		: !strncmp(ip, "172.", 4)                                         ? "local network / VPN"
		                                                                  : "public?";
	printf("    %s:%d   (%s)\n", ip, port, hint);
}

static void print_addresses(int port) {
	printf("  this PC:      127.0.0.1:%d\n  other PCs:\n", port);
#ifdef _WIN32
	char host[256];
	struct addrinfo hints = {.ai_family = AF_INET}, *res = NULL;
	if (gethostname(host, sizeof host) != 0 || getaddrinfo(host, NULL, &hints, &res) != 0) return;
	for (struct addrinfo *a = res; a; a = a->ai_next) {
		char ip[INET_ADDRSTRLEN];
		if (inet_ntop(AF_INET, &((struct sockaddr_in *)a->ai_addr)->sin_addr, ip, sizeof ip)) print_address(ip, port);
	}
	freeaddrinfo(res);
#else
	struct ifaddrs *list = NULL;
	if (getifaddrs(&list) != 0) return;
	for (struct ifaddrs *a = list; a; a = a->ifa_next) {
		char ip[INET_ADDRSTRLEN];
		if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET &&
			inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, ip, sizeof ip))
			print_address(ip, port);
	}
	freeifaddrs(list);
#endif
}

static void usage(void) {
	puts("uncreate-server — self-hosted Team Create relay for Roblox Studio\n"
	     "  --port N       TCP port (default 7878)\n"
	     "  --bind IP      listen address (default 0.0.0.0)\n"
	     "  --data DIR     project directory (default ./project); its name is the project name\n"
	     "  --key SECRET   shared password (or env UNCREATE_KEY)");
}

int main(int argc, char **argv) {
	int port = 7878;
	const char *bind_ip = "0.0.0.0", *dir = "project";
	const char *key = getenv("UNCREATE_KEY");
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(a, "--port") && v) port = atoi(v), i++;
		else if (!strcmp(a, "--bind") && v) bind_ip = v, i++;
		else if (!strcmp(a, "--data") && v) dir = v, i++;
		else if (!strcmp(a, "--key") && v) key = v, i++;
		else {
			usage();
			return a[2] == 'h' ? 0 : 2;
		}
	}
	snprintf(S.dir, sizeof S.dir, "%s", dir);
	/* Project name = last path component of the data folder. */
	char base[sizeof S.dir];
	snprintf(base, sizeof base, "%s", S.dir);
	for (size_t n = strlen(base); n > 1 && (base[n - 1] == '/' || base[n - 1] == '\\'); n--) base[n - 1] = 0;
	const char *leaf = base;
	for (const char *p = base; *p; p++)
		if (*p == '/' || *p == '\\') leaf = p + 1;
	sanitize_name(S.name, leaf);
	snprintf(S.key, sizeof S.key, "%s", key ? key : "");

#ifdef _WIN32
	WSADATA wsa;
	if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
#else
	signal(SIGPIPE, SIG_IGN);
#endif
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	setvbuf(stdout, NULL, _IONBF, 0);

	MKDIR(S.dir);
	meta_load();
	if (!log_load()) {
		fprintf(stderr, "uncreate-server: cannot open %s/ops.log\n", S.dir);
		return 1;
	}
	sock_t ls = listen_on(bind_ip, port);
	if (ls == SOCK_BAD) {
		fprintf(stderr, "uncreate-server: cannot listen on %s:%d\n", bind_ip, port);
		return 1;
	}
	for (int i = 0; i < MAX_CONNS; i++) g_conns[i].fd = SOCK_BAD;
	printf("uncreate-server: project \"%s\" (%s), rev %" PRIu64 ", snapshot %s, key %s\n", S.name, S.dir, S.rev,
		S.has_snap ? "yes" : "none yet", S.key[0] ? "set" : "NONE (anyone can connect!)");
	print_addresses(port);

	struct pollfd pf[MAX_CONNS + 1];
	int map[MAX_CONNS + 1];
	uint64_t last_house = now_ms();
	while (!g_stop) {
		uint64_t now = now_ms();
		int n = 0, timeout = 1000;
		pf[n] = (struct pollfd){.fd = ls, .events = POLLIN};
		map[n++] = -1;
		for (int i = 0; i < MAX_CONNS; i++) {
			Conn *c = &g_conns[i];
			if (c->st == C_FREE) continue;
			pf[n] = (struct pollfd){.fd = c->fd, .events = (short)(c->st == C_WRITE ? POLLOUT : POLLIN)};
			map[n++] = i;
			if (c->deadline_ms <= now) timeout = 0;
			else if (c->deadline_ms - now < (uint64_t)timeout) timeout = (int)(c->deadline_ms - now);
		}
		int ready = net_poll(pf, n, timeout);
		if (ready < 0) continue; /* EINTR on signal; loop re-checks g_stop */
		now = now_ms();
		for (int k = 0; k < n; k++) {
			short ev = pf[k].revents;
			if (!ev) continue;
			if (map[k] < 0) {
				accept_all(ls, now);
				continue;
			}
			Conn *c = &g_conns[map[k]];
			if (c->st == C_FREE) continue;
			if (ev & (POLLERR | POLLNVAL)) {
				conn_close(c);
				continue;
			}
			if (c->st == C_WRITE && (ev & POLLOUT)) conn_flush(c, now);
			else if (ev & (POLLIN | POLLHUP)) {
				if (c->st == C_PARKED) {
					/* A parked client only sends again if it gave up: drop it. */
					char tmp[512];
					int r = (int)recv(c->fd, tmp, sizeof tmp, 0);
					if (r <= 0 && !(r < 0 && sock_would_block())) conn_close(c);
				} else conn_read(c, now);
			}
		}
		/* Deadlines: a parked poll gets its (empty) reply, anything else is dead. */
		for (int i = 0; i < MAX_CONNS; i++) {
			Conn *c = &g_conns[i];
			if (c->st == C_FREE || c->deadline_ms > now) continue;
			if (c->st == C_PARKED) poll_reply(c, c->poll_client, c->poll_since);
			else conn_close(c);
		}
		/* Send every reply queued this iteration, including those that
		 * wake_parked() queued on other connections. */
		for (int i = 0; i < MAX_CONNS; i++)
			if (g_conns[i].st == C_WRITE) conn_flush(&g_conns[i], now);
		if (now - last_house >= 1000) {
			last_house = now;
			if (clients_prune(now)) wake_parked_ex(true);
			if (S.stage_active && elapsed(now, S.stage_started_ms) > STAGE_TTL_MS) stage_clear();
		}
	}
	puts("uncreate-server: stopping");
	if (S.log_fp) fclose(S.log_fp);
	for (int i = 0; i < MAX_CONNS; i++) conn_close(&g_conns[i]);
	sock_close(ls);
	free(S.batches);
	buf_free(&S.blob);
#ifdef _WIN32
	WSACleanup();
#endif
	return 0;
}
