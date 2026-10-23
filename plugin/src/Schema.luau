--!strict
--[[
	Schema — which properties sync, and which of them are references.
	Pure data plus two per-class caches; no sync logic lives here, so the
	lists can grow without touching the engine.

	[ @Claude | 23.10.2026 ]
]]

local Schema = {}

-- Never synced: derived, read-only or runtime-only properties.
local SKIP_ANY: { string } = {
	"AbsolutePosition",
	"AbsoluteSize",
	"AbsoluteRotation",
	"AbsoluteCanvasSize",
	"AbsoluteWindowSize",
	"AbsoluteContentSize",
	"AbsoluteCellSize",
	"AbsoluteCellCount",
	"TextBounds",
	"TextFits",
	"ContentText",
	"GuiState",
	"IsLoaded",
	"IsPlaying",
	"IsPaused",
	"TimeLength",
	"TimePosition",
	"PlaybackLoudness",
	"ReceiveAge",
	"Mass",
	"AssemblyMass",
	"AssemblyCenterOfMass",
	"AssemblyRootPart",
	"CenterOfMass",
	"ResizeIncrement",
	"ResizeableFaces",
	"LocalTransparencyModifier",
	"WorldPosition",
	"WorldOrientation",
	"WorldCFrame",
	"WorldAxis",
	"WorldSecondaryAxis",
	"CurrentEditor",
	"LinkedSource",
	"ClassName",
	"DataCost",
	"RobloxLocked",
	"SourceAssetId",
	"UniqueId",
	"HistoryId",
}

-- Derived from CFrame on these classes; syncing both would make them fight.
-- (Moving a part fires CFrame, Position, Orientation and Rotation; only
-- CFrame travels.)
local SKIP_BY_CLASS: { [string]: { string } } = {
	BasePart = { "Position", "Orientation", "Rotation" },
	Attachment = { "Position", "Orientation", "Axis", "SecondaryAxis" },
}

-- Not writable by plugins: a change ships the whole instance again.
Schema.RECREATE = { MeshId = true, MeshContent = true } :: { [string]: true }

-- Reference properties that rbxm drops when the target is outside the
-- serialized subtree; the engine re-sends them explicitly.
local REF_PROPS: { { className: string, props: { string } } } = {
	{ className = "ObjectValue", props = { "Value" } },
	{ className = "JointInstance", props = { "Part0", "Part1" } },
	{ className = "WeldConstraint", props = { "Part0", "Part1" } },
	{ className = "NoCollisionConstraint", props = { "Part0", "Part1" } },
	{ className = "Constraint", props = { "Attachment0", "Attachment1" } },
	{ className = "Beam", props = { "Attachment0", "Attachment1" } },
	{ className = "Trail", props = { "Attachment0", "Attachment1" } },
	{ className = "Model", props = { "PrimaryPart" } },
	{ className = "Highlight", props = { "Adornee" } },
	{ className = "BillboardGui", props = { "Adornee" } },
	{ className = "SurfaceGui", props = { "Adornee" } },
	{ className = "Sound", props = { "SoundGroup" } },
}

-- Properties of the roots themselves (services) that travel with the project.
Schema.ROOT_PROPS = {
	["@Lighting"] = {
		"Ambient",
		"Brightness",
		"ColorShift_Bottom",
		"ColorShift_Top",
		"EnvironmentDiffuseScale",
		"EnvironmentSpecularScale",
		"GlobalShadows",
		"OutdoorAmbient",
		"ShadowSoftness",
		"ClockTime",
		"GeographicLatitude",
		"ExposureCompensation",
		"FogColor",
		"FogEnd",
		"FogStart",
		"Technology",
	},
	["@Workspace"] = { "Gravity", "FallenPartsDestroyHeight", "AirDensity", "GlobalWind", "StreamingEnabled" },
	["@StarterPlayer"] = {
		"CameraMaxZoomDistance",
		"CameraMinZoomDistance",
		"CameraMode",
		"CharacterWalkSpeed",
		"CharacterJumpPower",
		"CharacterJumpHeight",
		"CharacterUseJumpPower",
		"CharacterMaxSlopeAngle",
		"AutoJumpEnabled",
		"LoadCharacterAppearance",
		"HealthDisplayDistance",
		"NameDisplayDistance",
		"EnableMouseLockOption",
	},
	["@SoundService"] = { "AmbientReverb", "DistanceFactor", "DopplerScale", "RolloffScale", "RespectFilteringEnabled" },
	["@StarterGui"] = { "ShowDevelopmentGui", "ResetPlayerGuiOnSpawn", "ScreenOrientation" },
} :: { [string]: { string } }

-- Per-class caches. Both answers depend only on the class (IsA results), so
-- each is computed once per class instead of once per Changed event.
local skipByClass: { [string]: { [string]: true } } = {}
local refPropsByClass: { [string]: { string } } = {}

-- Set of property names never synced for inst's class. Mutable: a property
-- found unwritable at runtime is added, so it is not tried again.
function Schema.SkipSet(inst: Instance): { [string]: true }
	local cached = skipByClass[inst.ClassName]
	if cached then
		return cached
	end
	local set: { [string]: true } = {}
	for _, prop in SKIP_ANY do
		set[prop] = true
	end
	for className, props in SKIP_BY_CLASS do
		if inst:IsA(className) then
			for _, prop in props do
				set[prop] = true
			end
		end
	end
	skipByClass[inst.ClassName] = set
	return set
end

function Schema.RefProps(inst: Instance): { string }
	local cached = refPropsByClass[inst.ClassName]
	if cached then
		return cached
	end
	local props: { string } = {}
	for _, rule in REF_PROPS do
		if inst:IsA(rule.className) then
			table.move(rule.props, 1, #rule.props, #props + 1, props)
		end
	end
	refPropsByClass[inst.ClassName] = props
	return props
end

-- Reads a property by name; for pcall (a named function: no closure per call).
function Schema.Get(inst: Instance, prop: string): any
	return (inst :: any)[prop]
end

function Schema.Set(inst: Instance, prop: string, value: any)
	(inst :: any)[prop] = value
end

-- Visits every reference property of node that currently points somewhere.
function Schema.ForEachRef(node: Instance, visit: (prop: string, target: Instance) -> ())
	for _, prop in Schema.RefProps(node) do
		local ok, target = pcall(Schema.Get, node, prop)
		if ok and typeof(target) == "Instance" then
			visit(prop, target :: Instance)
		end
	end
end

return Schema
