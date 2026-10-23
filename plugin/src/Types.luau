--!strict
--[[
	Types — shared vocabulary of the Uncreate plugin: wire shapes exchanged with
	uncreate-server and the small records modules pass to each other. Depends on nothing.

	Wire op (one element of a batch posted to /ops), by `t`:
		"new"  { id?, p, b, z? }  instance subtree as rbxm (base64, zstd if z=1)
		"set"  { id, k, v }       property k = encoded value v ("Parent" = move)
		"attr" { id, k, v }       attribute k = encoded value v
		"tag"  { id, k, v }       tag k is present (v = true) or absent (false)
		"del"  { id }             destroy instance and its subtree
	Ids are strings: "@Workspace" for roots, opaque strings for instances.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

export type Op = {
	t: string,
	id: string?,
	p: string?,
	b: string?,
	z: number?,
	k: string?,
	v: any,
}

export type Batch = {
	r: number,
	c: number,
	o: { Op },
}

export type Peer = {
	id: number,
	name: string,
	cam: { number }?, -- camera {x, y, z, lookX, lookY, lookZ}; absent until known
}

export type Hello = {
	proto: number,
	client: number,
	rev: number,
	snapRev: number,
	logStart: number,
	hasSnap: boolean,
	project: string?, -- the server's project name (its data folder)
}

export type PollReply = {
	resync: boolean?,
	rev: number?,
	snapRev: number?,
	want: boolean?,
	more: boolean?,
	upto: number?, -- the reply covers the log up to this rev (own batches are not echoed)
	peers: { Peer }?,
	b: { Batch }?,
}

export type ChunkInfo = {
	root: string,
	first: number, -- index of the first server part
	n: number, -- number of parts
	z: number, -- 1 when zstd-compressed
}

export type RefFix = { string } -- { instanceId, property, targetId }

export type Manifest = {
	v: number,
	roots: { [string]: { [string]: any } }, -- rootId -> property -> encoded value
	chunks: { ChunkInfo },
	refs: { RefFix },
}

export type SnapshotHeader = {
	snapRev: number,
	chunks: number,
	manifest: Manifest,
}

export type Status = "Idle" | "Connecting" | "Loading" | "Live" | "Error"

return nil
