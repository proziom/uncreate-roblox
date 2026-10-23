#!/usr/bin/env python3
"""End-to-end protocol test for uncreate-server. Usage: test_protocol.py PATH_TO_BINARY"""
import http.client, json, os, shutil, subprocess, sys, tempfile, threading, time

BIN = sys.argv[1]
PORT = 7979
KEY = "secret"
DATA = tempfile.mkdtemp(prefix="uncreate_test_")


def start():
    p = subprocess.Popen([BIN, "--port", str(PORT), "--data", DATA, "--key", KEY, "--bind", "127.0.0.1"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for _ in range(50):
        try:
            c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=2)
            c.request("GET", "/")
            if c.getresponse().read() == b"uncreate-server ok\n":
                return p
        except OSError:
            time.sleep(0.1)
    raise SystemExit("server did not start")


class Client:
    def __init__(self, key=KEY):
        self.c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=40)
        self.key = key

    def req(self, method, path, body=None, expect=200):
        self.c.request(method, path, body=body, headers={"X-Key": self.key})
        r = self.c.getresponse()
        data = r.read()
        assert r.status == expect, (method, path, r.status, data[:200])
        return json.loads(data) if data[:1] in (b"{", b"[") else data


def main():
    srv = start()
    try:
        a, b = Client(), Client()
        Client(key="wrong").req("POST", "/hello?name=x", b"", expect=401)
        assert Client().req("GET", f"http://127.0.0.1:{PORT}/status")["rev"] == 0  # absolute-form target

        ha = a.req("POST", "/hello?name=%D0%92%D0%B0%D1%81%D1%8F", b"")  # "Вася" url-encoded
        hb = b.req("POST", "/hello?name=Lan", b"")
        assert ha["rev"] == 0 and not ha["hasSnap"], ha
        ida, idb = ha["client"], hb["client"]

        # host uploads a snapshot at base 0
        tok = a.req("POST", f"/snap/begin?client={ida}&base=0", b"")["token"]
        a.req("POST", f"/snap/part?token={tok}&i=0", b"QUJD")
        a.req("POST", f"/snap/part?token={tok}&i=1", b"REVG")
        a.req("POST", f"/snap/commit?token={tok}&chunks=3", b'{"v":1}', expect=409)  # chunk 2 missing
        a.req("POST", f"/snap/commit?token={tok}&chunks=2", b'{"v":1,"chunks":[]}')
        m = b.req("GET", "/snap/manifest")
        assert m["snapRev"] == 0 and m["chunks"] == 2 and m["manifest"]["v"] == 1, m
        assert b.req("GET", "/snap/chunk?i=1&rev=0") == b"REVG"
        b.req("GET", "/snap/chunk?i=1&rev=5", expect=409)

        # long poll wakes on a new batch from the other client
        got = {}

        def waiter():
            w = Client()
            got["r"] = w.req("GET", f"/poll?client={idb}&since=0&wait=10")
        t = threading.Thread(target=waiter)
        t.start()
        time.sleep(0.3)
        t0 = time.time()
        rev = a.req("POST", f"/ops?client={ida}", b'[{"t":"set","id":"x","k":"Name","v":"A"}]')["rev"]
        t.join()
        assert rev == 1 and time.time() - t0 < 1.0
        r = got["r"]
        assert r["b"][0]["r"] == 1 and r["b"][0]["c"] == ida and r["b"][0]["o"][0]["v"] == "A", r
        assert {p["name"] for p in r["peers"]} == {"Вася", "Lan"}, r["peers"]

        # presence: camera stored in memory, returned to everyone, junk refused
        pr = b.req("POST", f"/presence?client={idb}", b"[1.5,2,-3,0,0,-1]")
        cams = {p["name"]: p.get("cam") for p in pr["peers"]}
        assert cams["Lan"] == [1.5, 2, -3, 0, 0, -1] and cams["Вася"] is None, cams
        b.req("POST", f"/presence?client={idb}", b'["<script>"]')
        pr = a.req("POST", f"/presence?client={ida}", b"")
        assert {p["name"]: p.get("cam") for p in pr["peers"]}["Lan"] == [1.5, 2, -3, 0, 0, -1], pr
        a.req("POST", "/presence?client=999", b"[]", expect=409)
        # bye: a client that leaves disappears from presence at once
        hx = Client().req("POST", "/hello?name=Ghost", b"")
        Client().req("POST", f"/presence?client={hx['client']}", b"[0,0,0,0,0,-1]")
        assert "Ghost" in {p["name"] for p in a.req("POST", f"/presence?client={ida}", b"")["peers"]}
        Client().req("POST", f"/bye?client={hx['client']}", b"")
        assert "Ghost" not in {p["name"] for p in a.req("POST", f"/presence?client={ida}", b"")["peers"]}
        assert ha["project"] == os.path.basename(DATA), ha
        st = a.req("GET", "/status")
        assert st["rev"] == 1, "presence must not touch the log"

        a.req("POST", f"/ops?client={ida}", b'{"not":"array"}', expect=400)
        a.req("POST", f"/ops?client=999", b"[]", expect=409)

        # timeout reply is empty
        t0 = time.time()
        r = b.req("GET", f"/poll?client={idb}&since=1&wait=1")
        assert r["b"] == [] and 0.8 < time.time() - t0 < 2.5, r

        # import a fake binary rbxm
        rbxm = b"<roblox!\x89\xff\r\n\x1a\n" + bytes(range(256))
        rev = a.req("POST", "/import?into=ReplicatedStorage", rbxm)["rev"]
        r = b.req("GET", f"/poll?client={idb}&since=1&wait=0")
        op = r["b"][0]["o"][0]
        import base64
        assert op["p"] == "@ReplicatedStorage" and base64.b64decode(op["b"]) == rbxm, op
        a.req("POST", "/import?into=Bad.Name", rbxm, expect=400)

        # many batches through one keep-alive connection; force the "want" path
        for i in range(20050):
            a.req("POST", f"/ops?client={ida}", b'[{"t":"set","id":"y","k":"V","v":%d}]' % i)
        st = a.req("GET", "/status")
        last = st["rev"]
        # client b catches up in bounded pages
        since, pages = 2, 0
        while since < last:
            r = b.req("GET", f"/poll?client={idb}&since={since}&wait=0")
            since = r["upto"]
            pages += 1
        own = a.req("GET", f"/poll?client={ida}&since=2&wait=0")
        assert own["b"] == [] and own["upto"] == last, "own batches must not echo"
        r = b.req("GET", f"/poll?client={idb}&since={since}&wait=5")
        assert r["want"] is True, "caught-up client should be asked for a snapshot"
        r2 = a.req("GET", f"/poll?client={ida}&since={since}&wait=1")
        assert r2["want"] is False, "only one client at a time is asked"
        # b uploads the snapshot at `last`; log is truncated (a and b both acked `last`)
        tok = b.req("POST", f"/snap/begin?client={idb}&base={last}", b"")["token"]
        b.req("POST", f"/snap/part?token={tok}&i=0", b"WFla")
        b.req("POST", f"/snap/commit?token={tok}&chunks=1", b'{"v":1}')
        st = a.req("GET", "/status")
        assert st["snapRev"] == last and st["batches"] == 0 and st["logStart"] == last, st
        r = a.req("GET", f"/poll?client={ida}&since=3&wait=0")
        assert r.get("resync") is True, r

        a.req("POST", f"/ops?client={ida}", b'[{"t":"del","id":"q"}]')
        # same-rev re-upload is refused
        b.req("POST", f"/snap/begin?client={idb}&base={last}", b"", expect=409)
    finally:
        srv.terminate()
        out = srv.communicate(timeout=5)[0].decode("utf-8", "replace")
    assert not os.path.exists(os.path.join(DATA, "snap_0")), "old snapshot dir must be deleted"

    # restart: state persists
    srv = start()
    try:
        c = Client()
        st = c.req("GET", "/status")
        assert st["rev"] == last + 1 and st["snapRev"] == last and st["batches"] == 1, st
        idc = c.req("POST", "/hello?name=again", b"")["client"]
        r = c.req("GET", f"/poll?client={idc}&since={last}&wait=0")
        assert r["b"][0]["o"][0]["t"] == "del", r
        assert c.req("GET", f"/snap/chunk?i=0") == b"WFla"
    finally:
        srv.terminate()
        srv.communicate(timeout=5)

    # a project written before the rename (meta tag "rbxsync") still loads
    meta = os.path.join(DATA, "meta.txt")
    with open(meta) as f:
        text = f.read()
    assert text.startswith("uncreate 1"), text
    with open(meta, "w") as f:
        f.write(text.replace("uncreate 1", "rbxsync 1", 1))
    srv = start()
    try:
        st = Client().req("GET", "/status")
        assert st["snapRev"] == last and st["hasSnap"], st
    finally:
        srv.terminate()
        srv.communicate(timeout=5)

    # torn log tail is repaired on start
    with open(os.path.join(DATA, "ops.log"), "ab") as f:
        f.write(b"\x01\x02\x03")
    srv = start()
    try:
        st = Client().req("GET", "/status")
        assert st["batches"] == 1, st
    finally:
        srv.terminate()
        srv.communicate(timeout=5)
    shutil.rmtree(DATA)
    print("ALL OK  (pages to catch up 20k batches:", pages, ")")


main()
