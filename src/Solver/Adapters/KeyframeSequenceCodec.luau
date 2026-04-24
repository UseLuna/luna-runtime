--!strict
local Luna = script.Parent.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local ExportTypes = require(Luna.Types.ExportTypes)
local ImportTypes = require(Luna.Types.ImportTypes)
local AnimationData = require(Luna.Core.AnimationData)
local Logger = require(Luna.Shared.Logger)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type ExportSnapshot = ExportTypes.ExportSnapshot
type JointHierarchy = ExportTypes.JointHierarchy
type JointNode = ExportTypes.JointNode
type TimedPose = ExportTypes.TimedPose
type ExportAdapter = ExportTypes.ExportAdapter
type ImportAdapter = ImportTypes.ImportAdapter
type PoseEasingInfo = ExportTypes.PoseEasingInfo
type EditAnimation = AnimationData.EditAnimation
type EditTrack = AnimationData.EditTrack
type InterpolationMode = AnimationData.InterpolationMode

-- [[ SHARED MAPPING TABLES (used by both encode and decode) ]]

-- Easing style: Luna string ↔ Roblox enum
local STYLE_TO_ENUM: StringIndexable<Enum.PoseEasingStyle> = {
	Linear = Enum.PoseEasingStyle.Linear,
	Constant = Enum.PoseEasingStyle.Constant,
	Cubic = Enum.PoseEasingStyle.CubicV2,
	Bounce = Enum.PoseEasingStyle.Bounce,
	Elastic = Enum.PoseEasingStyle.Elastic,
}

local ENUM_TO_STYLE: { [Enum.PoseEasingStyle]: { Curve: string, EasingStyle: string? } } = {
	[Enum.PoseEasingStyle.Linear] = { Curve = "Linear", EasingStyle = nil },
	[Enum.PoseEasingStyle.Constant] = { Curve = "Stepped", EasingStyle = nil },
	[Enum.PoseEasingStyle.CubicV2] = { Curve = "Easing", EasingStyle = "Cubic" },
	[Enum.PoseEasingStyle.Cubic] = { Curve = "Easing", EasingStyle = "Cubic" }, -- deprecated, treat same
	[Enum.PoseEasingStyle.Bounce] = { Curve = "Easing", EasingStyle = "Bounce" },
	[Enum.PoseEasingStyle.Elastic] = { Curve = "Easing", EasingStyle = "Elastic" },
}

-- Easing direction: Luna string ↔ Roblox enum
local DIRECTION_TO_ENUM: StringIndexable<Enum.PoseEasingDirection> = {
	In = Enum.PoseEasingDirection.In,
	Out = Enum.PoseEasingDirection.Out,
	InOut = Enum.PoseEasingDirection.InOut,
}

local ENUM_TO_DIRECTION: { [Enum.PoseEasingDirection]: string } = {
	[Enum.PoseEasingDirection.In] = "In",
	[Enum.PoseEasingDirection.Out] = "Out",
	[Enum.PoseEasingDirection.InOut] = "InOut",
}

-- Priority: number ↔ Roblox enum (both tables keyed consistently by their native type)
local PRIORITY_TO_ENUM: { [number]: Enum.AnimationPriority } = {
	[0] = Enum.AnimationPriority.Core,
	[1] = Enum.AnimationPriority.Idle,
	[2] = Enum.AnimationPriority.Movement,
	[3] = Enum.AnimationPriority.Action,
	[4] = Enum.AnimationPriority.Action2,
	[5] = Enum.AnimationPriority.Action3,
	[6] = Enum.AnimationPriority.Action4,
}

local ENUM_TO_PRIORITY: { [Enum.AnimationPriority]: number } = {
	[Enum.AnimationPriority.Core] = 0,
	[Enum.AnimationPriority.Idle] = 1,
	[Enum.AnimationPriority.Movement] = 2,
	[Enum.AnimationPriority.Action] = 3,
	[Enum.AnimationPriority.Action2] = 4,
	[Enum.AnimationPriority.Action3] = 5,
	[Enum.AnimationPriority.Action4] = 6,
}

-- [[ SHARED HELPERS ]]

-- Apply easing properties to a Pose instance from PoseEasingInfo (encode direction).
local function __ApplyEasing(PoseInstance: Pose, EasingInfo: PoseEasingInfo?)
	if not EasingInfo then
		return
	end

	local Style = STYLE_TO_ENUM[EasingInfo.Style]
	local Direction = DIRECTION_TO_ENUM[EasingInfo.Direction]

	if Style then
		PoseInstance.EasingStyle = Style
	end
	if Direction then
		PoseInstance.EasingDirection = Direction
	end
end

-- Read easing from a Pose instance into an InterpolationMode (decode direction).
local function __ReadEasing(PoseInstance: Pose): InterpolationMode
	local StyleInfo = ENUM_TO_STYLE[PoseInstance.EasingStyle]
	local Direction = ENUM_TO_DIRECTION[PoseInstance.EasingDirection]

	if not StyleInfo then
		return AnimationData.DefaultInterpolation()
	end

	return {
		Curve = StyleInfo.Curve,
		EasingStyle = StyleInfo.EasingStyle,
		EasingDirection = if StyleInfo.Curve == "Easing" then (Direction or "In") else nil,
		LeftHandle = nil,
		RightHandle = nil,
		HandleType = nil,
	}
end

-- [[ ENCODE (Export: EditAnimation → KeyframeSequence) ]]

-- Recursively build the Pose hierarchy matching the rig's Motor6D tree.
-- Only includes joints that have pose data in this frame (sparse-aware).
-- Root pose gets Weight = 0 (not directly animated), all others get Weight = 1.
-- Returns nil if this joint and all its descendants have no pose data.
local function __BuildPoseTree(
	JointName: string,
	Hierarchy: JointHierarchy,
	Poses: StringIndexable<CFrame>,
	Easing: StringIndexable<PoseEasingInfo>?,
	IsRoot: boolean
): Pose?
	local HasOwnPose = Poses[JointName] ~= nil :: any

	-- Recurse into children first to see if any descendants have data
	local ChildPoses: Array<Pose> = {}
	local Node = Hierarchy.Nodes[JointName]
	if Node then
		for _, ChildName in Node.Children do
			local ChildPose = __BuildPoseTree(ChildName, Hierarchy, Poses, Easing, false)
			if ChildPose then
				table.insert(ChildPoses, ChildPose)
			end
		end
	end

	-- Skip this node entirely if it has no data and no children with data
	-- Exception: root always gets created if any children exist
	if not HasOwnPose and #ChildPoses == 0 and not IsRoot then
		return nil
	end

	local PoseInstance = Instance.new("Pose")
	PoseInstance.Name = JointName
	-- Weight = 0 for root OR for hierarchy-only nodes (parent exists for children but has no data)
	-- Weight = 1 only if this joint has actual pose data at this time
	PoseInstance.Weight = if HasOwnPose and not IsRoot then 1 else 0
	PoseInstance.CFrame = if HasOwnPose then Poses[JointName] else CFrame.identity

	-- Apply per-joint easing only if this joint has actual data
	if Easing and HasOwnPose then
		__ApplyEasing(PoseInstance, Easing[JointName])
	end

	for _, ChildPose in ChildPoses do
		PoseInstance:AddSubPose(ChildPose)
	end

	return PoseInstance
end

local function __Encode(Snapshot: ExportSnapshot): any
	local Metadata = Snapshot.Metadata
	local Hierarchy = Metadata.Hierarchy

	local Sequence = Instance.new("KeyframeSequence")
	Sequence.Name = Metadata.Name
	Sequence.Loop = Metadata.Looping

	-- Map priority number to Roblox AnimationPriority enum
	Sequence.Priority = PRIORITY_TO_ENUM[Metadata.Priority] or Enum.AnimationPriority.Action

	-- Build a Keyframe for each sampled time
	for _, Frame in Snapshot.Frames do
		local KeyframeInstance = Instance.new("Keyframe")
		KeyframeInstance.Time = Frame.Time

		-- Build the pose tree (sparse — only joints with data at this time)
		if Hierarchy.Root ~= "" then
			local RootPose = __BuildPoseTree(Hierarchy.Root, Hierarchy, Frame.Poses, Frame.Easing, true)
			if RootPose then
				KeyframeInstance:AddPose(RootPose)
			end
		end

		Sequence:AddKeyframe(KeyframeInstance)
	end

	-- Add markers as KeyframeMarker instances on the appropriate Keyframes
	if Snapshot.Markers and #Snapshot.Markers > 0 then
		-- Build a time→Keyframe lookup from existing keyframes
		local KeyframesByTime: StringIndexable<Keyframe> = {}
		for _, KF: Keyframe in Sequence:GetKeyframes() :: any do
			-- Use string key for float comparison (round to 4 decimal places)
			KeyframesByTime[string.format("%.4f", KF.Time)] = KF
		end

		for _, Marker in Snapshot.Markers do
			local TimeKey = string.format("%.4f", Marker.Time)
			local TargetKeyframe = KeyframesByTime[TimeKey]

			-- If no keyframe exists at this marker's time, create one
			if not TargetKeyframe then
				TargetKeyframe = Instance.new("Keyframe")
				TargetKeyframe.Time = Marker.Time
				Sequence:AddKeyframe(TargetKeyframe)
				KeyframesByTime[TimeKey] = TargetKeyframe
			end

			local MarkerInstance = Instance.new("KeyframeMarker")
			MarkerInstance.Name = Marker.Name
			MarkerInstance.Value = Marker.Value :: any
			(TargetKeyframe :: Keyframe):AddMarker(MarkerInstance)
		end
	end

	Logger.Info(`Exported KeyframeSequence "{Metadata.Name}" with {Snapshot.FrameCount} keyframes`)

	return Sequence
end

-- [[ DECODE (Import: KeyframeSequence → EditAnimation) ]]

-- Recursively walk a Pose tree and collect joint CFrames + easing.
local function __CollectPoses(
	PoseInstance: Pose,
	Poses: StringIndexable<CFrame>,
	Easings: StringIndexable<InterpolationMode>
)
	-- Only include joints with Weight > 0 (skip hierarchy-only nodes)
	if PoseInstance.Weight > 0 then
		Poses[PoseInstance.Name] = PoseInstance.CFrame
		Easings[PoseInstance.Name] = __ReadEasing(PoseInstance)
	end

	-- Recurse into sub-poses
	for _, SubPose: Pose in PoseInstance:GetSubPoses() :: any do
		__CollectPoses(SubPose, Poses, Easings)
	end
end

local function __Decode(Source: any): EditAnimation
	local KFS = Source :: KeyframeSequence

	-- 1. Read metadata
	local Priority = ENUM_TO_PRIORITY[KFS.Priority] or 3

	-- 2. Get sorted keyframes
	local Keyframes = KFS:GetKeyframes() :: any
	table.sort(Keyframes, function(A: Keyframe, B: Keyframe)
		return A.Time < B.Time
	end)

	-- 3. Compute duration
	local Duration = 0
	if #Keyframes > 0 then
		Duration = Keyframes[#Keyframes].Time
	end
	if Duration <= 0 then
		Duration = 1
	end

	-- 4. Create animation
	local Animation = AnimationData.CreateEmptyAnimation(KFS.Name, Duration)
	Animation.Looping = KFS.Loop
	Animation.Priority = Priority

	-- 5. Collect per-joint data and markers across all keyframes
	local TracksByName: StringIndexable<EditTrack> = {}

	for _, KeyframeInstance: Keyframe in Keyframes do
		-- Walk all root poses in this keyframe
		for _, RootPose: Pose in KeyframeInstance:GetPoses() :: any do
			local Poses: StringIndexable<CFrame> = {}
			local Easings: StringIndexable<InterpolationMode> = {}

			-- Root pose itself (if weighted)
			__CollectPoses(RootPose, Poses, Easings)

			-- Add keyframes to tracks
			for JointName, JointCFrame in Poses do
				local Track = TracksByName[JointName]
				if not Track then
					Track = AnimationData.CreateEmptyTrack(JointName)
					TracksByName[JointName] = Track
					table.insert(Animation.Tracks, Track)
				end

				local Interp = Easings[JointName] or AnimationData.DefaultInterpolation()
				AnimationData.AddKeyframe(Track :: EditTrack, KeyframeInstance.Time, JointCFrame, Interp)
			end
		end

		-- Collect KeyframeMarker instances from this Keyframe
		local MarkerInstances = KeyframeInstance:GetMarkers()
		for _, MarkerInstance in MarkerInstances do
			table.insert(Animation.Markers, {
				Name = MarkerInstance.Name,
				Value = tostring((MarkerInstance :: any).Value),
				Time = KeyframeInstance.Time,
			})
		end
	end

	Logger.Info(
		`Imported KeyframeSequence "{KFS.Name}": {#Animation.Tracks} tracks, {#Keyframes} keyframes, {#Animation.Markers} markers`
	)

	return Animation
end

-- [[ MODULE EXPORTS ]]

return {
	ExportAdapter = {
		Name = "KeyframeSequence",
		Export = __Encode,
	} :: ExportAdapter,
	ImportAdapter = {
		Name = "KeyframeSequence",
		Import = __Decode,
	} :: ImportAdapter,
}
