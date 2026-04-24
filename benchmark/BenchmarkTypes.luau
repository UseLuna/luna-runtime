--!strict

local BenchmarkTypes = {}

export type AnimationSourceKind = "Synthetic" | "FromPlace" | "AssetId"

-- Discriminated union: exactly one payload field is non-nil, matching Kind.
-- Assert at runtime: if Kind == "Synthetic" then assert(SyntheticType ~= nil), etc.
export type AnimationSource = {
	Kind: AnimationSourceKind,
	SyntheticType: ("Simple" | "WalkCycle" | "Heavy")?,
	KeyframeSequence: KeyframeSequence?,
	AssetId: string?,
}

export type RigVariantConfig = {
	PristinePercent: number,
	MissingLimbPercent: number,
	ToolEquippedPercent: number,
}

export type TimingSnapshot = {
	AvgEvalMs: number,
	AvgApplyMs: number,
	AvgTotalMs: number,
	PeakEvalMs: number,
	PeakApplyMs: number,
	PeakTotalMs: number,
	PerTrackUs: number,
	PerMotorUs: number,
	PerNpcUs: number,
	EvalPercent: number,
	ApplyPercent: number,
	CurrentFps: number,
	FrameCount: number,
	HeapKb: number,
}

export type CacheSnapshot = {
	UniqueFingerprints: number,
	Entries: { { Fingerprint: string, BoneCount: number, RefCount: number } },
	HitCount: number,
	MissCount: number,
	EstimatedMemorySavedBytes: number,
}

export type LodSnapshot = {
	TierCounts: { number },
	SolversUpdated: number,
	TotalRegistered: number,
	SavingsPercent: number,
}

export type NativeTimingSnapshot = {
	AvgTotalMs: number,
	PeakTotalMs: number,
	PerNpcUs: number,
	CurrentFps: number,
	HeapKb: number,
}

export type SuiteResultConfig = {
	NpcCount: number,
	RigType: string,
	EvalMode: string,
	SampleRate: number,
	LayerCount: number,
	IsolationMode: string,
	AnimationSourceKind: AnimationSourceKind,
	SyntheticType: string?,
	LodEnabled: boolean,
	LodPreset: string?,
}

export type SuiteResult = {
	Config: SuiteResultConfig,
	Timing: TimingSnapshot,
	NativeTiming: NativeTimingSnapshot?,
	GcWarning: boolean?,
}

export type BaselineSnapshot = {
	Results: { SuiteResult },
	Note: string,
	Timestamp: string,
}

export type SpawnConfig = {
	Count: number,
	Density: number,
	RigType: string,
	Variants: RigVariantConfig,
	IsolationMode: string,
}

export type SpawnResult = {
	Models: { Model },
	RigBindings: { any },
	VariantCounts: { Pristine: number, MissingLimb: number, ToolEquipped: number },
}

export type TransitionState = "Idle" | "Running" | "Respawning" | "WarmingUp" | "Cooldown"
	| "ComparisonLuna" | "ComparisonNativePlaying" | "ComparisonNativeIdle" | "ComparisonDone"

export type BenchmarkConfig = {
	NpcCount: number,
	Density: number,
	RigType: string,
	EvalMode: string,
	SampleRate: number,
	LayerCount: number,
	Speed: number,
	Weight: number,
	IsolationMode: string,
	AnimationSource: AnimationSource,
	RigVariants: RigVariantConfig,
	IsLodEnabled: boolean,
	LodPreset: string,
	IsComparisonMode: boolean,
	ComparisonMode: string,
}

return BenchmarkTypes
