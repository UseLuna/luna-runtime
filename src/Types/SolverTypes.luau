--!strict
--[[
	Types for the AnimationSolver blending system.
	Shared between AnimationSolver, PoseApplier, and consumer code.
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local SampledTypes = require(Luna.Types.SampledTypes)
local AnimationData = require(Luna.Core.AnimationData)

type Array<V> = CoreTypes.Array<V>
type RuntimeAnimation = AnimationData.RuntimeAnimation
type SampledAnimation = SampledTypes.SampledAnimation

local SolverTypes = {}

export type BlendMode = "Replace" | "Additive"

export type TransitionMethod = "Snap" | "Lerp" | "Spring"

-- Buffer-backed per-bone weights with smooth transitions.
-- CurrentWeights: separate buffer for hot blend loop (read per bone × per layer).
-- TransitionState: AoS packed Target/Speed/Velocity (read once per bone per frame).
-- Methods: u8 buffer encoding transition method per bone.
export type LiveBoneWeights = {
	CurrentWeights: buffer, -- BoneCount × 4 bytes (f32, stride 4)
	TransitionState: buffer, -- BoneCount × 12 bytes (f32 Target + f32 Speed + f32 Velocity, stride 12)
	Methods: buffer, -- BoneCount × 1 byte (u8: SNAP=0, LERP=1, SPRING=2)
	BoneCount: number,
}

-- Config for creating a new blend layer.
export type LayerConfig = {
	Name: string?,
	Animation: RuntimeAnimation?,
	SampledAnimation: SampledAnimation?,
	Weight: number?,
	BlendMode: BlendMode?,
	Priority: number?,
	AutoRevert: boolean?,
	-- Initial bone mask buffer (optional — nil = full body). From BoneMask.Weights.
	InitialMaskWeights: buffer?,
	-- Animation markers (optional — fired when TimePosition crosses marker Time)
	Markers: Array<{ Name: string, Value: string, Time: number }>?,
	-- LOD tier tag: 0 = always evaluate (default), 1-3+ = can be skipped by LOD manager
	LodTier: number?,
}

-- Ownership record for auto-revert: tracks which bones this layer changed.
export type OwnedWeightChange = {
	BoneIndex: number,
	PreviousTarget: number,
}

-- LOD tier configuration for one distance band.
-- UpdateInterval is in seconds (0 = every frame, 0.033 = ~30Hz, 0.066 = ~15Hz).
export type LodTierConfig = {
	MaxDistance: number,
	UpdateInterval: number,
	MaxLodTier: number,
}

-- Named LOD preset — configures viewport padding, recalc frequency, and tier bands.
export type LodPreset = {
	ViewportPadding: number?,
	RecalcInterval: number?,
	Tiers: Array<LodTierConfig>,
}

-- Hook configuration for PreSolve/PostSolve game modifier hooks.
-- PreSolve Run signature: (Solver, Payload, State, DeltaTime)
-- PostSolve Run signature: (Solver, Payload, State, DeltaTime, OutputPosBuf, OutputRotBuf, BoneCount)
export type HookConfig = {
	Priority: number?,
	LodTier: number?,
	Init: (() -> any)?,
	Run: (...any) -> (),
}

export type SolverTypes = typeof(SolverTypes)

return SolverTypes
