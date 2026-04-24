--!strict

local BenchmarkConstants = {}

-- Profiling flags (compile-time — toggle and re-sync via Rojo)
BenchmarkConstants.DEBUG_PROFILING = false
BenchmarkConstants.DEBUG_PROFILING_GRANULAR = false

-- Default config values
BenchmarkConstants.DEFAULT_NPC_COUNT = 100
BenchmarkConstants.DEFAULT_DENSITY = 6
BenchmarkConstants.DEFAULT_RIG_TYPE = "R15"
BenchmarkConstants.DEFAULT_EVAL_MODE = "Sampled"
BenchmarkConstants.DEFAULT_SAMPLE_RATE = 30
BenchmarkConstants.DEFAULT_LAYER_COUNT = 1
BenchmarkConstants.DEFAULT_ISOLATION_MODE = "Full"
BenchmarkConstants.DEFAULT_WINDOW_SECONDS = 5

-- Warmup thresholds
BenchmarkConstants.WARMUP_CV_THRESHOLD = 0.05
BenchmarkConstants.WARMUP_WINDOW_FRAMES = 30
BenchmarkConstants.WARMUP_MIN_FRAMES = 30
BenchmarkConstants.WARMUP_MAX_FRAMES = 120

-- Cooldown thresholds
BenchmarkConstants.COOLDOWN_HEAP_DELTA_KB = 1
BenchmarkConstants.COOLDOWN_SAMPLE_INTERVAL = 0.5
BenchmarkConstants.COOLDOWN_MAX_TIMEOUT = 15

-- Timing buffer sizing (worst case: 240fps * max window)
BenchmarkConstants.MAX_RING_BUFFER_SIZE = 2400

-- Comparison thresholds
BenchmarkConstants.FACTOR_PARITY_MAX = 1.1
BenchmarkConstants.FACTOR_ACCEPTABLE_MAX = 1.5

-- Regression thresholds
BenchmarkConstants.REGRESSION_NOISE_PERCENT = 5
BenchmarkConstants.REGRESSION_WARN_PERCENT = 15

-- Color constants
BenchmarkConstants.COLOR_GREEN = Color3.fromRGB(0, 200, 0)
BenchmarkConstants.COLOR_YELLOW = Color3.fromRGB(255, 220, 0)
BenchmarkConstants.COLOR_RED = Color3.fromRGB(255, 50, 50)
BenchmarkConstants.COLOR_WHITE = Color3.fromRGB(220, 220, 220)
BenchmarkConstants.COLOR_GRAY = Color3.fromRGB(128, 128, 128)
BenchmarkConstants.COLOR_ORANGE = Color3.fromRGB(255, 140, 0)
BenchmarkConstants.COLOR_CYAN = Color3.fromRGB(0, 200, 255)

-- LOD tier colors (T0 through T4)
BenchmarkConstants.TIER_COLORS = {
	Color3.fromRGB(128, 128, 128), -- T0: Gray (Frozen)
	Color3.fromRGB(0, 200, 0),     -- T1: Green (Full)
	Color3.fromRGB(255, 220, 0),   -- T2: Yellow (Reduced)
	Color3.fromRGB(255, 140, 0),   -- T3: Orange (Low)
	Color3.fromRGB(255, 50, 50),   -- T4: Red (Minimal)
}

-- ── UI option arrays ────────────────────────────────────────────────────────
BenchmarkConstants.NPC_OPTIONS = { 10, 25, 50, 100, 200, 500, 1000 }
BenchmarkConstants.LAYER_OPTIONS = { 1, 2, 4, 8 }
BenchmarkConstants.SAMPLE_RATE_OPTIONS = { 24, 30, 60, 120 }
BenchmarkConstants.LOD_PRESETS = { "Quality", "Default", "Performance", "Aggressive" }
BenchmarkConstants.SYNTHETIC_TYPES = { "Simple", "WalkCycle", "Heavy" }

BenchmarkConstants.ISOLATION_MODES = { "Full", "No Render", "No Apply", "No Eval" }
BenchmarkConstants.ISOLATION_DESCRIPTIONS = {
	Full = "Eval + Motor writes + Render (real-world cost)",
	["No Render"] = "Eval + Motor writes, meshes hidden (isolates Motor6D cost)",
	["No Apply"] = "Eval only, skip Motor6D writes (isolates pure eval cost)",
	["No Eval"] = "Baseline frame cost with rigs in scene (measures engine overhead)",
}

-- ── Quick preset configs ────────────────────────────────────────────────────
-- Each preset overrides only the fields it specifies; the runner merges with defaults.
BenchmarkConstants.PRESET_CONFIGS = {
	["100 R15 Walk"] = {
		NpcCount = 100,
		RigType = "R15",
		AnimationSourceKind = "Synthetic",
		SyntheticType = "WalkCycle",
		EvalMode = "Sampled",
		SampleRate = 30,
		LayerCount = 1,
	},
	["1000 R6 Simple"] = {
		NpcCount = 1000,
		RigType = "R6",
		AnimationSourceKind = "Synthetic",
		SyntheticType = "Simple",
		EvalMode = "Sampled",
		SampleRate = 30,
		LayerCount = 1,
	},
	["Stress Test"] = {
		NpcCount = 2000,
		RigType = "R15",
		AnimationSourceKind = "Synthetic",
		SyntheticType = "WalkCycle",
		EvalMode = "Sampled",
		SampleRate = 60,
		LayerCount = 4,
	},
	["Cache Test"] = {
		NpcCount = 500,
		RigType = "R15",
		AnimationSourceKind = "Synthetic",
		SyntheticType = "WalkCycle",
		EvalMode = "Sampled",
		SampleRate = 30,
		LayerCount = 1,
		MissingLimbPercent = 30,
		ToolEquippedPercent = 20,
	},
}

return BenchmarkConstants
