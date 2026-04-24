--!strict
--!optimize 2
--!native
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local Constants = require(script.Parent.Constants)
local Quaternion = require(script.Parent.Quaternion)
local CFrameUtils = require(script.Parent.CFrameUtils)
local AnimationData = require(script.Parent.AnimationData)
local Curves = require(script.Parent.Curves)
local SearchUtils = require(script.Parent.SearchUtils)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type Quat = Quaternion.Quat
type DecomposedCFrame = CFrameUtils.DecomposedCFrame

local POS_STRIDE = Constants.POS_STRIDE
local ROT_STRIDE = Constants.ROTATION_BUFFER_STRIDE
type RuntimeKeyframe = AnimationData.RuntimeKeyframe
type RuntimeTrack = AnimationData.RuntimeTrack
type RuntimeAnimation = AnimationData.RuntimeAnimation

local Evaluator = {}

-- [[ INTERNAL HELPERS ]]

-- Binary search delegated to SearchUtils (shared across Core modules).

-- Find the two keyframes surrounding a given time.
-- Uses cached index for O(1) sequential playback, binary search as O(log n) fallback.
-- Mutates Track.CachedIndex for next frame's fast path.
local function __FindKeyframeIndex(Track: RuntimeTrack, Time: number): (number, number)
	local Keyframes = Track.Keyframes
	local Count = #Keyframes

	if Count == 0 then
		return 1, 1
	end

	if Count == 1 then
		return 1, 1
	end

	-- Clamp to valid range
	if Time <= Keyframes[1].Time then
		Track.CachedIndex = 1
		return 1, 1
	end

	if Time >= Keyframes[Count].Time then
		Track.CachedIndex = Count
		return Count, Count
	end

	-- 1. Fast path: check if cached index is still valid
	local Cached = Track.CachedIndex
	if Cached >= 1 and Cached < Count then
		local CachedTime = Keyframes[Cached].Time
		local NextTime = Keyframes[Cached + 1].Time
		if Time >= CachedTime and Time < NextTime then
			return Cached, Cached + 1
		end

		-- Check one step forward (common during linear playback)
		if Cached + 1 < Count then
			local NextNextTime = Keyframes[Cached + 2].Time
			if Time >= NextTime and Time < NextNextTime then
				Track.CachedIndex = Cached + 1
				return Cached + 1, Cached + 2
			end
		end
	end

	-- 2. Fallback: binary search
	local LeftIndex = SearchUtils.FindLastAtOrBefore(Keyframes :: any, Time)
	local RightIndex = math.min(LeftIndex + 1, Count)
	Track.CachedIndex = LeftIndex
	return LeftIndex, RightIndex
end

-- Interpolate between two keyframes using a remapped alpha.
-- Position: Vector3 lerp. Rotation: quaternion slerp. Compose to CFrame.
local function __Interpolate(A: RuntimeKeyframe, B: RuntimeKeyframe, Alpha: number): CFrame
	local Interpolated: DecomposedCFrame = {
		Position = A.Position:Lerp(B.Position, Alpha),
		Rotation = Quaternion.Slerp(A.Rotation, B.Rotation, Alpha),
	}
	return CFrameUtils.Compose(Interpolated)
end

local function __ClampTime(Time: number, Duration: number, IsLooping: boolean): number
	if Duration <= 0 then
		return 0
	end

	if IsLooping then
		return Time % Duration
	end

	return math.clamp(Time, 0, Duration)
end

-- [[ PUBLIC API ]]

function Evaluator.EvaluateTrack(Track: RuntimeTrack, Time: number): CFrame
	-- Constant track: return cached value immediately (O(1), no computation)
	if Track.IsConstant and Track.ConstantValue then
		return Track.ConstantValue
	end

	local Keyframes = Track.Keyframes
	local Count = #Keyframes

	if Count == 0 then
		return CFrame.identity
	end

	if Count == 1 then
		return CFrameUtils.Compose({
			Position = Keyframes[1].Position,
			Rotation = Keyframes[1].Rotation,
		})
	end

	local LeftIndex, RightIndex = __FindKeyframeIndex(Track, Time)

	-- Exact match or clamped to boundary
	if LeftIndex == RightIndex then
		return CFrameUtils.Compose({
			Position = Keyframes[LeftIndex].Position,
			Rotation = Keyframes[LeftIndex].Rotation,
		})
	end

	local Left = Keyframes[LeftIndex]
	local Right = Keyframes[RightIndex]

	-- Compute interpolation alpha (0-1) between the two keyframes
	local SegmentDuration = Right.Time - Left.Time
	local Alpha = if SegmentDuration > 0 then (Time - Left.Time) / SegmentDuration else 0

	-- Remap alpha through curve system (inline fast path for Linear)
	local RemappedAlpha
	if Left.CurveMode == "Linear" then
		RemappedAlpha = Alpha
	else
		RemappedAlpha = Curves.RemapAlpha(Left.CurveMode, Alpha, Left.CurveContext)
	end

	return __Interpolate(Left, Right, RemappedAlpha)
end

function Evaluator.EvaluateAnimation(Animation: RuntimeAnimation, Time: number): StringIndexable<CFrame>
	local ClampedTime = __ClampTime(Time, Animation.Duration, Animation.Looping)
	local Result: StringIndexable<CFrame> = {}

	for _, Track in Animation.Tracks do
		Result[Track.Name] = Evaluator.EvaluateTrack(Track, ClampedTime)
	end

	return Result
end

-- [[ DIRECT BUFFER WRITES (zero allocation, no CFrame intermediate) ]]

-- Evaluate a single track and write Position + Quaternion directly into buffers at BoneIndex.
-- BoneIndex is 1-based. Uses Slerp (returns Quat table — acceptable for live eval / editor path).
function Evaluator.EvaluateTrackInto(
	Track: RuntimeTrack,
	Time: number,
	PosBuf: buffer,
	RotBuf: buffer,
	BoneIndex: number
)
	local PosOff = (BoneIndex - 1) * POS_STRIDE
	local RotOff = (BoneIndex - 1) * ROT_STRIDE

	-- Helper: write a Quat to the rotation buffer
	local function WriteQuat(Q: Quat)
		buffer.writef32(RotBuf, RotOff, Q.X)
		buffer.writef32(RotBuf, RotOff + 4, Q.Y)
		buffer.writef32(RotBuf, RotOff + 8, Q.Z)
		buffer.writef32(RotBuf, RotOff + 12, Q.W)
	end

	-- Helper: write a Position to the position buffer
	local function WritePos(P: Vector3)
		buffer.writef32(PosBuf, PosOff, P.X)
		buffer.writef32(PosBuf, PosOff + 4, P.Y)
		buffer.writef32(PosBuf, PosOff + 8, P.Z)
	end

	-- Constant track: decompose CFrame, write to buffers
	if Track.IsConstant and Track.ConstantValue then
		local CF = Track.ConstantValue
		WritePos(CF.Position)
		WriteQuat(Quaternion.FromCFrame(CF))
		return
	end

	local Keyframes = Track.Keyframes
	local Count = #Keyframes

	if Count == 0 then
		buffer.writef32(RotBuf, RotOff + 12, 1)
		return
	end

	if Count == 1 then
		WritePos(Keyframes[1].Position)
		WriteQuat(Keyframes[1].Rotation)
		return
	end

	local LeftIndex, RightIndex = __FindKeyframeIndex(Track, Time)

	if LeftIndex == RightIndex then
		WritePos(Keyframes[LeftIndex].Position)
		WriteQuat(Keyframes[LeftIndex].Rotation)
		return
	end

	local Left = Keyframes[LeftIndex]
	local Right = Keyframes[RightIndex]

	local SegmentDuration = Right.Time - Left.Time
	local Alpha = if SegmentDuration > 0 then (Time - Left.Time) / SegmentDuration else 0

	local RemappedAlpha
	if Left.CurveMode == "Linear" then
		RemappedAlpha = Alpha
	else
		RemappedAlpha = Curves.RemapAlpha(Left.CurveMode, Alpha, Left.CurveContext)
	end

	-- Position: inline lerp and write to buffer
	local LP = Left.Position
	local RP = Right.Position
	buffer.writef32(PosBuf, PosOff, LP.X + (RP.X - LP.X) * RemappedAlpha)
	buffer.writef32(PosBuf, PosOff + 4, LP.Y + (RP.Y - LP.Y) * RemappedAlpha)
	buffer.writef32(PosBuf, PosOff + 8, LP.Z + (RP.Z - LP.Z) * RemappedAlpha)

	-- Rotation: Slerp returns a Quat table (acceptable for live eval path)
	WriteQuat(Quaternion.Slerp(Left.Rotation, Right.Rotation, RemappedAlpha))
end

-- Evaluate all tracks into buffer-backed Pose. NameToIndex maps track name → 1-based bone index.
-- BoneMaskWeights is optional buffer — bones with weight < 0.001 are skipped.
function Evaluator.EvaluateAnimationInto(
	Animation: RuntimeAnimation,
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

		Evaluator.EvaluateTrackInto(Track, ClampedTime, PosBuf, RotBuf, BoneIndex)
	end
end

export type Evaluator = typeof(Evaluator)

return Evaluator
