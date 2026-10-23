--!strict
--[[
	Ui — the Uncreate dock widget: connection fields, status line, peer list,
	a log, and an inline yes/no confirm used before destructive steps.
	Knows nothing about sync; Main wires its callbacks to a Session.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local Strings = require(script.Parent.Strings)
local Types = require(script.Parent.Types)

local Ui = {}
Ui.__index = Ui

export type Fields = { url: string, key: string, name: string }

type Themed = { inst: GuiObject, prop: string, color: Enum.StudioStyleGuideColor }

export type Ui = typeof(setmetatable(
	{} :: {
		OnConnect: (fields: Fields) -> (),
		OnDisconnect: () -> (),
		OnSnapshot: () -> (),
		_widget: DockWidgetPluginGui,
		_root: ScrollingFrame,
		_order: number, -- LayoutOrder of the next element added to _root
		_url: TextBox,
		_key: TextBox,
		_name: TextBox,
		_connect: TextButton,
		_snapshot: TextButton,
		_status: TextLabel,
		_peers: TextLabel,
		_log: ScrollingFrame,
		_logLines: { TextLabel }, -- oldest first, at most MAX_LOG_LINES
		_logCount: number,
		_confirm: Frame,
		_confirmText: TextLabel,
		_confirmResume: ((answer: boolean) -> ())?,
		_connected: boolean,
		_themed: { Themed },
	},
	Ui
))

local MAX_LOG_LINES = 200
local STATUS_COLORS: { [Types.Status]: Color3 } = {
	Idle = Color3.fromRGB(150, 150, 150),
	Connecting = Color3.fromRGB(230, 180, 60),
	Loading = Color3.fromRGB(230, 180, 60),
	Live = Color3.fromRGB(80, 200, 120),
	Error = Color3.fromRGB(230, 80, 80),
}

local function theme(): StudioTheme
	return (settings() :: any).Studio.Theme
end

-- Instance.new + property table; the cast is the one untyped boundary here.
local function make<T>(className: string, props: { [string]: any }, parent: Instance?): T
	local inst = Instance.new(className :: any)
	for k, v in props do
		(inst :: any)[k] = v
	end
	if parent then
		inst.Parent = parent
	end
	return inst :: any
end

local function padding(parent: Instance, px: number)
	make("UIPadding", {
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
	}, parent)
end

local function verticalList(parent: Instance, gap: number)
	make("UIListLayout", { Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder }, parent)
end

function Ui.new(widget: DockWidgetPluginGui, initial: Fields): Ui
	local self = setmetatable({}, Ui) :: any
	self.OnConnect = function(_: Fields) end
	self.OnDisconnect = function() end
	self.OnSnapshot = function() end
	self._widget = widget
	self._order = 0
	self._logLines = {}
	self._logCount = 0
	self._connected = false
	self._themed = {}

	self._root = make("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, widget)
	padding(self._root, 8)
	verticalList(self._root, 6)

	local ui = self :: Ui
	ui:_theme(ui._root, "BackgroundColor3", Enum.StudioStyleGuideColor.MainBackground)
	ui:_build(initial)
	ui:_applyTheme()
	return ui
end

function Ui._nextOrder(self: Ui): number
	self._order += 1
	return self._order
end

function Ui._label(self: Ui, text: string): TextLabel
	local label = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 16),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.SourceSans,
		TextSize = 14,
		LayoutOrder = self:_nextOrder(),
	}, self._root) :: TextLabel
	self:_theme(label, "TextColor3", Enum.StudioStyleGuideColor.SubText)
	return label
end

function Ui._field(self: Ui, caption: string, value: string, placeholder: string): TextBox
	self:_label(caption)
	local box = make("TextBox", {
		Size = UDim2.new(1, 0, 0, 26),
		Text = value,
		PlaceholderText = placeholder,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.SourceSans,
		TextSize = 15,
		BorderSizePixel = 1,
		LayoutOrder = self:_nextOrder(),
	}, self._root) :: TextBox
	make("UIPadding", { PaddingLeft = UDim.new(0, 6) }, box)
	self:_theme(box, "BackgroundColor3", Enum.StudioStyleGuideColor.InputFieldBackground)
	self:_theme(box, "TextColor3", Enum.StudioStyleGuideColor.MainText)
	self:_theme(box, "BorderColor3", Enum.StudioStyleGuideColor.InputFieldBorder)
	return box
end

function Ui._button(self: Ui, text: string, parent: Instance?, size: UDim2?): TextButton
	local main = parent == nil
	local button = make("TextButton", {
		Size = size or UDim2.new(1, 0, 0, 30),
		Text = text,
		Font = Enum.Font.SourceSansSemibold,
		TextSize = if main then 16 else 15,
		BorderSizePixel = 0,
		LayoutOrder = if main then self:_nextOrder() else 0,
	}, parent or self._root) :: TextButton
	make("UICorner", { CornerRadius = UDim.new(0, 4) }, button)
	self:_theme(
		button,
		"BackgroundColor3",
		if main then Enum.StudioStyleGuideColor.DialogMainButton else Enum.StudioStyleGuideColor.Button
	)
	self:_theme(
		button,
		"TextColor3",
		if main then Enum.StudioStyleGuideColor.DialogMainButtonText else Enum.StudioStyleGuideColor.ButtonText
	)
	return button
end

function Ui._build(self: Ui, initial: Fields)
	self._url = self:_field(Strings.FieldServer, initial.url, Strings.FieldServerHint)
	self._key = self:_field(Strings.FieldKey, initial.key, Strings.FieldKeyHint)
	self._name = self:_field(Strings.FieldName, initial.name, Strings.FieldNameHint)

	self._status = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = "● " .. Strings.NotConnected,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.SourceSansSemibold,
		TextSize = 15,
		TextColor3 = STATUS_COLORS["Idle" :: Types.Status],
		LayoutOrder = self:_nextOrder(),
	}, self._root) :: TextLabel

	self:_buildConfirm()

	self._connect = self:_button(Strings.Connect)
	self._connect.Activated:Connect(function()
		if self._connected then
			self.OnDisconnect()
		else
			self.OnConnect(self:Fields())
		end
	end)
	self._snapshot = self:_button(Strings.SaveSnapshot)
	self._snapshot.Visible = false
	self._snapshot.Activated:Connect(function()
		self.OnSnapshot()
	end)

	self._peers = self:_label(Strings.OnlineNone)
	self._peers.RichText = true -- names are shown in their head colors

	self:_label(Strings.Log)
	self._log = make("ScrollingFrame", {
		Size = UDim2.new(1, 0, 0, 180),
		BorderSizePixel = 1,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		LayoutOrder = self:_nextOrder(),
	}, self._root) :: ScrollingFrame
	self:_theme(self._log, "BackgroundColor3", Enum.StudioStyleGuideColor.ScriptBackground)
	self:_theme(self._log, "BorderColor3", Enum.StudioStyleGuideColor.Border)
	make("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, self._log)
	make("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingTop = UDim.new(0, 2) }, self._log)
end

-- Inline confirm panel: hidden until Confirm() shows it.
function Ui._buildConfirm(self: Ui)
	self._confirm = make("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BorderSizePixel = 0,
		Visible = false,
		LayoutOrder = self:_nextOrder(),
	}, self._root) :: Frame
	self:_theme(self._confirm, "BackgroundColor3", Enum.StudioStyleGuideColor.Tooltip)
	padding(self._confirm, 6)
	verticalList(self._confirm, 6)
	self._confirmText = make("TextLabel", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.SourceSansSemibold,
		TextSize = 15,
		LayoutOrder = 1,
	}, self._confirm) :: TextLabel
	self:_theme(self._confirmText, "TextColor3", Enum.StudioStyleGuideColor.MainText)
	local row = make("Frame", {
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
	}, self._confirm) :: Frame
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6) }, row)
	local half = UDim2.new(0.5, -3, 1, 0)
	self:_button(Strings.Yes, row, half).Activated:Connect(function()
		self:_answer(true)
	end)
	self:_button(Strings.Cancel, row, half).Activated:Connect(function()
		self:_answer(false)
	end)
end

function Ui._theme(self: Ui, inst: GuiObject, prop: string, color: Enum.StudioStyleGuideColor)
	table.insert(self._themed, { inst = inst, prop = prop, color = color })
end

function Ui._applyTheme(self: Ui)
	local current = theme()
	for _, entry in self._themed do
		(entry.inst :: any)[entry.prop] = current:GetColor(entry.color)
	end
	local text = current:GetColor(Enum.StudioStyleGuideColor.MainText)
	for _, line in self._logLines do
		line.TextColor3 = text
	end
end

-- Re-applies Studio colors; Main calls this on Studio theme change.
function Ui.RefreshTheme(self: Ui)
	self:_applyTheme()
end

function Ui.Fields(self: Ui): Fields
	return { url = self._url.Text, key = self._key.Text, name = self._name.Text }
end

function Ui.SetConnected(self: Ui, connected: boolean)
	self._connected = connected
	self._connect.Text = if connected then Strings.Disconnect else Strings.Connect
	self._snapshot.Visible = connected
	for _, box in { self._url, self._key, self._name } do
		box.TextEditable = not connected
	end
	if not connected then
		self._peers.Text = Strings.OnlineNone
	end
end

function Ui.SetStatus(self: Ui, status: Types.Status, text: string)
	self._status.Text = "● " .. text
	self._status.TextColor3 = STATUS_COLORS[status]
end

local function escapeRich(text: string): string
	return (string.gsub(text, "[<>&\"']", {
		["<"] = "&lt;",
		[">"] = "&gt;",
		["&"] = "&amp;",
		['"'] = "&quot;",
		["'"] = "&apos;",
	}))
end

-- Lists who is online, each name in the color of their flying head.
function Ui.SetPeers(self: Ui, peers: { Types.Peer }, me: number, colorOf: (id: number) -> Color3)
	local names: { string } = {}
	for _, peer in peers do
		local name = escapeRich(peer.name)
		if peer.id == me then
			name ..= " (" .. Strings.You .. ")"
		end
		table.insert(names, ('<font color="#%s">%s</font>'):format(colorOf(peer.id):ToHex(), name))
	end
	self._peers.Text = Strings.OnlineList:format(#names, table.concat(names, ", "))
end

-- Appends a line to the widget log (and the Output window), dropping the
-- oldest line beyond MAX_LOG_LINES.
function Ui.Log(self: Ui, text: string)
	self._logCount += 1
	local line = make("TextLabel", {
		Size = UDim2.new(1, -8, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Text = (os.date("%H:%M:%S ") :: string) .. text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = theme():GetColor(Enum.StudioStyleGuideColor.MainText),
		LayoutOrder = self._logCount,
	}, self._log) :: TextLabel
	table.insert(self._logLines, line)
	if #self._logLines > MAX_LOG_LINES then
		local oldest = table.remove(self._logLines, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	self._log.CanvasPosition = Vector2.new(0, math.huge)
	print("[Uncreate] " .. text)
end

-- Shows text with Yes/Cancel inside the widget and yields until answered.
-- A newer question (or CancelConfirm) answers the pending one with "no".
function Ui.Confirm(self: Ui, text: string): boolean
	self:CancelConfirm()
	local thread = coroutine.running()
	self._confirmResume = function(answer: boolean)
		task.spawn(thread, answer)
	end
	self._widget.Enabled = true
	self._confirmText.Text = text
	self._confirm.Visible = true
	return coroutine.yield()
end

function Ui.CancelConfirm(self: Ui)
	self:_answer(false)
end

function Ui._answer(self: Ui, answer: boolean)
	local resume = self._confirmResume
	if resume then
		self._confirmResume = nil
		self._confirm.Visible = false
		resume(answer)
	end
end

return Ui
