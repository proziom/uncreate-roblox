--!strict
--[[
	Snapshot — the project as a set of rbxm chunks plus a manifest.

	Building:  Plan (group the synced children of every root into chunks of
	about GROUP_INSTANCES instances, record root properties and references
	that cross chunks) → Pack (serialize, zstd, cut into PART_CHARS pieces)
	→ Upload (begin / part… / commit).
	Loading:   FetchHeader, then FetchChunk per chunk; the Session places
	the instances (it owns the registry and the echo bookkeeping).

	Everything here yields on Studio or HTTP calls and errors with a
	readable message on failure.

	[ @Claude | 23.10.2026 ]
]]

local SerializationService = game:GetService("SerializationService")

local Codec = require(script.Parent.Codec)
local Net = require(script.Parent.Net)
local Registry = require(script.Parent.Registry)
local Schema = require(script.Parent.Schema)
local Strings = require(script.Parent.Strings)
local Types = require(script.Parent.Types)

local GROUP_INSTANCES = 4000 -- instances per serialized chunk
local PART_CHARS = 3 * 1024 * 1024 -- base64 chars per HTTP request

export type Group = { root: string, list: { Instance } }
export type Progress = (stage: "pack" | "upload", done: number, total: number) -> ()

local Snapshot = {}

-- Root properties into the manifest; synced children into groups, one
-- rbxm chunk each. Also ids anything not registered yet.
function Snapshot.Plan(reg: Registry.Registry, resolver: Codec.Resolver): (Types.Manifest, { Group })
	local manifest: Types.Manifest = { v = 1, roots = {}, chunks = {}, refs = {} }
	local groups: { Group } = {}
	for _, rootId in reg:RootIds() do
		local root = reg:Root(rootId) :: Instance
		local props: { [string]: any } = {}
		local rootProps: { string } = Schema.ROOT_PROPS[rootId] or {}
		for _, prop in rootProps do
			local readOk, value = pcall(Schema.Get, root, prop)
			if readOk then
				local encOk, encoded = Codec.Encode(value, resolver)
				if encOk then
					props[prop] = encoded
				end
			end
		end
		manifest.roots[rootId] = props

		local current: { Instance } = {}
		local count = 0
		for _, child in reg:SyncedChildren(root) do
			reg:RegisterTree(child) -- no-op for registered nodes
			local size = #child:GetDescendants() + 1
			if count > 0 and count + size > GROUP_INSTANCES then
				table.insert(groups, { root = rootId, list = current })
				current, count = {}, 0
			end
			table.insert(current, child)
			count += size
		end
		if #current > 0 then
			table.insert(groups, { root = rootId, list = current })
		end
	end
	Snapshot._collectCrossRefs(reg, manifest, groups)
	return manifest, groups
end

-- rbxm drops references that leave a chunk; the manifest lists them so a
-- joiner restores them after every chunk is placed.
function Snapshot._collectCrossRefs(reg: Registry.Registry, manifest: Types.Manifest, groups: { Group })
	local groupOf: { [Instance]: number } = {}
	for index, group in groups do
		for _, child in group.list do
			groupOf[child] = index
		end
	end
	for index, group in groups do
		for _, child in group.list do
			Registry.Walk(child, function(node: Instance)
				Schema.ForEachRef(node, function(prop: string, target: Instance)
					local top = reg:TopLevelOf(target)
					local nodeId, targetId = reg:IdOf(node), reg:IdOf(target)
					if nodeId and targetId and (top == nil or groupOf[top] ~= index) then
						table.insert(manifest.refs, { nodeId, prop, targetId })
					end
				end)
			end)
		end
	end
end

local function serialize(list: { Instance }): (boolean, any)
	return pcall(SerializationService.SerializeInstancesAsync, SerializationService, list)
end

-- Serializes every group into base64 parts and fills manifest.chunks.
-- One bad instance must not sink the snapshot: a failing group is retried
-- member by member and the failures are reported through `skipped`.
-- Returns nil when `cancelled` turns true midway.
function Snapshot.Pack(
	manifest: Types.Manifest,
	groups: { Group },
	cancelled: () -> boolean,
	skipped: (inst: Instance, reason: string) -> (),
	progress: Progress?
): { string }?
	local parts: { string } = {}
	local function addChunk(rootId: string, raw: buffer)
		local text, compressed = Codec.Pack(raw)
		local first = #parts
		for pos = 1, #text, PART_CHARS do
			table.insert(parts, string.sub(text, pos, pos + PART_CHARS - 1))
		end
		table.insert(manifest.chunks, {
			root = rootId,
			first = first,
			n = #parts - first,
			z = if compressed then 1 else 0,
		})
	end
	for index, group in groups do
		if cancelled() then
			return nil
		end
		local ok, raw = serialize(group.list)
		if ok then
			addChunk(group.root, raw)
		else
			for _, inst in group.list do
				local oneOk, one = serialize({ inst })
				if oneOk then
					addChunk(group.root, one)
				else
					skipped(inst, tostring(one))
				end
			end
		end
		if progress then
			progress("pack", index, #groups)
		end
	end
	return parts
end

-- Uploads a packed snapshot taken at `base`. Returns "sent", "current" (the
-- server already has a snapshot at least this new) or "cancelled".
function Snapshot.Upload(
	net: Net.Net,
	clientId: number,
	base: number,
	manifest: Types.Manifest,
	parts: { string },
	cancelled: () -> boolean,
	progress: Progress?
): "sent" | "current" | "cancelled"
	local beginOk, reply = net:Json("POST", ("/snap/begin?client=%d&base=%d"):format(clientId, base), "")
	if not beginOk then
		if reply == "snapshot is already current" then
			return "current"
		end
		error(Strings.ErrSnapshotRefused:format(tostring(reply)), 0)
	end
	local token: number = reply.token
	for i, part in parts do
		if cancelled() then
			return "cancelled"
		end
		local partOk, status = net:Request("POST", ("/snap/part?token=%d&i=%d"):format(token, i - 1), part)
		if not partOk then
			error(Strings.ErrPartUpload:format(i - 1, status), 0)
		end
		if progress then
			progress("upload", i, #parts)
		end
	end
	local commitOk, commitReply =
		net:Json("POST", ("/snap/commit?token=%d&chunks=%d"):format(token, #parts), Net.ToJson(manifest))
	if not commitOk then
		error(Strings.ErrCommit:format(tostring(commitReply)), 0)
	end
	return "sent"
end

function Snapshot.FetchHeader(net: Net.Net): Types.SnapshotHeader
	local ok, reply = net:Json("GET", "/snap/manifest")
	if not ok then
		error(Strings.ErrManifest:format(tostring(reply)), 0)
	end
	return reply
end

-- Downloads and decodes one chunk. Returns nil when the server replaced the
-- snapshot meanwhile (the caller restarts the join); errors on anything else.
function Snapshot.FetchChunk(net: Net.Net, snapRev: number, chunk: Types.ChunkInfo): buffer?
	local parts: { string } = {}
	for i = chunk.first, chunk.first + chunk.n - 1 do
		local ok, status, text = net:Request("GET", ("/snap/chunk?i=%d&rev=%d"):format(i, snapRev))
		if not ok then
			if status == 409 then
				return nil
			end
			error(Strings.ErrChunk:format(i, status), 0)
		end
		table.insert(parts, text)
	end
	return Codec.Unpack(table.concat(parts), chunk.z == 1)
end

return Snapshot
