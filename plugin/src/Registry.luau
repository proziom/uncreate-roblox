--!strict
--[[
	Registry — which instances are synced and under what id.

	Synced roots are fixed singletons (services, StarterPlayerScripts, ...);
	their ids are "@Name" and they are never created or destroyed by sync.
	Every other synced instance carries its id in the attribute UncreateId, so
	ids survive save/load, serialization and Ctrl+Z. A copy (Ctrl+D, paste)
	carries its source's id; Stamp detects the collision and re-ids the copy.

	The registry owns the per-instance change subscriptions and reports raw
	property / attribute names to the two handlers given to Registry.new.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local HttpService = game:GetService("HttpService")

local Registry = {}
Registry.__index = Registry

export type ChangeHandler = (inst: Instance, name: string) -> ()
export type IdSource = () -> string

local ATTR = "UncreateId"
Registry.ATTR = ATTR

local ROOT_SERVICES: { string } = {
	"Workspace",
	"Lighting",
	"MaterialService",
	"ReplicatedFirst",
	"ReplicatedStorage",
	"ServerScriptService",
	"ServerStorage",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"SoundService",
	"Teams",
}

-- Singleton children that act as roots themselves.
local NESTED_ROOTS: { [string]: { string } } = {
	StarterPlayer = { "StarterPlayerScripts", "StarterCharacterScripts" },
}

-- ValueBase.Changed passes the new value instead of a property name.
local VALUE_PROPS: { string } = { "Value", "Name", "Parent" }

export type Registry = typeof(setmetatable(
	{} :: {
		_byId: { [string]: Instance },
		_idOf: { [Instance]: string },
		_conns: { [Instance]: { RBXScriptConnection } },
		_rootById: { [string]: Instance },
		_rootIdOf: { [Instance]: string },
		_rootOrder: { string },
		_onProp: ChangeHandler,
		_onAttr: ChangeHandler,
		_prefix: string,
		_counter: number, -- last id number handed out by NewId
		_size: number, -- registered instances, kept live (Count is called per poll)
	},
	Registry
))

local function base36(n: number): string
	local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
	if n == 0 then
		return "0"
	end
	local out = ""
	while n > 0 do
		local d = n % 36
		out = string.sub(digits, d + 1, d + 1) .. out
		n = n // 36
	end
	return out
end

function Registry.new(onProp: ChangeHandler, onAttr: ChangeHandler): Registry
	local guid = string.lower((string.gsub(HttpService:GenerateGUID(false), "-", "")))
	local self = setmetatable({
		_byId = {},
		_idOf = {},
		_conns = {},
		_rootById = {},
		_rootIdOf = {},
		_rootOrder = {},
		_onProp = onProp,
		_onAttr = onAttr,
		_prefix = string.sub(guid, 1, 10),
		_counter = 0,
		_size = 0,
	}, Registry)
	for _, serviceName in ROOT_SERVICES do
		local ok, service = pcall(game.GetService, game, serviceName)
		if ok and service then
			self:_addRoot("@" .. serviceName, service)
			local nested = NESTED_ROOTS[serviceName]
			if nested then
				for _, childName in nested do
					local child = service:FindFirstChild(childName)
					if child then
						self:_addRoot("@" .. childName, child)
					end
				end
			end
		end
	end
	return self
end

function Registry._addRoot(self: Registry, id: string, inst: Instance)
	self._rootById[id] = inst
	self._rootIdOf[inst] = id
	table.insert(self._rootOrder, id)
end

-- Roots -------------------------------------------------------------------

function Registry.RootIds(self: Registry): { string }
	return self._rootOrder
end

function Registry.Root(self: Registry, id: string): Instance?
	return self._rootById[id]
end

function Registry.IsRoot(self: Registry, inst: Instance): boolean
	return self._rootIdOf[inst] ~= nil
end

-- Direct children of a root that sync never touches.
function Registry.IsExcludedTopLevel(self: Registry, child: Instance, root: Instance): boolean
	if self._rootIdOf[child] ~= nil or child:IsA("Terrain") then
		return true
	end
	return root:IsA("Workspace") and child:IsA("Camera")
end

-- Children of a root that belong in a snapshot, in GetChildren order.
function Registry.SyncedChildren(self: Registry, root: Instance): { Instance }
	local out: { Instance } = {}
	for _, child in root:GetChildren() do
		if child.Archivable and not self:IsExcludedTopLevel(child, root) then
			table.insert(out, child)
		end
	end
	return out
end

-- True when inst sits (archivably) under a root and is not a root itself.
function Registry.IsSyncable(self: Registry, inst: Instance): boolean
	if self._rootIdOf[inst] ~= nil then
		return false
	end
	local node: Instance = inst
	while true do
		if not node.Archivable then
			return false
		end
		local parent = node.Parent
		if parent == nil then
			return false
		end
		if self._rootIdOf[parent] ~= nil then
			return not self:IsExcludedTopLevel(node, parent)
		end
		node = parent
	end
end

-- The ancestor of inst that is a direct child of a root (inst itself if so).
function Registry.TopLevelOf(self: Registry, inst: Instance): Instance?
	local node: Instance = inst
	while true do
		local parent = node.Parent
		if parent == nil then
			return nil
		end
		if self._rootIdOf[parent] ~= nil then
			return node
		end
		node = parent
	end
end

-- Ids ---------------------------------------------------------------------

function Registry.IdOf(self: Registry, inst: Instance): string?
	return self._rootIdOf[inst] or self._idOf[inst]
end

function Registry.Find(self: Registry, id: string): Instance?
	return self._rootById[id] or self._byId[id]
end

function Registry.IsRegistered(self: Registry, inst: Instance): boolean
	return self._idOf[inst] ~= nil
end

function Registry.NewId(self: Registry): string
	self._counter += 1
	return self._prefix .. "." .. base36(self._counter)
end

-- Deterministic ids for unstamped instances that arrive from the server
-- (raw .rbxm imports): every client walks the same tree in the same order.
function Registry.SequentialIds(prefix: string): IdSource
	local n = 0
	return function(): string
		n += 1
		return prefix .. base36(n)
	end
end

-- Ensures inst has an id that is unique in this place, writing the
-- attribute when it is missing or collides with another live instance.
function Registry.Stamp(self: Registry, inst: Instance, nextId: IdSource?): string
	local current = inst:GetAttribute(ATTR)
	if type(current) == "string" and current ~= "" then
		local owner = self._byId[current]
		if not owner or owner == inst then
			return current
		end
	end
	local id = if nextId then nextId() else self:NewId()
	inst:SetAttribute(ATTR, id)
	return id
end

-- Subscriptions -------------------------------------------------------------

function Registry.Register(self: Registry, inst: Instance, id: string)
	if self._idOf[inst] == id then
		return
	end
	self:Unregister(inst)
	local previous = self._byId[id]
	if previous and previous ~= inst then
		self:Unregister(previous)
	end
	self._byId[id] = inst
	self._idOf[inst] = id
	self._conns[inst] = self:_connect(inst)
	self._size += 1
end

function Registry._connect(self: Registry, inst: Instance): { RBXScriptConnection }
	local onProp, onAttr = self._onProp, self._onAttr
	local conns: { RBXScriptConnection } = {}
	if inst:IsA("ValueBase") then
		for _, prop in VALUE_PROPS do
			table.insert(
				conns,
				inst:GetPropertyChangedSignal(prop):Connect(function()
					onProp(inst, prop)
				end)
			)
		end
	else
		table.insert(
			conns,
			inst.Changed:Connect(function(prop: string)
				onProp(inst, prop)
			end)
		)
	end
	table.insert(
		conns,
		inst.AttributeChanged:Connect(function(name: string)
			if name ~= ATTR then
				onAttr(inst, name)
			end
		end)
	)
	return conns
end

function Registry.Unregister(self: Registry, inst: Instance)
	local id = self._idOf[inst]
	if id == nil then
		return
	end
	local conns: { RBXScriptConnection }? = self._conns[inst]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
	end
	self._conns[inst] = nil
	self._idOf[inst] = nil
	self._size -= 1
	if self._byId[id] == inst then
		self._byId[id] = nil
	end
end

-- Visits root and its archivable descendants, parents before children, in
-- GetChildren order. Deterministic: identical trees give identical orders.
function Registry.Walk(root: Instance, visit: (Instance) -> ())
	local stack: { Instance } = { root }
	while #stack > 0 do
		local node = table.remove(stack) :: Instance
		if node.Archivable then
			visit(node)
			local children = node:GetChildren()
			for i = #children, 1, -1 do
				table.insert(stack, children[i])
			end
		end
	end
end

-- Stamps and registers root and every archivable descendant.
function Registry.RegisterTree(self: Registry, root: Instance, nextId: IdSource?)
	Registry.Walk(root, function(node: Instance)
		if self._idOf[node] == nil then
			self:Register(node, self:Stamp(node, nextId))
		end
	end)
end

-- Registers a tree that came from the server. Unlike RegisterTree, ids in
-- the data win over local state: a collision means the local holder is
-- stale, never that the incoming instance needs a new id. Missing ids are
-- filled from nextId, which must be deterministic across clients.
function Registry.AdoptTree(self: Registry, root: Instance, nextId: IdSource)
	Registry.Walk(root, function(node: Instance)
		local id = node:GetAttribute(ATTR)
		if type(id) ~= "string" or id == "" then
			id = nextId()
			node:SetAttribute(ATTR, id)
		end
		self:Register(node, id :: string)
	end)
end

-- Unregisters inst and everything below it; returns the ids dropped.
function Registry.UnregisterTree(self: Registry, inst: Instance): { string }
	local dropped: { string } = {}
	local function drop(node: Instance)
		local id = self._idOf[node]
		if id then
			table.insert(dropped, id)
			self:Unregister(node)
		end
	end
	drop(inst)
	for _, d in inst:GetDescendants() do
		drop(d)
	end
	return dropped
end

function Registry.Count(self: Registry): number
	return self._size
end

function Registry.Clear(self: Registry)
	for _, conns in self._conns do
		for _, conn in conns do
			conn:Disconnect()
		end
	end
	table.clear(self._conns)
	self._size = 0
	table.clear(self._byId)
	table.clear(self._idOf)
end

return Registry
