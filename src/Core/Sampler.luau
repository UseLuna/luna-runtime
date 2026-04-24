--!strict
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local SampledTypes = require(script.Parent.Parent.Types.SampledTypes)
local Constants = require(script.Parent.Constants)
local Quaternion = require(script.Parent.Quaternion)
local CFrameUtils = require(script.Parent.CFrameUtils)
local AnimationData = require(script.Parent.AnimationData)
local Evaluator = require(script.Parent.Evaluator)
local SearchUtils = require(script.Parent.SearchUtils)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type Quat = Quaternion.Quat
type DecomposedCFrame = CFrameUtils.DecomposedCFrame
type RuntimeAnimation = AnimationData.RuntimeAnimation
type RuntimeTrack = AnimationData.RuntimeTrack
type SampledTrack = SampledTypes.SampledTrack
type SampledAnimation = SampledTypes.SampledAnimation

local ROT_STRIDE = Constants.ROTATION_BUFFER_STRIDE
local POS_STRIDE = Constants.POS_STRIDE
local EPSILON = Constants.EPSILON

local Sampler = {}

-- [[ BUFFER HELPERS (rotations only — positions use native Vector3 arrays) ]]

local function __WriteRotation(Buf: buffer, SampleIndex: number, Rotation: Quat)
	local Offset = SampleIndex * ROT_STRIDE
	buffer.writef32(Buf, Offset, Rotation.X)
	buffer.writef32(Buf, Offset + 4, Rotation.Y)
	buffer.writef32(Buf, Offset + 8, Rotation.Z)
	buffer.writef32(Buf, Offset + 12, Rotation.W)
end

local function __ReadRotation(Buf: buffer, SampleIndex: number): Quat
	local Offset = SampleIndex * ROT_STRIDE
	return {
		X = buffer.readf32(Buf, Offset),
		Y = buffer.readf32(Buf, Offset + 4),
		Z = buffer.readf32(Buf, Offset + 8),
		W = buffer.readf32(Buf, Offset + 12),
	}
end

-- Zero-allocation variant: read buffer floats into an existing Quat table.
local function __ReadRotationInto(Buf: buffer, SampleIndex: number, Out: Quat)
	local Offset = SampleIndex * ROT_STRIDE
	Out.X = buffer.readf32(Buf, Offset)
	Out.Y = buffer.readf32(Buf, Offset + 4)
	Out.Z = buffer.readf32(Buf, Offset + 8)
	Out.W = buffer.readf32(Buf, Offset + 12)
end

-- [[ TIME HELPERS ]]

local function __ClampTime(Time: number, Duration: number, IsLooping: boolean): number
	if Duration <= 0 then
		return 0
	end

	if IsLooping then
		return Time % Duration
	end

	return math.clamp(Time, 0, Duration)
end

-- [[ SPARSE TRACK HELPERS ]]

type SparseKeyframe = SampledTypes.SparseKeyframe

-- Determine the eval strategy for a runtime track based on its keyframes' curve modes.
-- All Linear → Sparse, All Stepped → Stepped, otherwise Dense.
local function __DetectStrategy(Track: RuntimeTrack): SampledTypes.EvalStrategy
	local Keyframes = Track.Keyframes
	if #Keyframes <= 1 then
		return "Dense" -- constant tracks handled separately
	end

	local AllLinear = true
	local AllStepped = true
	-- Last keyframe's curve mode doesn't matter (no segment after it)
	for Index = 1, #Keyframes - 1 do
		local Mode = Keyframes[Index].CurveMode
		if Mode ~= "Linear" then
			AllLinear = false
		end
		if Mode ~= "Stepped" then
			AllStepped = false
		end
		if not AllLinear and not AllStepped then
			return "Dense"
		end
	end

	if AllStepped then
		return "Stepped"
	end
	if AllLinear then
		return "Sparse"
	end
	return "Dense"
end

-- Build a pre-computed segment map for O(1) sparse keyframe lookup.
-- Maps quantized time buckets → keyframe index hints. Immutable after construction.
local function __BuildSegmentMap(SparseKFs: Array<SparseKeyframe>, Duration: number): (buffer, number)
	local KeyframeCount = #SparseKFs
	local Resolution = math.max(KeyframeCount * 2, 16)
	-- Clamp resolution to fit in uint8 indices (max 255 keyframes)
	Resolution = math.min(Resolution, 255)

	local SegMap = buffer.create(Resolution)

	for Bucket = 0, Resolution - 1 do
		local BucketTime = if Duration > 0 then Bucket * Duration / Resolution else 0
		local Index = SearchUtils.FindLastAtOrBefore(SparseKFs :: any, BucketTime)
		-- Store as 0-based uint8 (index into 1-based SparseKeyframes, subtract 1)
		buffer.writeu8(SegMap, Bucket, math.max(Index - 1, 0))
	end

	return SegMap, Resolution
end

-- Find the keyframe segment index for a given time in sparse keyframes.
-- Uses segment map for O(1) hint, then short linear scan (1-2 steps max).
-- Returns 1-based index of the LEFT keyframe in the bracketing pair.
local function __FindSparseIndex(
	SparseKFs: Array<SparseKeyframe>,
	Time: number,
	SegMap: buffer,
	SegResolution: number,
	Duration: number
): number
	local Count = #SparseKFs
	if Count <= 1 then
		return 1
	end

	-- Clamp
	if Time <= SparseKFs[1].Time then
		return 1
	end
	if Time >= SparseKFs[Count].Time then
		return Count
	end

	-- O(1) segment map lookup
	local BucketIndex = math.clamp(math.floor(Time * SegResolution / math.max(Duration, 0.001)), 0, SegResolution - 1)
	local Hint = buffer.readu8(SegMap, BucketIndex) + 1 -- convert 0-based to 1-based

	-- Linear scan forward from hint (at most 1-2 steps with good resolution)
	while Hint < Count and SparseKFs[Hint + 1].Time <= Time do
		Hint += 1
	end

	return Hint
end

-- [[ BAKING ]]

-- Bake a RuntimeAnimation into a pre-sampled format.
-- Positions: Array<Vector3> (native value type, zero allocation on read)
-- Rotations: flat f32 buffer (eliminates Quat table GC pressure)
-- SampleRate defaults to Constants.DEFAULT_FPS if nil.
-- For looping animations, the redundant last sample (identical to first) is dropped.
function Sampler.BakeToSampled(Runtime: RuntimeAnimation, SampleRate: number?): SampledAnimation
	local Rate = SampleRate or Constants.DEFAULT_FPS
	local Duration = Runtime.Duration
	local TotalSamples = math.floor(Duration * Rate) + 1

	-- Looping: drop redundant last sample (it equals the first)
	local StoredSamples = if Runtime.Looping then math.max(TotalSamples - 1, 1) else TotalSamples

	local SampledTracks: Array<SampledTrack> = table.create(#Runtime.Tracks)

	for TrackIndex, Track in Runtime.Tracks do
		-- 1. Constant tracks — single cached value
		if Track.IsConstant and Track.ConstantValue then
			local Decomposed = CFrameUtils.Decompose(Track.ConstantValue)
			SampledTracks[TrackIndex] = {
				Name = Track.Name,
				IsConstant = true,
				ConstantPosition = Decomposed.Position,
				ConstantRotation = Decomposed.Rotation,
				Positions = {},
				RotationBuffer = nil,
			}
			continue
		end

		local Strategy = __DetectStrategy(Track)

		-- 2. Sparse (Linear) or Stepped — keep original keyframes, build segment map
		if Strategy == "Sparse" or Strategy == "Stepped" then
			local SparseKFs: Array<SparseKeyframe> = table.create(#Track.Keyframes)
			for KeyIndex, Keyframe in Track.Keyframes do
				local Rot = Keyframe.Rotation
				-- Pre-flip: ensure adjacent quaternions are in the same hemisphere
				-- so runtime NLerp never needs a sign check (ozz pattern)
				if KeyIndex > 1 then
					local Prev = SparseKFs[KeyIndex - 1].Rotation
					local D = Prev.X * Rot.X + Prev.Y * Rot.Y + Prev.Z * Rot.Z + Prev.W * Rot.W
					if D < 0 then
						Rot = { X = -Rot.X, Y = -Rot.Y, Z = -Rot.Z, W = -Rot.W }
					end
				end
				SparseKFs[KeyIndex] = {
					Time = Keyframe.Time,
					Position = Keyframe.Position,
					Rotation = Rot,
				}
			end

			local SegMap, SegResolution = __BuildSegmentMap(SparseKFs, Duration)

			SampledTracks[TrackIndex] = {
				Name = Track.Name,
				IsConstant = false,
				ConstantPosition = nil,
				ConstantRotation = nil,
				Positions = {},
				RotationBuffer = nil,
				EvalStrategy = Strategy,
				SparseKeyframes = SparseKFs,
				SegmentMap = SegMap,
				SegmentMapResolution = SegResolution,
			}
			continue
		end

		-- 3. Dense (Bezier/Easing/Hermite/mixed) — bake to dense samples
		local Positions: Array<Vector3> = table.create(StoredSamples)
		local RotBuf = buffer.create(StoredSamples * ROT_STRIDE)
		local PrevRot: Quat? = nil

		for SampleIndex = 0, StoredSamples - 1 do
			local Time = math.min(SampleIndex / Rate, Duration)
			local Result = Evaluator.EvaluateTrack(Track, Time)
			local Decomposed = CFrameUtils.Decompose(Result)
			Positions[SampleIndex + 1] = Decomposed.Position

			-- Pre-flip: ensure adjacent samples are in the same hemisphere
			local Rot = Decomposed.Rotation
			if PrevRot then
				local D = PrevRot.X * Rot.X + PrevRot.Y * Rot.Y + PrevRot.Z * Rot.Z + PrevRot.W * Rot.W
				if D < 0 then
					Rot.X = -Rot.X
					Rot.Y = -Rot.Y
					Rot.Z = -Rot.Z
					Rot.W = -Rot.W
				end
			end
			PrevRot = Rot

			__WriteRotation(RotBuf, SampleIndex, Rot)
		end

		SampledTracks[TrackIndex] = {
			Name = Track.Name,
			IsConstant = false,
			ConstantPosition = nil,
			ConstantRotation = nil,
			Positions = Positions,
			RotationBuffer = RotBuf,
			EvalStrategy = "Dense",
		}
	end

	return {
		Name = Runtime.Name,
		Duration = Duration,
		SampleRate = Rate,
		SampleCount = StoredSamples,
		Tracks = SampledTracks,
		Looping = Runtime.Looping,
		Priority = Runtime.Priority,
	}
end

-- [[ O(1) EVALUATION ]]

-- Evaluate a single sampled track at an arbitrary time.
-- O(1) lookup via floor(Time * SampleRate) + Nlerp between adjacent samples.
-- If SnapToNearest is true, skips interpolation and returns the closest sample (cheaper, for LOD).
function Sampler.EvaluateSampledTrack(
	Track: SampledTrack,
	Time: number,
	SampleRate: number,
	SampleCount: number,
	SnapToNearest: boolean?
): CFrame
	-- Constant track: return cached value immediately
	if Track.IsConstant then
		if Track.ConstantPosition and Track.ConstantRotation then
			return CFrameUtils.Compose({
				Position = Track.ConstantPosition,
				Rotation = Track.ConstantRotation,
			})
		end
		return CFrame.identity
	end

	-- Sparse/Stepped: use original keyframes with segment map for O(1) lookup
	local Strategy = Track.EvalStrategy
	if (Strategy == "Sparse" or Strategy == "Stepped") and Track.SparseKeyframes and Track.SegmentMap then
		local SparseKFs = Track.SparseKeyframes
		local Count = #SparseKFs
		if Count == 0 then
			return CFrame.identity
		end
		if Count == 1 then
			return CFrameUtils.Compose({ Position = SparseKFs[1].Position, Rotation = SparseKFs[1].Rotation })
		end

		-- Duration derived from last keyframe time (segment map was built with this)
		local SparseDuration = SparseKFs[Count].Time
		local LeftIndex =
			__FindSparseIndex(SparseKFs, Time, Track.SegmentMap, Track.SegmentMapResolution :: number, SparseDuration)

		-- Stepped: snap to floor keyframe, no interpolation
		if Strategy == "Stepped" then
			return CFrameUtils.Compose({
				Position = SparseKFs[LeftIndex].Position,
				Rotation = SparseKFs[LeftIndex].Rotation,
			})
		end

		-- Sparse (Linear): lerp between left and right keyframes
		if LeftIndex >= Count then
			return CFrameUtils.Compose({ Position = SparseKFs[Count].Position, Rotation = SparseKFs[Count].Rotation })
		end

		local Left = SparseKFs[LeftIndex]
		local Right = SparseKFs[LeftIndex + 1]
		local SegDur = Right.Time - Left.Time
		local Alpha = if SegDur > 0 then (Time - Left.Time) / SegDur else 0

		return CFrameUtils.Compose({
			Position = Left.Position:Lerp(Right.Position, Alpha),
			Rotation = Quaternion.Slerp(Left.Rotation, Right.Rotation, Alpha),
		})
	end

	-- Dense: pre-sampled array + Nlerp (existing path)
	local Positions = Track.Positions
	local RotBuf = Track.RotationBuffer
	if #Positions == 0 or not RotBuf then
		return CFrame.identity
	end

	-- O(1) index calculation
	local ExactIndex = math.max(0, Time * SampleRate)
	local LowerIndex = math.floor(ExactIndex)
	local Alpha = ExactIndex - LowerIndex

	-- Clamp indices (1-based for Positions array, 0-based for RotationBuffer)
	local Lower = math.clamp(LowerIndex, 0, SampleCount - 1)
	local Upper = math.clamp(LowerIndex + 1, 0, SampleCount - 1)

	-- Snap to nearest: skip interpolation (LOD optimization)
	if SnapToNearest then
		local Nearest = if Alpha >= 0.5 then Upper else Lower
		return CFrameUtils.Compose({
			Position = Positions[Nearest + 1],
			Rotation = __ReadRotation(RotBuf, Nearest),
		})
	end

	-- No interpolation needed at exact sample boundary
	if Alpha < Constants.EPSILON or Lower == Upper then
		return CFrameUtils.Compose({
			Position = Positions[Lower + 1],
			Rotation = __ReadRotation(RotBuf, Lower),
		})
	end

	-- Nlerp between adjacent samples (faster than Slerp, accurate at 30fps spacing)
	local RotA = __ReadRotation(RotBuf, Lower)
	local RotB = __ReadRotation(RotBuf, Upper)

	return CFrameUtils.Compose({
		Position = Positions[Lower + 1]:Lerp(Positions[Upper + 1], Alpha),
		Rotation = Quaternion.Nlerp(RotA, RotB, Alpha),
	})
end

-- Evaluate all tracks in a sampled animation at an arbitrary time.
function Sampler.EvaluateSampledAnimation(Animation: SampledAnimation, Time: number): StringIndexable<CFrame>
	local ClampedTime = __ClampTime(Time, Animation.Duration, Animation.Looping)
	local Result: StringIndexable<CFrame> = {}

	for _, Track in Animation.Tracks do
		Result[Track.Name] =
			Sampler.EvaluateSampledTrack(Track, ClampedTime, Animation.SampleRate, Animation.SampleCount)
	end

	return Result
end

-- [[ ADDITIVE BAKING ]]

-- Bake a RuntimeAnimation as additive deltas from a reference pose.
-- Each sample stores the difference from RestPositions/RestRotations.
-- At runtime, these deltas are ADDED to the base pose (not replacing).
-- Reference is typically the rest/bind pose or frame 0 of the clip.
function Sampler.BakeToSampledAdditive(
	Runtime: RuntimeAnimation,
	RestPositions: Array<Vector3>,
	RestRotations: Array<Quaternion.Quat>,
	NameToIndex: StringIndexable<number>,
	SampleRate: number?
): SampledAnimation
	local Rate = SampleRate or Constants.DEFAULT_FPS
	local Duration = Runtime.Duration
	local TotalSamples = math.floor(Duration * Rate) + 1
	local StoredSamples = if Runtime.Looping then math.max(TotalSamples - 1, 1) else TotalSamples

	local SampledTracks: Array<SampledTrack> = table.create(#Runtime.Tracks)

	for TrackIndex, Track in Runtime.Tracks do
		local BoneIndex = NameToIndex[Track.Name]
		local RefPos = if BoneIndex then RestPositions[BoneIndex] else Vector3.zero
		local RefRot = if BoneIndex then RestRotations[BoneIndex] else Quaternion.Identity()
		-- Conjugate of reference rotation for delta computation: deltaRot = sampleRot * conjugate(refRot)
		local RefRotConj = Quaternion.Conjugate(RefRot)

		if Track.IsConstant and Track.ConstantValue then
			local Decomposed = CFrameUtils.Decompose(Track.ConstantValue)
			local DeltaPos = Decomposed.Position - RefPos
			local DeltaRot = Quaternion.Multiply(Decomposed.Rotation, RefRotConj)
			-- Check if delta is effectively zero (constant track with no change from rest)
			local IsZeroDelta = DeltaPos.Magnitude < 0.0001
				and math.abs(DeltaRot.X) < 0.0001
				and math.abs(DeltaRot.Y) < 0.0001
				and math.abs(DeltaRot.Z) < 0.0001
				and math.abs(DeltaRot.W - 1) < 0.0001

			SampledTracks[TrackIndex] = {
				Name = Track.Name,
				IsConstant = true,
				ConstantPosition = if IsZeroDelta then Vector3.zero else DeltaPos,
				ConstantRotation = if IsZeroDelta then Quaternion.Identity() else DeltaRot,
				Positions = {},
				RotationBuffer = nil,
			}
		else
			local Positions: Array<Vector3> = table.create(StoredSamples)
			local RotBuf = buffer.create(StoredSamples * ROT_STRIDE)

			for SampleIndex = 0, StoredSamples - 1 do
				local Time = math.min(SampleIndex / Rate, Duration)
				local Result = Evaluator.EvaluateTrack(Track, Time)
				local Decomposed = CFrameUtils.Decompose(Result)

				-- Compute delta from reference
				local DeltaPos = Decomposed.Position - RefPos
				local DeltaRot = Quaternion.Multiply(Decomposed.Rotation, RefRotConj)

				Positions[SampleIndex + 1] = DeltaPos
				__WriteRotation(RotBuf, SampleIndex, DeltaRot)
			end

			SampledTracks[TrackIndex] = {
				Name = Track.Name,
				IsConstant = false,
				ConstantPosition = nil,
				ConstantRotation = nil,
				Positions = Positions,
				RotationBuffer = RotBuf,
			}
		end
	end

	return {
		Name = Runtime.Name,
		Duration = Duration,
		SampleRate = Rate,
		SampleCount = StoredSamples,
		Tracks = SampledTracks,
		Looping = Runtime.Looping,
		Priority = Runtime.Priority,
		IsAdditive = true,
	}
end

-- [[ DIRECT POSE BUFFER WRITES (zero allocation, no CFrame intermediate) ]]

-- Evaluate a single sampled track and write Position + Quaternion directly into buffers at BoneIndex.
-- ZERO ALLOCATION: all results written via buffer.writef32.
-- BoneIndex is 1-based.
function Sampler.EvaluateSampledTrackInto(
	Track: SampledTrack,
	Time: number,
	SampleRate: number,
	SampleCount: number,
	PosBuf: buffer,
	RotBuf: buffer,
	BoneIndex: number
)
	local PosOff = (BoneIndex - 1) * POS_STRIDE
	local RotOff = (BoneIndex - 1) * ROT_STRIDE

	-- Constant track: write cached values
	if Track.IsConstant then
		local CP = Track.ConstantPosition
		if CP then
			buffer.writef32(PosBuf, PosOff, CP.X)
			buffer.writef32(PosBuf, PosOff + 4, CP.Y)
			buffer.writef32(PosBuf, PosOff + 8, CP.Z)
		end
		local CR = Track.ConstantRotation
		if CR then
			buffer.writef32(RotBuf, RotOff, CR.X)
			buffer.writef32(RotBuf, RotOff + 4, CR.Y)
			buffer.writef32(RotBuf, RotOff + 8, CR.Z)
			buffer.writef32(RotBuf, RotOff + 12, CR.W)
		else
			buffer.writef32(RotBuf, RotOff, 0)
			buffer.writef32(RotBuf, RotOff + 4, 0)
			buffer.writef32(RotBuf, RotOff + 8, 0)
			buffer.writef32(RotBuf, RotOff + 12, 1)
		end
		return
	end

	-- Sparse/Stepped: keyframe lookup via segment map
	local Strategy = Track.EvalStrategy
	if (Strategy == "Sparse" or Strategy == "Stepped") and Track.SparseKeyframes and Track.SegmentMap then
		local SparseKFs = Track.SparseKeyframes
		local Count = #SparseKFs
		if Count == 0 then
			buffer.writef32(RotBuf, RotOff + 12, 1)
			return
		end

		-- Helper: write a sparse keyframe's Position + Rotation to output buffers
		local function WriteSparseKF(KF: SparseKeyframe)
			local P = KF.Position
			buffer.writef32(PosBuf, PosOff, P.X)
			buffer.writef32(PosBuf, PosOff + 4, P.Y)
			buffer.writef32(PosBuf, PosOff + 8, P.Z)
			local R = KF.Rotation
			buffer.writef32(RotBuf, RotOff, R.X)
			buffer.writef32(RotBuf, RotOff + 4, R.Y)
			buffer.writef32(RotBuf, RotOff + 8, R.Z)
			buffer.writef32(RotBuf, RotOff + 12, R.W)
		end

		if Count == 1 then
			WriteSparseKF(SparseKFs[1])
			return
		end

		local SparseDuration = SparseKFs[Count].Time
		local LeftIndex =
			__FindSparseIndex(SparseKFs, Time, Track.SegmentMap, Track.SegmentMapResolution :: number, SparseDuration)

		if Strategy == "Stepped" then
			WriteSparseKF(SparseKFs[LeftIndex])
			return
		end

		-- Sparse (Linear): NLerp
		if LeftIndex >= Count then
			WriteSparseKF(SparseKFs[Count])
			return
		end

		local Left = SparseKFs[LeftIndex]
		local Right = SparseKFs[LeftIndex + 1]
		local SegDur = Right.Time - Left.Time
		local Alpha = if SegDur > 0 then (Time - Left.Time) / SegDur else 0

		-- Inline position lerp
		local LP = Left.Position
		local RP = Right.Position
		buffer.writef32(PosBuf, PosOff, LP.X + (RP.X - LP.X) * Alpha)
		buffer.writef32(PosBuf, PosOff + 4, LP.Y + (RP.Y - LP.Y) * Alpha)
		buffer.writef32(PosBuf, PosOff + 8, LP.Z + (RP.Z - LP.Z) * Alpha)

		-- Inline NLerp (pre-flipped at bake time, no sign check needed)
		local LR = Left.Rotation
		local RR = Right.Rotation
		local RX = LR.X + (RR.X - LR.X) * Alpha
		local RY = LR.Y + (RR.Y - LR.Y) * Alpha
		local RZ = LR.Z + (RR.Z - LR.Z) * Alpha
		local RW = LR.W + (RR.W - LR.W) * Alpha
		local Len = math.sqrt(RX * RX + RY * RY + RZ * RZ + RW * RW)
		if Len < EPSILON then
			buffer.writef32(RotBuf, RotOff + 12, 1)
		else
			local InvLen = 1 / Len
			buffer.writef32(RotBuf, RotOff, RX * InvLen)
			buffer.writef32(RotBuf, RotOff + 4, RY * InvLen)
			buffer.writef32(RotBuf, RotOff + 8, RZ * InvLen)
			buffer.writef32(RotBuf, RotOff + 12, RW * InvLen)
		end
		return
	end

	-- Dense: pre-sampled array + Nlerp
	local TrackPositions = Track.Positions
	local TrackRotBuf = Track.RotationBuffer
	if #TrackPositions == 0 or not TrackRotBuf then
		buffer.writef32(RotBuf, RotOff + 12, 1)
		return
	end

	-- O(1) index calculation
	local ExactIndex = math.max(0, Time * SampleRate)
	local LowerIndex = math.floor(ExactIndex)
	local Alpha = ExactIndex - LowerIndex

	local Lower = math.clamp(LowerIndex, 0, SampleCount - 1)
	local Upper = math.clamp(LowerIndex + 1, 0, SampleCount - 1)

	-- No interpolation needed at exact sample boundary — zero-copy rotation
	if Alpha < Constants.EPSILON or Lower == Upper then
		local P = TrackPositions[Lower + 1]
		buffer.writef32(PosBuf, PosOff, P.X)
		buffer.writef32(PosBuf, PosOff + 4, P.Y)
		buffer.writef32(PosBuf, PosOff + 8, P.Z)
		buffer.copy(RotBuf, RotOff, TrackRotBuf, Lower * ROT_STRIDE, ROT_STRIDE)
		return
	end

	-- Inline position lerp
	local LP = TrackPositions[Lower + 1]
	local UP = TrackPositions[Upper + 1]
	buffer.writef32(PosBuf, PosOff, LP.X + (UP.X - LP.X) * Alpha)
	buffer.writef32(PosBuf, PosOff + 4, LP.Y + (UP.Y - LP.Y) * Alpha)
	buffer.writef32(PosBuf, PosOff + 8, LP.Z + (UP.Z - LP.Z) * Alpha)

	-- Read adjacent rotation samples from track buffer
	local LowerRotOff = Lower * ROT_STRIDE
	local UpperRotOff = Upper * ROT_STRIDE
	local AX = buffer.readf32(TrackRotBuf, LowerRotOff)
	local AY = buffer.readf32(TrackRotBuf, LowerRotOff + 4)
	local AZ = buffer.readf32(TrackRotBuf, LowerRotOff + 8)
	local AW = buffer.readf32(TrackRotBuf, LowerRotOff + 12)
	local BX = buffer.readf32(TrackRotBuf, UpperRotOff)
	local BY = buffer.readf32(TrackRotBuf, UpperRotOff + 4)
	local BZ = buffer.readf32(TrackRotBuf, UpperRotOff + 8)
	local BW = buffer.readf32(TrackRotBuf, UpperRotOff + 12)

	-- Pre-flipped at bake time — inline NLerp
	local D = AX * BX + AY * BY + AZ * BZ + AW * BW
	local Sign = if D < 0 then -1 else 1
	BX *= Sign
	BY *= Sign
	BZ *= Sign
	BW *= Sign
	local RX = AX + (BX - AX) * Alpha
	local RY = AY + (BY - AY) * Alpha
	local RZ = AZ + (BZ - AZ) * Alpha
	local RW = AW + (BW - AW) * Alpha
	local Len = math.sqrt(RX * RX + RY * RY + RZ * RZ + RW * RW)
	if Len < EPSILON then
		buffer.writef32(RotBuf, RotOff, 0)
		buffer.writef32(RotBuf, RotOff + 4, 0)
		buffer.writef32(RotBuf, RotOff + 8, 0)
		buffer.writef32(RotBuf, RotOff + 12, 1)
	else
		local InvLen = 1 / Len
		buffer.writef32(RotBuf, RotOff, RX * InvLen)
		buffer.writef32(RotBuf, RotOff + 4, RY * InvLen)
		buffer.writef32(RotBuf, RotOff + 8, RZ * InvLen)
		buffer.writef32(RotBuf, RotOff + 12, RW * InvLen)
	end
end

-- Evaluate all tracks of a sampled animation into buffer-backed Pose.
-- NameToIndex maps track name → 1-based bone index.
-- BoneMaskWeights is optional buffer — bones with weight < 0.001 are skipped.
function Sampler.EvaluateSampledInto(
	Animation: SampledAnimation,
	Time: number,
	PosBuf: buffer,
	RotBuf: buffer,
	NameToIndex: StringIndexable<number>,
	BoneMaskWeights: buffer?
)
	local ClampedTime = __ClampTime(Time, Animation.Duration, Animation.Looping)

	for _, Track in Animation.Tracks do
		local BoneIndex = NameToIndex[Track.Name]
		if not BoneIndex then
			continue
		end

		-- Partial track evaluation: skip bones with zero mask weight
		if BoneMaskWeights and buffer.readf32(BoneMaskWeights, (BoneIndex - 1) * 4) < 0.001 then
			continue
		end

		Sampler.EvaluateSampledTrackInto(
			Track,
			ClampedTime,
			Animation.SampleRate,
			Animation.SampleCount,
			PosBuf,
			RotBuf,
			BoneIndex
		)
	end
end

export type Sampler = typeof(Sampler)

return Sampler
