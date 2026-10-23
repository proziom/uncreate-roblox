--!strict
--[[
	Codec — turns Roblox values into JSON-safe values and back, and packs
	binary blobs (rbxm buffers) into base64 strings for the wire.

	Encoded form: booleans, finite numbers and valid UTF-8 strings travel as
	themselves; everything else is an array tagged by its first element,
	e.g. { "V3", x, y, z }. ENCODERS and DECODERS below are mirror images:
	adding a type means adding one row to each. Instance references go
	through a resolver, so the codec never needs to know about the registry.

		local ok, enc = Codec.Encode(part.CFrame, resolver)
		local ok2, value = Codec.Decode(enc, resolver)

	[ @Claude | 23.10.2026 ]
	edited [ @Claude | 23.10.2026 ]
]]

local EncodingService = game:GetService("EncodingService")

export type Resolver = {
	IdOf: (Instance) -> string?,
	Find: (string) -> Instance?,
}

local Codec = {}

local COMPRESS_MIN_BYTES = 4096
local ZSTD_LEVEL = 3
local ZSTD_MIN_GAIN = 0.9 -- keep zstd output only if it is at most 90% of the input

-- Binary <-> base64 -------------------------------------------------------

function Codec.ToBase64(raw: buffer): string
	return buffer.tostring(EncodingService:Base64Encode(raw))
end

function Codec.FromBase64(text: string): buffer
	return EncodingService:Base64Decode(buffer.fromstring(text))
end

-- Returns base64 text and whether it is zstd-compressed. rbxm is already
-- LZ4-compressed per chunk, so zstd is kept only when it actually pays.
function Codec.Pack(raw: buffer): (string, boolean)
	if buffer.len(raw) >= COMPRESS_MIN_BYTES then
		local ok, packed = pcall(function(): buffer
			return EncodingService:CompressBuffer(raw, Enum.CompressionAlgorithm.Zstd, ZSTD_LEVEL)
		end)
		if ok and buffer.len(packed) < buffer.len(raw) * ZSTD_MIN_GAIN then
			return Codec.ToBase64(packed), true
		end
	end
	return Codec.ToBase64(raw), false
end

function Codec.Unpack(text: string, compressed: boolean): buffer
	local raw = Codec.FromBase64(text)
	if compressed then
		return EncodingService:DecompressBuffer(raw, Enum.CompressionAlgorithm.Zstd)
	end
	return raw
end

-- Values -------------------------------------------------------------------

local NORMAL_IDS: { Enum.NormalId } = {
	Enum.NormalId.Right,
	Enum.NormalId.Top,
	Enum.NormalId.Back,
	Enum.NormalId.Left,
	Enum.NormalId.Bottom,
	Enum.NormalId.Front,
}

-- Tagged array; mixed element types, so built through varargs.
local function tag(...: any): { any }
	return { ... }
end

-- One encoder per typeof() name. Returning nil means "cannot travel":
-- the property is skipped rather than nulled on other clients.
type Encoder = (value: any, resolver: Resolver) -> any
local ENCODERS: { [string]: Encoder } = {
	boolean = function(b)
		return b
	end,
	number = function(n: number)
		if n ~= n then
			return tag("F", "nan")
		elseif n == math.huge then
			return tag("F", "inf")
		elseif n == -math.huge then
			return tag("F", "-inf")
		end
		return n
	end,
	string = function(s: string)
		if utf8.len(s) ~= nil then
			return s
		end
		return tag("S64", Codec.ToBase64(buffer.fromstring(s))) -- binary data, not text
	end,
	Vector3 = function(v: Vector3)
		return tag("V3", v.X, v.Y, v.Z)
	end,
	Vector2 = function(v: Vector2)
		return tag("V2", v.X, v.Y)
	end,
	CFrame = function(cf: CFrame)
		return tag("CF", cf:GetComponents())
	end,
	Color3 = function(c: Color3)
		return tag("C3", c.R, c.G, c.B)
	end,
	BrickColor = function(b: BrickColor)
		return tag("BC", b.Number)
	end,
	UDim = function(u: UDim)
		return tag("U", u.Scale, u.Offset)
	end,
	UDim2 = function(u: UDim2)
		return tag("U2", u.X.Scale, u.X.Offset, u.Y.Scale, u.Y.Offset)
	end,
	EnumItem = function(e: EnumItem)
		return tag("E", tostring(e.EnumType), e.Name)
	end,
	Instance = function(inst: Instance, resolver)
		local id = resolver.IdOf(inst)
		return if id then tag("I", id) else nil -- outside the synced tree
	end,
	NumberRange = function(r: NumberRange)
		return tag("NR", r.Min, r.Max)
	end,
	NumberSequence = function(seq: NumberSequence)
		local out = tag("NS")
		for _, kp in seq.Keypoints do
			table.insert(out, kp.Time)
			table.insert(out, kp.Value)
			table.insert(out, kp.Envelope)
		end
		return out
	end,
	ColorSequence = function(seq: ColorSequence)
		local out = tag("CS")
		for _, kp in seq.Keypoints do
			table.insert(out, kp.Time)
			table.insert(out, kp.Value.R)
			table.insert(out, kp.Value.G)
			table.insert(out, kp.Value.B)
		end
		return out
	end,
	Rect = function(r: Rect)
		return tag("R", r.Min.X, r.Min.Y, r.Max.X, r.Max.Y)
	end,
	Vector3int16 = function(v: Vector3int16)
		return tag("V3i", v.X, v.Y, v.Z)
	end,
	Vector2int16 = function(v: Vector2int16)
		return tag("V2i", v.X, v.Y)
	end,
	Font = function(f: Font)
		return tag("FT", f.Family, f.Weight.Name, f.Style.Name)
	end,
	PhysicalProperties = function(p: PhysicalProperties)
		return tag("PP", p.Density, p.Friction, p.Elasticity, p.FrictionWeight, p.ElasticityWeight, p.AcousticAbsorption)
	end,
	Faces = function(f: Faces)
		return tag("FA", f.Right, f.Top, f.Back, f.Left, f.Bottom, f.Front)
	end,
	Content = function(c: Content)
		if c.SourceType == Enum.ContentSourceType.None then
			return tag("CT")
		elseif c.SourceType == Enum.ContentSourceType.Uri and c.Uri then
			return tag("CT", c.Uri)
		end
		return nil -- object-backed content (EditableImage etc.) cannot travel
	end,
}

local NIL_ENCODED = tag("0")

-- Returns (true, encoded) or (false, nil) for values the protocol skips.
function Codec.Encode(value: any, resolver: Resolver): (boolean, any)
	if value == nil then
		return true, NIL_ENCODED
	end
	local encoder = ENCODERS[typeof(value)]
	if encoder == nil then
		return false, nil
	end
	local encoded = encoder(value, resolver)
	return encoded ~= nil, encoded
end

-- Untyped JSON arrays enter the typed world here; every element is a
-- number or string by construction of ENCODERS, so these are boundary casts.
type Decoder = (e: { any }, resolver: Resolver) -> any
local DECODERS: { [string]: Decoder } = {
	["0"] = function()
		return nil
	end,
	F = function(e)
		local which = e[2]
		return if which == "nan" then 0 / 0 elseif which == "inf" then math.huge else -math.huge
	end,
	S64 = function(e)
		return buffer.tostring(Codec.FromBase64(e[2]))
	end,
	V3 = function(e)
		return Vector3.new(e[2], e[3], e[4])
	end,
	V2 = function(e)
		return Vector2.new(e[2], e[3])
	end,
	CF = function(e)
		return CFrame.new(e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9], e[10], e[11], e[12], e[13])
	end,
	C3 = function(e)
		return Color3.new(e[2], e[3], e[4])
	end,
	BC = function(e)
		return BrickColor.new(e[2] :: number)
	end,
	U = function(e)
		return UDim.new(e[2], e[3])
	end,
	U2 = function(e)
		return UDim2.new(e[2], e[3], e[4], e[5])
	end,
	E = function(e)
		return ((Enum :: any)[e[2]] :: any)[e[3]]
	end,
	I = function(e, resolver)
		local id = e[2]
		if type(id) ~= "string" then
			return nil
		end
		local target = resolver.Find(id)
		if target == nil then
			error("unresolved reference " .. id)
		end
		return target
	end,
	NR = function(e)
		return NumberRange.new(e[2], e[3])
	end,
	NS = function(e)
		local kps: { NumberSequenceKeypoint } = {}
		for i = 2, #e, 3 do
			table.insert(kps, NumberSequenceKeypoint.new(e[i], e[i + 1], e[i + 2]))
		end
		return NumberSequence.new(kps)
	end,
	CS = function(e)
		local kps: { ColorSequenceKeypoint } = {}
		for i = 2, #e, 4 do
			table.insert(kps, ColorSequenceKeypoint.new(e[i], Color3.new(e[i + 1], e[i + 2], e[i + 3])))
		end
		return ColorSequence.new(kps)
	end,
	R = function(e)
		return Rect.new(e[2], e[3], e[4], e[5])
	end,
	V3i = function(e)
		return Vector3int16.new(e[2], e[3], e[4])
	end,
	V2i = function(e)
		return Vector2int16.new(e[2], e[3])
	end,
	FT = function(e)
		return Font.new(e[2], (Enum.FontWeight :: any)[e[3]], (Enum.FontStyle :: any)[e[4]])
	end,
	PP = function(e)
		return PhysicalProperties.new(e[2], e[3], e[4], e[5], e[6], e[7] or 1)
	end,
	FA = function(e)
		local ids: { Enum.NormalId } = {}
		for i, normal in NORMAL_IDS do
			if e[i + 1] == true then
				table.insert(ids, normal)
			end
		end
		return Faces.new(table.unpack(ids))
	end,
	CT = function(e)
		local uri = e[2]
		return if type(uri) == "string" then Content.fromUri(uri) else Content.none
	end,
}

-- Returns (true, value) or (false, errorMessage).
function Codec.Decode(encoded: any, resolver: Resolver): (boolean, any)
	if type(encoded) ~= "table" then
		return true, encoded
	end
	local e: { any } = encoded
	local decoder = DECODERS[e[1]]
	if decoder == nil then
		return false, "unknown tag " .. tostring(e[1])
	end
	return pcall(decoder, e, resolver)
end

return Codec
