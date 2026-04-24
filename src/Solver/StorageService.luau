--!strict
--[[
	StorageService — Compression + encoding utilities for animation storage.

	Two output modes:
	- Buffer (for DataStore, which natively supports buffer types)
	- String (for Attributes, StringValues, ProfileService, or plugin context)

	Luna never calls DataStore directly — the developer handles persistence.
	This module works in both server and plugin contexts.
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local Constants = require(Luna.Core.Constants)
local AnimationData = require(Luna.Core.AnimationData)
local Serializer = require(Luna.Core.Serializer)
local Logger = require(Luna.Shared.Logger)

type Array<V> = CoreTypes.Array<V>
type EditAnimation = AnimationData.EditAnimation

local EncodingService = game:GetService("EncodingService")

local PACK_VERSION = Constants.STORAGE_PACK_VERSION
local DATASTORE_LIMIT = Constants.DATASTORE_SIZE_LIMIT
local ATTRIBUTE_LIMIT = Constants.ATTRIBUTE_SIZE_LIMIT

local StorageService = {}

-- [[ LOW-LEVEL: COMPRESS / DECOMPRESS ]]

function StorageService.Compress(Data: buffer): (buffer?, string?)
	local IsSuccess, Result = pcall(function()
		return EncodingService:CompressBuffer(Data, Enum.CompressionAlgorithm.Zstd)
	end)
	if not IsSuccess then
		Logger.Warn(`Compression failed: {Result}`)
		return nil, `Compression failed: {Result}`
	end
	return Result, nil
end

function StorageService.Decompress(Data: buffer): (buffer?, string?)
	-- Safety check: validate decompressed size before decompressing
	local IsSizeSuccess, DecompressedSize = pcall(function()
		return EncodingService:GetDecompressedBufferSize(Data, Enum.CompressionAlgorithm.Zstd)
	end)
	if not IsSizeSuccess then
		Logger.Warn(`Failed to read decompressed size: {DecompressedSize}`)
		return nil, `Failed to read decompressed size: {DecompressedSize}`
	end

	-- Guard against decompression bombs (> 100MB) or nil size
	if not DecompressedSize or DecompressedSize > 100_000_000 then
		Logger.Warn(`Decompressed size too large: {DecompressedSize} bytes`)
		return nil, `Decompressed size too large: {DecompressedSize} bytes`
	end

	local IsSuccess, Result = pcall(function()
		return EncodingService:DecompressBuffer(Data, Enum.CompressionAlgorithm.Zstd)
	end)
	if not IsSuccess then
		Logger.Warn(`Decompression failed: {Result}`)
		return nil, `Decompression failed: {Result}`
	end
	return Result, nil
end

-- [[ MID-LEVEL: BUFFER STORAGE (DataStore) ]]

-- Prepend version byte + compress. Returns a buffer ready for DataStore:SetAsync.
function StorageService.PrepareForDataStore(Data: buffer): (buffer?, string?)
	-- Prepend version byte
	local Versioned = buffer.create(1 + buffer.len(Data))
	buffer.writeu8(Versioned, 0, PACK_VERSION)
	buffer.copy(Versioned, 1, Data)

	local Compressed, Error = StorageService.Compress(Versioned)
	if not Compressed then
		return nil, Error
	end

	local Size = buffer.len(Compressed)
	if Size > DATASTORE_LIMIT then
		Logger.Warn(`Compressed data ({Size} bytes) exceeds DataStore limit ({DATASTORE_LIMIT} bytes)`)
	end

	return Compressed, nil
end

-- Decompress + strip version byte. Input is a buffer from DataStore:GetAsync.
function StorageService.RestoreFromDataStore(Data: buffer): (buffer?, string?)
	local Decompressed, Error = StorageService.Decompress(Data)
	if not Decompressed then
		return nil, Error
	end

	if buffer.len(Decompressed) < 1 then
		return nil, "Decompressed data is empty"
	end

	local Version = buffer.readu8(Decompressed, 0)
	if Version ~= PACK_VERSION then
		return nil, `Unknown pack version: {Version} (expected {PACK_VERSION})`
	end

	-- Strip version byte
	local Stripped = buffer.create(buffer.len(Decompressed) - 1)
	buffer.copy(Stripped, 0, Decompressed, 1)

	return Stripped, nil
end

-- [[ MID-LEVEL: STRING STORAGE (Attributes, StringValues, ProfileService, Plugins) ]]

-- Compress + base64 encode → UTF-8 string safe for any string-based storage.
function StorageService.EncodeToString(Data: buffer): (string?, string?)
	-- Prepend version byte
	local Versioned = buffer.create(1 + buffer.len(Data))
	buffer.writeu8(Versioned, 0, PACK_VERSION)
	buffer.copy(Versioned, 1, Data)

	local Compressed, CompressError = StorageService.Compress(Versioned)
	if not Compressed then
		return nil, CompressError
	end

	local IsSuccess, Encoded = pcall(function()
		local Base64Buffer = EncodingService:Base64Encode(Compressed)
		return buffer.tostring(Base64Buffer)
	end)
	if not IsSuccess then
		Logger.Warn(`Base64 encoding failed: {Encoded}`)
		return nil, `Base64 encoding failed: {Encoded}`
	end

	if #Encoded > ATTRIBUTE_LIMIT then
		Logger.Warn(`Encoded string ({#Encoded} bytes) exceeds Attribute limit ({ATTRIBUTE_LIMIT} bytes)`)
	end

	return Encoded, nil
end

-- Base64 decode + decompress → original buffer.
function StorageService.DecodeFromString(Encoded: string): (buffer?, string?)
	local IsDecodeSuccess, Decoded = pcall(function()
		local EncodedBuffer = buffer.fromstring(Encoded)
		return EncodingService:Base64Decode(EncodedBuffer)
	end)
	if not IsDecodeSuccess then
		Logger.Warn(`Base64 decoding failed: {Decoded}`)
		return nil, `Base64 decoding failed: {Decoded}`
	end

	local Decompressed, DecompressError = StorageService.Decompress(Decoded)
	if not Decompressed then
		return nil, DecompressError
	end

	if buffer.len(Decompressed) < 1 then
		return nil, "Decoded data is empty"
	end

	local Version = buffer.readu8(Decompressed, 0)
	if Version ~= PACK_VERSION then
		return nil, `Unknown pack version: {Version} (expected {PACK_VERSION})`
	end

	-- Strip version byte
	local Stripped = buffer.create(buffer.len(Decompressed) - 1)
	buffer.copy(Stripped, 0, Decompressed, 1)

	return Stripped, nil
end

-- [[ HIGH-LEVEL: PACK/UNPACK EDIT ANIMATIONS ]]

-- Serialize + compress → buffer ready for DataStore.
function StorageService.PackEdit(Animation: EditAnimation): (buffer?, string?)
	local Serialized = Serializer.SerializeEdit(Animation)
	return StorageService.PrepareForDataStore(Serialized)
end

-- Decompress + deserialize → EditAnimation.
function StorageService.UnpackEdit(Data: buffer): (EditAnimation?, string?)
	local Restored, Error = StorageService.RestoreFromDataStore(Data)
	if not Restored then
		return nil, Error
	end

	local IsSuccess, Result = pcall(function()
		return Serializer.DeserializeEdit(Restored)
	end)
	if not IsSuccess then
		Logger.Warn(`Deserialization failed: {Result}`)
		return nil, `Deserialization failed: {Result}`
	end
	return Result, nil
end

-- Serialize + compress + base64 → string for Attributes/StringValues/Plugins.
function StorageService.PackEditToString(Animation: EditAnimation): (string?, string?)
	local Serialized = Serializer.SerializeEdit(Animation)
	return StorageService.EncodeToString(Serialized)
end

-- Base64 decode + decompress + deserialize → EditAnimation.
function StorageService.UnpackEditFromString(Encoded: string): (EditAnimation?, string?)
	local Restored, Error = StorageService.DecodeFromString(Encoded)
	if not Restored then
		return nil, Error
	end

	local IsSuccess, Result = pcall(function()
		return Serializer.DeserializeEdit(Restored)
	end)
	if not IsSuccess then
		Logger.Warn(`Deserialization failed: {Result}`)
		return nil, `Deserialization failed: {Result}`
	end
	return Result, nil
end

export type StorageService = typeof(StorageService)

return StorageService
