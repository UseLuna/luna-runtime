--!strict
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local ModifierTypes = require(script.Parent.Parent.Types.ModifierTypes)
local Constants = require(script.Parent.Constants)
local Quaternion = require(script.Parent.Quaternion)
local CFrameUtils = require(script.Parent.CFrameUtils)
local Curves = require(script.Parent.Curves)
local Logger = require(script.Parent.Parent.Shared.Logger)
local SearchUtils = require(script.Parent.SearchUtils)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type ModifierEntry = ModifierTypes.ModifierEntry
type Quat = Quaternion.Quat
type DecomposedCFrame = CFrameUtils.DecomposedCFrame
type BezierCoefficients = Curves.BezierCoefficients
type EasingFunction = Curves.EasingFunction
type CurveContext = Curves.CurveContext

local AnimationData = {}

-- [[ TYPES — EDIT FORMAT ]]

export type BezierHandle = Curves.BezierHandle

export type InterpolationMode = {
	Curve: string,
	EasingStyle: string?,
	EasingDirection: string?,
	LeftHandle: BezierHandle?,
	RightHandle: BezierHandle?,
	HandleType: string?,
}

-- Channel identifiers for per-channel scalar keyframes
export type ChannelId = "PositionX" | "PositionY" | "PositionZ" | "RotationX" | "RotationY" | "RotationZ"

-- A single scalar keyframe (studs for position, degrees for rotation)
export type ScalarKeyframe = {
	Time: number,
	Value: number,
	Interpolation: InterpolationMode,
}

-- One channel of a track (e.g., PositionX for "RightArm")
export type EditChannel = {
	Id: ChannelId,
	Keyframes: Array<ScalarKeyframe>,
	IsConstant: boolean,
}

export type EditTrack = {
	Name: string,
	Channels: StringIndexable<EditChannel>,
	IsConstant: boolean,
	Modifiers: Array<ModifierEntry>?,
}

export type AnimationMarker = {
	Name: string,
	Value: string,
	Time: number,
}

export type EditAnimation = {
	Name: string,
	Duration: number,
	Tracks: Array<EditTrack>,
	Looping: boolean,
	Priority: number,
	FrameRate: number,
	TimeRemapCurve: EditTrack?,
	Markers: Array<AnimationMarker>,
}

-- [[ TYPES — RUNTIME FORMAT ]]

export type RuntimeKeyframe = {
	Time: number,
	Position: Vector3,
	Rotation: Quat,
	CurveMode: string,
	CurveContext: CurveContext,
}

export type RuntimeTrack = {
	Name: string,
	Keyframes: Array<RuntimeKeyframe>,
	CachedIndex: number,
	IsConstant: boolean,
	ConstantValue: CFrame?,
}

export type RuntimeAnimation = {
	Name: string,
	Duration: number,
	Tracks: Array<RuntimeTrack>,
	Looping: boolean,
	Priority: number,
}

-- [[ CONSTRUCTORS ]]

function AnimationData.DefaultInterpolation(): InterpolationMode
	return {
		Curve = "Linear",
		EasingStyle = nil,
		EasingDirection = nil,
		LeftHandle = nil,
		RightHandle = nil,
		HandleType = nil,
	}
end

function AnimationData.CreateEmptyAnimation(Name: string, Duration: number): EditAnimation
	return {
		Name = Name,
		Duration = Duration,
		Tracks = {},
		Looping = false,
		Priority = 0,
		FrameRate = Constants.DEFAULT_FPS,
		TimeRemapCurve = nil,
		Markers = {},
	}
end

function AnimationData.CreateEmptyChannel(Id: ChannelId): EditChannel
	return {
		Id = Id,
		Keyframes = {},
		IsConstant = true,
	}
end

function AnimationData.CreateEmptyTrack(Name: string): EditTrack
	local Channels: StringIndexable<EditChannel> = {}
	for _, Id in Constants.CHANNEL_IDS do
		Channels[Id] = AnimationData.CreateEmptyChannel(Id :: ChannelId)
	end
	return {
		Name = Name,
		Channels = Channels,
		IsConstant = true,
		Modifiers = nil,
	}
end

-- [[ INTERNAL HELPERS ]]

-- Check if a single channel has all identical values.
local function __CheckChannelIsConstant(Channel: EditChannel): boolean
	local Keyframes = Channel.Keyframes
	if #Keyframes <= 1 then
		return true
	end
	local First = Keyframes[1].Value
	local Epsilon = Constants.EPSILON
	for Index = 2, #Keyframes do
		if math.abs(Keyframes[Index].Value - First) > Epsilon then
			return false
		end
	end
	return true
end

-- Update a channel's IsConstant flag, then recompute the track-level flag.
local function __UpdateConstantFlags(Track: EditTrack, Channel: EditChannel)
	Channel.IsConstant = __CheckChannelIsConstant(Channel)
	-- Track is constant only if ALL channels are constant
	local AllConstant = true
	for _, Id in Constants.CHANNEL_IDS do
		if not Track.Channels[Id].IsConstant then
			AllConstant = false
			break
		end
	end
	Track.IsConstant = AllConstant
end

-- Euler continuity filter: unwrap NewDegrees to be within ±180° of PrevDegrees.
-- Prevents discontinuities like 179° → -181° when decomposing CFrames.
local function __EulerContinuityFilter(NewDegrees: number, PrevDegrees: number): number
	local Delta = NewDegrees - PrevDegrees
	-- Wrap delta into [-180, 180)
	Delta = ((Delta + 180) % 360) - 180
	return PrevDegrees + Delta
end

-- [[ KEYFRAME OPERATIONS ]]

-- Insert a scalar keyframe into a single channel in sorted order. Returns insertion index.
function AnimationData.AddChannelKeyframe(
	Track: EditTrack,
	Channel: EditChannel,
	Time: number,
	Value: number,
	Interpolation: InterpolationMode?
): number
	local Interp = Interpolation or AnimationData.DefaultInterpolation()
	local Keyframe: ScalarKeyframe = {
		Time = Time,
		Value = Value,
		Interpolation = Interp,
	}

	-- Binary search for insertion point to maintain sorted order
	local Keyframes = Channel.Keyframes
	local InsertIndex = SearchUtils.FindInsertIndex(Keyframes :: any, Time)

	table.insert(Keyframes, InsertIndex, Keyframe)
	__UpdateConstantFlags(Track, Channel)

	return InsertIndex
end

-- Backward-compatible CFrame keyframe insertion.
-- Decomposes CFrame into 6 scalar channels (position in studs, rotation in degrees).
-- Applies Euler continuity filter to prevent curve discontinuities.
-- Returns the insertion index of the PositionX channel (for compat).
function AnimationData.AddKeyframe(
	Track: EditTrack,
	Time: number,
	Value: CFrame,
	Interpolation: InterpolationMode?
): number
	local Interp = Interpolation or AnimationData.DefaultInterpolation()

	-- Decompose CFrame to position + euler angles (degrees)
	local Position = Value.Position
	local RX, RY, RZ = Value:ToEulerAnglesYXZ()
	local RotXDeg = math.deg(RX)
	local RotYDeg = math.deg(RY)
	local RotZDeg = math.deg(RZ)

	-- Apply Euler continuity filter for rotation channels
	-- Compare to the last keyframe in each rotation channel to prevent discontinuities
	local RotChannelValues = { RotXDeg, RotYDeg, RotZDeg }
	for Index, Id in Constants.ROTATION_CHANNELS do
		local Channel = Track.Channels[Id]
		if #Channel.Keyframes > 0 then
			local PrevValue = Channel.Keyframes[#Channel.Keyframes].Value
			RotChannelValues[Index] = __EulerContinuityFilter(RotChannelValues[Index], PrevValue)
		end
	end

	-- Write to all 6 channels
	local Values = {
		Position.X,
		Position.Y,
		Position.Z,
		RotChannelValues[1],
		RotChannelValues[2],
		RotChannelValues[3],
	}

	local FirstIndex = 0
	for Index, Id in Constants.CHANNEL_IDS do
		local Channel = Track.Channels[Id]
		local InsertIndex = AnimationData.AddChannelKeyframe(Track, Channel, Time, Values[Index], Interp)
		if Index == 1 then
			FirstIndex = InsertIndex
		end
	end

	return FirstIndex
end

-- Remove a keyframe from a single channel by index.
function AnimationData.RemoveChannelKeyframe(Track: EditTrack, Channel: EditChannel, Index: number)
	table.remove(Channel.Keyframes, Index)
	__UpdateConstantFlags(Track, Channel)
end

-- Remove keyframes at a given time from all channels (backward compat).
function AnimationData.RemoveKeyframeAtTime(Track: EditTrack, Time: number)
	local Epsilon = Constants.EPSILON
	for _, Id in Constants.CHANNEL_IDS do
		local Channel = Track.Channels[Id]
		for KeyIndex = #Channel.Keyframes, 1, -1 do
			if math.abs(Channel.Keyframes[KeyIndex].Time - Time) < Epsilon then
				table.remove(Channel.Keyframes, KeyIndex)
			end
		end
		__UpdateConstantFlags(Track, Channel)
	end
end

-- [[ COMPILATION ]]

-- Recompose 6 scalar channel values into a CFrame.
-- Position values are in studs, rotation values are in degrees (converted to radians here).
local function __RecomposeCFrame(
	PosX: number,
	PosY: number,
	PosZ: number,
	RotXDeg: number,
	RotYDeg: number,
	RotZDeg: number
): CFrame
	return CFrame.new(PosX, PosY, PosZ)
		* CFrame.fromEulerAnglesYXZ(math.rad(RotXDeg), math.rad(RotYDeg), math.rad(RotZDeg))
end

-- Compile a per-channel EditTrack into a RuntimeTrack.
-- Fast path: all channels share the same keyframe times (common case from AddKeyframe).
-- Slow path: channels have different times — merges and bakes (Chunk C).
local function __CompileTrack(Track: EditTrack): RuntimeTrack
	local Channels = Track.Channels
	local PosXChannel = Channels.PositionX
	local KeyframeCount = #PosXChannel.Keyframes

	-- 1. Check if all channels are aligned (same count and same times)
	local IsAligned = true
	for _, Id in Constants.CHANNEL_IDS do
		local Channel = Channels[Id]
		if #Channel.Keyframes ~= KeyframeCount then
			IsAligned = false
			break
		end
	end

	if IsAligned and KeyframeCount > 0 then
		-- Verify times match across all channels
		for Index = 1, KeyframeCount do
			local ReferenceTime = PosXChannel.Keyframes[Index].Time
			for ChannelIndex = 2, Constants.CHANNEL_COUNT do
				local Id = Constants.CHANNEL_IDS[ChannelIndex]
				local Channel = Channels[Id]
				if math.abs(Channel.Keyframes[Index].Time - ReferenceTime) > Constants.EPSILON then
					IsAligned = false
					break
				end
			end
			if not IsAligned then
				break
			end
		end
	end

	if not IsAligned then
		-- TODO (Chunk C): Implement misaligned channel compilation
		-- For now, truncate to the minimum channel count to avoid out-of-bounds access
		local MinCount = KeyframeCount
		for _, Id in Constants.CHANNEL_IDS do
			local ChannelCount = #Channels[Id].Keyframes
			if ChannelCount < MinCount then
				MinCount = ChannelCount
			end
		end
		Logger.Warn(
			`Misaligned channel times in track "{Track.Name}" — truncating to {MinCount} keyframes (min across channels)`
		)
		KeyframeCount = MinCount
	end

	-- 2. Build RuntimeKeyframes from aligned channels
	local RuntimeKeyframes: Array<RuntimeKeyframe> = table.create(KeyframeCount)

	for Index = 1, KeyframeCount do
		local PosXKf = Channels.PositionX.Keyframes[Index]
		local PosYKf = Channels.PositionY.Keyframes[Index]
		local PosZKf = Channels.PositionZ.Keyframes[Index]
		local RotXKf = Channels.RotationX.Keyframes[Index]
		local RotYKf = Channels.RotationY.Keyframes[Index]
		local RotZKf = Channels.RotationZ.Keyframes[Index]

		-- Recompose CFrame from 6 scalar values
		local CF = __RecomposeCFrame(PosXKf.Value, PosYKf.Value, PosZKf.Value, RotXKf.Value, RotYKf.Value, RotZKf.Value)
		local Decomposed = CFrameUtils.Decompose(CF)

		-- Use interpolation from PositionX as the representative curve mode
		-- (when AddKeyframe is used, all channels share the same interpolation)
		local Interp = PosXKf.Interpolation
		local CurveMode = Interp.Curve

		-- Build CurveContext with compiled data for this segment
		local BezierCoeffs: BezierCoefficients? = nil
		local EasingFn: EasingFunction? = nil

		-- Bezier: compile coefficients from current RightHandle + next LeftHandle
		if CurveMode == "Bezier" and Index < KeyframeCount then
			local NextInterp = Channels.PositionX.Keyframes[Index + 1].Interpolation
			local SegmentDuration = Channels.PositionX.Keyframes[Index + 1].Time - PosXKf.Time
			if SegmentDuration > 0 then
				local RightHandle = Interp.RightHandle or { TimeOffset = 0, ValueOffset = 0 }
				local LeftHandle = NextInterp.LeftHandle or { TimeOffset = 0, ValueOffset = 0 }
				BezierCoeffs = Curves.CompileBezier(RightHandle, LeftHandle, SegmentDuration)
			end
		end

		-- Easing: resolve style + direction to a callable function at compile time
		if CurveMode == "Easing" and Interp.EasingStyle and Interp.EasingDirection then
			EasingFn = Curves.ResolveEasing(Interp.EasingStyle, Interp.EasingDirection)
		end

		RuntimeKeyframes[Index] = {
			Time = PosXKf.Time,
			Position = Decomposed.Position,
			Rotation = Decomposed.Rotation,
			CurveMode = CurveMode,
			CurveContext = {
				BezierCoeffs = BezierCoeffs,
				EasingFn = EasingFn,
			},
		}
	end

	-- 3. Pre-compute constant value if applicable
	local ConstantValue: CFrame? = nil
	if Track.IsConstant and KeyframeCount > 0 then
		local PosXKf = Channels.PositionX.Keyframes[1]
		local PosYKf = Channels.PositionY.Keyframes[1]
		local PosZKf = Channels.PositionZ.Keyframes[1]
		local RotXKf = Channels.RotationX.Keyframes[1]
		local RotYKf = Channels.RotationY.Keyframes[1]
		local RotZKf = Channels.RotationZ.Keyframes[1]
		ConstantValue =
			__RecomposeCFrame(PosXKf.Value, PosYKf.Value, PosZKf.Value, RotXKf.Value, RotYKf.Value, RotZKf.Value)
	end

	return {
		Name = Track.Name,
		Keyframes = RuntimeKeyframes,
		CachedIndex = 1,
		IsConstant = Track.IsConstant,
		ConstantValue = ConstantValue,
	}
end

function AnimationData.CompileEditToRuntime(Edit: EditAnimation): RuntimeAnimation
	local RuntimeTracks: Array<RuntimeTrack> = table.create(#Edit.Tracks)

	for Index, Track in Edit.Tracks do
		RuntimeTracks[Index] = __CompileTrack(Track)
	end

	return {
		Name = Edit.Name,
		Duration = Edit.Duration,
		Tracks = RuntimeTracks,
		Looping = Edit.Looping,
		Priority = Edit.Priority,
	}
end

-- Expose internals for testing (single underscore = internal)
AnimationData._EulerContinuityFilter = __EulerContinuityFilter
AnimationData._RecomposeCFrame = __RecomposeCFrame

export type AnimationData = typeof(AnimationData)

return AnimationData
