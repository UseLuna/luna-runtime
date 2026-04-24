--!strict
--[[
	LunaFile codec — encode/decode Luna's native compressed binary format.
	Used for .luna files, plugin settings storage, and place StringValues.

	Encode: EditAnimation → serialize → compress → Base64 string (safe for StringValue/attributes)
	Decode: string → Base64 decode → decompress → deserialize → EditAnimation
	       (auto-detects Base64 vs raw binary input)
]]

local Luna = script.Parent.Parent.Parent

local ImportTypes = require(Luna.Types.ImportTypes)
local AnimationData = require(Luna.Core.AnimationData)
local Serializer = require(Luna.Core.Serializer)
local StorageService = require(Luna.Solver.StorageService)
local Logger = require(Luna.Shared.Logger)

type ImportAdapter = ImportTypes.ImportAdapter
type EditAnimation = AnimationData.EditAnimation

-- Luna binary magic bytes for detection
local LUNA_MAGIC = "\137LNA"

-- [[ ENCODE ]]
-- Returns a Base64 string (compressed + encoded). Safe for StringValue, plugin settings, attributes.
local function __Encode(Animation: EditAnimation): string
	-- StorageService.PackEditToString: serialize → compress → Base64
	local Encoded, Error = StorageService.PackEditToString(Animation)
	if not Encoded then
		Logger.Error(`Encode failed: {Error}`)
		return "" -- dead code: Logger.Error throws
	end
	return Encoded
end

-- [[ DECODE ]]
-- Accepts either:
--   1. Base64 string (from StringValue, plugin settings, .luna.rbxm) → decode → decompress → deserialize
--   2. Raw binary string (from .luna file via PromptImportFileAsync) → deserialize directly
local function __Decode(Source: any): EditAnimation
	local InputString = Source :: string

	-- Try Base64 path first (stored data from Encode is always Base64)
	local Animation, DecodeError = StorageService.UnpackEditFromString(InputString)
	if Animation then
		return Animation
	end

	-- Fallback: try raw binary (uncompressed .luna file loaded from disk)
	local RawBuf = buffer.fromstring(InputString)
	if buffer.len(RawBuf) >= 4 and buffer.readstring(RawBuf, 0, 4) == LUNA_MAGIC then
		local IsOk, RawAnimation = pcall(function()
			return Serializer.DeserializeEdit(RawBuf)
		end)
		if IsOk and RawAnimation then
			return RawAnimation
		end
	end

	-- Fallback: try compressed but not Base64 (raw compressed buffer)
	local DecompressedBuf, _ = StorageService.Decompress(RawBuf)
	if DecompressedBuf then
		if buffer.len(DecompressedBuf) >= 4 and buffer.readstring(DecompressedBuf, 0, 4) == LUNA_MAGIC then
			local IsDecompressOk, CompressedAnimation = pcall(function()
				return Serializer.DeserializeEdit(DecompressedBuf)
			end)
			if IsDecompressOk and CompressedAnimation then
				return CompressedAnimation
			end
		end
	end

	error(`Invalid Luna file: unrecognized format ({DecodeError or "unknown"})`)
end

-- [[ MODULE EXPORTS ]]

local LunaFileCodec = {
	Encode = __Encode,
	Decode = __Decode,

	ImportAdapter = {
		Name = "LunaFile",
		Import = __Decode,
	} :: ImportAdapter,
}

return LunaFileCodec
