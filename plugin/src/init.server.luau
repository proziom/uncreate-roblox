--!strict
--[[
	Uncreate — self-hosted Team Create for Roblox Studio (plugin entry point).
	Builds the toolbar button and dock widget, persists the connection
	fields, and owns at most one Session at a time.

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local RunService = game:GetService("RunService")

local Presence = require(script.Presence)
local Session = require(script.Session)
local Strings = require(script.Strings)
local Ui = require(script.Ui)

local SETTINGS_KEY = "Uncreate.Fields"

-- Plugins also load inside play-test DataModels; sync only edits the place.
if not RunService:IsEdit() then
	return
end

local toolbar = plugin:CreateToolbar("Uncreate")
local toggle = toolbar:CreateButton("Uncreate", Strings.ToolbarTooltip, "")
toggle.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 320, 520, 260, 320)
local widget = plugin:CreateDockWidgetPluginGuiAsync("UncreateWidget", widgetInfo)
widget.Title = Strings.WidgetTitle
widget.Name = "Uncreate"

-- Plugin settings are untyped storage; read each field defensively.
local saved = plugin:GetSetting(SETTINGS_KEY)
local function savedField(name: string, default: string): string
	local value = type(saved) == "table" and saved[name]
	return if type(value) == "string" then value else default
end
local ui = Ui.new(widget, {
	url = savedField("url", "127.0.0.1:7878"),
	key = savedField("key", ""),
	name = savedField("name", ""),
})

local session: Session.Session? = nil

local function stopSession()
	local current = session
	session = nil -- first: events from the stopping session are now ignored
	ui:CancelConfirm()
	if current then
		current:Stop()
	end
	ui:SetConnected(false)
	ui:SetStatus("Idle", Strings.StatusDisconnected)
end

ui.OnConnect = function(input: Ui.Fields)
	if session then
		return
	end
	if input.name == "" then
		input.name = "Dev" .. math.random(100, 999)
	end
	plugin:SetSetting(SETTINGS_KEY, input)
	ui:SetConnected(true)

	local created: Session.Session
	-- Callbacks act only while their session is the current one.
	local function isCurrent(): boolean
		return session ~= nil and session == created
	end
	created = Session.new(input.url, input.key, input.name, {
		OnStatus = function(status, text)
			if not isCurrent() then
				return
			end
			ui:SetStatus(status, text)
			if status == "Idle" then -- the session stopped itself (e.g. "Cancel")
				session = nil
				ui:SetConnected(false)
			end
		end,
		OnLog = function(text)
			ui:Log(text)
		end,
		OnPeers = function(peers)
			if isCurrent() then
				ui:SetPeers(peers, created:ClientId(), Presence.ColorOf)
			end
		end,
		Confirm = function(text)
			return ui:Confirm(text)
		end,
	})
	session = created
	created:Start()
end

ui.OnDisconnect = stopSession

ui.OnSnapshot = function()
	if session then
		session:UploadSnapshot()
	end
end

toggle.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggle:SetActive(widget.Enabled)
end)

local studio = (settings() :: any).Studio
studio.ThemeChanged:Connect(function()
	ui:RefreshTheme()
end)

plugin.Unloading:Connect(stopSession)
