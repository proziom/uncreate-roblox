--[[
	rbxmock — just enough of the Roblox engine to run the Uncreate plugin's
	sync engine headless under Lune, against a real uncreate-server.

	Faithful where the engine depends on it: deferred signals (handlers run
	via task.defer, like SignalBehavior.Deferred), Changed only on actual
	change, DescendantAdded/Removing on every ancestor, attributes, Clone
	copies attributes (so copies collide on UncreateId), Destroy locks Parent.
	Serialization is a JSON stand-in for rbxm with the same contract:
	subtree in, subtree out, references outside the subtree dropped.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local net = require("@lune/net")
local serde = require("@lune/serde")
local task = require("@lune/task")

local M = {}

-- Datatypes ------------------------------------------------------------------

local Vector3Meta = {}
Vector3Meta.__index = function(v, k)
	if k == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	end
	return nil
end
Vector3Meta.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3Meta.__tostring = function(v)
	return ("%g, %g, %g"):format(v.X, v.Y, v.Z)
end
local Vector3 = {
	new = function(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3Meta)
	end,
}
Vector3Meta.__add = function(a, b)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3Meta.__sub = function(a, b)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3Meta.__mul = function(a, k)
	return Vector3.new(a.X * k, a.Y * k, a.Z * k)
end
local function unit(v)
	local m = v.Magnitude
	return Vector3.new(v.X / m, v.Y / m, v.Z / m)
end
local function cross(a, b)
	return Vector3.new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end

local CFrameMeta = {}
CFrameMeta.__eq = function(a, b)
	for i = 1, 12 do
		if a._c[i] ~= b._c[i] then
			return false
		end
	end
	return true
end
CFrameMeta.__index = function(cf, k)
	if k == "Position" then
		return Vector3.new(cf._c[1], cf._c[2], cf._c[3])
	elseif k == "Lerp" then
		return function(a, b, t) -- test-only: positions interpolate, rotation jumps
			local c = table.clone(b._c)
			for i = 1, 3 do
				c[i] = a._c[i] + (b._c[i] - a._c[i]) * t
			end
			return setmetatable({ _c = c }, CFrameMeta)
		end
	elseif k == "LookVector" then
		return Vector3.new(-cf._c[6], -cf._c[9], -cf._c[12])
	elseif k == "GetComponents" then
		return function(self)
			return table.unpack(self._c)
		end
	end
	return nil
end
local CFrame = {
	new = function(...)
		local a = { ... }
		if #a == 1 then -- CFrame.new(Vector3)
			a = { a[1].X, a[1].Y, a[1].Z, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
		elseif #a == 3 then
			a = { a[1], a[2], a[3], 1, 0, 0, 0, 1, 0, 0, 0, 1 }
		elseif #a == 0 then
			a = { 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 }
		end
		return setmetatable({ _c = a }, CFrameMeta)
	end,
}

-- Components: x, y, z, then the rotation matrix row by row.
CFrame.lookAt = function(pos, target)
	local f = unit(target - pos)
	local r = unit(cross(f, Vector3.new(0, 1, 0)))
	local u = cross(r, f)
	return CFrame.new(pos.X, pos.Y, pos.Z, r.X, u.X, -f.X, r.Y, u.Y, -f.Y, r.Z, u.Z, -f.Z)
end
CFrame.Angles = function(rx, ry, rz)
	local function rot(axis, a)
		local c, s = math.cos(a), math.sin(a)
		if axis == "x" then
			return CFrame.new(0, 0, 0, 1, 0, 0, 0, c, -s, 0, s, c)
		elseif axis == "y" then
			return CFrame.new(0, 0, 0, c, 0, s, 0, 1, 0, -s, 0, c)
		end
		return CFrame.new(0, 0, 0, c, -s, 0, s, c, 0, 0, 0, 1)
	end
	return rot("x", rx) * rot("y", ry) * rot("z", rz)
end
CFrameMeta.__mul = function(a, b)
	local A, B = a._c, b._c
	local function rot(i, j) -- (R_a * R_b)[i][j], 1-based rows/cols
		local sum = 0
		for k = 1, 3 do
			sum += A[3 + (i - 1) * 3 + k] * B[3 + (k - 1) * 3 + j]
		end
		return sum
	end
	local px = A[1] + A[4] * B[1] + A[5] * B[2] + A[6] * B[3]
	local py = A[2] + A[7] * B[1] + A[8] * B[2] + A[9] * B[3]
	local pz = A[3] + A[10] * B[1] + A[11] * B[2] + A[12] * B[3]
	return CFrame.new(px, py, pz, rot(1, 1), rot(1, 2), rot(1, 3), rot(2, 1), rot(2, 2), rot(2, 3), rot(3, 1), rot(3, 2), rot(3, 3))
end

local Color3Meta = {}
Color3Meta.__index = Color3Meta
Color3Meta.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
local Color3 = {
	new = function(r, g, b)
		return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3Meta)
	end,
}
Color3.fromHSV = Color3.new -- test-only: hue math is irrelevant here
Color3.fromRGB = function(r, g, b)
	return Color3.new(r / 255, g / 255, b / 255)
end
Color3Meta.__index = function(c, k)
	if k == "ToHex" then
		return function(self)
			return ("%02x%02x%02x"):format(self.R * 255, self.G * 255, self.B * 255)
		end
	end
	return nil
end

local UDim2 = {
	new = function(...)
		return { ... }
	end,
}
UDim2.fromScale, UDim2.fromOffset = UDim2.new, UDim2.new
local TweenInfo = {
	new = function(time)
		return { Time = time }
	end,
}
local Vector2 = {
	new = function(x, y)
		return { X = x, Y = y }
	end,
}

local EnumItemMeta = {}
EnumItemMeta.__tostring = function(e)
	return "Enum." .. tostring(e.EnumType) .. "." .. e.Name
end
local Enum = setmetatable({}, {
	__index = function(enums, typeName)
		local enumType = setmetatable({}, {
			__tostring = function()
				return typeName
			end,
		})
		local items = setmetatable({}, {
			__index = function(t, name)
				local item = setmetatable({ Name = name, EnumType = enumType }, EnumItemMeta)
				rawset(t, name, item)
				return item
			end,
			__tostring = function()
				return typeName
			end,
		})
		rawset(enums, typeName, items)
		return items
	end,
})

-- Signals --------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal
function Signal.new()
	return setmetatable({ _conns = {} }, Signal)
end
function Signal:Connect(fn)
	local conn = { Connected = true }
	function conn.Disconnect()
		conn.Connected = false
	end
	conn.fn = fn
	table.insert(self._conns, conn)
	return conn
end
function Signal:Fire(...)
	local args = table.pack(...)
	for _, conn in self._conns do
		if conn.Connected then
			task.defer(function()
				if conn.Connected then
					conn.fn(table.unpack(args, 1, args.n))
				end
			end)
		end
	end
end
function Signal:DisconnectAll()
	for _, conn in self._conns do
		conn.Connected = false
	end
	table.clear(self._conns)
end

-- Instances ------------------------------------------------------------------

local SUPER = {
	Part = "BasePart",
	BasePart = "PVInstance",
	Terrain = "BasePart",
	PVInstance = "Instance",
	Model = "PVInstance",
	WorldRoot = "Model",
	Workspace = "WorldRoot",
	Folder = "Instance",
	Script = "BaseScript",
	LocalScript = "Script",
	BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
	StringValue = "ValueBase",
	ObjectValue = "ValueBase",
	ValueBase = "Instance",
	Camera = "Instance",
	Attachment = "Instance",
}

local DEFAULTS = {
	Instance = { Name = "Instance", Archivable = true },
	BasePart = function()
		return {
			CFrame = CFrame.new(),
			Size = Vector3.new(4, 1, 2),
			Color = Color3.new(0.6, 0.6, 0.6),
			Anchored = false,
			Transparency = 0,
		}
	end,
	LuaSourceContainer = { Source = "" },
	StringValue = { Value = "" },
	Lighting = { ClockTime = 14, Brightness = 2 },
	Workspace = { Gravity = 196.2 },
}

local InstanceMeta = {}
local idCounter = 0

local function isA(className, wanted)
	local c = className
	while c do
		if c == wanted then
			return true
		end
		c = SUPER[c] or (c ~= "Instance" and "Instance" or nil)
	end
	return false
end

-- Properties whose default is nil still exist (reading them must not error).
local NILABLE = { Model = { PrimaryPart = true }, ObjectValue = { Value = true } }

-- Viewport-only classes (presence markers): any property is accepted.
local LOOSE = {
	SphereHandleAdornment = true,
	CylinderHandleAdornment = true,
	ImageHandleAdornment = true,
	BillboardGui = true,
	TextLabel = true,
}

local function hasProp(inst, k)
	if inst._props[k] ~= nil or LOOSE[inst._class] then
		return true
	end
	local c = inst._class
	while c do
		local n = NILABLE[c]
		if n and n[k] then
			return true
		end
		c = SUPER[c] or (c ~= "Instance" and "Instance" or nil)
	end
	return false
end

local methods = {}

local function new(className)
	idCounter += 1
	local self = {
		_class = className,
		_props = {},
		_attrs = {},
		_tags = {}, -- set of tag names
		_children = {},
		_parent = nil,
		_destroyed = false,
		_uid = idCounter,
		_signals = {},
	}
	local c = className
	local chain = {}
	while c do
		table.insert(chain, 1, c)
		c = SUPER[c] or (c ~= "Instance" and "Instance" or nil)
	end
	for _, cls in chain do
		local d = DEFAULTS[cls]
		if type(d) == "function" then
			d = d()
		end
		for k, v in d or {} do
			self._props[k] = v
		end
	end
	self._props.Name = className
	return setmetatable(self, InstanceMeta)
end

local function signal(self, name)
	local s = self._signals[name]
	if not s then
		s = Signal.new()
		self._signals[name] = s
	end
	return s
end

local function ancestors(inst)
	local out = {}
	local p = inst._parent
	while p do
		table.insert(out, p)
		p = p._parent
	end
	return out
end

local function subtree(inst)
	local out = { inst }
	local i = 1
	while i <= #out do
		local node = out[i]
		for _, c in node._children do
			table.insert(out, c)
		end
		i += 1
	end
	return out
end

-- The DataModel an instance lives in, if any (CollectionService only
-- reports instances that are inside one).
local function gameOf(inst)
	local node = inst
	while node._parent do
		node = node._parent
	end
	return if node._class == "DataModel" then node else nil
end

local function fireTag(game, inst, tag, added)
	local cs = game._services.CollectionService
	if added and not cs._known[tag] then
		cs._known[tag] = true
		cs.TagAdded:Fire(tag) -- deferred: lands after the instance signal below
	end
	local sig = (if added then cs._added else cs._removed)[tag]
	if sig then
		sig:Fire(inst)
	end
end

local function setParent(self, parent)
	if self._destroyed then
		error("The Parent property of " .. self._props.Name .. " is locked")
	end
	if parent == self._parent then
		return
	end
	local p = parent
	while p do
		if p == self then
			error("Attempt to set parent of " .. self._props.Name .. " to a descendant")
		end
		p = p._parent
	end
	local nodes = subtree(self)
	local wasIn = gameOf(self)
	if self._parent then
		for _, a in ancestors(self) do
			for _, n in nodes do
				signal(a, "DescendantRemoving"):Fire(n)
			end
		end
		local siblings = self._parent._children
		table.remove(siblings, table.find(siblings, self))
	end
	self._parent = parent
	if parent then
		table.insert(parent._children, self)
	end
	signal(self, "Changed"):Fire("Parent")
	signal(self, "Parent"):Fire()
	local isIn = gameOf(self)
	if wasIn ~= isIn then -- tagged instances entering / leaving a place
		for _, n in nodes do
			for tag in n._tags do
				if wasIn then
					fireTag(wasIn, n, tag, false)
				end
				if isIn then
					fireTag(isIn, n, tag, true)
				end
			end
		end
	end
	if parent then
		for _, a in ancestors(self) do
			for _, n in nodes do
				signal(a, "DescendantAdded"):Fire(n)
			end
		end
	end
end

InstanceMeta.__index = function(self, k)
	if type(k) == "string" and string.sub(k, 1, 1) == "_" then
		return nil -- internal field currently nil
	end
	if k == "ClassName" then
		return self._class
	elseif k == "Parent" then
		return self._parent
	elseif k == "Changed" or k == "DescendantAdded" or k == "DescendantRemoving" or k == "AttributeChanged" then
		return signal(self, k)
	elseif methods[k] then
		return methods[k]
	end
	if k == "Position" and isA(self._class, "BasePart") then
		return self._props.CFrame.Position
	end
	local v = self._props[k]
	if v == nil and not hasProp(self, k) then
		local child = methods.FindFirstChild(self, k)
		if child then
			return child
		end
		error(k .. " is not a valid member of " .. self._class)
	end
	return v
end

InstanceMeta.__newindex = function(self, k, v)
	if type(k) == "string" and string.sub(k, 1, 1) == "_" then
		rawset(self, k, v)
		return
	end
	if k == "Parent" then
		setParent(self, v)
		return
	end
	if k == "Position" and isA(self._class, "BasePart") then
		local c = self._props.CFrame._c
		self._props.CFrame = CFrame.new(v.X, v.Y, v.Z, c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
		signal(self, "Changed"):Fire("CFrame")
		signal(self, "Changed"):Fire("Position")
		return
	end
	if self._props[k] == nil and not hasProp(self, k) then
		error(k .. " is not a valid member of " .. self._class)
	end
	if self._props[k] == v then
		return
	end
	self._props[k] = v
	if isA(self._class, "ValueBase") and k == "Value" then
		signal(self, "Changed"):Fire(v)
	else
		signal(self, "Changed"):Fire(k)
	end
	signal(self, k):Fire()
	if k == "CFrame" and isA(self._class, "BasePart") then
		signal(self, "Changed"):Fire("Position")
	end
end

InstanceMeta.__tostring = function(self)
	return self._props.Name
end

function methods.IsA(self, className)
	return isA(self._class, className)
end
function methods.GetChildren(self)
	return table.clone(self._children)
end
function methods.GetDescendants(self)
	local out = {}
	local function walk(node)
		for _, c in node._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods.FindFirstChildOfClass(self, className)
	for _, c in self._children do
		if c._class == className then
			return c
		end
	end
	return nil
end
function methods.FindFirstChild(self, name)
	for _, c in self._children do
		if c._props.Name == name then
			return c
		end
	end
	return nil
end
function methods.IsDescendantOf(self, other)
	local p = self._parent
	while p do
		if p == other then
			return true
		end
		p = p._parent
	end
	return false
end
function methods.GetFullName(self)
	local parts = {}
	local n = self
	while n and n._class ~= "DataModel" do
		table.insert(parts, 1, n._props.Name)
		n = n._parent
	end
	return table.concat(parts, ".")
end
function methods.GetAttribute(self, name)
	return self._attrs[name]
end
function methods.GetAttributes(self)
	return table.clone(self._attrs)
end
function methods.AddTag(self, tag)
	if self._tags[tag] then
		return
	end
	self._tags[tag] = true
	local g = gameOf(self)
	if g then
		fireTag(g, self, tag, true)
	end
end
function methods.RemoveTag(self, tag)
	if not self._tags[tag] then
		return
	end
	self._tags[tag] = nil
	local g = gameOf(self)
	if g then
		fireTag(g, self, tag, false)
	end
end
function methods.HasTag(self, tag)
	return self._tags[tag] == true
end
function methods.GetTags(self)
	local out = {}
	for tag in self._tags do
		table.insert(out, tag)
	end
	table.sort(out)
	return out
end
function methods.SetAttribute(self, name, value)
	if self._attrs[name] == value then
		return
	end
	self._attrs[name] = value
	signal(self, "AttributeChanged"):Fire(name)
end
function methods.GetPropertyChangedSignal(self, prop)
	return signal(self, prop)
end
function methods.Destroy(self)
	if self._destroyed then
		return
	end
	for _, c in table.clone(self._children) do
		methods.Destroy(c)
	end
	setParent(self, nil)
	self._destroyed = true
	for _, s in self._signals do
		s:DisconnectAll()
	end
end
function methods.Clone(self)
	if not self._props.Archivable then
		return nil
	end
	local copy = new(self._class)
	for k, v in self._props do
		copy._props[k] = v
	end
	for k, v in self._attrs do
		copy._attrs[k] = v
	end
	for k in self._tags do
		copy._tags[k] = true
	end
	for _, c in self._children do
		local cc = methods.Clone(c)
		if cc then
			setParent(cc, copy)
		end
	end
	return copy
end
function methods.GetService(self, name)
	return self._services[name]
end
function methods.ClearAllChildren(self)
	for _, c in table.clone(self._children) do
		methods.Destroy(c)
	end
end

-- typeof ------------------------------------------------------------------------

local rawTypeof = typeof
local function mockTypeof(v)
	local mt = getmetatable(v)
	if mt == InstanceMeta then
		return "Instance"
	elseif mt == Vector3Meta then
		return "Vector3"
	elseif mt == CFrameMeta then
		return "CFrame"
	elseif mt == Color3Meta then
		return "Color3"
	elseif mt == EnumItemMeta then
		return "EnumItem"
	end
	return rawTypeof(v)
end

-- Serialization stand-in --------------------------------------------------------

local function encodeValue(v, index)
	local t = mockTypeof(v)
	if t == "Vector3" then
		return { "V3", v.X, v.Y, v.Z }
	elseif t == "CFrame" then
		return { "CF", table.unpack(v._c) }
	elseif t == "Color3" then
		return { "C3", v.R, v.G, v.B }
	elseif t == "Instance" then
		local i = index[v]
		return if i then { "REF", i } else nil -- outside the subtree: dropped
	end
	return v
end

local function decodeValue(v, nodes, fixups, target, key)
	if type(v) ~= "table" then
		return v
	end
	if v[1] == "V3" then
		return Vector3.new(v[2], v[3], v[4])
	elseif v[1] == "CF" then
		return CFrame.new(table.unpack(v, 2, 13))
	elseif v[1] == "C3" then
		return Color3.new(v[2], v[3], v[4])
	elseif v[1] == "REF" then
		table.insert(fixups, { target, key, v[2] })
		return nil
	end
	return nil
end

local function serialize(list)
	local index, flat = {}, {}
	local function number(node)
		if not node._props.Archivable then
			return
		end
		table.insert(flat, node)
		index[node] = #flat
		for _, c in node._children do
			number(c)
		end
	end
	for _, root in list do
		number(root)
	end
	local out = {}
	for i, node in flat do
		local props = {}
		for k, v in node._props do
			props[k] = encodeValue(v, index)
		end
		out[i] = {
			class = node._class,
			props = props,
			attrs = node._attrs,
			tags = methods.GetTags(node),
			parent = node._parent and index[node._parent] or 0,
			root = table.find(list, node) ~= nil,
		}
	end
	return buffer.fromstring(serde.encode("json", out))
end

local function deserialize(buf)
	local data = serde.decode("json", buffer.tostring(buf))
	local nodes, roots, fixups = {}, {}, {}
	for i, rec in data do
		local inst = new(rec.class)
		for k, v in rec.props do
			inst._props[k] = decodeValue(v, nodes, fixups, inst, k)
		end
		for k, v in rec.attrs or {} do
			inst._attrs[k] = v
		end
		for _, tag in rec.tags or {} do
			inst._tags[tag] = true
		end
		nodes[i] = inst
		if rec.root then
			table.insert(roots, inst)
		else
			local parent = nodes[rec.parent]
			inst._parent = parent
			table.insert(parent._children, inst)
		end
	end
	for _, fix in fixups do
		fix[1]._props[fix[2]] = nodes[fix[3]]
	end
	return roots
end

-- Base64 (EncodingService) -------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64encode(buf)
	local s = buffer.tostring(buf)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = string.byte(s, i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local q = {}
		for j = 3, 0, -1 do
			local d = (n // 64 ^ j) % 64
			table.insert(q, string.sub(B64, d + 1, d + 1))
		end
		if not b then
			q[3], q[4] = "=", "="
		elseif not c then
			q[4] = "="
		end
		table.insert(out, table.concat(q))
	end
	return buffer.fromstring(table.concat(out))
end
local function b64decode(buf)
	local s = string.gsub(buffer.tostring(buf), "[^%w%+/=]", "")
	local out = {}
	for i = 1, #s, 4 do
		local n, pad = 0, 0
		for j = 0, 3 do
			local ch = string.sub(s, i + j, i + j)
			if ch == "=" then
				pad += 1
				n = n * 64
			else
				n = n * 64 + (string.find(B64, ch, 1, true) - 1)
			end
		end
		local bytes = string.char(n // 65536 % 256, n // 256 % 256, n % 256)
		table.insert(out, string.sub(bytes, 1, 3 - pad))
	end
	return buffer.fromstring(table.concat(out))
end

-- A fresh DataModel ----------------------------------------------------------------

local SERVICES = {
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

function M.newGame(clientName)
	local game = new("DataModel")
	game._props.Name = clientName
	rawset(game, "_services", {})
	for _, name in SERVICES do
		local s = new(name)
		s._props.Name = name
		s._parent = game
		table.insert(game._children, s)
		game._services[name] = s
	end
	local ws = game._services.Workspace
	local terrain = new("Terrain")
	terrain._props.Name = "Terrain"
	setParent(terrain, ws)
	local cam = new("Camera")
	cam._props.Name = "Camera"
	cam._props.Archivable = false
	cam._props.CFrame = CFrame.new(0, 10, 0)
	ws._props.CurrentCamera = cam
	setParent(cam, ws)
	for _, n in { "StarterPlayerScripts", "StarterCharacterScripts" } do
		local f = new("Folder")
		f._class = n
		f._props.Name = n
		setParent(f, game._services.StarterPlayer)
	end

	local textChanged = Signal.new()
	game._services.HttpService = {
		RequestAsync = function(_, o)
			local r = net.request({ url = o.Url, method = o.Method, headers = o.Headers, body = o.Body })
			return { Success = r.ok, StatusCode = r.statusCode, Body = r.body }
		end,
		JSONEncode = function(_, v)
			return serde.encode("json", v)
		end,
		JSONDecode = function(_, s)
			return serde.decode("json", s)
		end,
		UrlEncode = function(_, s)
			return (string.gsub(s, "[^%w%-_%.~]", function(c)
				return ("%%%02X"):format(string.byte(c))
			end))
		end,
		GenerateGUID = function()
			local hex = {}
			for i = 1, 32 do
				hex[i] = string.format("%x", math.random(0, 15))
			end
			return table.concat(hex)
		end,
	}
	game._services.EncodingService = {
		Base64Encode = function(_, b)
			return b64encode(b)
		end,
		Base64Decode = function(_, b)
			return b64decode(b)
		end,
		CompressBuffer = function()
			error("not in mock")
		end,
		DecompressBuffer = function(_, b)
			return b
		end,
	}
	game._services.SerializationService = {
		SerializeInstancesAsync = function(_, list)
			task.wait() -- yields, like the real one
			return serialize(list)
		end,
		DeserializeInstancesAsync = function(_, buf)
			task.wait()
			return deserialize(buf)
		end,
	}
	game._services.ScriptEditorService = {
		GetEditorSource = function(_, s)
			return s.Source
		end,
		UpdateSourceAsync = function(_, s, fn)
			s.Source = fn(s.Source)
		end,
		TextDocumentDidChange = textChanged,
	}
	game._services.ChangeHistoryService = { ResetWaypoints = function() end }
	local cs = { _known = {}, _added = {}, _removed = {}, TagAdded = Signal.new() }
	function cs.GetAllTags(self)
		local out = {}
		for tag in self._known do
			table.insert(out, tag)
		end
		return out
	end
	function cs.GetInstanceAddedSignal(self, tag)
		self._added[tag] = self._added[tag] or Signal.new()
		return self._added[tag]
	end
	function cs.GetInstanceRemovedSignal(self, tag)
		self._removed[tag] = self._removed[tag] or Signal.new()
		return self._removed[tag]
	end
	function cs.GetTagged(_, tag)
		local out = {}
		for _, d in methods.GetDescendants(game) do
			if d._tags[tag] then
				table.insert(out, d)
			end
		end
		return out
	end
	game._services.CollectionService = cs
	game._services.CoreGui = new("CoreGui")
	game._services.TweenService = {
		Create = function(_, inst, _info, goal)
			return {
				Play = function()
					for k, v in goal do
						inst[k] = v
					end
				end,
			}
		end,
	}
	local heartbeat = Signal.new()
	task.spawn(function()
		while true do
			task.wait(1 / 30)
			heartbeat:Fire(1 / 30)
		end
	end)
	game._services.RunService = {
		Heartbeat = heartbeat,
		IsEdit = function()
			return true
		end,
	}
	return game
end

M.Instance = {
	new = function(className, parent)
		local inst = new(className)
		if parent then
			inst.Parent = parent
		end
		return inst
	end,
}
M.Vector3 = Vector3
M.CFrame = CFrame
M.Color3 = Color3
M.UDim2 = UDim2
M.TweenInfo = TweenInfo
M.Vector2 = Vector2
M.Enum = Enum
M.typeof = mockTypeof
M.task = task

return M
