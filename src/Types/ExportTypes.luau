--!strict
local CoreTypes = require(script.Parent.CoreTypes)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>

local ExportTypes = {}

export type JointNode = {
	Name: string,
	Parent: string?,
	Children: Array<string>,
}

export type JointHierarchy = {
	Root: string,
	Nodes: StringIndexable<JointNode>,
}

export type PoseEasingInfo = {
	Style: string,
	Direction: string,
}

export type TimedPose = {
	Time: number,
	Poses: StringIndexable<CFrame>,
	Easing: StringIndexable<PoseEasingInfo>?,
}

export type ExportMetadata = {
	Name: string,
	Duration: number,
	Looping: boolean,
	Priority: number,
	Hierarchy: JointHierarchy,
}

export type AnimationMarker = { Name: string, Value: string, Time: number }

export type ExportSnapshot = {
	Metadata: ExportMetadata,
	FrameCount: number,
	Frames: Array<TimedPose>,
	Markers: Array<AnimationMarker>?,
}

export type ExportAdapter = {
	Name: string,
	Export: (Snapshot: ExportSnapshot) -> any,
}

return ExportTypes
