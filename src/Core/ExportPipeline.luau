--!strict
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local AnimationData = require(script.Parent.AnimationData)
local Curves = require(script.Parent.Curves)
local Evaluator = require(script.Parent.Evaluator)
local ExportTypes = require(script.Parent.Parent.Types.ExportTypes)
local SearchUtils = require(script.Parent.SearchUtils)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type EditAnimation = AnimationData.EditAnimation
type RuntimeAnimation = AnimationData.RuntimeAnimation
type JointNode = ExportTypes.JointNode
type JointHierarchy = ExportTypes.JointHierarchy
type TimedPose = ExportTypes.TimedPose
type ExportSnapshot = ExportTypes.ExportSnapshot

type JointInput = CoreTypes.JointInput
type PoseEasingInfo = ExportTypes.PoseEasingInfo
type InterpolationMode = AnimationData.InterpolationMode

local ExportPipeline = {}

-- Build the joint parent-child hierarchy from a flat list of joints.
-- Uses Part0Name (parent) and Part1Name (child) to reconstruct the tree.
function ExportPipeline.BuildHierarchy(Joints: Array<JointInput>): JointHierarchy
	local Nodes: StringIndexable<JointNode> = {}
	local AllChildNames: StringIndexable<boolean> = {}

	-- 1. Create a node for every joint
	for _, Joint in Joints do
		local ChildName = Joint.Part1Name
		local ParentName = Joint.Part0Name

		AllChildNames[ChildName] = true

		if not Nodes[ChildName] then
			Nodes[ChildName] = {
				Name = ChildName,
				Parent = ParentName,
				Children = {},
			}
		else
			Nodes[ChildName].Parent = ParentName
		end

		-- Ensure the parent node exists
		if ParentName ~= "" and not Nodes[ParentName] then
			Nodes[ParentName] = {
				Name = ParentName,
				Parent = nil,
				Children = {},
			}
		end

		-- Register this child under its parent
		if ParentName ~= "" then
			table.insert(Nodes[ParentName].Children, ChildName)
		end
	end

	-- 2. Find the root — the node that is a parent but never a child
	local RootName = ""
	for NodeName, _ in Nodes do
		if not AllChildNames[NodeName] then
			RootName = NodeName
			break
		end
	end

	-- Fallback: if no clear root found, use the first joint's parent
	if RootName == "" and #Joints > 0 then
		RootName = Joints[1].Part0Name
	end

	return {
		Root = RootName,
		Nodes = Nodes,
	}
end

-- Collect all unique keyframe times across all tracks and channels, sorted ascending.
function ExportPipeline.CollectKeyframeTimes(Animation: EditAnimation): Array<number>
	local TimeSet: StringIndexable<boolean> = {}
	local Times: Array<number> = {}

	for _, Track in Animation.Tracks do
		for _, Channel in Track.Channels do
			for _, Keyframe in Channel.Keyframes do
				local Key = string.format("%.6f", Keyframe.Time)
				if not TimeSet[Key] then
					TimeSet[Key] = true
					table.insert(Times, Keyframe.Time)
				end
			end
		end
	end

	table.sort(Times)
	return Times
end

-- Sample the full rig pose at a given time using the compiled runtime animation.
function ExportPipeline.SamplePosesAtTime(Runtime: RuntimeAnimation, Time: number): StringIndexable<CFrame>
	return Evaluator.EvaluateAnimation(Runtime, Time)
end

-- Create a complete ExportSnapshot from an EditAnimation and joint data.
-- This is the main entry point — orchestrates the full pipeline.
function ExportPipeline.CreateSnapshot(Animation: EditAnimation, Joints: Array<JointInput>): ExportSnapshot
	-- 1. Build hierarchy
	local Hierarchy = ExportPipeline.BuildHierarchy(Joints)

	-- 2. Collect all unique keyframe times
	local Times = ExportPipeline.CollectKeyframeTimes(Animation)

	-- 3. Compile to runtime for evaluation
	local Runtime = AnimationData.CompileEditToRuntime(Animation)

	-- 4. Sample full pose at each time
	local Frames: Array<TimedPose> = {}
	for Index, Time in Times do
		Frames[Index] = {
			Time = Time,
			Poses = ExportPipeline.SamplePosesAtTime(Runtime, Time),
		}
	end

	return {
		Metadata = {
			Name = Animation.Name,
			Duration = Animation.Duration,
			Looping = Animation.Looping,
			Priority = Animation.Priority,
			Hierarchy = Hierarchy,
		},
		FrameCount = #Frames,
		Frames = Frames,
		Markers = Animation.Markers,
	}
end

-- Determine the Roblox easing info for a keyframe's interpolation, or nil if it must be baked.
local function __GetKeyframeRobloxEasing(Interp: InterpolationMode): PoseEasingInfo?
	return Curves.GetRobloxEasing(Interp.Curve, Interp.EasingStyle, Interp.EasingDirection)
end

-- Check if a specific track segment (between two keyframe indices) needs baking.
-- Uses PositionX channel as representative (all channels share interpolation from AddKeyframe).
-- Returns the PoseEasingInfo if native, or nil if baking is required.
local function __GetSegmentEasing(Track: AnimationData.EditTrack, LeftIndex: number): PoseEasingInfo?
	local Keyframes = Track.Channels.PositionX.Keyframes
	if LeftIndex >= #Keyframes then
		return { Style = "Linear", Direction = "In" }
	end
	return __GetKeyframeRobloxEasing(Keyframes[LeftIndex].Interpolation)
end

-- Format a time as a string key for set lookups (6 decimal places).
local function __TimeKey(Time: number): string
	return string.format("%.6f", Time)
end

-- Compute per-track keyframe time sets: native tracks get original times only,
-- baked tracks get original times + intermediate samples.
-- Returns a set (StringIndexable<boolean>) per track for O(1) lookup,
-- plus the sorted union of all times.
local function __CollectBakedTimeSets(
	Animation: AnimationData.EditAnimation,
	TargetFPS: number
): (StringIndexable<StringIndexable<boolean>>, Array<number>)
	local PerTrackSets: StringIndexable<StringIndexable<boolean>> = {}
	local UnionSet: StringIndexable<boolean> = {}
	local UnionTimes: Array<number> = {}
	local FrameInterval = 1 / TargetFPS

	for _, Track in Animation.Tracks do
		-- Use PositionX channel as representative for keyframe times and easing
		local Keyframes = Track.Channels.PositionX.Keyframes
		local Count = #Keyframes
		local TrackSet: StringIndexable<boolean> = {}

		for Index = 1, Count do
			local Key = __TimeKey(Keyframes[Index].Time)
			TrackSet[Key] = true
			if not UnionSet[Key] then
				UnionSet[Key] = true
				table.insert(UnionTimes, Keyframes[Index].Time)
			end

			-- If this segment needs baking, add intermediate samples
			if Index < Count then
				local Easing = __GetSegmentEasing(Track, Index)
				if not Easing then
					local StartTime = Keyframes[Index].Time
					local EndTime = Keyframes[Index + 1].Time
					local SampleTime = StartTime + FrameInterval
					while SampleTime < EndTime - (FrameInterval * 0.5) do
						local SampleKey = __TimeKey(SampleTime)
						TrackSet[SampleKey] = true
						if not UnionSet[SampleKey] then
							UnionSet[SampleKey] = true
							table.insert(UnionTimes, SampleTime)
						end
						SampleTime += FrameInterval
					end
				end
			end
		end

		PerTrackSets[Track.Name] = TrackSet
	end

	table.sort(UnionTimes)
	return PerTrackSets, UnionTimes
end

-- Binary search delegated to SearchUtils. Epsilon added to TargetTime at call site
-- to handle floating-point boundary cases during export sampling.

-- Get the easing info for a track at a given time.
-- Uses PositionX channel as representative (all channels share interpolation from AddKeyframe).
local function __GetTrackEasingAtTime(Track: AnimationData.EditTrack, Time: number): PoseEasingInfo
	local Keyframes = Track.Channels.PositionX.Keyframes
	local Count = #Keyframes
	if Count == 0 then
		return { Style = "Linear", Direction = "In" }
	end

	-- Find which segment this time falls in (O(log n) binary search)
	local SegmentIndex = SearchUtils.FindLastAtOrBefore(Keyframes :: any, Time + 1e-6)
	if SegmentIndex > Count - 1 then
		SegmentIndex = math.max(Count - 1, 1)
	end

	local NativeEasing = __GetSegmentEasing(Track, SegmentIndex)
	if NativeEasing then
		return NativeEasing
	end

	-- Baked segment: Linear interpolation between dense samples
	return { Style = "Linear", Direction = "In" }
end

-- Create an ExportSnapshot with curve-aware baking.
-- Native tracks (Linear, Constant, Cubic, Bounce, Elastic) export at original
-- keyframe times with easing metadata. Non-native tracks are baked at TargetFPS.
-- Poses are SPARSE: each frame only contains joints that have data at that time.
-- TargetFPS defaults to Animation.FrameRate if nil.
function ExportPipeline.CreateBakedSnapshot(
	Animation: EditAnimation,
	Joints: Array<JointInput>,
	TargetFPS: number?
): ExportSnapshot
	local FPS = TargetFPS or Animation.FrameRate

	-- 1. Build hierarchy
	local Hierarchy = ExportPipeline.BuildHierarchy(Joints)

	-- 2. Compute per-track time sets and union of all times
	local PerTrackSets, AllTimes = __CollectBakedTimeSets(Animation, FPS)

	-- 3. Compile to runtime for evaluation
	local Runtime = AnimationData.CompileEditToRuntime(Animation)

	-- 4. Build lookup for edit tracks by name
	local TrackByName: StringIndexable<AnimationData.EditTrack> = {}
	for _, Track in Animation.Tracks do
		TrackByName[Track.Name] = Track
	end

	-- 5. Build sparse frames — each joint only appears at times it needs
	local Frames: Array<TimedPose> = {}
	for _, Time in AllTimes do
		local FullPose = ExportPipeline.SamplePosesAtTime(Runtime, Time)
		local TimeKey = __TimeKey(Time)
		local Poses: StringIndexable<CFrame> = {}
		local Easing: StringIndexable<PoseEasingInfo> = {}
		local HasPose = false

		for TrackName, TrackSet in PerTrackSets do
			if TrackSet[TimeKey] then
				if FullPose[TrackName] then
					Poses[TrackName] = FullPose[TrackName]
					HasPose = true

					local Track = TrackByName[TrackName]
					if Track then
						Easing[TrackName] = __GetTrackEasingAtTime(Track, Time)
					end
				end
			end
		end

		if HasPose then
			table.insert(Frames, {
				Time = Time,
				Poses = Poses,
				Easing = Easing,
			})
		end
	end

	return {
		Metadata = {
			Name = Animation.Name,
			Duration = Animation.Duration,
			Looping = Animation.Looping,
			Priority = Animation.Priority,
			Hierarchy = Hierarchy,
		},
		FrameCount = #Frames,
		Frames = Frames,
		Markers = Animation.Markers,
	}
end

export type ExportPipeline = typeof(ExportPipeline)

return ExportPipeline
