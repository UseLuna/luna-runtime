--!strict
local CoreTypes = require(script.Parent.CoreTypes)
local ModifierTypes = require(script.Parent.ModifierTypes)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>

-- Inline Quat type to avoid upward dependency on Core/Quaternion
type Quat = {
	X: number,
	Y: number,
	Z: number,
	W: number,
}
type ModifierEntry = ModifierTypes.ModifierEntry
type ConstraintEntry = ModifierTypes.ConstraintEntry

local SampledTypes = {}

-- Hybrid storage for optimal runtime performance:
-- Positions: Array<Vector3> — native Roblox value type, zero allocation on read
-- RotationBuffer: flat buffer of f32 quats — eliminates Lua Quat table GC pressure
-- Vector3 is engine-managed (no GC overhead). Quat tables are the expensive objects.
-- Eval strategy for sampled tracks:
-- "Dense"   = pre-sampled at N fps, array lookup + Nlerp (for Bezier/Easing/Hermite)
-- "Sparse"  = original keyframes + cached index + lerp (for Linear tracks — saves memory)
-- "Stepped" = original keyframes + snap to floor (for Stepped tracks — no interpolation)
export type EvalStrategy = "Dense" | "Sparse" | "Stepped"

-- Sparse keyframe (decomposed Position + Quaternion, stored on sparse/stepped tracks)
export type SparseKeyframe = {
	Time: number,
	Position: Vector3,
	Rotation: Quat,
}

export type SampledTrack = {
	Name: string,
	IsConstant: boolean,
	ConstantPosition: Vector3?,
	ConstantRotation: Quat?,
	-- Dense storage (used when EvalStrategy == "Dense")
	Positions: Array<Vector3>,
	RotationBuffer: buffer?,
	-- Eval strategy
	EvalStrategy: EvalStrategy?,
	-- Sparse storage (used when EvalStrategy == "Sparse" or "Stepped")
	SparseKeyframes: Array<SparseKeyframe>?,
	-- Pre-computed O(1) segment map (immutable, maps quantized time → keyframe index hint)
	SegmentMap: buffer?,
	SegmentMapResolution: number?,
}

-- Fully baked animation — O(1) evaluation
export type SampledAnimation = {
	Name: string,
	Duration: number,
	SampleRate: number,
	SampleCount: number,
	Tracks: Array<SampledTrack>,
	Looping: boolean,
	Priority: number,
	IsAdditive: boolean?, -- if true, samples are deltas from rest/reference pose
}

-- Baked animation with modifier metadata for live application by Solver
export type SampledAnimationWithModifiers = {
	Animation: SampledAnimation,
	TrackModifiers: StringIndexable<Array<ModifierEntry>>,
	Constraints: Array<ConstraintEntry>?,
}

return SampledTypes
