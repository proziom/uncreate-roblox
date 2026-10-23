--!strict
--[[
	Presence — the "flying heads": shows where other people's Studio cameras
	are and tells the server where ours is.

	Network: one POST /presence per tick does both directions (send my
	camera, get everyone's); ticks are fast while any camera moves and slow
	when all are still. Motion: the network only sets each head's target;
	a single Heartbeat connection glides every head toward its target with
	frame-rate independent smoothing, so heads fly instead of teleporting.

	Look: a colored sphere with two dark eyes looking where the camera
	looks, in a per-person color, name on top.
	Everything is HandleAdornments and a BillboardGui in CoreGui: drawn in
	the viewport, never part of the place (not saved, synced or selectable).

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Net = require(script.Parent.Net)
local Types = require(script.Parent.Types)

local TICK_ACTIVE = 0.3 -- s between updates while some camera moves
local TICK_IDLE = 1.5 -- s between updates while every camera is still
local ACTIVE_FOR = 3 -- s a camera counts as moving after its last change
local BUDGET_LIMIT = 250 -- requests/min already used by sync: presence yields to it
local SMOOTHING = 12 -- 1/s; higher follows the target more tightly
local SNAP_DISTANCE = 200 -- studs; a jump this far teleports instead of flying
local NEAR_FADE = 4 -- studs; heads closer than this to my camera fade out
local FADE = TweenInfo.new(0.25, Enum.EasingStyle.Quad)

-- Head geometry, in studs, relative to the camera position (-Z is forward).
local HEAD_RADIUS = 1.2
local HEAD_TRANSPARENCY = 0.1
local EYE_RADIUS = 0.28
local EYE_COLOR = Color3.new(0.08, 0.08, 0.1)
local EYE_OFFSETS = { CFrame.new(-0.45, 0.3, -1.0), CFrame.new(0.45, 0.3, -1.0) }
local TAG_LIFT = Vector3.new(0, HEAD_RADIUS + 1.2, 0)

type Shape = { adornment: HandleAdornment, offset: CFrame, transparency: number }

type Marker = {
	shapes: { Shape },
	tag: BillboardGui,
	label: TextLabel,
	current: CFrame,
	target: CFrame,
	camera: string, -- last raw camera seen, to detect movement
	fade: number, -- extra transparency from the near-camera fade, 0..1
	faded: boolean, -- transparency was overridden last frame (restore when it ends)
}

local Presence = {}
Presence.__index = Presence

export type Presence = typeof(setmetatable(
	{} :: {
		_net: Net.Net,
		_clientId: () -> number,
		_gen: number,
		_folder: Folder?,
		_markers: { [number]: Marker },
		_glide: RBXScriptConnection?,
		_activeUntil: number,
	},
	Presence
))

function Presence.new(net: Net.Net, clientId: () -> number): Presence
	return setmetatable({
		_net = net,
		_clientId = clientId,
		_gen = 0,
		_folder = nil,
		_markers = {},
		_glide = nil,
		_activeUntil = 0,
	}, Presence)
end

-- A stable, distinct color per person (golden-ratio hue steps).
function Presence.ColorOf(id: number): Color3
	return Color3.fromHSV((id * 0.618034) % 1, 0.65, 0.95)
end

-- Position and look direction, rounded: small enough to send 3x a second.
local function encodeCamera(cf: CFrame): string
	local p, l = cf.Position, cf.LookVector
	return ("[%.2f,%.2f,%.2f,%.3f,%.3f,%.3f]"):format(p.X, p.Y, p.Z, l.X, l.Y, l.Z)
end

local function decodeCamera(cam: { number }): CFrame
	local pos = Vector3.new(cam[1], cam[2], cam[3])
	local look = Vector3.new(cam[4], cam[5], cam[6])
	if look.Magnitude < 1e-3 then
		look = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(pos, pos + look)
end

-- Lifecycle ----------------------------------------------------------------------

function Presence.Start(self: Presence)
	self:Stop()
	self._gen += 1
	local gen = self._gen
	local folder = Instance.new("Folder")
	folder.Name = "UncreatePresence"
	folder.Archivable = false
	folder.Parent = CoreGui
	self._folder = folder
	self._glide = RunService.Heartbeat:Connect(function(dt: number)
		self:_glideAll(dt)
	end)
	task.spawn(self._tickLoop, self, gen)
end

function Presence.Stop(self: Presence)
	self._gen += 1
	if self._glide then
		self._glide:Disconnect()
		self._glide = nil
	end
	if self._folder then
		self._folder:Destroy()
		self._folder = nil
	end
	table.clear(self._markers)
end

function Presence._tickLoop(self: Presence, gen: number)
	local lastSent = ""
	while self._gen == gen do
		local camera = Workspace.CurrentCamera
		local mine = if camera then encodeCamera(camera.CFrame) else ""
		if mine ~= lastSent then
			self._activeUntil = os.clock() + ACTIVE_FOR
		end
		if self._net:RecentRequests() < BUDGET_LIMIT then
			local ok, reply = self._net:Json("POST", "/presence?client=" .. self._clientId(), mine)
			if self._gen ~= gen then
				break
			end
			if ok then
				lastSent = mine
				self:_sync(reply.peers or {})
			end
		end
		task.wait(if os.clock() < self._activeUntil then TICK_ACTIVE else TICK_IDLE)
	end
end

-- Markers --------------------------------------------------------------------------

-- Creates, retargets and removes markers to match the peer list.
function Presence._sync(self: Presence, peers: { Types.Peer })
	local me = self._clientId()
	local seen: { [number]: true } = {}
	for _, peer in peers do
		local cam = peer.cam
		if peer.id == me or type(cam) ~= "table" or #cam ~= 6 then
			continue -- myself, or a camera not known (or no longer fresh)
		end
		seen[peer.id] = true
		local raw = table.concat(cam, ",")
		local marker = self._markers[peer.id]
		if marker == nil then
			marker = self:_createMarker(peer, decodeCamera(cam))
			self._markers[peer.id] = marker
		elseif marker.camera ~= raw then
			self._activeUntil = os.clock() + ACTIVE_FOR -- someone moves: tick fast
			marker.target = decodeCamera(cam)
		end
		marker.camera = raw
		marker.label.Text = peer.name
	end
	for id, marker in self._markers do
		if not seen[id] then
			self._markers[id] = nil
			self:_fadeOutAndDestroy(marker)
		end
	end
end

function Presence._createMarker(self: Presence, peer: Types.Peer, at: CFrame): Marker
	local group = Instance.new("Folder")
	group.Name = peer.name
	group.Parent = self._folder
	local anchor = Workspace.Terrain -- at the origin, so adornment CFrames are world CFrames
	local color = Presence.ColorOf(peer.id)

	local shapes: { Shape } = {}
	local function add(adornment: HandleAdornment, offset: CFrame, transparency: number)
		adornment.Adornee = anchor
		adornment.Transparency = 1 -- fades in below
		adornment.Parent = group
		table.insert(shapes, { adornment = adornment, offset = offset, transparency = transparency })
		TweenService:Create(adornment, FADE, { Transparency = transparency }):Play()
	end
	local head = Instance.new("SphereHandleAdornment")
	head.Name = "Head"
	head.Radius = HEAD_RADIUS
	head.Color3 = color
	add(head, CFrame.new(), HEAD_TRANSPARENCY)
	for _, offset in EYE_OFFSETS do
		local eye = Instance.new("SphereHandleAdornment")
		eye.Radius = EYE_RADIUS
		eye.Color3 = EYE_COLOR
		eye.ZIndex = 2
		add(eye, offset, 0)
	end

	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(180, 22)
	tag.AlwaysOnTop = true
	tag.LightInfluence = 0
	tag.MaxDistance = 1000
	tag.Adornee = anchor
	tag.Parent = group
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 15
	label.TextColor3 = color
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.Text = peer.name
	label.Parent = tag

	local marker: Marker = {
		shapes = shapes,
		tag = tag,
		label = label,
		current = at,
		target = at,
		camera = "",
		fade = 0,
		faded = false,
	}
	self:_apply(marker)
	return marker
end

function Presence._fadeOutAndDestroy(_self: Presence, marker: Marker)
	for _, shape in marker.shapes do
		TweenService:Create(shape.adornment, FADE, { Transparency = 1 }):Play()
	end
	TweenService:Create(marker.label, FADE, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	local group = marker.tag.Parent
	task.delay(FADE.Time, function()
		if group then
			group:Destroy()
		end
	end)
end

-- Motion ----------------------------------------------------------------------------

-- Moves every head a frame-rate independent step toward its target, and
-- fades heads that sit right in front of my own camera.
function Presence._glideAll(self: Presence, dt: number)
	local alpha = 1 - math.exp(-SMOOTHING * dt)
	local camera = Workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position
	for _, marker in self._markers do
		if (marker.current.Position - marker.target.Position).Magnitude > SNAP_DISTANCE then
			marker.current = marker.target
		else
			marker.current = marker.current:Lerp(marker.target, alpha)
		end
		if eye then
			local distance = (marker.current.Position - eye).Magnitude
			marker.fade = math.clamp(1 - (distance - 1) / (NEAR_FADE - 1), 0, 1)
		end
		self:_apply(marker)
	end
end

function Presence._apply(_self: Presence, marker: Marker)
	local frame = marker.current
	-- Transparency is only written while a near-camera fade is (or just
	-- was) active, so the fade-in tween owns it the rest of the time.
	local touchTransparency = marker.fade > 0 or marker.faded
	marker.faded = marker.fade > 0
	for _, shape in marker.shapes do
		shape.adornment.CFrame = frame * shape.offset
		if touchTransparency then
			shape.adornment.Transparency = shape.transparency + (1 - shape.transparency) * marker.fade
		end
	end
	marker.tag.StudsOffsetWorldSpace = frame.Position + TAG_LIFT
end

return Presence
