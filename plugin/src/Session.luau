--!strict
--[[
	Session — one live connection between this Studio place and uncreate-server.

	Lifecycle:  Start() → hello → host (empty server: upload this place as the
	snapshot) or join (download snapshot, replay log) → Live, with two loops:
	  • poll loop   long-polls /poll and applies other people's op batches;
	  • flush loop  every FLUSH_INTERVAL turns coalesced local changes into
	                one op batch and posts it to /ops;
	plus Presence (the flying heads). Stop() says goodbye to the server and
	ends everything; the place keeps its content.

	Consistency model: the server's batch order is the truth and every
	property is last-writer-wins in that order. A client skips a remote op
	for a key (instance id + property) while it has a local change to that
	key that is unsent, in flight, or acked at a later rev; everyone then
	converges on the later value. Local echoes of applied remote values are
	recognised by comparing against `shadow`, the last value synced per key.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local SerializationService = game:GetService("SerializationService")

local Codec = require(script.Parent.Codec)
local Net = require(script.Parent.Net)
local Presence = require(script.Parent.Presence)
local Registry = require(script.Parent.Registry)
local Schema = require(script.Parent.Schema)
local Snapshot = require(script.Parent.Snapshot)
local Strings = require(script.Parent.Strings)
local Types = require(script.Parent.Types)

type Op = Types.Op
type Batch = Types.Batch

local FLUSH_INTERVAL = 0.15 -- s between flushes while editing
local FLUSH_INTERVAL_HEAVY = 0.5 -- s after a batch of HEAVY_BATCH_OPS or more
local HEAVY_BATCH_OPS = 300
local SOURCE_MIN_INTERVAL = 0.4 -- s between Source sends of one script while typing
local POLL_WAIT = 15 -- s the server may hold a poll open (under HttpService's timeout)
local SEND_RETRY_DELAY = 2 -- s before resending a batch the server did not take
local COMPACT_QUIET_LIMIT = 30 -- s to wait for local edits to settle before a snapshot

-- Shadow marker for "the last synced value was nil" (absent key = unknown).
local NIL = newproxy(false)

-- Small helpers ----------------------------------------------------------------------

local function readSource(inst: Instance): string
	return ScriptEditorService:GetEditorSource(inst :: LuaSourceContainer)
end

local function propKey(id: string, prop: string): string
	return id .. "|" .. prop
end

local function attrKey(id: string, attr: string): string
	return id .. "|@" .. attr
end

local function tagKey(id: string, tag: string): string
	return id .. "|#" .. tag
end

local function shadowMatches(stored: any, current: any): boolean
	if stored == nil then
		return false
	end
	return stored == current or (stored == NIL and current == nil)
end

local function setShadow(map: { [Instance]: { [string]: any } }, inst: Instance, name: string, value: any)
	local t = map[inst]
	if t == nil then
		t = {}
		map[inst] = t
	end
	t[name] = if value == nil then NIL else value
end

local function mark(map: { [Instance]: { [string]: true } }, inst: Instance, name: string)
	local t = map[inst]
	if t == nil then
		t = {}
		map[inst] = t
	end
	t[name] = true
end

local function isMarked(map: { [Instance]: { [string]: true } }, inst: Instance, name: string): boolean
	local t = map[inst]
	return t ~= nil and t[name] == true
end

-- Session ------------------------------------------------------------------------------

export type Callbacks = {
	OnStatus: (status: Types.Status, text: string) -> (),
	OnLog: (text: string) -> (),
	OnPeers: (peers: { Types.Peer }) -> (),
	Confirm: (text: string) -> boolean,
}

-- One op batch being built or waiting in the outbox. `keys` are the conflict
-- keys it carries; each is counted in _keyInflight until the server acks.
type Outgoing = { ops: { Op }, keys: { string } }

local Session = {}
Session.__index = Session

export type Session = typeof(setmetatable(
	{} :: {
		_net: Net.Net,
		_reg: Registry.Registry,
		_presence: Presence.Presence,
		_name: string,
		_cb: Callbacks,
		_resolver: Codec.Resolver,
		_gen: number, -- bumped by Start/Stop; loops of an older generation exit
		_status: Types.Status,
		_clientId: number, -- 0 while not registered with the server
		_project: string,
		_appliedRev: number,
		_hooks: { RBXScriptConnection },
		-- local changes not yet turned into ops (taken by each flush)
		_dirty: { [Instance]: { [string]: true } },
		_dirtyAttr: { [Instance]: { [string]: true } },
		_dirtyTags: { [Instance]: { [string]: true } },
		_added: { [Instance]: true },
		_removed: { [Instance]: true },
		_recreate: { [Instance]: true },
		_outbox: { Outgoing },
		-- conflict bookkeeping, keyed by propKey / attrKey
		_keyInflight: { [string]: number },
		_keyRev: { [string]: number },
		-- last synced values (echo suppression)
		_shadow: { [Instance]: { [string]: any } },
		_shadowAttr: { [Instance]: { [string]: any } },
		_shadowTags: { [Instance]: { [string]: true } }, -- tags last synced (absent = none)
		_shadowParent: { [Instance]: string },
		_lastSource: { [Instance]: number },
		_warned: { [string]: true },
		_flushing: boolean,
		_snapshotting: boolean,
		_helloBusy: boolean,
		_nextFlushAt: number,
	},
	Session
))

function Session.new(url: string, key: string, name: string, callbacks: Callbacks): Session
	local self: Session
	local reg = Registry.new(function(inst: Instance, prop: string)
		self:_onProp(inst, prop)
	end, function(inst: Instance, attr: string)
		self:_onAttr(inst, attr)
	end)
	local net = Net.new(url, key)
	self = setmetatable({
		_net = net,
		_reg = reg,
		_presence = Presence.new(net, function(): number
			return self._clientId
		end),
		_name = name,
		_cb = callbacks,
		_resolver = {
			IdOf = function(inst: Instance): string?
				return reg:IdOf(inst)
			end,
			Find = function(id: string): Instance?
				return reg:Find(id)
			end,
		},
		_gen = 0,
		_status = "Idle" :: Types.Status,
		_clientId = 0,
		_project = "",
		_appliedRev = 0,
		_hooks = {},
		_dirty = {},
		_dirtyAttr = {},
		_dirtyTags = {},
		_added = {},
		_removed = {},
		_recreate = {},
		_outbox = {},
		_keyInflight = {},
		_keyRev = {},
		_shadow = {},
		_shadowAttr = {},
		_shadowTags = {},
		_shadowParent = {},
		_lastSource = {},
		_warned = {},
		_flushing = false,
		_snapshotting = false,
		_helloBusy = false,
		_nextFlushAt = 0,
	}, Session)
	return self
end

-- Public surface ------------------------------------------------------------------------

function Session.Start(self: Session)
	self._gen += 1
	local gen = self._gen
	task.spawn(function()
		local ok, err = pcall(function()
			self:_run(gen, false)
		end)
		if not ok and self._gen == gen then
			self:_setStatus("Error", tostring(err))
			self:_teardown()
		end
	end)
end

function Session.Stop(self: Session)
	self._gen += 1
	self:_bye()
	self:_teardown()
	self:_setStatus("Idle", Strings.StatusDisconnected)
end

-- This client's id on the server (0 while not connected).
function Session.ClientId(self: Session): number
	return self._clientId
end

-- Uploads a fresh snapshot now (also done automatically when the server asks).
function Session.UploadSnapshot(self: Session)
	if self._status ~= "Live" then
		self:_log(Strings.LogConnectFirst)
		return
	end
	self:_spawnCompact(self._gen)
end

-- Status & logging ----------------------------------------------------------------------

function Session._setStatus(self: Session, status: Types.Status, text: string)
	self._status = status
	self._cb.OnStatus(status, text)
end

function Session._showLive(self: Session)
	self:_setStatus("Live", Strings.StatusLive:format(self._project, self._appliedRev, self._reg:Count()))
end

function Session._log(self: Session, text: string)
	self._cb.OnLog(text)
end

function Session._warnOnce(self: Session, key: string, text: string)
	if not self._warned[key] then
		self._warned[key] = true
		self:_log(text)
	end
end

-- Tells the server we are leaving, so our head disappears for everyone at
-- once instead of after a timeout. Fire-and-forget: Stop must not wait.
function Session._bye(self: Session)
	local id = self._clientId
	if id ~= 0 then
		self._clientId = 0
		local net = self._net
		task.spawn(function()
			net:Request("POST", "/bye?client=" .. id, "")
		end)
	end
end

function Session._teardown(self: Session)
	for _, conn in self._hooks do
		conn:Disconnect()
	end
	table.clear(self._hooks)
	self._presence:Stop()
	self._reg:Clear()
	local state: { { [any]: any } } = {
		self._dirty,
		self._dirtyAttr,
		self._dirtyTags,
		self._added,
		self._removed,
		self._recreate,
		self._outbox,
		self._keyInflight,
		self._keyRev,
		self._shadow,
		self._shadowAttr,
		self._shadowTags,
		self._shadowParent,
		self._lastSource,
	}
	for _, t in state do
		table.clear(t)
	end
	self._flushing = false
	self._snapshotting = false
end

-- Connect: host or join -------------------------------------------------------------------

function Session._hello(self: Session): Types.Hello
	local ok, reply = self._net:Json("POST", "/hello?name=" .. Net.Encode(self._name), "")
	if not ok then
		error(Strings.ErrNoAnswer:format(self._net:Base(), tostring(reply)), 0)
	end
	local hello: Types.Hello = reply
	if hello.proto ~= 1 then
		error(Strings.ErrProtocol, 0)
	end
	self._clientId = hello.client
	self._project = hello.project or "project"
	return hello
end

-- The server forgot this client (it restarted): register again. Both loops
-- may notice at once; only one re-registers, the other just retries later.
function Session._rehello(self: Session): Types.Hello?
	if self._helloBusy then
		return nil
	end
	self._helloBusy = true
	local ok, hello = pcall(self._hello, self)
	self._helloBusy = false
	return if ok then hello else nil
end

function Session._run(self: Session, gen: number, isResync: boolean)
	self:_setStatus("Connecting", Strings.StatusConnecting:format(self._net:Base()))
	local hello = self:_hello()
	if self._gen ~= gen then
		return
	end
	local isEmptyServer = not hello.hasSnap and hello.rev == 0
	local question = if isEmptyServer then Strings.ConfirmHost else Strings.ConfirmJoin
	if not isResync and not self._cb.Confirm(question) then
		self:Stop()
		return
	end
	if isEmptyServer then
		self:_host(gen)
	else
		self:_join(gen, hello)
	end
	if self._gen ~= gen then
		return
	end
	self:_showLive()
	task.spawn(self._pollLoop, self, gen)
	task.spawn(self._flushLoop, self, gen)
	self._presence:Start()
end

-- Makes this place the project: id every instance, then upload it.
function Session._host(self: Session, gen: number)
	self:_setStatus("Loading", Strings.StatusUploadingPlace)
	local reg = self._reg
	for _, rootId in reg:RootIds() do
		for _, child in reg:SyncedChildren(reg:Root(rootId) :: Instance) do
			reg:RegisterTree(child)
			self:_adoptSynced(child, rootId)
		end
	end
	self:_hook()
	self._appliedRev = 0
	self:_uploadSnapshot(gen, 0, true)
end

-- Replaces this place's content with the server's project.
function Session._join(self: Session, gen: number, hello: Types.Hello)
	self:_setStatus("Loading", Strings.StatusDownloading)
	self:_clearLocal()
	if hello.hasSnap then
		local restarted = self:_loadSnapshot(gen)
		if restarted or self._gen ~= gen then
			return
		end
	else
		self._appliedRev = hello.logStart -- only imports so far; the poll replays them
	end
	-- The load must not be one Ctrl+Z away from being undone (and synced).
	ChangeHistoryService:ResetWaypoints()
	self:_hook()
end

-- Destroys every synced child of every root.
function Session._clearLocal(self: Session)
	local reg = self._reg
	for _, rootId in reg:RootIds() do
		for _, child in reg:SyncedChildren(reg:Root(rootId) :: Instance) do
			pcall(child.Destroy, child)
		end
	end
end

-- Downloads and places the snapshot. Returns true when a newer snapshot
-- replaced it mid-download and the join was restarted from scratch.
function Session._loadSnapshot(self: Session, gen: number): boolean
	local header = Snapshot.FetchHeader(self._net)
	local manifest = header.manifest
	local reg = self._reg
	local started = os.clock()
	for chunkIndex, chunk in manifest.chunks do
		if self._gen ~= gen then
			return false
		end
		local raw = Snapshot.FetchChunk(self._net, header.snapRev, chunk)
		if raw == nil then
			self:_log(Strings.LogSnapshotRestarted)
			self:_join(gen, self:_hello())
			return true
		end
		local root = reg:Root(chunk.root)
		if root then
			local nextId = Registry.SequentialIds(("s%d.%d."):format(header.snapRev, chunkIndex))
			for _, inst in SerializationService:DeserializeInstancesAsync(raw) do
				self:_placeRemote(inst, root, chunk.root, nextId)
			end
		end
		self:_setStatus("Loading", Strings.StatusDownloadingPart:format(chunkIndex, #manifest.chunks))
	end
	for rootId, props in manifest.roots do
		local root = reg:Root(rootId)
		if root then
			for prop, encoded in props do
				self:_applyProperty(root, prop, encoded)
			end
		end
	end
	for _, fix in manifest.refs do
		local inst = reg:Find(fix[1])
		if inst then
			self:_applyProperty(inst, fix[2], { "I", fix[3] })
		end
	end
	self._appliedRev = header.snapRev
	self:_log(Strings.LogLoaded:format(reg:Count(), os.clock() - started))
	return false
end

-- Registers a tree that came from the server and parents it. If parenting
-- fails the tree is dropped again, so nothing half-placed stays registered.
function Session._placeRemote(
	self: Session,
	inst: Instance,
	parent: Instance,
	parentId: string,
	nextId: Registry.IdSource
)
	self._reg:AdoptTree(inst, nextId)
	self:_adoptSynced(inst, parentId)
	local ok, err = pcall(function()
		inst.Parent = parent
	end)
	if not ok then
		self:_log(Strings.LogSkipped:format(inst.Name, tostring(err)))
		self:_forget(inst)
	end
end

-- Local change capture ------------------------------------------------------------------------

function Session._hook(self: Session)
	local reg = self._reg
	local hooks = self._hooks
	for _, rootId in reg:RootIds() do
		local root = reg:Root(rootId) :: Instance
		if root.Parent == game then -- nested roots are covered by their service
			table.insert(
				hooks,
				root.DescendantAdded:Connect(function(inst: Instance)
					self:_onAdded(inst)
				end)
			)
			table.insert(
				hooks,
				root.DescendantRemoving:Connect(function(inst: Instance)
					self:_onRemoving(inst)
				end)
			)
		end
		local props = Schema.ROOT_PROPS[rootId]
		if props then
			local wanted: { [string]: true } = {}
			for _, p in props do
				wanted[p] = true
			end
			table.insert(
				hooks,
				root.Changed:Connect(function(prop: string)
					if wanted[prop] then
						self:_onProp(root, prop)
					end
				end)
			)
		end
	end
	self:_hookTags()
	table.insert(
		hooks,
		ScriptEditorService.TextDocumentDidChange:Connect(function(doc: ScriptDocument)
			local ok, scriptInst = pcall(doc.GetScript, doc)
			if ok and scriptInst and reg:IsRegistered(scriptInst) then
				self:_onProp(scriptInst, "Source")
			end
		end)
	)
end

-- Tags have no Changed event: listen per tag through CollectionService,
-- for every tag that exists now and every tag that appears later.
function Session._hookTags(self: Session)
	local hooks = self._hooks
	local watched: { [string]: true } = {}
	local function watch(tag: string, isNew: boolean)
		if watched[tag] then
			return
		end
		watched[tag] = true
		local function changed(inst: Instance)
			self:_onTag(inst, tag)
		end
		table.insert(hooks, CollectionService:GetInstanceAddedSignal(tag):Connect(changed))
		table.insert(hooks, CollectionService:GetInstanceRemovedSignal(tag):Connect(changed))
		if isNew then
			-- TagAdded arrives after the first instance got the tag, so that
			-- instance's added signal fired before we listened: catch up.
			for _, inst in CollectionService:GetTagged(tag) do
				changed(inst)
			end
		end
	end
	for _, tag in CollectionService:GetAllTags() do
		watch(tag, false)
	end
	table.insert(
		hooks,
		CollectionService.TagAdded:Connect(function(tag: string)
			watch(tag, true)
		end)
	)
end

function Session._onAdded(self: Session, inst: Instance)
	if not self._reg:IsSyncable(inst) then
		return
	end
	if self._reg:IsRegistered(inst) then
		self:_onProp(inst, "Parent") -- a move, or the echo of a remote create
	else
		self._added[inst] = true
	end
end

function Session._onRemoving(self: Session, inst: Instance)
	if self._reg:IsRegistered(inst) then
		self._removed[inst] = true
	end
	self._added[inst] = nil
end

-- Hot path: Studio fires Changed many times per frame while dragging, so
-- the cheapest exits come first.
function Session._onProp(self: Session, inst: Instance, prop: string)
	if isMarked(self._dirty, inst, prop) or Schema.SkipSet(inst)[prop] then
		return
	end
	if self._reg:IdOf(inst) == nil then
		return
	end
	-- Echo check now, while the value is fresh: a remote apply sets shadow
	-- first, so its deferred Changed event lands here and stops.
	if prop == "Parent" then
		local parent = inst.Parent
		local parentId = parent and self._reg:IdOf(parent)
		if parentId ~= nil and parentId == self._shadowParent[inst] then
			return
		end
	elseif prop == "Source" then
		local shadow = self._shadow[inst]
		if shadow and shadow.Source ~= nil and inst:IsA("LuaSourceContainer") and shadow.Source == readSource(inst) then
			return
		end
	elseif prop == "WorldPivot" then
		-- Only meaningful for models without a PrimaryPart (else derived from it).
		if not (inst:IsA("Model") and inst.PrimaryPart == nil) then
			return
		end
	elseif Schema.RECREATE[prop] then
		self._recreate[inst] = true
		return
	else
		local shadow = self._shadow[inst]
		if shadow and shadow[prop] ~= nil then
			local ok, current = pcall(Schema.Get, inst, prop)
			if ok and shadowMatches(shadow[prop], current) then
				return
			end
		end
	end
	mark(self._dirty, inst, prop)
end

function Session._onAttr(self: Session, inst: Instance, attr: string)
	if self._reg:IdOf(inst) == nil then
		return
	end
	local shadow = self._shadowAttr[inst]
	if shadow and shadowMatches(shadow[attr], inst:GetAttribute(attr)) then
		return
	end
	mark(self._dirtyAttr, inst, attr)
end

-- A tag was added to or removed from inst (CollectionService signals fire
-- for both, and also when tagged instances enter or leave the place).
function Session._onTag(self: Session, inst: Instance, tag: string)
	if self._reg:IdOf(inst) == nil then
		return
	end
	local synced = self._shadowTags[inst]
	if (synced ~= nil and synced[tag] == true) == inst:HasTag(tag) then
		return -- unchanged since last sync: an echo or an enter/leave event
	end
	mark(self._dirtyTags, inst, tag)
end

-- Records the synced state that travels inside rbxm — each node's parent
-- id and tags — for a subtree that was just registered. The events it
-- produces (DescendantAdded, Changed("Parent"), CollectionService's
-- instance-added signals) are then recognised as echoes, not edits.
function Session._adoptSynced(self: Session, top: Instance, parentId: string)
	local reg = self._reg
	self._shadowParent[top] = parentId
	self:_adoptTags(top)
	for _, d in top:GetDescendants() do
		local p = d.Parent
		local pid = p and reg:IdOf(p)
		if pid and reg:IsRegistered(d) then
			self._shadowParent[d] = pid
			self:_adoptTags(d)
		end
	end
end

function Session._adoptTags(self: Session, inst: Instance)
	local tags = inst:GetTags()
	if #tags == 0 then
		self._shadowTags[inst] = nil
		return
	end
	local set: { [string]: true } = {}
	for _, tag in tags do
		set[tag] = true
	end
	self._shadowTags[inst] = set
end

-- Drops all local bookkeeping for inst and its subtree.
function Session._forget(self: Session, inst: Instance)
	self._reg:UnregisterTree(inst)
	local nodes = inst:GetDescendants()
	table.insert(nodes, inst)
	for _, node in nodes do
		self._dirty[node] = nil
		self._dirtyAttr[node] = nil
		self._dirtyTags[node] = nil
		self._added[node] = nil
		self._removed[node] = nil
		self._recreate[node] = nil
		self._shadow[node] = nil
		self._shadowAttr[node] = nil
		self._shadowTags[node] = nil
		self._shadowParent[node] = nil
		self._lastSource[node] = nil
	end
end

-- Flush: local changes -> one op batch ------------------------------------------------------

function Session._flushLoop(self: Session, gen: number)
	while self._gen == gen do
		task.wait(FLUSH_INTERVAL)
		if self._gen ~= gen then
			break
		end
		if not self._flushing and os.clock() >= self._nextFlushAt then
			self._flushing = true
			local ok, err = pcall(self._flush, self)
			self._flushing = false
			if not ok then
				self:_log(Strings.LogSendError:format(tostring(err)))
			end
		end
	end
end

-- Takes the pending set out of a field, leaving a fresh one for new events.
local function take(self: Session, field: string): any
	local taken = (self :: any)[field]
	;(self :: any)[field] = {}
	return taken
end

-- Appends an op; a conflict key makes this client win that key until acked.
function Session._push(self: Session, out: Outgoing, op: Op, key: string?)
	table.insert(out.ops, op)
	if key then
		table.insert(out.keys, key)
		self._keyInflight[key] = (self._keyInflight[key] or 0) + 1
	end
end

function Session._flush(self: Session)
	if #self._outbox > 0 then -- earlier batches first: order is part of the protocol
		self:_sendOutbox()
		return
	end
	local out: Outgoing = { ops = {}, keys = {} }
	-- Order matters: removals can mark moves dirty, additions clear the
	-- dirt their rbxm already carries, and only then are properties taken.
	self:_collectRemovals(out, take(self, "_removed"))
	local fresh = self:_collectAdditions(out, take(self, "_added"))
	self:_collectRecreates(out, take(self, "_recreate"), fresh)
	self:_collectProperties(out, take(self, "_dirty"))
	self:_collectAttributes(out, take(self, "_dirtyAttr"))
	self:_collectTags(out, take(self, "_dirtyTags"))
	if #out.ops == 0 then
		return
	end
	table.insert(self._outbox, out)
	self._nextFlushAt = os.clock() + (if #out.ops >= HEAVY_BATCH_OPS then FLUSH_INTERVAL_HEAVY else 0)
	self:_sendOutbox()
end

-- Removed and still under a root means moved; otherwise it was deleted and
-- only the topmost deleted instance needs an op (its subtree goes with it).
function Session._collectRemovals(self: Session, out: Outgoing, removed: { [Instance]: true })
	local reg = self._reg
	local deleted: { [Instance]: true } = {}
	for inst in removed do
		if reg:IsRegistered(inst) then
			if reg:IsSyncable(inst) then
				self:_onProp(inst, "Parent")
			else
				deleted[inst] = true
			end
		end
	end
	for inst in deleted do
		local parent = inst.Parent
		if not (parent and deleted[parent]) then
			self:_push(out, { t = "del", id = reg:IdOf(inst) })
		end
	end
	for inst in deleted do
		if reg:IsRegistered(inst) then
			self:_forget(inst)
		end
	end
end

-- Registers new subtrees (copies get fresh ids: Stamp sees the collision)
-- and ships each topmost one as rbxm. Returns the set of new instances.
function Session._collectAdditions(self: Session, out: Outgoing, added: { [Instance]: true }): { [Instance]: true }
	local reg = self._reg
	local fresh: { [Instance]: true } = {}
	for inst in added do
		if inst.Parent ~= nil and reg:IsSyncable(inst) and not reg:IsRegistered(inst) then
			fresh[inst] = true
		end
	end
	for inst in fresh do
		reg:RegisterTree(inst)
	end
	for inst in fresh do
		local parent = inst.Parent
		if parent == nil or fresh[parent] or not reg:IsSyncable(inst) then
			continue -- inside another new subtree, or already gone again
		end
		local parentId = reg:IdOf(parent)
		if parentId then
			Registry.Walk(inst, function(node: Instance)
				self._dirty[node] = nil -- the rbxm carries the current state
			end)
			self:_pushNew(out, inst, parentId)
		end
	end
	return fresh
end

-- Mesh swaps cannot be set by a plugin: delete + recreate under the same id.
function Session._collectRecreates(
	self: Session,
	out: Outgoing,
	recreate: { [Instance]: true },
	fresh: { [Instance]: true }
)
	local reg = self._reg
	for inst in recreate do
		local parent = inst.Parent
		local id, parentId = reg:IdOf(inst), parent and reg:IdOf(parent)
		if id and parentId and reg:IsSyncable(inst) and not fresh[inst] then
			self:_push(out, { t = "del", id = id })
			self:_pushNew(out, inst, parentId)
		end
	end
end

function Session._collectProperties(self: Session, out: Outgoing, dirty: { [Instance]: { [string]: true } })
	local reg = self._reg
	local now = os.clock()
	for inst, props in dirty do
		local id = reg:IdOf(inst)
		if id == nil or not (reg:IsRoot(inst) or reg:IsSyncable(inst)) then
			continue -- gone: a removal handles it
		end
		for prop in props do
			local key = propKey(id, prop)
			if prop == "Parent" then
				local parent = inst.Parent
				local parentId = parent and reg:IdOf(parent)
				if parentId and parentId ~= self._shadowParent[inst] then
					self:_push(out, { t = "set", id = id, k = "Parent", v = { "I", parentId } }, key)
					self._shadowParent[inst] = parentId
				end
			elseif prop == "Source" then
				self:_pushSource(out, inst, id, key, now)
			else
				self:_pushProperty(out, inst, id, prop, key)
			end
		end
	end
end

function Session._pushProperty(self: Session, out: Outgoing, inst: Instance, id: string, prop: string, key: string)
	local readOk, value = pcall(Schema.Get, inst, prop)
	if not readOk then
		Schema.SkipSet(inst)[prop] = true -- not readable here: never will be
		return
	end
	local shadow = self._shadow[inst]
	if shadow and shadowMatches(shadow[prop], value) then
		return
	end
	local encOk, encoded = Codec.Encode(value, self._resolver)
	if not encOk then
		self:_warnOnce(
			"enc." .. inst.ClassName .. "." .. prop,
			Strings.LogUnsyncable:format(inst.ClassName, prop, typeof(value))
		)
		return
	end
	self:_push(out, { t = "set", id = id, k = prop, v = encoded }, key)
	setShadow(self._shadow, inst, prop, value)
end

-- Scripts are sent whole, at most every SOURCE_MIN_INTERVAL while typing.
function Session._pushSource(self: Session, out: Outgoing, inst: Instance, id: string, key: string, now: number)
	if not inst:IsA("LuaSourceContainer") then
		return
	end
	if now - (self._lastSource[inst] or 0) < SOURCE_MIN_INTERVAL then
		mark(self._dirty, inst, "Source") -- typing burst: send on a later flush
		return
	end
	local source = readSource(inst)
	local shadow = self._shadow[inst]
	if shadow and shadow.Source == source then
		return
	end
	local _, encoded = Codec.Encode(source, self._resolver)
	self:_push(out, { t = "set", id = id, k = "Source", v = encoded }, key)
	setShadow(self._shadow, inst, "Source", source)
	self._lastSource[inst] = now
end

function Session._collectAttributes(self: Session, out: Outgoing, dirtyAttr: { [Instance]: { [string]: true } })
	local reg = self._reg
	for inst, attrs in dirtyAttr do
		local id = reg:IdOf(inst)
		if id == nil then
			continue
		end
		for attr in attrs do
			local value = inst:GetAttribute(attr)
			local encOk, encoded = Codec.Encode(value, self._resolver)
			if encOk then
				self:_push(out, { t = "attr", id = id, k = attr, v = encoded }, attrKey(id, attr))
				setShadow(self._shadowAttr, inst, attr, value)
			end
		end
	end
end

function Session._collectTags(self: Session, out: Outgoing, dirtyTags: { [Instance]: { [string]: true } })
	local reg = self._reg
	for inst, tags in dirtyTags do
		local id = reg:IdOf(inst)
		if id == nil or not (reg:IsRoot(inst) or reg:IsSyncable(inst)) then
			continue
		end
		local synced: { [string]: true }? = self._shadowTags[inst]
		for tag in tags do
			local has = inst:HasTag(tag)
			if (synced ~= nil and synced[tag] == true) ~= has then
				self:_push(out, { t = "tag", id = id, k = tag, v = has }, tagKey(id, tag))
				synced = self:_setTagShadow(inst, tag, has)
			end
		end
	end
end

-- Records one tag as synced (present or absent); returns the instance's set.
function Session._setTagShadow(self: Session, inst: Instance, tag: string, has: boolean): { [string]: true }?
	local set = self._shadowTags[inst]
	if has then
		if set == nil then
			set = {}
			self._shadowTags[inst] = set
		end
		(set :: { [string]: true })[tag] = true
	elseif set then
		set[tag] = nil
	end
	return set
end

-- Ships inst's subtree as rbxm, plus the references that leave it (rbxm
-- keeps only references inside the serialized subtree).
function Session._pushNew(self: Session, out: Outgoing, inst: Instance, parentId: string)
	local ok, raw = pcall(SerializationService.SerializeInstancesAsync, SerializationService, { inst })
	if not ok then
		self:_log(Strings.LogSerializeFailed:format(inst:GetFullName(), tostring(raw)))
		return
	end
	local text, compressed = Codec.Pack(raw)
	local reg = self._reg
	self:_push(out, {
		t = "new",
		id = reg:IdOf(inst),
		p = parentId,
		b = text,
		z = if compressed then 1 else nil,
	})
	self:_adoptSynced(inst, parentId)
	Registry.Walk(inst, function(node: Instance)
		local nodeId = reg:IdOf(node)
		if nodeId == nil then
			return
		end
		Schema.ForEachRef(node, function(prop: string, target: Instance)
			local targetId = reg:IdOf(target)
			if targetId and target ~= inst and not target:IsDescendantOf(inst) then
				self:_push(out, { t = "set", id = nodeId, k = prop, v = { "I", targetId } }, propKey(nodeId, prop))
				setShadow(self._shadow, node, prop, target)
			end
		end)
	end)
end

-- Sends queued batches in order; a failure leaves them queued for retry.
function Session._sendOutbox(self: Session)
	while #self._outbox > 0 do
		local entry = self._outbox[1]
		local encodedOk, body = pcall(Net.ToJson, entry.ops)
		if not encodedOk then
			self:_log(Strings.LogBatchDropped:format(tostring(body)))
			table.remove(self._outbox, 1)
			self:_releaseKeys(entry.keys, nil)
			continue
		end
		local ok, reply, status = self._net:Json("POST", "/ops?client=" .. self._clientId, body)
		if not ok then
			if status == 409 then
				self:_rehello()
			end
			self._nextFlushAt = os.clock() + SEND_RETRY_DELAY
			self:_log(Strings.LogSendRetry:format(status))
			return
		end
		table.remove(self._outbox, 1)
		self:_releaseKeys(entry.keys, reply.rev)
	end
end

function Session._releaseKeys(self: Session, keys: { string }, rev: number?)
	for _, key in keys do
		local n = (self._keyInflight[key] or 1) - 1
		if n > 0 then
			self._keyInflight[key] = n
		else
			self._keyInflight[key] = nil
		end
		local previous: number = self._keyRev[key] or 0
		if rev ~= nil and rev > previous then
			self._keyRev[key] = rev
		end
	end
end

-- True when this client's own change to a key must win over a remote op at
-- rev: the change is still unsent, in flight, or was sequenced after rev.
function Session._localWins(self: Session, pending: boolean, key: string, rev: number): boolean
	if pending or self._keyInflight[key] then
		return true
	end
	local mine = self._keyRev[key]
	return mine ~= nil and mine > rev
end

-- Poll: remote batches -> this place ----------------------------------------------------------

function Session._pollLoop(self: Session, gen: number)
	local failures = 0
	while self._gen == gen do
		local ok, reply, status = self._net:Json(
			"GET",
			("/poll?client=%d&since=%d&wait=%d"):format(self._clientId, self._appliedRev, POLL_WAIT)
		)
		if self._gen ~= gen then
			return
		end
		if not ok then
			failures += 1
			if status == 409 then
				local hello = self:_rehello()
				if hello and hello.rev < self._appliedRev then
					self:_resync(gen, Strings.LogResyncHistoryLost)
					return
				end
			end
			if failures == 3 then
				self:_setStatus("Error", Strings.StatusReconnecting)
			end
			task.wait(math.min(1 + failures, 10))
			continue
		end
		if failures >= 3 then
			self:_log(Strings.LogRestored)
			self._status = "Live"
		end
		failures = 0
		local poll: Types.PollReply = reply
		if poll.resync then
			self:_resync(gen, Strings.LogResyncCompacted)
			return
		end
		if poll.peers then
			self._cb.OnPeers(poll.peers)
		end
		local batches: { Batch } = poll.b or {}
		for _, batch in batches do
			if self._gen ~= gen then
				return
			end
			self:_applyBatch(batch)
		end
		if type(poll.upto) == "number" and poll.upto > self._appliedRev then
			self._appliedRev = poll.upto
		end
		self:_pruneKeyRevs()
		if self._status == "Live" then
			self:_showLive()
		end
		if poll.want then
			self:_spawnCompact(gen)
		end
	end
end

-- Once everything up to a key's rev is applied, no older remote op for it
-- can still arrive, so the entry has done its job.
function Session._pruneKeyRevs(self: Session)
	local applied = self._appliedRev
	for key, rev in self._keyRev do
		if rev <= applied and not self._keyInflight[key] then
			self._keyRev[key] = nil
		end
	end
end

function Session._resync(self: Session, gen: number, reason: string)
	self:_log(Strings.LogResync:format(reason))
	self:_bye()
	self:_teardown()
	if self._gen ~= gen then
		return
	end
	local ok, err = pcall(function()
		self:_run(gen, true)
	end)
	if not ok and self._gen == gen then
		self:_setStatus("Error", tostring(err))
		self:_teardown()
	end
end

function Session._applyBatch(self: Session, batch: Batch)
	for index, op in batch.o do
		local ok, err = pcall(self._applyOp, self, op, batch.r, index)
		if not ok then
			-- One warning per op kind and property, not one per failing instance.
			self:_warnOnce("apply." .. op.t .. "." .. tostring(op.k), Strings.LogApplyFailed:format(tostring(err)))
		end
	end
	self._appliedRev = math.max(self._appliedRev, batch.r)
end

function Session._applyOp(self: Session, op: Op, rev: number, index: number)
	local reg = self._reg
	if op.t == "set" then
		local id, prop = op.id :: string, op.k :: string
		local inst = reg:Find(id)
		if inst and not self:_localWins(isMarked(self._dirty, inst, prop), propKey(id, prop), rev) then
			self:_applyProperty(inst, prop, op.v)
		end
	elseif op.t == "attr" then
		local id, attr = op.id :: string, op.k :: string
		local inst = reg:Find(id)
		if inst and not self:_localWins(isMarked(self._dirtyAttr, inst, attr), attrKey(id, attr), rev) then
			local ok, value = Codec.Decode(op.v, self._resolver)
			if ok then
				setShadow(self._shadowAttr, inst, attr, value)
				inst:SetAttribute(attr, value)
			end
		end
	elseif op.t == "tag" then
		local id, tag = op.id :: string, op.k :: string
		local inst = reg:Find(id)
		if inst and not self:_localWins(isMarked(self._dirtyTags, inst, tag), tagKey(id, tag), rev) then
			local has = op.v == true
			self:_setTagShadow(inst, tag, has) -- before the change: its signal is an echo
			if has then
				inst:AddTag(tag)
			else
				inst:RemoveTag(tag)
			end
		end
	elseif op.t == "new" then
		local parentId = op.p :: string
		local parent = reg:Find(parentId)
		if parent == nil or (op.id and reg:Find(op.id)) then
			return -- parent deleted meanwhile, or we already have it
		end
		local raw = Codec.Unpack(op.b :: string, op.z == 1)
		local nextId = Registry.SequentialIds(("r%d.%d."):format(rev, index))
		for _, inst in SerializationService:DeserializeInstancesAsync(raw) do
			self:_placeRemote(inst, parent, parentId, nextId)
		end
	elseif op.t == "del" then
		local inst = reg:Find(op.id :: string)
		if inst and not reg:IsRoot(inst) then
			self:_forget(inst)
			inst:Destroy()
		end
	end
end

-- Writes one remote property value, recording it as the synced shadow first
-- so the local Changed echo is ignored.
function Session._applyProperty(self: Session, inst: Instance, prop: string, encoded: any)
	local reg = self._reg
	if prop == "Parent" then
		local targetId = type(encoded) == "table" and encoded[2]
		local parent = type(targetId) == "string" and reg:Find(targetId) or nil
		if parent and not reg:IsRoot(inst) then
			self._shadowParent[inst] = targetId :: string
			inst.Parent = parent
		end
		return
	end
	local ok, value = Codec.Decode(encoded, self._resolver)
	if not ok then
		return
	end
	if prop == "Source" then
		if type(value) == "string" and inst:IsA("LuaSourceContainer") then
			setShadow(self._shadow, inst, "Source", value)
			self:_writeSource(inst, value)
		end
		return
	end
	local skip = Schema.SkipSet(inst)
	if skip[prop] then
		return
	end
	if not pcall(Schema.Set, inst, prop, value) then
		skip[prop] = true -- read-only for plugins; stop trying (and stop sending)
		return
	end
	local readOk, readBack = pcall(Schema.Get, inst, prop)
	setShadow(self._shadow, inst, prop, if readOk then readBack else value)
end

-- UpdateSourceAsync keeps an open script editor in step (it also works on
-- closed scripts); .Source is the fallback when the editor API refuses.
function Session._writeSource(self: Session, inst: Instance, source: string)
	local updated = pcall(function()
		ScriptEditorService:UpdateSourceAsync(inst :: LuaSourceContainer, function(): string
			return source
		end)
	end)
	if not updated then
		pcall(Schema.Set, inst, "Source", source)
	end
end

-- Snapshot upload --------------------------------------------------------------------------------

function Session._spawnCompact(self: Session, gen: number)
	task.spawn(function()
		local ok, err = pcall(self._compact, self, gen)
		if not ok then
			self:_log(Strings.LogSnapshotFailed:format(tostring(err)))
		end
	end)
end

function Session._hasUnsentChanges(self: Session): boolean
	return self._flushing
		or #self._outbox > 0
		or next(self._dirty) ~= nil
		or next(self._dirtyAttr) ~= nil
		or next(self._dirtyTags) ~= nil
		or next(self._added) ~= nil
		or next(self._removed) ~= nil
		or next(self._keyInflight) ~= nil
end

-- Waits until nothing local is unsent, then uploads at the applied rev, so
-- the snapshot equals the server's state at exactly that rev.
function Session._compact(self: Session, gen: number)
	if self._snapshotting then
		return
	end
	local deadline = os.clock() + COMPACT_QUIET_LIMIT
	while self._gen == gen and self:_hasUnsentChanges() do
		if os.clock() > deadline then
			return -- the server will ask again later
		end
		task.wait(0.5)
	end
	if self._gen == gen then
		self:_uploadSnapshot(gen, self._appliedRev, false)
	end
end

-- verbose: report progress in the status line (initial upload only; a
-- background compaction must not hijack the "Live" status).
function Session._uploadSnapshot(self: Session, gen: number, base: number, verbose: boolean)
	self._snapshotting = true
	local ok, err = pcall(function()
		self:_buildAndSendSnapshot(gen, base, verbose)
	end)
	self._snapshotting = false
	if not ok then
		error(err, 0)
	end
end

function Session._buildAndSendSnapshot(self: Session, gen: number, base: number, verbose: boolean)
	local started = os.clock()
	local function cancelled(): boolean
		return self._gen ~= gen
	end
	local progress: Snapshot.Progress? = nil
	if verbose then
		progress = function(stage, done, total)
			local text = if stage == "pack" then Strings.StatusPacking else Strings.StatusUploading
			self:_setStatus("Loading", text:format(done, total))
		end
	end
	local manifest, groups = Snapshot.Plan(self._reg, self._resolver)
	local parts = Snapshot.Pack(manifest, groups, cancelled, function(inst: Instance, reason: string)
		self:_log(Strings.LogSnapshotSkipped:format(inst:GetFullName(), reason))
	end, progress)
	if parts == nil then
		return
	end
	local result = Snapshot.Upload(self._net, self._clientId, base, manifest, parts, cancelled, progress)
	if result == "current" then
		self:_log(Strings.LogSnapshotCurrent)
	elseif result == "sent" then
		local bytes = 0
		for _, part in parts do
			bytes += #part
		end
		self:_log(Strings.LogSnapshotDone:format(base, self._reg:Count(), bytes / 1048576, os.clock() - started))
	end
end

return Session
