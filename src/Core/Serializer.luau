--!strict
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local Constants = require(script.Parent.Constants)
local Quaternion = require(script.Parent.Quaternion)
local AnimationData = require(script.Parent.AnimationData)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type Quat = Quaternion.Quat
type EditAnimation = AnimationData.EditAnimation
type EditTrack = AnimationData.EditTrack
type EditChannel = AnimationData.EditChannel
type ScalarKeyframe = AnimationData.ScalarKeyframe
type InterpolationMode = AnimationData.InterpolationMode

-- Deserialization header types
type ChannelHeader = { ChannelId: string, KeyframeCount: number }
type TrackHeader = { Name: string, IsConstant: boolean, ChannelHeaders: Array<ChannelHeader> }

local Serializer = {}

-- [[ CRC16-CCITT ]]

local CRC16_POLYNOMIAL = Constants.CRC16_POLYNOMIAL
local __CRC16Table: buffer = buffer.create(256 * 2)

do
	for Index = 0, 255 do
		local Crc = bit32.lshift(Index, 8)
		for _ = 1, 8 do
			if bit32.band(Crc, 0x8000) ~= 0 then
				Crc = bit32.bxor(bit32.lshift(Crc, 1), CRC16_POLYNOMIAL)
			else
				Crc = bit32.lshift(Crc, 1)
			end
		end
		buffer.writeu16(__CRC16Table, Index * 2, bit32.band(Crc, 0xFFFF))
	end
end

local function __ComputeCRC16(Buf: buffer, StartOffset: number, Length: number): number
	local Crc = 0xFFFF
	for Offset = StartOffset, StartOffset + Length - 1 do
		local Byte = buffer.readu8(Buf, Offset)
		local TableIndex = bit32.band(bit32.bxor(bit32.rshift(Crc, 8), Byte), 0xFF)
		Crc = bit32.bxor(bit32.lshift(bit32.band(Crc, 0xFF), 8), buffer.readu16(__CRC16Table, TableIndex * 2))
	end
	return bit32.band(Crc, 0xFFFF)
end

-- [[ QUATERNION PACKING — SMALLEST THREE, 32 BITS ]]

local QUAT_RANGE = Constants.QUANTIZE_ROTATION_RANGE
local QUAT_MAX = Constants.QUANTIZE_ROTATION_MAX

function Serializer._PackQuaternion(Q: Quat): number
	local CX, CY, CZ, CW = Q.X, Q.Y, Q.Z, Q.W

	-- Find largest absolute component
	local AbsX = math.abs(CX)
	local AbsY = math.abs(CY)
	local AbsZ = math.abs(CZ)
	local AbsW = math.abs(CW)
	local LargestIndex = 1
	local LargestAbs = AbsX
	if AbsY > LargestAbs then
		LargestIndex = 2
		LargestAbs = AbsY
	end
	if AbsZ > LargestAbs then
		LargestIndex = 3
		LargestAbs = AbsZ
	end
	if AbsW > LargestAbs then
		LargestIndex = 4
	end

	-- Negate if largest is negative (ensures reconstructed component is positive)
	if
		(LargestIndex == 1 and CX < 0)
		or (LargestIndex == 2 and CY < 0)
		or (LargestIndex == 3 and CZ < 0)
		or (LargestIndex == 4 and CW < 0)
	then
		CX, CY, CZ, CW = -CX, -CY, -CZ, -CW
	end

	-- Collect the 3 smallest in order (no table allocation)
	local S1, S2, S3
	if LargestIndex == 1 then
		S1, S2, S3 = CY, CZ, CW
	elseif LargestIndex == 2 then
		S1, S2, S3 = CX, CZ, CW
	elseif LargestIndex == 3 then
		S1, S2, S3 = CX, CY, CW
	else
		S1, S2, S3 = CX, CY, CZ
	end

	-- Quantize [-RANGE, RANGE] → [0, QUAT_MAX]
	local A = math.clamp(math.floor((S1 + QUAT_RANGE) / (2 * QUAT_RANGE) * QUAT_MAX + 0.5), 0, QUAT_MAX)
	local B = math.clamp(math.floor((S2 + QUAT_RANGE) / (2 * QUAT_RANGE) * QUAT_MAX + 0.5), 0, QUAT_MAX)
	local C = math.clamp(math.floor((S3 + QUAT_RANGE) / (2 * QUAT_RANGE) * QUAT_MAX + 0.5), 0, QUAT_MAX)

	-- Pack: [31..30]=index, [29..20]=A, [19..10]=B, [9..0]=C
	return bit32.bor(bit32.lshift(LargestIndex - 1, 30), bit32.lshift(A, 20), bit32.lshift(B, 10), C)
end

function Serializer._UnpackQuaternion(Packed: number): Quat
	local Index = bit32.rshift(Packed, 30) + 1
	local A = bit32.band(bit32.rshift(Packed, 20), 0x3FF)
	local B = bit32.band(bit32.rshift(Packed, 10), 0x3FF)
	local C = bit32.band(Packed, 0x3FF)

	-- Dequantize [0, QUAT_MAX] → [-RANGE, RANGE]
	local VA = (A / QUAT_MAX) * (2 * QUAT_RANGE) - QUAT_RANGE
	local VB = (B / QUAT_MAX) * (2 * QUAT_RANGE) - QUAT_RANGE
	local VC = (C / QUAT_MAX) * (2 * QUAT_RANGE) - QUAT_RANGE

	-- Reconstruct 4th component
	local SumSq = VA * VA + VB * VB + VC * VC
	local Largest = math.sqrt(math.max(0, 1 - SumSq))

	-- Insert into correct position (no table allocation)
	if Index == 1 then
		return { X = Largest, Y = VA, Z = VB, W = VC }
	elseif Index == 2 then
		return { X = VA, Y = Largest, Z = VB, W = VC }
	elseif Index == 3 then
		return { X = VA, Y = VB, Z = Largest, W = VC }
	end
	return { X = VA, Y = VB, Z = VC, W = Largest }
end

-- [[ LOW-LEVEL WRITE HELPERS ]]

local function __WriteString(Buf: buffer, Offset: number, Str: string): number
	local Length = math.min(#Str, Constants.MAX_NAME_LENGTH)
	buffer.writeu16(Buf, Offset, Length)
	if Length > 0 then
		buffer.writestring(Buf, Offset + 2, Str, Length)
	end
	return Offset + 2 + Length
end

local function __ReadString(Buf: buffer, Offset: number): (string, number)
	local Length = buffer.readu16(Buf, Offset)
	if Length == 0 then
		return "", Offset + 2
	end
	local Str = buffer.readstring(Buf, Offset + 2, Length)
	return Str, Offset + 2 + Length
end

local function __MeasureString(Str: string): number
	return 2 + math.min(#Str, Constants.MAX_NAME_LENGTH)
end

local function __WriteChunkEnvelope(Buf: buffer, Offset: number, ChunkType: number, ChunkSize: number): number
	buffer.writeu16(Buf, Offset, ChunkType)
	buffer.writeu32(Buf, Offset + 2, ChunkSize)
	return Offset + Constants.CHUNK_HEADER_SIZE
end

-- [[ CURVE MODE ENUM MAPPING ]]

local CURVE_MODE_TO_U8: StringIndexable<number> = {
	Linear = Constants.CURVE_MODE_LINEAR,
	Stepped = Constants.CURVE_MODE_STEPPED,
	Bezier = Constants.CURVE_MODE_BEZIER,
	Easing = Constants.CURVE_MODE_EASING,
	Hermite = Constants.CURVE_MODE_HERMITE,
}

local U8_TO_CURVE_MODE: Array<string> = {
	[0] = "Linear",
	[1] = "Stepped",
	[2] = "Bezier",
	[3] = "Easing",
	[4] = "Hermite",
}

local EASING_STYLE_TO_U8: StringIndexable<number> = {
	Sine = 0,
	Quad = 1,
	Cubic = 2,
	Quart = 3,
	Quint = 4,
	Expo = 5,
	Circ = 6,
	Back = 7,
	Bounce = 8,
	Elastic = 9,
}

local U8_TO_EASING_STYLE: Array<string> = {
	[0] = "Sine",
	[1] = "Quad",
	[2] = "Cubic",
	[3] = "Quart",
	[4] = "Quint",
	[5] = "Expo",
	[6] = "Circ",
	[7] = "Back",
	[8] = "Bounce",
	[9] = "Elastic",
}

local EASING_DIR_TO_U8: StringIndexable<number> = { ["In"] = 0, Out = 1, InOut = 2 }
local U8_TO_EASING_DIR: Array<string> = { [0] = "In", [1] = "Out", [2] = "InOut" }

local HANDLE_TYPE_TO_U8: StringIndexable<number> = {
	Free = 0,
	Aligned = 1,
	Vector = 2,
	Automatic = 3,
	AutoClamped = 4,
}
local U8_TO_HANDLE_TYPE: Array<string> = {
	[0] = "Free",
	[1] = "Aligned",
	[2] = "Vector",
	[3] = "Automatic",
	[4] = "AutoClamped",
}

-- [[ MEASURE PASS (Edit Format v2 — per-channel scalar keyframes) ]]

local function __MeasureScalarKeyframe(Keyframe: ScalarKeyframe): number
	local Size = 4 + 4 + 1 -- Time (f32) + Value (f32) + CurveMode (u8)
	local Mode = Keyframe.Interpolation.Curve
	if Mode == "Bezier" then
		Size += 4 + 4 + 4 + 4 + 1 -- LeftHandle (2×f32) + RightHandle (2×f32) + HandleType (u8)
	elseif Mode == "Easing" then
		Size += 1 + 1 -- EasingStyle (u8) + EasingDirection (u8)
	end
	return Size
end

local function __MeasureMetadata(Animation: EditAnimation): number
	return __MeasureString(Animation.Name) + 4 + 4 + 1 + 1 -- name + duration + frameRate + looping + priority
end

local function __MeasureTrackHeaders(Tracks: Array<EditTrack>): number
	local Size = 2 -- TrackCount (u16)
	for _, Track in Tracks do
		-- name + isConstant + 6 channel keyframe counts (u16 each)
		Size += __MeasureString(Track.Name) + 1 + (Constants.CHANNEL_COUNT * 2)
	end
	return Size
end

local function __MeasureEditKeyframes(Tracks: Array<EditTrack>): number
	local Size = 0
	for _, Track in Tracks do
		for _, ChannelId in Constants.CHANNEL_IDS do
			local Channel = Track.Channels[ChannelId]
			for _, Keyframe in Channel.Keyframes do
				Size += __MeasureScalarKeyframe(Keyframe)
			end
		end
	end
	return Size
end

local function __MeasureMarkers(Markers: Array<AnimationData.AnimationMarker>): number
	if #Markers == 0 then
		return 0
	end
	local Size = 2 -- MarkerCount (u16)
	for _, Marker in Markers do
		Size += 4 -- Time (f32)
		Size += __MeasureString(Marker.Name)
		Size += __MeasureString(Marker.Value)
	end
	return Size
end

-- [[ WRITE PASS (Edit Format) ]]

local function __WriteHeader(Buf: buffer, Offset: number, FormatType: number, FormatVersion: number): number
	buffer.writestring(Buf, Offset, Constants.LUNA_MAGIC)
	buffer.writeu8(Buf, Offset + 8, FormatType)
	buffer.writeu16(Buf, Offset + 9, FormatVersion)
	buffer.writeu8(Buf, Offset + 11, 0) -- Flags (reserved)
	return Offset + Constants.LUNA_HEADER_SIZE
end

local function __WriteChunkWithCRC(Buf: buffer, ChunkStartOffset: number, ChunkType: number, BodySize: number): number
	-- Write envelope
	__WriteChunkEnvelope(Buf, ChunkStartOffset, ChunkType, BodySize)
	-- CRC16 is written after the body — computed over type (2 bytes) + body (BodySize bytes)
	local CrcOffset = ChunkStartOffset + Constants.CHUNK_HEADER_SIZE + BodySize
	local Crc = __ComputeCRC16(Buf, ChunkStartOffset, 2 + BodySize) -- type bytes + body bytes, skip size field
	buffer.writeu16(Buf, CrcOffset, Crc)
	return CrcOffset + 2
end

-- [[ SERIALIZE EDIT FORMAT ]]

function Serializer.SerializeEdit(Animation: EditAnimation): buffer
	-- 1. Measure
	local MetadataSize = __MeasureMetadata(Animation)
	local TrackHeadersSize = __MeasureTrackHeaders(Animation.Tracks)
	local KeyframesSize = __MeasureEditKeyframes(Animation.Tracks)

	local MarkersSize = __MeasureMarkers(Animation.Markers)
	local HasMarkers = MarkersSize > 0

	local TotalSize = Constants.LUNA_HEADER_SIZE
		+ Constants.CHUNK_ENVELOPE_SIZE
		+ MetadataSize
		+ Constants.CHUNK_ENVELOPE_SIZE
		+ TrackHeadersSize
		+ Constants.CHUNK_ENVELOPE_SIZE
		+ KeyframesSize
		+ (if HasMarkers then Constants.CHUNK_ENVELOPE_SIZE + MarkersSize else 0)

	-- 2. Allocate and write
	local Buf = buffer.create(TotalSize)
	local Offset = __WriteHeader(Buf, 0, Constants.FORMAT_TYPE_EDIT, Constants.FORMAT_VERSION_EDIT)

	-- Metadata chunk
	local MetaChunkStart = Offset
	Offset += Constants.CHUNK_HEADER_SIZE
	Offset = __WriteString(Buf, Offset, Animation.Name)
	buffer.writef32(Buf, Offset, Animation.Duration)
	Offset += 4
	buffer.writef32(Buf, Offset, Animation.FrameRate)
	Offset += 4
	buffer.writeu8(Buf, Offset, if Animation.Looping then 1 else 0)
	Offset += 1
	buffer.writeu8(Buf, Offset, Animation.Priority)
	Offset += 1
	Offset = __WriteChunkWithCRC(Buf, MetaChunkStart, Constants.CHUNK_METADATA, MetadataSize)

	-- TrackHeaders chunk (v2: per-channel keyframe counts)
	local TrackChunkStart = Offset
	Offset += Constants.CHUNK_HEADER_SIZE
	buffer.writeu16(Buf, Offset, #Animation.Tracks)
	Offset += 2
	for _, Track in Animation.Tracks do
		Offset = __WriteString(Buf, Offset, Track.Name)
		buffer.writeu8(Buf, Offset, if Track.IsConstant then 1 else 0)
		Offset += 1
		-- Write keyframe count per channel (6 × u16)
		for _, ChannelId in Constants.CHANNEL_IDS do
			buffer.writeu16(Buf, Offset, #Track.Channels[ChannelId].Keyframes)
			Offset += 2
		end
	end
	Offset = __WriteChunkWithCRC(Buf, TrackChunkStart, Constants.CHUNK_TRACK_HEADERS, TrackHeadersSize)

	-- EditKeyframes chunk (v2: per-channel scalar keyframes)
	local KeyframeChunkStart = Offset
	Offset += Constants.CHUNK_HEADER_SIZE
	for _, Track in Animation.Tracks do
		for _, ChannelId in Constants.CHANNEL_IDS do
			local Channel = Track.Channels[ChannelId]
			for _, Keyframe in Channel.Keyframes do
				buffer.writef32(Buf, Offset, Keyframe.Time)
				Offset += 4
				buffer.writef32(Buf, Offset, Keyframe.Value)
				Offset += 4

				local Interp = Keyframe.Interpolation
				local CurveU8 = CURVE_MODE_TO_U8[Interp.Curve] or 0
				buffer.writeu8(Buf, Offset, CurveU8)
				Offset += 1

				if Interp.Curve == "Bezier" then
					local LH = Interp.LeftHandle or { TimeOffset = 0, ValueOffset = 0 }
					local RH = Interp.RightHandle or { TimeOffset = 0, ValueOffset = 0 }
					buffer.writef32(Buf, Offset, LH.TimeOffset)
					Offset += 4
					buffer.writef32(Buf, Offset, LH.ValueOffset)
					Offset += 4
					buffer.writef32(Buf, Offset, RH.TimeOffset)
					Offset += 4
					buffer.writef32(Buf, Offset, RH.ValueOffset)
					Offset += 4
					local HandleU8 = HANDLE_TYPE_TO_U8[Interp.HandleType or "Free"] or 0
					buffer.writeu8(Buf, Offset, HandleU8)
					Offset += 1
				elseif Interp.Curve == "Easing" then
					local StyleU8 = EASING_STYLE_TO_U8[Interp.EasingStyle or "Sine"] or 0
					local DirU8 = EASING_DIR_TO_U8[Interp.EasingDirection or "In"] or 0
					buffer.writeu8(Buf, Offset, StyleU8)
					Offset += 1
					buffer.writeu8(Buf, Offset, DirU8)
					Offset += 1
				end
			end
		end
	end
	Offset = __WriteChunkWithCRC(Buf, KeyframeChunkStart, Constants.CHUNK_EDIT_KEYFRAMES, KeyframesSize)

	-- Markers chunk (ancillary — old readers skip silently)
	if HasMarkers then
		local MarkerChunkStart = Offset
		Offset += Constants.CHUNK_HEADER_SIZE
		buffer.writeu16(Buf, Offset, #Animation.Markers)
		Offset += 2
		for _, Marker in Animation.Markers do
			buffer.writef32(Buf, Offset, Marker.Time)
			Offset += 4
			Offset = __WriteString(Buf, Offset, Marker.Name)
			Offset = __WriteString(Buf, Offset, Marker.Value)
		end
		Offset = __WriteChunkWithCRC(Buf, MarkerChunkStart, Constants.CHUNK_MARKERS, MarkersSize)
	end

	return Buf
end

-- [[ DESERIALIZE EDIT FORMAT ]]

function Serializer.DeserializeEdit(Data: buffer): EditAnimation
	local BufLen = buffer.len(Data)

	-- 1. Read and validate header
	if BufLen < Constants.LUNA_HEADER_SIZE then
		error("Buffer too small for Luna header")
	end

	local Magic = buffer.readstring(Data, 0, 8)
	if Magic ~= Constants.LUNA_MAGIC then
		error("Invalid Luna magic number")
	end

	local FormatType = buffer.readu8(Data, 8)
	if FormatType ~= Constants.FORMAT_TYPE_EDIT then
		error(`Expected Edit format (0), got {FormatType}`)
	end

	local Offset = Constants.LUNA_HEADER_SIZE

	-- 2. Read chunks
	local AnimName = ""
	local Duration = 0
	local FrameRate = Constants.DEFAULT_FPS
	local IsLooping = false
	local Priority = 0

	local Markers: Array<AnimationData.AnimationMarker> = {}

	-- v2 track headers: per-channel keyframe counts
	local TrackHeaders: Array<TrackHeader> = {}
	local Tracks: Array<EditTrack> = {}

	while Offset < BufLen - 1 do
		-- Read chunk envelope
		if Offset + Constants.CHUNK_HEADER_SIZE > BufLen then
			break
		end
		local ChunkType = buffer.readu16(Data, Offset)
		local ChunkSize = buffer.readu32(Data, Offset + 2)
		local BodyStart = Offset + Constants.CHUNK_HEADER_SIZE
		local ChunkEnd = BodyStart + ChunkSize

		-- Validate chunk fits in buffer
		if ChunkEnd + 2 > BufLen then
			error(
				`Chunk 0x{string.format("%04X", ChunkType)} exceeds buffer (offset {Offset}, size {ChunkSize}, bufLen {BufLen})`
			)
		end

		-- Validate CRC16 — covers type (2 bytes) + body, intentionally skips size field
		-- (matches write side in __WriteChunkWithCRC; size is validated by bounds check above)
		local StoredCrc = buffer.readu16(Data, ChunkEnd)
		local ComputedCrc = __ComputeCRC16(Data, Offset, 2 + ChunkSize)
		if StoredCrc ~= ComputedCrc then
			error(`CRC16 mismatch for chunk 0x{string.format("%04X", ChunkType)}`)
		end

		if ChunkType == Constants.CHUNK_METADATA then
			local ReadOffset = BodyStart
			AnimName, ReadOffset = __ReadString(Data, ReadOffset)
			Duration = buffer.readf32(Data, ReadOffset)
			ReadOffset += 4
			FrameRate = buffer.readf32(Data, ReadOffset)
			ReadOffset += 4
			IsLooping = buffer.readu8(Data, ReadOffset) == 1
			ReadOffset += 1
			Priority = buffer.readu8(Data, ReadOffset)
		elseif ChunkType == Constants.CHUNK_TRACK_HEADERS then
			local ReadOffset = BodyStart
			local TrackCount = buffer.readu16(Data, ReadOffset)
			ReadOffset += 2
			for _ = 1, TrackCount do
				local Name: string
				Name, ReadOffset = __ReadString(Data, ReadOffset)
				local IsConst = buffer.readu8(Data, ReadOffset) == 1
				ReadOffset += 1
				-- Read per-channel keyframe counts (6 × u16)
				local ChannelHeaders: Array<ChannelHeader> = {}
				for _, ChannelId in Constants.CHANNEL_IDS do
					local Count = buffer.readu16(Data, ReadOffset)
					ReadOffset += 2
					table.insert(ChannelHeaders, { ChannelId = ChannelId, KeyframeCount = Count })
				end
				table.insert(TrackHeaders, { Name = Name, IsConstant = IsConst, ChannelHeaders = ChannelHeaders })
			end
		elseif ChunkType == Constants.CHUNK_EDIT_KEYFRAMES then
			local ReadOffset = BodyStart
			for _, Header in TrackHeaders do
				local Track = AnimationData.CreateEmptyTrack(Header.Name)
				-- Read per-channel keyframes
				for _, ChHeader in Header.ChannelHeaders do
					local Channel = Track.Channels[ChHeader.ChannelId]
					for _ = 1, ChHeader.KeyframeCount do
						local Time = buffer.readf32(Data, ReadOffset)
						ReadOffset += 4
						local Value = buffer.readf32(Data, ReadOffset)
						ReadOffset += 4

						local CurveU8 = buffer.readu8(Data, ReadOffset)
						ReadOffset += 1
						local CurveMode = U8_TO_CURVE_MODE[CurveU8] or "Linear"

						local Interp: InterpolationMode = {
							Curve = CurveMode,
							EasingStyle = nil,
							EasingDirection = nil,
							LeftHandle = nil,
							RightHandle = nil,
							HandleType = nil,
						}

						if CurveMode == "Bezier" then
							local LT = buffer.readf32(Data, ReadOffset)
							ReadOffset += 4
							local LV = buffer.readf32(Data, ReadOffset)
							ReadOffset += 4
							local RT = buffer.readf32(Data, ReadOffset)
							ReadOffset += 4
							local RV = buffer.readf32(Data, ReadOffset)
							ReadOffset += 4
							local HandleU8 = buffer.readu8(Data, ReadOffset)
							ReadOffset += 1
							Interp.LeftHandle = { TimeOffset = LT, ValueOffset = LV }
							Interp.RightHandle = { TimeOffset = RT, ValueOffset = RV }
							Interp.HandleType = U8_TO_HANDLE_TYPE[HandleU8] or "Free"
						elseif CurveMode == "Easing" then
							local StyleU8 = buffer.readu8(Data, ReadOffset)
							ReadOffset += 1
							local DirU8 = buffer.readu8(Data, ReadOffset)
							ReadOffset += 1
							Interp.EasingStyle = U8_TO_EASING_STYLE[StyleU8] or "Sine"
							Interp.EasingDirection = U8_TO_EASING_DIR[DirU8] or "In"
						end

						AnimationData.AddChannelKeyframe(Track, Channel, Time, Value, Interp)
					end
				end
				-- Restore authoritative IsConstant from serialized header
				Track.IsConstant = Header.IsConstant
				table.insert(Tracks, Track)
			end
		elseif ChunkType == Constants.CHUNK_MARKERS then
			local ReadOffset = BodyStart
			local MarkerCount = buffer.readu16(Data, ReadOffset)
			ReadOffset += 2
			for _ = 1, MarkerCount do
				local MarkerTime = buffer.readf32(Data, ReadOffset)
				ReadOffset += 4
				local MarkerName: string
				MarkerName, ReadOffset = __ReadString(Data, ReadOffset)
				local MarkerValue: string
				MarkerValue, ReadOffset = __ReadString(Data, ReadOffset)
				table.insert(Markers, {
					Name = MarkerName,
					Value = MarkerValue,
					Time = MarkerTime,
				})
			end
		else
			-- Unknown chunk: check critical/ancillary bit
			if bit32.band(ChunkType, Constants.CHUNK_ANCILLARY_BIT) == 0 then
				error(`Unknown critical chunk 0x{string.format("%04X", ChunkType)}`)
			end
			-- Ancillary: skip silently
		end

		Offset = ChunkEnd + 2 -- skip CRC16
	end

	return {
		Name = AnimName,
		Duration = Duration,
		Tracks = Tracks,
		Looping = IsLooping,
		Priority = Priority,
		FrameRate = FrameRate,
		TimeRemapCurve = nil,
		Markers = Markers,
	}
end

-- [[ HEADER INSPECTION ]]

function Serializer.ReadHeader(Data: buffer): (number, number, number)
	if buffer.len(Data) < Constants.LUNA_HEADER_SIZE then
		error("Buffer too small for Luna header")
	end

	local Magic = buffer.readstring(Data, 0, 8)
	if Magic ~= Constants.LUNA_MAGIC then
		error("Invalid Luna magic number")
	end

	local FormatType = buffer.readu8(Data, 8)
	local FormatVersion = buffer.readu16(Data, 9)
	local Flags = buffer.readu8(Data, 11)

	return FormatType, FormatVersion, Flags
end

export type Serializer = typeof(Serializer)

return Serializer
