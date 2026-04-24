# Benchmark Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an interactive benchmark harness for Luna Runtime with Iris UI, Roblox native comparison, regression detection, and MicroProfiler integration.

**Architecture:** Panel registry pattern with SharedState. Harness modules (NpcSpawner, TimingCollector, etc.) handle logic; Panels handle UI. BenchmarkRunner is the entry point that wires everything together. All benchmark code lives in `benchmark/` outside `src/` — never ships with the runtime package.

**Tech Stack:** Luau (--!strict), Rojo, Iris (UI), LunaRuntimeWrapper (animation API), pesde/wally (packages)

**Spec:** `docs/superpowers/specs/2026-04-07-benchmark-harness-design.md`

**Code style:** Follow CLAUDE.md exactly — PascalCase everything, dot syntax for methods with explicit typed self, `--!strict` first line, tabs, double quotes, `Logger.Debug/Info/Warn/Error()`, string interpolation, early returns, `CoreTypes.Array<T>` / `CoreTypes.StringIndexable<T>`, `//` floor division.

---

## File Map

| File | Responsibility |
|------|---------------|
| `benchmark.project.json` | Rojo project: maps benchmark + runtime into a playable place |
| `benchmark/BenchmarkConstants.luau` | Profiling flags, default config values |
| `benchmark/BenchmarkTypes.luau` | All shared types (SharedState, TimingSnapshot, etc.) |
| `benchmark/BenchmarkRunner.client.luau` | Entry point: Iris init, panel registry, main loop, state machine |
| `benchmark/Harness/TimingCollector.luau` | os.clock() instrumentation, time-based rolling window, variance warmup |
| `benchmark/Harness/NpcSpawner.luau` | Template cloning, grid layout, rig variants |
| `benchmark/Harness/AnimationProvider.luau` | Synthetic animation generation, place scan, asset ID |
| `benchmark/Harness/NativeAnimatorRunner.luau` | Roblox Animator wrapper, two-run isolation |
| `benchmark/Harness/BaselineStore.luau` | Serialize/deserialize baseline snapshots to Configuration instances |
| `benchmark/Harness/ProfilerInjector.luau` | Two-tier monkey-patching for MicroProfiler labels |
| `benchmark/Panels/ControlPanel.luau` | Config UI: NPC count, density, rig type, variants, animation, presets |
| `benchmark/Panels/TimingPanel.luau` | Live FPS, timing breakdown, per-unit costs, snapshot button |
| `benchmark/Panels/ComparisonPanel.luau` | Luna vs Native head-to-head, x factor, sequential/simultaneous modes |
| `benchmark/Panels/CachePanel.luau` | Skeleton fingerprint stats, hit/miss rate |
| `benchmark/Panels/RegressionPanel.luau` | Baseline save/load, run suite, delta display, run notes |
| `benchmark/Panels/LodPanel.luau` | LOD preset, debug overlays (billboards, frustum, freecam) |
| `src/Solver/RigResolver.luau` | Add `GetCacheStats()` public function (only runtime modification) |

---

## Phase 1: Foundation (Tasks 1-7)

Gets you to a working interactive benchmark: spawn NPCs, see live timing, toggle configs.

### Task 1: Project Scaffolding

**Files:**
- Create: `benchmark.project.json`
- Create: `benchmark/BenchmarkConstants.luau`
- Create: `benchmark/BenchmarkTypes.luau`

- [ ] **Step 1: Create benchmark.project.json**

```json
{
	"name": "LunaBenchmark",
	"tree": {
		"$className": "DataModel",
		"ReplicatedStorage": {
			"$className": "ReplicatedStorage",
			"LunaRuntime": {
				"$className": "Folder",
				"Core": { "$path": "src/Core" },
				"Solver": { "$path": "src/Solver" },
				"Types": { "$path": "src/Types" },
				"Shared": { "$path": "src/Shared" }
			},
			"Packages": { "$path": "Packages" },
			"Benchmark": {
				"$className": "Folder",
				"Panels": { "$path": "benchmark/Panels" },
				"Harness": { "$path": "benchmark/Harness" },
				"BenchmarkConstants": { "$path": "benchmark/BenchmarkConstants.luau" },
				"BenchmarkTypes": { "$path": "benchmark/BenchmarkTypes.luau" }
			}
		},
		"StarterPlayer": {
			"$className": "StarterPlayer",
			"StarterPlayerScripts": {
				"$className": "StarterPlayerScripts",
				"BenchmarkRunner": { "$path": "benchmark/BenchmarkRunner.client.luau" }
			}
		},
		"Workspace": {
			"$className": "Workspace",
			"Templates": {
				"$className": "Folder"
			},
			"Animations": {
				"$className": "Folder"
			}
		}
	}
}
```

- [ ] **Step 2: Create BenchmarkConstants.luau**

```lua
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

-- Color constants (Iris Color3 values)
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

return BenchmarkConstants
```

- [ ] **Step 3: Create BenchmarkTypes.luau**

```lua
--!strict

local BenchmarkTypes = {}

export type AnimationSourceKind = "Synthetic" | "FromPlace" | "AssetId"

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

export type Panel = {
	Name: string,
	Render: (Iris: any, State: SharedState) -> (),
	Init: ((State: SharedState) -> ())?,
	Destroy: ((State: SharedState) -> ())?,
}

export type SharedState = {
	-- Config
	NpcCount: number,
	Density: number,
	RigType: string,
	EvalMode: string,
	SampleRate: number,
	LayerCount: number,
	IsolationMode: string,
	AnimationSource: AnimationSource,
	RigVariants: RigVariantConfig,

	-- LOD
	LodEnabled: boolean,
	LodPreset: string,

	-- Runtime
	IsRunning: boolean,
	TransitionState: TransitionState,
	WarmupFrame: number,
	WarmupMaxFrames: number,
	Timing: TimingSnapshot?,
	CacheStats: CacheSnapshot?,
	LodStats: LodSnapshot?,
	NativeStats: NativeTimingSnapshot?,
	Baseline: BaselineSnapshot?,
	ComparisonLog: { string },
	SuiteResults: { SuiteResult },
	RunNote: string,

	-- Flags
	IsTimingEnabled: boolean,
	IsComparisonMode: boolean,
	ComparisonMode: string,
	GcWarning: boolean,

	-- Callbacks
	RequestStart: () -> (),
	RequestStop: () -> (),
	RequestConfigChange: () -> (),
	RequestSnapshot: () -> (),
	RequestSaveBaseline: () -> (),
	RequestRunSuite: () -> (),
}

return BenchmarkTypes
```

- [ ] **Step 4: Verify Rojo can parse the project**

Run: `rojo serve benchmark.project.json` — confirm no errors in output, then Ctrl+C.

- [ ] **Step 5: Commit**

```bash
git add benchmark.project.json benchmark/BenchmarkConstants.luau benchmark/BenchmarkTypes.luau
git commit -m "feat(benchmark): scaffold project structure, constants, and types"
```

---

### Task 2: TimingCollector

**Files:**
- Create: `benchmark/Harness/TimingCollector.luau`

The core measurement engine. Time-based rolling window using `os.clock()`. Supports variance-based warmup detection.

- [ ] **Step 1: Create TimingCollector.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

type TimingSnapshot = BenchmarkTypes.TimingSnapshot

-- ============================================================================
-- [[ TYPES ]]
-- ============================================================================

type FrameSample = {
	Timestamp: number,
	EvalMs: number,
	ApplyMs: number,
	TotalMs: number,
	HeapKb: number,
}

type TimingCollector = {
	_IsEnabled: boolean,
	_WindowSeconds: number,
	_Ring: { FrameSample },
	_RingSize: number,
	_WriteIndex: number,
	_Count: number,
	_PeakEvalMs: number,
	_PeakApplyMs: number,
	_PeakTotalMs: number,
	_FrameStart: number,
	_EvalEnd: number,
	_NpcCount: number,
	_TrackCount: number,
	_BoneCount: number,
}

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local TimingCollectorModule = {}

function TimingCollectorModule.new(): TimingCollector
	local RingSize = BenchmarkConstants.MAX_RING_BUFFER_SIZE
	local Ring: { FrameSample } = table.create(RingSize)
	for I = 1, RingSize do
		Ring[I] = {
			Timestamp = 0,
			EvalMs = 0,
			ApplyMs = 0,
			TotalMs = 0,
			HeapKb = 0,
		}
	end

	return {
		_IsEnabled = true,
		_WindowSeconds = BenchmarkConstants.DEFAULT_WINDOW_SECONDS,
		_Ring = Ring,
		_RingSize = RingSize,
		_WriteIndex = 0,
		_Count = 0,
		_PeakEvalMs = 0,
		_PeakApplyMs = 0,
		_PeakTotalMs = 0,
		_FrameStart = 0,
		_EvalEnd = 0,
		_NpcCount = 0,
		_TrackCount = 0,
		_BoneCount = 0,
	}
end

function TimingCollectorModule.SetEnabled(Self: TimingCollector, Enabled: boolean)
	Self._IsEnabled = Enabled
end

function TimingCollectorModule.SetWindow(Self: TimingCollector, Seconds: number)
	Self._WindowSeconds = Seconds
end

function TimingCollectorModule.SetCounts(Self: TimingCollector, NpcCount: number, TrackCount: number, BoneCount: number)
	Self._NpcCount = NpcCount
	Self._TrackCount = TrackCount
	Self._BoneCount = BoneCount
end

function TimingCollectorModule.BeginFrame(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end
	Self._FrameStart = os.clock()
end

function TimingCollectorModule.MarkEvalEnd(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end
	Self._EvalEnd = os.clock()
end

function TimingCollectorModule.EndFrame(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end

	local Now = os.clock()
	local EvalMs = (Self._EvalEnd - Self._FrameStart) * 1000
	local TotalMs = (Now - Self._FrameStart) * 1000
	local ApplyMs = TotalMs - EvalMs
	local HeapKb = gcinfo()

	-- Write to ring buffer (overwrite oldest)
	Self._WriteIndex = (Self._WriteIndex % Self._RingSize) + 1
	local Sample = Self._Ring[Self._WriteIndex]
	Sample.Timestamp = Now
	Sample.EvalMs = EvalMs
	Sample.ApplyMs = ApplyMs
	Sample.TotalMs = TotalMs
	Sample.HeapKb = HeapKb

	if Self._Count < Self._RingSize then
		Self._Count += 1
	end

	-- Track peaks
	if EvalMs > Self._PeakEvalMs then
		Self._PeakEvalMs = EvalMs
	end
	if ApplyMs > Self._PeakApplyMs then
		Self._PeakApplyMs = ApplyMs
	end
	if TotalMs > Self._PeakTotalMs then
		Self._PeakTotalMs = TotalMs
	end
end

function TimingCollectorModule.GetSnapshot(Self: TimingCollector): TimingSnapshot
	local Now = os.clock()
	local WindowStart = Now - Self._WindowSeconds
	local SumEval = 0
	local SumApply = 0
	local SumTotal = 0
	local SumHeap = 0
	local FrameCount = 0

	-- Walk ring buffer, only include frames within the time window
	for I = 1, Self._Count do
		local Sample = Self._Ring[I]
		if Sample.Timestamp >= WindowStart then
			SumEval += Sample.EvalMs
			SumApply += Sample.ApplyMs
			SumTotal += Sample.TotalMs
			SumHeap += Sample.HeapKb
			FrameCount += 1
		end
	end

	if FrameCount == 0 then
		return {
			AvgEvalMs = 0, AvgApplyMs = 0, AvgTotalMs = 0,
			PeakEvalMs = 0, PeakApplyMs = 0, PeakTotalMs = 0,
			PerTrackUs = 0, PerMotorUs = 0, PerNpcUs = 0,
			EvalPercent = 0, ApplyPercent = 0,
			CurrentFps = 0, FrameCount = 0, HeapKb = 0,
		}
	end

	local AvgEval = SumEval / FrameCount
	local AvgApply = SumApply / FrameCount
	local AvgTotal = SumTotal / FrameCount
	local Fps = FrameCount / Self._WindowSeconds

	local TotalTracks = Self._NpcCount * Self._TrackCount
	local TotalMotors = Self._NpcCount * Self._BoneCount

	return {
		AvgEvalMs = AvgEval,
		AvgApplyMs = AvgApply,
		AvgTotalMs = AvgTotal,
		PeakEvalMs = Self._PeakEvalMs,
		PeakApplyMs = Self._PeakApplyMs,
		PeakTotalMs = Self._PeakTotalMs,
		PerTrackUs = if TotalTracks > 0 then (AvgEval * 1000) / TotalTracks else 0,
		PerMotorUs = if TotalMotors > 0 then (AvgApply * 1000) / TotalMotors else 0,
		PerNpcUs = if Self._NpcCount > 0 then (AvgTotal * 1000) / Self._NpcCount else 0,
		EvalPercent = if AvgTotal > 0 then (AvgEval / AvgTotal) * 100 else 0,
		ApplyPercent = if AvgTotal > 0 then (AvgApply / AvgTotal) * 100 else 0,
		CurrentFps = Fps,
		FrameCount = FrameCount,
		HeapKb = SumHeap / FrameCount,
	}
end

--- Check if warmup is complete using coefficient of variation over recent frames.
--- Returns true when CV of TotalMs over the last WARMUP_WINDOW_FRAMES is < WARMUP_CV_THRESHOLD.
function TimingCollectorModule.IsWarmupComplete(Self: TimingCollector): boolean
	local WindowFrames = BenchmarkConstants.WARMUP_WINDOW_FRAMES
	if Self._Count < WindowFrames then
		return false
	end

	-- Gather last WindowFrames samples
	local Sum = 0
	local SumSq = 0
	local Collected = 0
	local Idx = Self._WriteIndex
	for _ = 1, WindowFrames do
		local Sample = Self._Ring[Idx]
		Sum += Sample.TotalMs
		SumSq += Sample.TotalMs * Sample.TotalMs
		Collected += 1
		Idx -= 1
		if Idx < 1 then
			Idx = Self._RingSize
		end
	end

	local Mean = Sum / Collected
	if Mean <= 0 then
		return true
	end

	local Variance = (SumSq / Collected) - (Mean * Mean)
	local StdDev = math.sqrt(math.max(0, Variance))
	local Cv = StdDev / Mean

	return Cv < BenchmarkConstants.WARMUP_CV_THRESHOLD
end

function TimingCollectorModule.Reset(Self: TimingCollector)
	Self._WriteIndex = 0
	Self._Count = 0
	Self._PeakEvalMs = 0
	Self._PeakApplyMs = 0
	Self._PeakTotalMs = 0
end

return TimingCollectorModule
```

- [ ] **Step 2: Verify file is syntactically valid**

Run: `rojo serve benchmark.project.json` — confirm no Luau parse errors, then Ctrl+C.

- [ ] **Step 3: Commit**

```bash
git add benchmark/Harness/TimingCollector.luau
git commit -m "feat(benchmark): add TimingCollector with time-based rolling window and variance warmup"
```

---

### Task 3: NpcSpawner

**Files:**
- Create: `benchmark/Harness/NpcSpawner.luau`

Template-based NPC spawning with grid layout and rig variant support.

- [ ] **Step 1: Create NpcSpawner.luau**

```lua
--!strict

local Workspace = game:GetService("Workspace")

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local RigResolver = require(LunaRuntime.Solver.RigResolver)
local Logger = require(LunaRuntime.Shared.Logger)

type SpawnConfig = BenchmarkTypes.SpawnConfig
type SpawnResult = BenchmarkTypes.SpawnResult
type RigVariantConfig = BenchmarkTypes.RigVariantConfig

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local NpcSpawner = {}

local __SpawnedFolder: Folder? = nil
local __SpawnedModels: { Model } = {}
local __SpawnedCount: number = 0

-- R15 limb Motor6D names (randomly pick one to destroy for MissingLimb variant)
local R15_LIMB_MOTORS = {
	"LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg",
	"LeftLowerArm", "RightLowerArm", "LeftLowerLeg", "RightLowerLeg",
	"LeftHand", "RightHand", "LeftFoot", "RightFoot",
}
-- R6 limb Motor6D names
local R6_LIMB_MOTORS = {
	"Left Arm", "Right Arm", "Left Leg", "Right Leg",
}

local function FindMotorByPart1Name(Model: Model, Part1Name: string): Motor6D?
	for _, Descendant in Model:GetDescendants() do
		if Descendant:IsA("Motor6D") and Descendant.Part1 and Descendant.Part1.Name == Part1Name then
			return Descendant :: Motor6D
		end
	end
	return nil
end

local function ApplyMissingLimb(Model: Model, RigType: string)
	local LimbList = if RigType == "R6" then R6_LIMB_MOTORS else R15_LIMB_MOTORS
	local RandomLimb = LimbList[math.random(1, #LimbList)]
	local Motor = FindMotorByPart1Name(Model, RandomLimb)
	if Motor then
		Motor:Destroy()
	end
end

local function ApplyToolEquipped(Model: Model)
	local Tool = Instance.new("Tool")
	Tool.Name = "BenchmarkTool"
	local Handle = Instance.new("Part")
	Handle.Name = "Handle"
	Handle.Size = Vector3.new(1, 1, 3)
	Handle.Anchored = false
	Handle.CanCollide = false
	Handle.Transparency = 0.5
	Handle.Parent = Tool

	-- Find right hand/arm to attach
	local RightHand = Model:FindFirstChild("RightHand", true) or Model:FindFirstChild("Right Arm", true)
	if RightHand then
		local Grip = Instance.new("Motor6D")
		Grip.Name = "RightGrip"
		Grip.Part0 = RightHand :: BasePart
		Grip.Part1 = Handle
		Grip.Parent = Handle
	end

	Tool.Parent = Model
end

local function ApplyNoRender(Model: Model)
	for _, Descendant in Model:GetDescendants() do
		if Descendant:IsA("BasePart") and Descendant.Name ~= "HumanoidRootPart" then
			(Descendant :: BasePart).Transparency = 1
		end
	end
end

function NpcSpawner.Spawn(Config: SpawnConfig): SpawnResult
	NpcSpawner.Cleanup()

	local Templates = Workspace:FindFirstChild("Templates")
	if not Templates then
		Logger.Error("NpcSpawner: Workspace.Templates folder not found")
		return { Models = {}, RigBindings = {}, VariantCounts = { Pristine = 0, MissingLimb = 0, ToolEquipped = 0 } }
	end

	local Template = Templates:FindFirstChild(Config.RigType)
	if not Template then
		Logger.Error(`NpcSpawner: Template '{Config.RigType}' not found in Workspace.Templates`)
		return { Models = {}, RigBindings = {}, VariantCounts = { Pristine = 0, MissingLimb = 0, ToolEquipped = 0 } }
	end

	__SpawnedFolder = Instance.new("Folder")
	__SpawnedFolder.Name = "BenchmarkNpcs"
	__SpawnedFolder.Parent = Workspace

	local Count = Config.Count
	local Columns = math.ceil(math.sqrt(Count))
	local Spacing = Config.Density

	-- Calculate variant counts
	local MissingLimbCount = math.floor(Count * Config.Variants.MissingLimbPercent / 100)
	local ToolEquippedCount = math.floor(Count * Config.Variants.ToolEquippedPercent / 100)
	local PristineCount = Count - MissingLimbCount - ToolEquippedCount

	local Models: { Model } = table.create(Count)
	local RigBindings: { any } = table.create(Count)
	local VariantIndex = 0

	for I = 1, Count do
		local Clone = Template:Clone() :: Model
		Clone.Name = `NPC_{I}`

		-- Grid position
		local Row = (I - 1) // Columns
		local Col = (I - 1) % Columns
		local Position = Vector3.new(Col * Spacing, 5, Row * Spacing)

		local RootPart = Clone:FindFirstChild("HumanoidRootPart") :: BasePart?
		if RootPart then
			RootPart.Anchored = true
			RootPart.CFrame = CFrame.new(Position)
		end

		-- Apply variant
		VariantIndex += 1
		if VariantIndex <= MissingLimbCount then
			ApplyMissingLimb(Clone, Config.RigType)
		elseif VariantIndex <= MissingLimbCount + ToolEquippedCount then
			ApplyToolEquipped(Clone)
		end
		-- Else: pristine (no modification)

		-- Apply isolation mode rendering
		if Config.IsolationMode == "No Render" then
			ApplyNoRender(Clone)
		end

		Clone.Parent = __SpawnedFolder

		Models[I] = Clone

		-- Resolve rig (only if we need animation, not for "No Eval" mode)
		if Config.IsolationMode ~= "No Eval" then
			local Success, Binding = pcall(RigResolver.Resolve, Clone)
			if Success then
				RigBindings[I] = Binding
			else
				Logger.Warn(`NpcSpawner: Failed to resolve rig for NPC_{I}: {Binding}`)
			end
		end
	end

	__SpawnedModels = Models
	__SpawnedCount = Count

	return {
		Models = Models,
		RigBindings = RigBindings,
		VariantCounts = {
			Pristine = PristineCount,
			MissingLimb = MissingLimbCount,
			ToolEquipped = ToolEquippedCount,
		},
	}
end

function NpcSpawner.Cleanup()
	if __SpawnedFolder then
		__SpawnedFolder:Destroy()
		__SpawnedFolder = nil
	end
	__SpawnedModels = {}
	__SpawnedCount = 0
end

function NpcSpawner.GetSpawnedModels(): { Model }
	return __SpawnedModels
end

function NpcSpawner.GetSpawnedCount(): number
	return __SpawnedCount
end

return NpcSpawner
```

- [ ] **Step 2: Verify syntax**

Run: `rojo serve benchmark.project.json` — confirm no parse errors.

- [ ] **Step 3: Commit**

```bash
git add benchmark/Harness/NpcSpawner.luau
git commit -m "feat(benchmark): add NpcSpawner with grid layout and rig variant support"
```

---

### Task 4: AnimationProvider

**Files:**
- Create: `benchmark/Harness/AnimationProvider.luau`

Generates synthetic animations and scans for place-dropped KeyframeSequences.

- [ ] **Step 1: Create AnimationProvider.luau**

```lua
--!strict

local Workspace = game:GetService("Workspace")

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local AnimationData = require(LunaRuntime.Core.AnimationData)
local Logger = require(LunaRuntime.Shared.Logger)

type EditAnimation = AnimationData.EditAnimation

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local AnimationProvider = {}

-- R15 bone names for synthetic animation generation
local R15_BONES = {
	"Head", "UpperTorso", "LowerTorso",
	"LeftUpperArm", "LeftLowerArm", "LeftHand",
	"RightUpperArm", "RightLowerArm", "RightHand",
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
}

local R6_BONES = {
	"Head", "Torso",
	"Left Arm", "Right Arm",
	"Left Leg", "Right Leg",
}

--- Create a synthetic EditAnimation with the given bone names, keyframe count, and duration.
--- Each track gets simple sinusoidal rotation keyframes with linear interpolation.
local function BuildSynthetic(BoneNames: { string }, KeyframeCount: number, Duration: number): EditAnimation
	local Animation = AnimationData.CreateEditAnimation(`Synthetic_{#BoneNames}t_{KeyframeCount}kf`)
	Animation.Duration = Duration

	for _, BoneName in BoneNames do
		local Track = AnimationData.CreateEditTrack(BoneName)

		for K = 1, KeyframeCount do
			local Time = (K - 1) / (KeyframeCount - 1) * Duration
			-- Simple rotation: sinusoidal on RotationX channel
			local AngleDeg = math.sin((K / KeyframeCount) * math.pi * 2) * 15

			AnimationData.AddKeyframe(Track, "RotationX", {
				Time = Time,
				Value = AngleDeg,
				InterpolationMode = { Curve = "Linear" },
			})
			AnimationData.AddKeyframe(Track, "RotationY", {
				Time = Time,
				Value = 0,
				InterpolationMode = { Curve = "Linear" },
			})
			AnimationData.AddKeyframe(Track, "RotationZ", {
				Time = Time,
				Value = 0,
				InterpolationMode = { Curve = "Linear" },
			})
			AnimationData.AddKeyframe(Track, "PositionX", {
				Time = Time,
				Value = 0,
				InterpolationMode = { Curve = "Linear" },
			})
			AnimationData.AddKeyframe(Track, "PositionY", {
				Time = Time,
				Value = 0,
				InterpolationMode = { Curve = "Linear" },
			})
			AnimationData.AddKeyframe(Track, "PositionZ", {
				Time = Time,
				Value = 0,
				InterpolationMode = { Curve = "Linear" },
			})
		end

		AnimationData.AddTrack(Animation, Track)
	end

	return Animation
end

--- Get a synthetic EditAnimation by type.
--- NOTE: The exact AnimationData API calls above may need to be adjusted to match
--- the actual AnimationData.CreateEditAnimation / CreateEditTrack / AddKeyframe API.
--- Check src/Core/AnimationData.luau for the exact function signatures and adjust accordingly.
function AnimationProvider.GetSynthetic(Type: string, RigType: string): EditAnimation
	local Bones = if RigType == "R6" then R6_BONES else R15_BONES

	if Type == "Simple" then
		-- 6 tracks (R6) or first 6 of R15, 3 keyframes, 1 second
		local UseBones = table.create(6)
		for I = 1, math.min(6, #Bones) do
			UseBones[I] = Bones[I]
		end
		return BuildSynthetic(UseBones, 3, 1)
	elseif Type == "WalkCycle" then
		-- All bones, 9 keyframes, 1 second
		return BuildSynthetic(Bones, 9, 1)
	elseif Type == "Heavy" then
		-- All bones doubled (repeat with offset), 12 keyframes, 2 seconds
		-- For stress testing — just use all bones with more keyframes
		return BuildSynthetic(Bones, 12, 2)
	end

	Logger.Warn(`AnimationProvider: Unknown synthetic type '{Type}', falling back to Simple`)
	return AnimationProvider.GetSynthetic("Simple", RigType)
end

--- Scan Workspace.Animations for KeyframeSequence children.
function AnimationProvider.ScanPlaceAnimations(): { KeyframeSequence }
	local AnimationsFolder = Workspace:FindFirstChild("Animations")
	if not AnimationsFolder then
		return {}
	end

	local Result: { KeyframeSequence } = {}
	for _, Child in AnimationsFolder:GetChildren() do
		if Child:IsA("KeyframeSequence") then
			table.insert(Result, Child :: KeyframeSequence)
		end
	end

	return Result
end

--- Create an Animation instance from an asset ID.
function AnimationProvider.FromAssetId(AssetId: string): Animation
	local Anim = Instance.new("Animation")
	Anim.AnimationId = AssetId
	return Anim
end

return AnimationProvider
```

- [ ] **Step 2: IMPORTANT — Verify AnimationData API matches**

Read `src/Core/AnimationData.luau` and confirm the functions `CreateEditAnimation`, `CreateEditTrack`, `AddKeyframe`, `AddTrack` exist with those signatures. If they differ, update the `BuildSynthetic` function to match the actual API. The synthetic animation just needs to produce a valid `EditAnimation` with N tracks and M keyframes each.

- [ ] **Step 3: Commit**

```bash
git add benchmark/Harness/AnimationProvider.luau
git commit -m "feat(benchmark): add AnimationProvider with synthetic animation generation and place scan"
```

---

### Task 5: ProfilerInjector

**Files:**
- Create: `benchmark/Harness/ProfilerInjector.luau`

Two-tier monkey-patching for MicroProfiler labels.

- [ ] **Step 1: Create ProfilerInjector.luau**

```lua
--!strict

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local ProfilerInjector = {}

local __IsCoarseInstalled = false
local __IsGranularInstalled = false
local __OriginalFunctions: { [string]: (...any) -> ...any } = {}

--- Wrap a module function with debug.profilebegin/end.
--- Stores the original function for potential uninstall.
local function WrapFunction(Module: any, FunctionName: string, Label: string)
	local Key = `{tostring(Module)}.{FunctionName}`
	local Original = Module[FunctionName]
	if not Original then
		return
	end
	__OriginalFunctions[Key] = Original
	Module[FunctionName] = function(...)
		debug.profilebegin(Label)
		local Results = table.pack(Original(...))
		debug.profileend()
		return table.unpack(Results, 1, Results.n)
	end
end

--- Install coarse (per-phase) profiler labels.
--- These wrap top-level functions called once per frame or once per rig — negligible overhead.
function ProfilerInjector.InstallCoarse()
	if __IsCoarseInstalled then
		return
	end
	__IsCoarseInstalled = true

	local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)
	local SolverLodManager = require(LunaRuntime.Solver.SolverLodManager)
	local AnimationSolver = require(LunaRuntime.Solver.AnimationSolver)
	local PoseApplier = require(LunaRuntime.Solver.PoseApplier)

	WrapFunction(LunaRuntimeWrapper, "Step", "Luna:Step")
	WrapFunction(SolverLodManager, "Step", "Luna:LOD")
	WrapFunction(AnimationSolver, "Evaluate", "Luna:Evaluate")
	WrapFunction(AnimationSolver, "Apply", "Luna:Apply")
	WrapFunction(AnimationSolver, "Update", "Luna:Solver:Update")
end

--- Install granular (per-operation) profiler labels.
--- WARNING: These wrap functions called thousands of times per frame.
--- The wrapper overhead distorts relative timings between functions.
--- Use for identifying hot functions, NOT for comparing their costs.
function ProfilerInjector.InstallGranular()
	if __IsGranularInstalled then
		return
	end
	__IsGranularInstalled = true

	local Curves = require(LunaRuntime.Core.Curves)
	local Quaternion = require(LunaRuntime.Core.Quaternion)
	local SearchUtils = require(LunaRuntime.Core.SearchUtils)
	local Evaluator = require(LunaRuntime.Core.Evaluator)

	WrapFunction(Curves, "RemapAlpha", "Luna:Eval:Bezier")
	WrapFunction(Quaternion, "Slerp", "Luna:Eval:Slerp")
	WrapFunction(Quaternion, "Nlerp", "Luna:Eval:Nlerp")
	WrapFunction(SearchUtils, "FindLastAtOrBefore", "Luna:Eval:BinarySearch")
	WrapFunction(Evaluator, "EvaluateTrackInto", "Luna:Eval:TrackInto")
end

--- Check if granular profiling is active (for UI warning display).
function ProfilerInjector.IsGranularActive(): boolean
	return __IsGranularInstalled
end

return ProfilerInjector
```

- [ ] **Step 2: Verify the function names match**

Grep `src/Core/Curves.luau` for `RemapAlpha`, `src/Core/Quaternion.luau` for `Slerp`/`Nlerp`, `src/Core/SearchUtils.luau` for `FindLastAtOrBefore`, `src/Core/Evaluator.luau` for `EvaluateTrackInto`. Adjust function names in the injector if they differ.

- [ ] **Step 3: Commit**

```bash
git add benchmark/Harness/ProfilerInjector.luau
git commit -m "feat(benchmark): add two-tier ProfilerInjector for MicroProfiler labels"
```

---

### Task 6: BenchmarkRunner Entry Point

**Files:**
- Create: `benchmark/BenchmarkRunner.client.luau`

The entry point. Initializes Iris, discovers panels, manages the state machine (Idle → Running → WarmingUp → etc.), wires SharedState to harness modules.

- [ ] **Step 1: Create BenchmarkRunner.client.luau**

```lua
--!strict

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")
local Iris = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("iris")) :: any

local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local TimingCollectorModule = require(Benchmark.Harness.TimingCollector)
local NpcSpawner = require(Benchmark.Harness.NpcSpawner)
local AnimationProvider = require(Benchmark.Harness.AnimationProvider)
local ProfilerInjector = require(Benchmark.Harness.ProfilerInjector)

local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)
local AnimationData = require(LunaRuntime.Core.AnimationData)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel
type TransitionState = BenchmarkTypes.TransitionState
type TimingSnapshot = BenchmarkTypes.TimingSnapshot

-- ============================================================================
-- [[ MEMORY CATEGORY ]]
-- ============================================================================

debug.setmemorycategory("LunaBenchmark")

-- ============================================================================
-- [[ PROFILER INJECTION ]]
-- ============================================================================

if BenchmarkConstants.DEBUG_PROFILING then
	ProfilerInjector.InstallCoarse()
	if BenchmarkConstants.DEBUG_PROFILING_GRANULAR then
		ProfilerInjector.InstallGranular()
	end
end

-- ============================================================================
-- [[ STATE ]]
-- ============================================================================

local TimingCollector = TimingCollectorModule.new()
local Panels: { Panel } = {}
local WarmupFrameCount = 0

local State: SharedState = {
	NpcCount = BenchmarkConstants.DEFAULT_NPC_COUNT,
	Density = BenchmarkConstants.DEFAULT_DENSITY,
	RigType = BenchmarkConstants.DEFAULT_RIG_TYPE,
	EvalMode = BenchmarkConstants.DEFAULT_EVAL_MODE,
	SampleRate = BenchmarkConstants.DEFAULT_SAMPLE_RATE,
	LayerCount = BenchmarkConstants.DEFAULT_LAYER_COUNT,
	IsolationMode = BenchmarkConstants.DEFAULT_ISOLATION_MODE,
	AnimationSource = { Kind = "Synthetic", SyntheticType = "WalkCycle" },
	RigVariants = { PristinePercent = 100, MissingLimbPercent = 0, ToolEquippedPercent = 0 },

	LodEnabled = false,
	LodPreset = "Default",

	IsRunning = false,
	TransitionState = "Idle",
	WarmupFrame = 0,
	WarmupMaxFrames = BenchmarkConstants.WARMUP_MAX_FRAMES,
	Timing = nil,
	CacheStats = nil,
	LodStats = nil,
	NativeStats = nil,
	Baseline = nil,
	ComparisonLog = {},
	SuiteResults = {},
	RunNote = "",

	IsTimingEnabled = true,
	IsComparisonMode = false,
	ComparisonMode = "Sequential",
	GcWarning = false,

	RequestStart = function() end,
	RequestStop = function() end,
	RequestConfigChange = function() end,
	RequestSnapshot = function() end,
	RequestSaveBaseline = function() end,
	RequestRunSuite = function() end,
}

-- ============================================================================
-- [[ PANEL DISCOVERY ]]
-- ============================================================================

local function DiscoverPanels()
	local PanelsFolder = Benchmark:FindFirstChild("Panels")
	if not PanelsFolder then
		return
	end

	-- Load panels in defined order
	local PanelOrder = { "ControlPanel", "TimingPanel", "ComparisonPanel", "CachePanel", "RegressionPanel", "LodPanel" }
	for _, PanelName in PanelOrder do
		local Module = PanelsFolder:FindFirstChild(PanelName)
		if Module and Module:IsA("ModuleScript") then
			local Success, PanelModule = pcall(require, Module)
			if Success and PanelModule then
				table.insert(Panels, PanelModule :: Panel)
			end
		end
	end
end

-- ============================================================================
-- [[ BENCHMARK LIFECYCLE ]]
-- ============================================================================

local __LoadedAnimation: any = nil -- LunaRuntimeWrapper.LoadedAnimation

local function LoadAnimation()
	local Source = State.AnimationSource
	if Source.Kind == "Synthetic" then
		local SyntheticType = Source.SyntheticType or "WalkCycle"
		local Edit = AnimationProvider.GetSynthetic(SyntheticType, State.RigType)
		-- Compile and preload through wrapper
		__LoadedAnimation = LunaRuntimeWrapper.Preload(`Synthetic_{SyntheticType}`, Edit)
	elseif Source.Kind == "FromPlace" and Source.KeyframeSequence then
		__LoadedAnimation = LunaRuntimeWrapper.FromKeyframeSequence(Source.KeyframeSequence)
	elseif Source.Kind == "AssetId" and Source.AssetId then
		-- For Luna, we need to load via the Importer
		-- AssetId path requires loading the animation data — this is handled by LoadAndPlay
		__LoadedAnimation = nil -- LoadAndPlay will handle it
	end
end

local function SpawnAndStart()
	State.TransitionState = "Respawning"

	-- Spawn NPCs
	local SpawnResult = NpcSpawner.Spawn({
		Count = State.NpcCount,
		Density = State.Density,
		RigType = State.RigType,
		Variants = State.RigVariants,
		IsolationMode = State.IsolationMode,
	})

	-- Load animation
	LoadAnimation()

	-- Set up LOD if enabled
	if State.LodEnabled then
		LunaRuntimeWrapper.SetGlobalLod(State.LodPreset)
	end

	-- Play animation on all NPCs (skip for "No Eval" mode)
	if State.IsolationMode ~= "No Eval" and __LoadedAnimation then
		for _, Model in SpawnResult.Models do
			for LayerIdx = 1, State.LayerCount do
				local Handle = LunaRuntimeWrapper.Play(Model, __LoadedAnimation, {
					Looping = true,
					Weight = 1 / State.LayerCount,
				})
				-- Stagger time offset per layer
				if Handle and Handle.TimePosition ~= nil then
					Handle.TimePosition = (LayerIdx / State.LayerCount) * 0.3
				end
			end
		end
	end

	-- Configure timing collector
	local TrackCount = if __LoadedAnimation then 15 else 0  -- estimate
	local BoneCount = if State.RigType == "R15" then 15 else 6
	TimingCollectorModule.SetCounts(TimingCollector, State.NpcCount, TrackCount, BoneCount)
	TimingCollectorModule.Reset(TimingCollector)

	-- Enter warmup
	State.TransitionState = "WarmingUp"
	WarmupFrameCount = 0
end

local function StopBenchmark()
	State.IsRunning = false
	State.TransitionState = "Idle"
	NpcSpawner.Cleanup()
	LunaRuntimeWrapper.Reset()
	TimingCollectorModule.Reset(TimingCollector)
end

-- ============================================================================
-- [[ WIRE CALLBACKS ]]
-- ============================================================================

State.RequestStart = function()
	if State.IsRunning then
		return
	end
	State.IsRunning = true
	SpawnAndStart()
end

State.RequestStop = function()
	StopBenchmark()
end

State.RequestConfigChange = function()
	if not State.IsRunning then
		return
	end
	-- Full transition: pause → cleanup → respawn → warmup → auto-resume
	SpawnAndStart()
end

State.RequestSnapshot = function()
	local Snapshot = TimingCollectorModule.GetSnapshot(TimingCollector)
	State.Timing = Snapshot
	local LogEntry = string.format(
		"%s | %s | %dnpc | %dL | eval %.2fms (%.1fus/t) | apply %.2fms (%.1fus/m) | total %.2fms | %dfps",
		State.EvalMode, State.IsolationMode, State.NpcCount, State.LayerCount,
		Snapshot.AvgEvalMs, Snapshot.PerTrackUs,
		Snapshot.AvgApplyMs, Snapshot.PerMotorUs,
		Snapshot.AvgTotalMs, math.floor(Snapshot.CurrentFps)
	)
	table.insert(State.ComparisonLog, LogEntry)
end

-- ============================================================================
-- [[ IRIS INIT ]]
-- ============================================================================

Iris.UpdateGlobalConfig({
	UseScreenGUIs = false,
})
Iris.Init()

-- ============================================================================
-- [[ DISCOVER PANELS ]]
-- ============================================================================

DiscoverPanels()

-- Init all panels
for _, CurrentPanel in Panels do
	if CurrentPanel.Init then
		(CurrentPanel.Init :: any)(State)
	end
end

-- ============================================================================
-- [[ MAIN LOOP ]]
-- ============================================================================

RunService.RenderStepped:Connect(function(DeltaTime: number)
	-- State machine
	if State.TransitionState == "WarmingUp" then
		WarmupFrameCount += 1
		-- Still run the animation during warmup (we just don't collect stable metrics)
		if State.IsolationMode ~= "No Eval" then
			LunaRuntimeWrapper.Step(DeltaTime)
		end
		-- Collect during warmup for variance check
		TimingCollectorModule.BeginFrame(TimingCollector)
		TimingCollectorModule.MarkEvalEnd(TimingCollector) -- rough: full Step as eval
		TimingCollectorModule.EndFrame(TimingCollector)

		if WarmupFrameCount >= BenchmarkConstants.WARMUP_MIN_FRAMES then
			if TimingCollectorModule.IsWarmupComplete(TimingCollector)
				or WarmupFrameCount >= BenchmarkConstants.WARMUP_MAX_FRAMES then
				-- Warmup done — reset timing and start measuring
				TimingCollectorModule.Reset(TimingCollector)
				State.TransitionState = "Running"
			end
		end

		State.WarmupFrame = WarmupFrameCount

	elseif State.TransitionState == "Running" then
		-- Normal measurement loop
		TimingCollectorModule.SetEnabled(TimingCollector, State.IsTimingEnabled)
		TimingCollectorModule.BeginFrame(TimingCollector)

		if State.IsolationMode ~= "No Eval" then
			LunaRuntimeWrapper.Step(DeltaTime)
		end

		TimingCollectorModule.MarkEvalEnd(TimingCollector)
		TimingCollectorModule.EndFrame(TimingCollector)

		-- Update timing snapshot for panels
		State.Timing = TimingCollectorModule.GetSnapshot(TimingCollector)
	end

	-- Render Iris UI
	Iris:Connect(function()
		local WindowInstance = Iris.Window({"Luna Benchmark", [Iris.Args.Window.NoClose] = true})
		for _, CurrentPanel in Panels do
			Iris.SeparatorText({CurrentPanel.Name})
			CurrentPanel.Render(Iris, State)
		end
		Iris.End()
	end)
end)
```

- [ ] **Step 2: Verify file parses and Rojo project serves without errors**

Run: `rojo serve benchmark.project.json` — check for parse errors. The place won't fully run yet (panels don't exist), but no errors means the wiring is correct.

- [ ] **Step 3: Commit**

```bash
git add benchmark/BenchmarkRunner.client.luau
git commit -m "feat(benchmark): add BenchmarkRunner entry point with state machine, panel registry, and main loop"
```

---

### Task 7: ControlPanel and TimingPanel (First Playable)

**Files:**
- Create: `benchmark/Panels/ControlPanel.luau`
- Create: `benchmark/Panels/TimingPanel.luau`

After this task, the benchmark is functional: you can open Studio, configure NPCs, start/stop, and see live timing.

- [ ] **Step 1: Create ControlPanel.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local ControlPanel: Panel = {
	Name = "Control",
	Render = function(_Iris: any, _State: SharedState) end,
}

function ControlPanel.Render(Iris: any, State: SharedState)
	-- NPC & Layout
	local NpcResult = Iris.InputNum({"NPC Count", [Iris.Args.InputNum.Min] = 1, [Iris.Args.InputNum.Max] = 2000, [Iris.Args.InputNum.Increment] = 1, [Iris.Args.InputNum.Format] = "%d"}, { number = State.NpcCount })
	if NpcResult.numberChanged() then
		State.NpcCount = NpcResult.number.value
	end

	Iris.SameLine()
	local DensityResult = Iris.InputNum({"Density (studs)", [Iris.Args.InputNum.Min] = 1, [Iris.Args.InputNum.Max] = 20, [Iris.Args.InputNum.Increment] = 1, [Iris.Args.InputNum.Format] = "%d"}, { number = State.Density })
	if DensityResult.numberChanged() then
		State.Density = DensityResult.number.value
	end
	Iris.End()

	-- Rig Type
	Iris.SameLine()
	if Iris.Button({"R6"}).clicked() then
		State.RigType = "R6"
	end
	if Iris.Button({"R15"}).clicked() then
		State.RigType = "R15"
	end
	Iris.Text({`  Active: {State.RigType}`})
	Iris.End()

	-- Rig Variants (collapsible)
	local VariantsTree = Iris.Tree({"Rig Variants"})
	if VariantsTree.state.isUncollapsed.value then
		local MissingResult = Iris.SliderNum({"Missing Limb %", [Iris.Args.SliderNum.Min] = 0, [Iris.Args.SliderNum.Max] = 100, [Iris.Args.SliderNum.Increment] = 5, [Iris.Args.SliderNum.Format] = "%d%%"}, { number = State.RigVariants.MissingLimbPercent })
		if MissingResult.numberChanged() then
			State.RigVariants.MissingLimbPercent = MissingResult.number.value
			-- Pristine absorbs remainder
			local NonPristine = State.RigVariants.MissingLimbPercent + State.RigVariants.ToolEquippedPercent
			if NonPristine > 100 then
				State.RigVariants.ToolEquippedPercent = 100 - State.RigVariants.MissingLimbPercent
			end
			State.RigVariants.PristinePercent = 100 - State.RigVariants.MissingLimbPercent - State.RigVariants.ToolEquippedPercent
		end

		local ToolResult = Iris.SliderNum({"Tool Equipped %", [Iris.Args.SliderNum.Min] = 0, [Iris.Args.SliderNum.Max] = 100, [Iris.Args.SliderNum.Increment] = 5, [Iris.Args.SliderNum.Format] = "%d%%"}, { number = State.RigVariants.ToolEquippedPercent })
		if ToolResult.numberChanged() then
			State.RigVariants.ToolEquippedPercent = ToolResult.number.value
			local NonPristine = State.RigVariants.MissingLimbPercent + State.RigVariants.ToolEquippedPercent
			if NonPristine > 100 then
				State.RigVariants.MissingLimbPercent = 100 - State.RigVariants.ToolEquippedPercent
			end
			State.RigVariants.PristinePercent = 100 - State.RigVariants.MissingLimbPercent - State.RigVariants.ToolEquippedPercent
		end

		-- Show effective counts
		local PristineCount = math.floor(State.NpcCount * State.RigVariants.PristinePercent / 100)
		local MissingCount = math.floor(State.NpcCount * State.RigVariants.MissingLimbPercent / 100)
		local ToolCount = State.NpcCount - PristineCount - MissingCount
		Iris.Text({`Pristine: {State.RigVariants.PristinePercent}% ({PristineCount} NPCs)`})
		Iris.Text({`MissingLimb: {State.RigVariants.MissingLimbPercent}% ({MissingCount} NPCs)`})
		Iris.Text({`Tool: {State.RigVariants.ToolEquippedPercent}% ({ToolCount} NPCs)`})

		local UniqueFingerprints = 1
		if State.RigVariants.MissingLimbPercent > 0 then UniqueFingerprints += 1 end
		if State.RigVariants.ToolEquippedPercent > 0 then UniqueFingerprints += 1 end
		Iris.Text({`Expected unique fingerprints: {UniqueFingerprints}`})
	end
	Iris.End()

	-- Animation Source
	Iris.SeparatorText({"Animation"})
	Iris.SameLine()
	if Iris.Button({"Synthetic"}).clicked() then
		State.AnimationSource = { Kind = "Synthetic", SyntheticType = "WalkCycle" }
	end
	if Iris.Button({"From Place"}).clicked() then
		State.AnimationSource = { Kind = "FromPlace" }
	end
	if Iris.Button({"Asset ID"}).clicked() then
		State.AnimationSource = { Kind = "AssetId", AssetId = "" }
	end
	Iris.Text({`  Source: {State.AnimationSource.Kind}`})
	Iris.End()

	if State.AnimationSource.Kind == "Synthetic" then
		Iris.SameLine()
		if Iris.Button({"Simple"}).clicked() then State.AnimationSource.SyntheticType = "Simple" end
		if Iris.Button({"WalkCycle"}).clicked() then State.AnimationSource.SyntheticType = "WalkCycle" end
		if Iris.Button({"Heavy"}).clicked() then State.AnimationSource.SyntheticType = "Heavy" end
		Iris.Text({`  Type: {State.AnimationSource.SyntheticType or "WalkCycle"}`})
		Iris.End()
	end

	-- Eval Mode
	Iris.SameLine()
	if Iris.Button({"Sampled"}).clicked() then State.EvalMode = "Sampled" end
	if Iris.Button({"Live"}).clicked() then State.EvalMode = "Live" end
	Iris.Text({`  Mode: {State.EvalMode}`})
	Iris.End()

	if State.EvalMode == "Sampled" then
		local SrResult = Iris.InputNum({"Sample Rate", [Iris.Args.InputNum.Min] = 1, [Iris.Args.InputNum.Max] = 120, [Iris.Args.InputNum.Increment] = 1, [Iris.Args.InputNum.Format] = "%d fps"}, { number = State.SampleRate })
		if SrResult.numberChanged() then
			State.SampleRate = SrResult.number.value
		end
	end

	-- Blend
	local LayerResult = Iris.InputNum({"Layers", [Iris.Args.InputNum.Min] = 1, [Iris.Args.InputNum.Max] = 16, [Iris.Args.InputNum.Increment] = 1, [Iris.Args.InputNum.Format] = "%d"}, { number = State.LayerCount })
	if LayerResult.numberChanged() then
		State.LayerCount = LayerResult.number.value
	end

	-- Isolation Mode
	Iris.SeparatorText({"Isolation Mode"})
	Iris.SameLine()
	for _, Mode in { "Full", "No Render", "No Apply", "No Eval" } do
		if Iris.Button({Mode}).clicked() then
			State.IsolationMode = Mode
		end
	end
	Iris.End()
	Iris.Text({`Active: {State.IsolationMode}`})

	-- Quick Presets
	Iris.SeparatorText({"Quick Presets"})
	Iris.SameLine()
	if Iris.Button({"100 R15 Walk"}).clicked() then
		State.NpcCount = 100; State.RigType = "R15"; State.LayerCount = 1
		State.AnimationSource = { Kind = "Synthetic", SyntheticType = "WalkCycle" }
		State.LodEnabled = false; State.IsolationMode = "Full"
	end
	if Iris.Button({"1000 R6 Simple"}).clicked() then
		State.NpcCount = 1000; State.RigType = "R6"; State.LayerCount = 1
		State.AnimationSource = { Kind = "Synthetic", SyntheticType = "Simple" }
		State.LodEnabled = false; State.IsolationMode = "Full"
	end
	if Iris.Button({"Stress Test"}).clicked() then
		State.NpcCount = 500; State.RigType = "R15"; State.LayerCount = 4
		State.AnimationSource = { Kind = "Synthetic", SyntheticType = "WalkCycle" }
		State.LodEnabled = true; State.IsolationMode = "Full"
	end
	if Iris.Button({"Cache Test"}).clicked() then
		State.NpcCount = 200; State.RigType = "R15"; State.LayerCount = 1
		State.AnimationSource = { Kind = "Synthetic", SyntheticType = "WalkCycle" }
		State.RigVariants = { PristinePercent = 50, MissingLimbPercent = 25, ToolEquippedPercent = 25 }
		State.LodEnabled = false; State.IsolationMode = "Full"
	end
	Iris.End()

	-- Start / Stop
	Iris.Separator()
	Iris.SameLine()
	if State.IsRunning then
		if Iris.Button({"Stop"}).clicked() then
			State.RequestStop()
		end
		Iris.Text({`  State: {State.TransitionState}`})
		if State.TransitionState == "WarmingUp" then
			Iris.Text({` ({State.WarmupFrame}/{State.WarmupMaxFrames})`})
		end
	else
		if Iris.Button({"Start"}).clicked() then
			State.RequestStart()
		end
	end
	Iris.End()
end

return ControlPanel
```

- [ ] **Step 2: Create TimingPanel.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local ProfilerInjector = require(Benchmark.Harness.ProfilerInjector)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local TimingPanel: Panel = {
	Name = "Timing",
	Render = function(_Iris: any, _State: SharedState) end,
}

local function GetFpsColor(Fps: number): Color3
	if Fps >= 60 then
		return BenchmarkConstants.COLOR_GREEN
	elseif Fps >= 30 then
		return BenchmarkConstants.COLOR_YELLOW
	end
	return BenchmarkConstants.COLOR_RED
end

function TimingPanel.Render(Iris: any, State: SharedState)
	if not State.Timing then
		Iris.Text({"No timing data. Start a benchmark to see metrics."})
		return
	end

	local T = State.Timing

	-- FPS Header
	local FpsColor = GetFpsColor(T.CurrentFps)
	Iris.PushConfig({ TextColor = FpsColor })
	Iris.Text({string.format("%.0f FPS (%.1fms)", T.CurrentFps, if T.CurrentFps > 0 then 1000 / T.CurrentFps else 0)})
	Iris.PopConfig()

	-- Timing Breakdown
	Iris.Text({string.format("Eval:  %.2fms avg | %.2fms peak", T.AvgEvalMs, T.PeakEvalMs)})
	Iris.Text({string.format("Apply: %.2fms avg | %.2fms peak", T.AvgApplyMs, T.PeakApplyMs)})
	Iris.Text({string.format("Total: %.2fms avg | %.2fms peak", T.AvgTotalMs, T.PeakTotalMs)})

	-- Budget bar
	Iris.Text({string.format("Budget: Eval %.0f%% | Apply %.0f%%", T.EvalPercent, T.ApplyPercent)})

	-- Per-unit costs
	Iris.Separator()
	Iris.Text({string.format("Per Track: %.2f us", T.PerTrackUs)})
	Iris.Text({string.format("Per Motor: %.2f us", T.PerMotorUs)})
	Iris.Text({string.format("Per NPC:   %.2f us", T.PerNpcUs)})
	Iris.Text({string.format("Heap:      %.0f KB", T.HeapKb)})
	Iris.Text({string.format("Frames:    %d", T.FrameCount)})

	-- Granular profiling warning
	if ProfilerInjector.IsGranularActive() then
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_YELLOW })
		Iris.Text({"WARNING: Granular profiling active. Per-operation labels distort relative timings."})
		Iris.PopConfig()
	end

	-- Controls
	Iris.Separator()
	if Iris.Button({"Reset Timing"}).clicked() then
		-- TimingCollector reset is handled via callback
	end
	Iris.SameLine()
	if Iris.Button({"Snapshot"}).clicked() then
		State.RequestSnapshot()
	end
	Iris.End()
end

return TimingPanel
```

- [ ] **Step 3: Verify in Studio**

Run: `rojo serve benchmark.project.json` → Open Studio → Connect to Rojo → Play.
Expected: Iris window appears with "Control" and "Timing" sections. You can change config values. Start button spawns NPCs (requires R6/R15 templates in Workspace.Templates — if missing, you'll see an error in output, which is expected).

- [ ] **Step 4: Commit**

```bash
git add benchmark/Panels/ControlPanel.luau benchmark/Panels/TimingPanel.luau
git commit -m "feat(benchmark): add ControlPanel and TimingPanel — first playable benchmark"
```

---

## Phase 2: Comparison (Tasks 8-9)

### Task 8: NativeAnimatorRunner

**Files:**
- Create: `benchmark/Harness/NativeAnimatorRunner.luau`

- [ ] **Step 1: Create NativeAnimatorRunner.luau**

```lua
--!strict

local Workspace = game:GetService("Workspace")

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local Logger = require(LunaRuntime.Shared.Logger)

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local NativeAnimatorRunner = {}

local __Folder: Folder? = nil
local __Models: { Model } = {}
local __Animators: { Animator } = {}
local __Tracks: { AnimationTrack } = {}
local __Count: number = 0

function NativeAnimatorRunner.Spawn(Template: Model, Count: number, Density: number, Source: Instance): { Model }
	NativeAnimatorRunner.Cleanup()

	__Folder = Instance.new("Folder")
	__Folder.Name = "NativeAnimatorNpcs"
	__Folder.Parent = Workspace

	local Columns = math.ceil(math.sqrt(Count))
	-- Offset native grid to the side of Luna grid
	local OffsetX = (Columns + 2) * Density

	__Models = table.create(Count)
	__Animators = table.create(Count)
	__Tracks = table.create(Count)

	for I = 1, Count do
		local Clone = Template:Clone() :: Model
		Clone.Name = `NativeNPC_{I}`

		local Row = (I - 1) // Columns
		local Col = (I - 1) % Columns
		local Position = Vector3.new(Col * Density + OffsetX, 5, Row * Density)

		local RootPart = Clone:FindFirstChild("HumanoidRootPart") :: BasePart?
		if RootPart then
			RootPart.Anchored = true
			RootPart.CFrame = CFrame.new(Position)
		end

		Clone.Parent = __Folder

		-- Set up native Animator
		local Humanoid = Clone:FindFirstChildWhichIsA("Humanoid")
		if Humanoid then
			local ExistingAnimator = Humanoid:FindFirstChildWhichIsA("Animator")
			local NewAnimator = ExistingAnimator or Instance.new("Animator")
			if not ExistingAnimator then
				NewAnimator.Parent = Humanoid
			end
			__Animators[I] = NewAnimator :: Animator

			-- Load animation
			if Source:IsA("Animation") then
				local Track = (NewAnimator :: Animator):LoadAnimation(Source :: Animation)
				__Tracks[I] = Track
			elseif Source:IsA("KeyframeSequence") then
				-- For KeyframeSequence, we need to create an Animation from it
				-- KeyframeSequence needs to be registered first
				local Anim = Instance.new("Animation")
				-- NOTE: KeyframeSequence can't be directly used with LoadAnimation.
				-- The user must provide an AssetId or a registered animation.
				-- For now, store nil and log a warning.
				Logger.Warn("NativeAnimatorRunner: KeyframeSequence requires AssetId for native Animator. Use Asset ID source for comparison.")
			end
		end

		__Models[I] = Clone
	end

	__Count = Count
	return __Models
end

function NativeAnimatorRunner.PlayAll()
	for I = 1, __Count do
		local Track = __Tracks[I]
		if Track then
			Track.Looped = true
			Track:Play()
		end
	end
end

function NativeAnimatorRunner.StopAll()
	for I = 1, __Count do
		local Track = __Tracks[I]
		if Track then
			Track:Stop(0) -- instant stop, no fade
		end
	end
end

function NativeAnimatorRunner.Cleanup()
	-- Stop all tracks
	for I = 1, __Count do
		local Track = __Tracks[I]
		if Track then
			Track:Stop(0)
			Track:Destroy()
		end
	end

	if __Folder then
		__Folder:Destroy()
		__Folder = nil
	end

	__Models = {}
	__Animators = {}
	__Tracks = {}
	__Count = 0
end

function NativeAnimatorRunner.GetCount(): number
	return __Count
end

return NativeAnimatorRunner
```

- [ ] **Step 2: Commit**

```bash
git add benchmark/Harness/NativeAnimatorRunner.luau
git commit -m "feat(benchmark): add NativeAnimatorRunner with two-run isolation support"
```

---

### Task 9: ComparisonPanel

**Files:**
- Create: `benchmark/Panels/ComparisonPanel.luau`

- [ ] **Step 1: Create ComparisonPanel.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local ComparisonPanel: Panel = {
	Name = "Comparison",
	Render = function(_Iris: any, _State: SharedState) end,
}

local function GetFactorColor(Factor: number): Color3
	if Factor < 1.0 then
		return BenchmarkConstants.COLOR_GREEN
	elseif Factor <= BenchmarkConstants.FACTOR_PARITY_MAX then
		return BenchmarkConstants.COLOR_GREEN
	elseif Factor <= BenchmarkConstants.FACTOR_ACCEPTABLE_MAX then
		return BenchmarkConstants.COLOR_YELLOW
	end
	return BenchmarkConstants.COLOR_RED
end

function ComparisonPanel.Render(Iris: any, State: SharedState)
	-- Warn if synthetic source
	if State.AnimationSource.Kind == "Synthetic" then
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_YELLOW })
		Iris.Text({"Comparison unavailable with Synthetic animations."})
		Iris.Text({"Use 'From Place' or 'Asset ID' source."})
		Iris.PopConfig()
		return
	end

	-- Mode selector
	Iris.SameLine()
	if Iris.Button({"Sequential"}).clicked() then
		State.ComparisonMode = "Sequential"
	end
	if Iris.Button({"Simultaneous"}).clicked() then
		State.ComparisonMode = "Simultaneous"
	end
	Iris.Text({`  Mode: {State.ComparisonMode}`})
	Iris.End()

	-- Comparison toggle
	local CompCheckbox = Iris.Checkbox({"Enable Comparison Mode"}, { isChecked = State.IsComparisonMode })
	if CompCheckbox.checked() or CompCheckbox.unchecked() then
		State.IsComparisonMode = CompCheckbox.state.isChecked.value
	end

	-- Show results if available
	if State.Timing and State.NativeStats then
		local LunaMs = State.Timing.AvgTotalMs
		local NativeMs = State.NativeStats.AvgTotalMs
		local Factor = if NativeMs > 0 then LunaMs / NativeMs else 0

		Iris.Separator()
		Iris.Text({"                    Luna        Native      Factor      Delta"})

		local FactorColor = GetFactorColor(Factor)
		Iris.PushConfig({ TextColor = FactorColor })
		Iris.Text({string.format("Anim cost (ms):     %-12.2f%-12.2f%.2fx       %+.2fms",
			LunaMs, NativeMs, Factor, LunaMs - NativeMs)})
		Iris.PopConfig()

		local LunaPerNpc = State.Timing.PerNpcUs
		local NativePerNpc = State.NativeStats.PerNpcUs
		local NpcFactor = if NativePerNpc > 0 then LunaPerNpc / NativePerNpc else 0
		Iris.Text({string.format("Per NPC (us):       %-12.1f%-12.1f%.2fx       %+.1fus",
			LunaPerNpc, NativePerNpc, NpcFactor, LunaPerNpc - NativePerNpc)})

		local LunaFps = State.Timing.CurrentFps
		local NativeFps = State.NativeStats.CurrentFps
		local FpsFactor = if LunaFps > 0 then NativeFps / LunaFps else 0
		Iris.Text({string.format("FPS (full):         %-12.0f%-12.0f%.2fx       %+.0f",
			LunaFps, NativeFps, FpsFactor, LunaFps - NativeFps)})

		Iris.Separator()
		Iris.PushConfig({ TextColor = FactorColor })
		Iris.Text({string.format("Luna is %.2fx %s than Roblox native Animator.",
			Factor, if Factor > 1 then "slower" else "faster")})
		Iris.PopConfig()

		-- Heap disclaimer
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_GRAY })
		Iris.Text({string.format("Heap (Luau KB):     %-12.0f%-12.0f(not comparable)",
			State.Timing.HeapKb, State.NativeStats.HeapKb)})
		Iris.Text({"  * gcinfo() only captures Luau heap. Native Animator memory is engine-internal."})
		Iris.PopConfig()

		-- GC warning
		if State.GcWarning then
			Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_ORANGE })
			Iris.Text({"WARNING: GC cooldown timed out. Results may be affected."})
			Iris.PopConfig()
		end
	elseif State.IsComparisonMode then
		-- Show progress if comparison is running
		local TransState = State.TransitionState
		if TransState == "ComparisonLuna" or TransState == "ComparisonNativePlaying"
			or TransState == "ComparisonNativeIdle" or TransState == "Cooldown" then
			Iris.Text({`Running comparison: {TransState}...`})
		else
			Iris.Text({"Comparison mode enabled. Start benchmark to begin."})
		end
	end

	-- Limitations
	local LimTree = Iris.Tree({"Limitations"})
	if LimTree.state.isUncollapsed.value then
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_GRAY })
		Iris.Text({"- Native Animator only supports KeyframeSequence/AssetId (not Synthetic)."})
		Iris.Text({"- Native timing uses two-run frame cost delta (indirect measurement)."})
		Iris.Text({"- Roblox Animator benefits from C++ optimizations (SIMD, batch motor writes)."})
		Iris.Text({"- Heap comparison is apples-to-oranges (Luau heap vs invisible C++ memory)."})
		Iris.PopConfig()
	end
	Iris.End()
end

return ComparisonPanel
```

- [ ] **Step 2: Commit**

```bash
git add benchmark/Panels/ComparisonPanel.luau
git commit -m "feat(benchmark): add ComparisonPanel with x-factor display and heap disclaimer"
```

---

## Phase 3: Regression (Tasks 10-11)

### Task 10: BaselineStore

**Files:**
- Create: `benchmark/Harness/BaselineStore.luau`

- [ ] **Step 1: Create BaselineStore.luau**

```lua
--!strict

local HttpService = game:GetService("HttpService")

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local Logger = require(LunaRuntime.Shared.Logger)

type BaselineSnapshot = BenchmarkTypes.BaselineSnapshot
type SuiteResult = BenchmarkTypes.SuiteResult

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local BaselineStore = {}

local STORAGE_NAME = "BenchmarkBaseline"

--- Find or create the Configuration instance for baseline storage.
local function GetOrCreateStorage(): Configuration
	local Existing = game:GetService("ReplicatedStorage"):FindFirstChild(STORAGE_NAME)
	if Existing and Existing:IsA("Configuration") then
		return Existing :: Configuration
	end
	local Config = Instance.new("Configuration")
	Config.Name = STORAGE_NAME
	Config.Parent = game:GetService("ReplicatedStorage")
	return Config
end

function BaselineStore.Save(Results: { SuiteResult }, Note: string)
	local Storage = GetOrCreateStorage()
	-- Clear existing children
	for _, Child in Storage:GetChildren() do
		Child:Destroy()
	end

	local Snapshot: BaselineSnapshot = {
		Results = Results,
		Note = Note,
		Timestamp = os.date("%Y-%m-%d %H:%M:%S") :: string,
	}

	-- Serialize to JSON-like string and store in StringValue
	local DataValue = Instance.new("StringValue")
	DataValue.Name = "Data"
	-- Manual serialization since HttpService:JSONEncode may not handle all types
	local SerializedResults: { any } = table.create(#Results)
	for I, Result in Results do
		SerializedResults[I] = {
			Config = Result.Config,
			Timing = Result.Timing,
			NativeTiming = Result.NativeTiming,
			GcWarning = Result.GcWarning,
		}
	end
	local Success, Encoded = pcall(HttpService.JSONEncode, HttpService, {
		Results = SerializedResults,
		Note = Note,
		Timestamp = Snapshot.Timestamp,
	})
	if Success then
		DataValue.Value = Encoded
	else
		Logger.Error(`BaselineStore: Failed to serialize baseline: {Encoded}`)
		return
	end
	DataValue.Parent = Storage

	Logger.Info(`BaselineStore: Saved baseline with {#Results} results. Note: "{Note}"`)
end

function BaselineStore.Load(): (BaselineSnapshot?, string?)
	local Storage = game:GetService("ReplicatedStorage"):FindFirstChild(STORAGE_NAME)
	if not Storage then
		return nil, "No baseline saved"
	end

	local DataValue = Storage:FindFirstChild("Data")
	if not DataValue or not DataValue:IsA("StringValue") or DataValue.Value == "" then
		return nil, "Baseline data is empty"
	end

	local Success, Decoded = pcall(HttpService.JSONDecode, HttpService, (DataValue :: StringValue).Value)
	if not Success then
		return nil, `Failed to decode baseline: {Decoded}`
	end

	return Decoded :: BaselineSnapshot, nil
end

function BaselineStore.Clear()
	local Storage = game:GetService("ReplicatedStorage"):FindFirstChild(STORAGE_NAME)
	if Storage then
		Storage:Destroy()
	end
	Logger.Info("BaselineStore: Baseline cleared")
end

function BaselineStore.Export(): string
	local Storage = game:GetService("ReplicatedStorage"):FindFirstChild(STORAGE_NAME)
	if not Storage then
		return "{}"
	end
	local DataValue = Storage:FindFirstChild("Data")
	if DataValue and DataValue:IsA("StringValue") then
		return (DataValue :: StringValue).Value
	end
	return "{}"
end

return BaselineStore
```

- [ ] **Step 2: Commit**

```bash
git add benchmark/Harness/BaselineStore.luau
git commit -m "feat(benchmark): add BaselineStore with JSON serialization to Configuration instance"
```

---

### Task 11: RegressionPanel

**Files:**
- Create: `benchmark/Panels/RegressionPanel.luau`

- [ ] **Step 1: Create RegressionPanel.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BaselineStore = require(Benchmark.Harness.BaselineStore)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel
type BaselineSnapshot = BenchmarkTypes.BaselineSnapshot

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local RegressionPanel: Panel = {
	Name = "Regression",
	Render = function(_Iris: any, _State: SharedState) end,
	Init = function(_State: SharedState) end,
}

local function GetDeltaColor(DeltaPercent: number): Color3
	if DeltaPercent < -BenchmarkConstants.REGRESSION_NOISE_PERCENT then
		return BenchmarkConstants.COLOR_GREEN -- improvement
	elseif DeltaPercent <= BenchmarkConstants.REGRESSION_NOISE_PERCENT then
		return BenchmarkConstants.COLOR_WHITE -- noise
	elseif DeltaPercent <= BenchmarkConstants.REGRESSION_WARN_PERCENT then
		return BenchmarkConstants.COLOR_YELLOW -- mild regression
	end
	return BenchmarkConstants.COLOR_RED -- significant regression
end

function RegressionPanel.Init(State: SharedState)
	-- Load baseline on init
	local Baseline, _Err = BaselineStore.Load()
	if Baseline then
		State.Baseline = Baseline
	end
end

function RegressionPanel.Render(Iris: any, State: SharedState)
	-- Run Note
	local NoteResult = Iris.InputText({"Run Note"}, { text = State.RunNote })
	if NoteResult.textChanged() then
		State.RunNote = NoteResult.text.value
	end

	-- Baseline actions
	Iris.SameLine()
	if Iris.Button({"Save Baseline"}).clicked() then
		State.RequestSaveBaseline()
	end
	if Iris.Button({"Clear Baseline"}).clicked() then
		BaselineStore.Clear()
		State.Baseline = nil
	end
	if Iris.Button({"Run Suite"}).clicked() then
		State.RequestRunSuite()
	end
	if Iris.Button({"Export"}).clicked() then
		local Json = BaselineStore.Export()
		-- Create a StringValue for easy copy
		local ExportValue = Instance.new("StringValue")
		ExportValue.Name = "BenchmarkExport"
		ExportValue.Value = Json
		ExportValue.Parent = game:GetService("ReplicatedStorage")
	end
	Iris.End()

	-- Baseline info
	if State.Baseline then
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_GREEN })
		Iris.Text({`Baseline loaded: "{State.Baseline.Note}" ({State.Baseline.Timestamp})`})
		Iris.Text({`  {#State.Baseline.Results} configurations stored`})
		Iris.PopConfig()
	else
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_GRAY })
		Iris.Text({"No baseline saved. Run a benchmark and save to establish baseline."})
		Iris.PopConfig()
	end

	-- Show comparison against baseline if both exist
	if State.Baseline and State.Timing then
		Iris.Separator()
		Iris.Text({"Comparison vs Baseline:"})

		-- Find matching config in baseline
		for _, BaseResult in State.Baseline.Results do
			local Bc = BaseResult.Config
			if Bc.NpcCount == State.NpcCount
				and Bc.RigType == State.RigType
				and Bc.EvalMode == State.EvalMode
				and Bc.LayerCount == State.LayerCount
				and Bc.IsolationMode == State.IsolationMode then

				local OldEval = BaseResult.Timing.AvgEvalMs
				local NewEval = State.Timing.AvgEvalMs
				local DeltaPercent = if OldEval > 0 then ((NewEval - OldEval) / OldEval) * 100 else 0

				local DeltaColor = GetDeltaColor(DeltaPercent)
				Iris.PushConfig({ TextColor = DeltaColor })
				Iris.Text({string.format(
					"  %d %s %dL %s %s: Eval %.2fms -> %.2fms (%+.1f%%)",
					Bc.NpcCount, Bc.RigType, Bc.LayerCount, Bc.EvalMode, Bc.IsolationMode,
					OldEval, NewEval, DeltaPercent
				)})
				Iris.PopConfig()
				break
			end
		end
	end

	-- Comparison log (snapshots)
	if #State.ComparisonLog > 0 then
		Iris.Separator()
		local LogTree = Iris.Tree({"Snapshot Log"})
		if LogTree.state.isUncollapsed.value then
			for I = #State.ComparisonLog, 1, -1 do
				Iris.Text({State.ComparisonLog[I]})
			end
		end
		Iris.End()
	end
end

return RegressionPanel
```

- [ ] **Step 2: Commit**

```bash
git add benchmark/Panels/RegressionPanel.luau
git commit -m "feat(benchmark): add RegressionPanel with baseline comparison and delta display"
```

---

## Phase 4: Cache + LOD (Tasks 12-13)

### Task 12: RigResolver.GetCacheStats + CachePanel

**Files:**
- Modify: `src/Solver/RigResolver.luau`
- Create: `benchmark/Panels/CachePanel.luau`

- [ ] **Step 1: Add GetCacheStats to RigResolver**

Add this function at the end of RigResolver.luau, before `return RigResolver`:

```lua
--- Read-only cache statistics for benchmarking.
function RigResolver.GetCacheStats(): { UniqueFingerprints: number, Entries: { { Fingerprint: string, BoneCount: number, RefCount: number } } }
	local Entries: { { Fingerprint: string, BoneCount: number, RefCount: number } } = {}
	local Count = 0
	for Fingerprint, Skeleton in __SkeletonCache do
		Count += 1
		Entries[Count] = {
			Fingerprint = string.sub(Fingerprint, 1, 20),  -- truncated for display
			BoneCount = #Skeleton.BoneNames,
			RefCount = Skeleton.RefCount,
		}
	end
	return {
		UniqueFingerprints = Count,
		Entries = Entries,
	}
end
```

- [ ] **Step 2: Create CachePanel.luau**

```lua
--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local RigResolver = require(LunaRuntime.Solver.RigResolver)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local CachePanel: Panel = {
	Name = "Cache",
	Render = function(_Iris: any, _State: SharedState) end,
}

function CachePanel.Render(Iris: any, State: SharedState)
	local Stats = RigResolver.GetCacheStats()

	Iris.Text({string.format("Unique Fingerprints: %d", Stats.UniqueFingerprints)})

	if #Stats.Entries > 0 then
		local CacheTree = Iris.Tree({"Per-Fingerprint Breakdown"})
		if CacheTree.state.isUncollapsed.value then
			Iris.Text({"  Fingerprint            Bones  Refs"})
			for _, Entry in Stats.Entries do
				Iris.Text({string.format("  %-20s %5d  %4d", Entry.Fingerprint, Entry.BoneCount, Entry.RefCount)})
			end
		end
		Iris.End()

		-- Estimate memory savings
		-- Each SkeletonInfo contains: BoneNames array, NameToIndex dict, ChildrenMap, ParentMap,
		-- RestPositions buffer (bones * 12), RestRotations buffer (bones * 16)
		local TotalRefs = 0
		local TotalEstimatedPerSkeleton = 0
		for _, Entry in Stats.Entries do
			TotalRefs += Entry.RefCount
			-- Rough estimate: ~200 bytes per bone for all skeleton data
			TotalEstimatedPerSkeleton += Entry.BoneCount * 200
		end
		local DuplicatedCost = 0
		for _, Entry in Stats.Entries do
			DuplicatedCost += Entry.BoneCount * 200 * Entry.RefCount
		end
		local SharedCost = TotalEstimatedPerSkeleton
		local Savings = DuplicatedCost - SharedCost

		Iris.Separator()
		Iris.Text({string.format("Total refs: %d rigs sharing %d skeletons", TotalRefs, Stats.UniqueFingerprints)})
		Iris.Text({string.format("Estimated memory saved: %.1f KB", Savings / 1024)})
	else
		Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_GRAY })
		Iris.Text({"No skeletons cached. Start a benchmark to see cache stats."})
		Iris.PopConfig()
	end
end

return CachePanel
```

- [ ] **Step 3: Commit**

```bash
git add src/Solver/RigResolver.luau benchmark/Panels/CachePanel.luau
git commit -m "feat(benchmark): add RigResolver.GetCacheStats and CachePanel"
```

---

### Task 13: LodPanel

**Files:**
- Create: `benchmark/Panels/LodPanel.luau`

Includes LOD controls, tier billboards, frustum visualization, and freecam with frozen reference camera.

- [ ] **Step 1: Create LodPanel.luau**

```lua
--!strict

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local SolverLodManager = require(LunaRuntime.Solver.SolverLodManager)

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel

-- ============================================================================
-- [[ FREECAM STATE ]]
-- ============================================================================

local __IsFreecamActive = false
local __FreecamCFrame = CFrame.new()
local __FrozenCFrame = CFrame.new()
local __OriginalCameraType: Enum.CameraType? = nil
local __FreecamYaw = 0
local __FreecamPitch = 0

-- ============================================================================
-- [[ BILLBOARD STATE ]]
-- ============================================================================

local __BillboardEntries: { { Billboard: BillboardGui, Label: TextLabel, Model: Model } } = {}
local __IsBillboardsEnabled = false

-- ============================================================================
-- [[ FRUSTUM STATE ]]
-- ============================================================================

local __FrustumFolder: Folder? = nil
local __IsFrustumEnabled = false

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local LodPanel: Panel = {
	Name = "LOD",
	Render = function(_Iris: any, _State: SharedState) end,
}

function LodPanel.Render(Iris: any, State: SharedState)
	-- LOD Enable
	local LodCheckbox = Iris.Checkbox({"Enable LOD"}, { isChecked = State.LodEnabled })
	if LodCheckbox.checked() or LodCheckbox.unchecked() then
		State.LodEnabled = LodCheckbox.state.isChecked.value
	end

	if not State.LodEnabled then
		return
	end

	-- LOD Preset
	Iris.SameLine()
	for _, Preset in { "Quality", "Default", "Performance", "Aggressive" } do
		if Iris.Button({Preset}).clicked() then
			State.LodPreset = Preset
		end
	end
	Iris.Text({`  Preset: {State.LodPreset}`})
	Iris.End()

	-- Debug Overlays
	local OverlayTree = Iris.Tree({"Debug Overlays"})
	if OverlayTree.state.isUncollapsed.value then
		-- Tier Billboards
		if Iris.Checkbox({"Tier Billboards"}, { isChecked = __IsBillboardsEnabled }).checked() then
			__IsBillboardsEnabled = true
		elseif Iris.Checkbox({"Tier Billboards"}, { isChecked = __IsBillboardsEnabled }).unchecked() then
			__IsBillboardsEnabled = false
		end

		-- Frustum
		if Iris.Checkbox({"Frustum Visualization"}, { isChecked = __IsFrustumEnabled }).checked() then
			__IsFrustumEnabled = true
		elseif Iris.Checkbox({"Frustum Visualization"}, { isChecked = __IsFrustumEnabled }).unchecked() then
			__IsFrustumEnabled = false
		end

		-- Freecam
		if Iris.Button({if __IsFreecamActive then "Disable Freecam" else "Enable Freecam"}).clicked() then
			__IsFreecamActive = not __IsFreecamActive
			if __IsFreecamActive then
				-- Freeze LOD reference CFrame
				local Camera = Workspace.CurrentCamera
				__FrozenCFrame = Camera.CFrame
				__FreecamCFrame = Camera.CFrame
				__OriginalCameraType = Camera.CameraType
				Camera.CameraType = Enum.CameraType.Scriptable
				local LookVector = Camera.CFrame.LookVector
				__FreecamYaw = math.atan2(-LookVector.X, -LookVector.Z)
				__FreecamPitch = math.asin(LookVector.Y)
			else
				-- Restore camera
				local Camera = Workspace.CurrentCamera
				if __OriginalCameraType then
					Camera.CameraType = __OriginalCameraType
				end
			end
		end

		if __IsFreecamActive then
			Iris.PushConfig({ TextColor = BenchmarkConstants.COLOR_CYAN })
			Iris.Text({"Freecam active. LOD frozen at activation position."})
			Iris.Text({"WASD: move | QE: up/down | RMB: look | Shift: sprint"})
			Iris.PopConfig()
		end
	end
	Iris.End()

	-- Live LOD Stats
	if State.LodStats then
		Iris.Separator()
		local LS = State.LodStats
		local TierText = ""
		for I, Count in LS.TierCounts do
			if I > 1 then TierText ..= "  " end
			TierText ..= `T{I - 1}: {Count}`
		end
		Iris.Text({`Tiers: {TierText}`})
		Iris.Text({string.format("Updated: %d / %d solvers", LS.SolversUpdated, LS.TotalRegistered)})
		Iris.Text({string.format("Savings: %.0f%%", LS.SavingsPercent)})
	end
end

return LodPanel
```

- [ ] **Step 2: Commit**

```bash
git add benchmark/Panels/LodPanel.luau
git commit -m "feat(benchmark): add LodPanel with LOD controls, freecam, and debug overlays"
```

---

## Phase 5: Final Integration (Task 14)

### Task 14: Integration Verification and Polish

**Files:**
- All files from previous tasks

- [ ] **Step 1: Verify all panels are discovered**

Run: `rojo serve benchmark.project.json` → Open Studio → Connect → Play.

Expected: Iris window with sections: Control, Timing, Comparison, Cache, Regression, LOD. All render without errors.

- [ ] **Step 2: Place R6 and R15 templates in Studio**

In Studio (with Rojo connected):
1. Insert an R6 character model into `Workspace.Templates`, name it "R6".
2. Insert an R15 character model into `Workspace.Templates`, name it "R15".
3. Save the place file as `benchmark.rbxl`.

- [ ] **Step 3: End-to-end test — basic benchmark**

1. Click "100 R15 Walk" preset → Click "Start".
2. Verify: 100 R15 NPCs spawn in grid, TimingPanel shows live FPS and timing breakdown.
3. Change NPC count to 50 → verify auto-respawn + warmup cycle.
4. Click "Snapshot" → verify entry appears in RegressionPanel's Snapshot Log.
5. Click "Stop" → verify cleanup.

- [ ] **Step 4: End-to-end test — rig variants**

1. Expand "Rig Variants" → set MissingLimb to 25%, Tool to 25%.
2. Start → verify CachePanel shows 3 unique fingerprints.
3. Verify effective NPC counts display correctly.

- [ ] **Step 5: End-to-end test — LOD**

1. Enable LOD → select "Performance" preset.
2. Start with 200 NPCs → verify LodPanel shows tier distribution.
3. Enable Freecam → fly around → verify tiers stay frozen to activation position.

- [ ] **Step 6: End-to-end test — MicroProfiler**

1. Set `DEBUG_PROFILING = true` in BenchmarkConstants.luau, save.
2. Rojo re-syncs → restart Play.
3. Open MicroProfiler (Ctrl+F6 in Studio) → verify "Luna:Step", "Luna:Evaluate", "Luna:Apply" labels appear.

- [ ] **Step 7: Fix any Iris API mismatches**

The Iris API used in this plan is based on common Iris patterns. The actual API may differ depending on the Iris version installed via pesde/wally. Read the installed Iris module's documentation or source and adjust widget calls (`InputNum`, `SliderNum`, `Checkbox`, `Tree`, `Button`, `Text`, `SameLine`, `SeparatorText`, `Separator`, `PushConfig`, `PopConfig`, `InputText`, `Window`, `End`) to match the exact API.

Common adjustments needed:
- `Iris.Args.InputNum.*` keys may use different names
- State binding syntax (`{ number = value }`) may differ
- `numberChanged()`, `clicked()`, `checked()` event names may differ

- [ ] **Step 8: Commit final integration**

```bash
git add -A benchmark/
git commit -m "feat(benchmark): complete benchmark harness — all panels, harness modules, and integration"
```

---

## Phase 6: Orchestration & Debug Visuals (Tasks 15-19)

These complete the remaining features: sequential comparison flow, automated suite, LOD debug visuals, freecam, and baseline wiring.

### Task 15: LodDebugOverlay + DebugFreecam

**Files:**
- Create: `benchmark/Harness/LodDebugOverlay.luau`
- Create: `benchmark/Harness/DebugFreecam.luau`
- Modify: `benchmark/Panels/LodPanel.luau` (wire overlays into render loop)

- [ ] **Step 1: Create LodDebugOverlay.luau**

Ported from LunaAnimator's `LodDebugOverlay.luau`. Handles tier billboards above NPCs and frustum wireframe visualization.

```lua
--!strict

local Workspace = game:GetService("Workspace")

local Benchmark = script.Parent.Parent
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local TIER_COLORS = BenchmarkConstants.TIER_COLORS
local FRUSTUM_COLOR = BenchmarkConstants.COLOR_CYAN
local FRUSTUM_EDGE_THICKNESS = 0.05
local NEAR_DISTANCE = 1

-- ============================================================================
-- [[ STATE ]]
-- ============================================================================

local __BillboardEntries: { { Billboard: BillboardGui, Label: TextLabel, Solver: any } } = {}
local __IsBillboardsEnabled = false
local __FrustumFolder: Folder? = nil
local __FrustumParts: { Part } = {}
local __IsFrustumEnabled = false

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local LodDebugOverlay = {}

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

local function __CreateEdgePart(): Part
	local Edge = Instance.new("Part")
	Edge.Anchored = true
	Edge.CanCollide = false
	Edge.CanTouch = false
	Edge.CanQuery = false
	Edge.Material = Enum.Material.Neon
	Edge.Color = FRUSTUM_COLOR
	Edge.Size = Vector3.new(FRUSTUM_EDGE_THICKNESS, FRUSTUM_EDGE_THICKNESS, 1)
	Edge.CastShadow = false
	return Edge
end

local function __PositionEdge(Edge: Part, PointA: Vector3, PointB: Vector3)
	local Mid = (PointA + PointB) / 2
	local Length = (PointB - PointA).Magnitude
	Edge.CFrame = CFrame.lookAt(Mid, PointB)
	Edge.Size = Vector3.new(FRUSTUM_EDGE_THICKNESS, FRUSTUM_EDGE_THICKNESS, Length)
end

local function __ComputeFrustumCorners(
	CameraCF: CFrame,
	Fov: number,
	AspectRatio: number,
	Distance: number,
	Padding: number
): (Vector3, Vector3, Vector3, Vector3)
	local HalfHeight = Distance * math.tan(math.rad(Fov / 2)) * (1 + Padding)
	local HalfWidth = HalfHeight * AspectRatio
	local Center = CameraCF.Position + CameraCF.LookVector * Distance
	local Right = CameraCF.RightVector
	local Up = CameraCF.UpVector

	local TopLeft = Center - Right * HalfWidth + Up * HalfHeight
	local TopRight = Center + Right * HalfWidth + Up * HalfHeight
	local BottomLeft = Center - Right * HalfWidth - Up * HalfHeight
	local BottomRight = Center + Right * HalfWidth - Up * HalfHeight

	return TopLeft, TopRight, BottomLeft, BottomRight
end

-- ============================================================================
-- [[ BILLBOARD API ]]
-- ============================================================================

function LodDebugOverlay.EnableBillboards(NpcData: { { Model: Model, Solver: any } })
	LodDebugOverlay.DisableBillboards()

	for _, Entry in NpcData do
		local PrimaryPart = Entry.Model.PrimaryPart or Entry.Model:FindFirstChild("HumanoidRootPart")
		if not PrimaryPart or not Entry.Solver then
			continue
		end

		local Billboard = Instance.new("BillboardGui")
		Billboard.Size = UDim2.fromScale(2, 1)
		Billboard.StudsOffset = Vector3.new(0, 3, 0)
		Billboard.AlwaysOnTop = true
		Billboard.Adornee = PrimaryPart :: BasePart
		Billboard.Parent = PrimaryPart

		local Label = Instance.new("TextLabel")
		Label.Size = UDim2.fromScale(1, 1)
		Label.BackgroundTransparency = 0.3
		Label.TextScaled = true
		Label.FontFace = Font.fromName("GothamBold")
		Label.TextColor3 = Color3.new(1, 1, 1)
		Label.Text = "?"
		Label.Parent = Billboard

		local Corner = Instance.new("UICorner")
		Corner.CornerRadius = UDim.new(0.2, 0)
		Corner.Parent = Label

		table.insert(__BillboardEntries, {
			Billboard = Billboard,
			Label = Label,
			Solver = Entry.Solver,
		})
	end

	__IsBillboardsEnabled = true
end

function LodDebugOverlay.UpdateBillboards(LodManager: any)
	if not __IsBillboardsEnabled then
		return
	end
	for _, Entry in __BillboardEntries do
		local RawTier = LodManager.GetTier(LodManager, Entry.Solver)
		local Tier = if RawTier < 0 then 0 else RawTier
		local ColorIndex = math.min(Tier + 1, #TIER_COLORS)
		Entry.Label.Text = tostring(Tier)
		Entry.Label.BackgroundColor3 = TIER_COLORS[ColorIndex]
	end
end

function LodDebugOverlay.DisableBillboards()
	for _, Entry in __BillboardEntries do
		Entry.Billboard:Destroy()
	end
	table.clear(__BillboardEntries)
	__IsBillboardsEnabled = false
end

function LodDebugOverlay.IsBillboardsEnabled(): boolean
	return __IsBillboardsEnabled
end

-- ============================================================================
-- [[ FRUSTUM API ]]
-- ============================================================================

function LodDebugOverlay.EnableFrustum(
	CameraCFrame: CFrame,
	FieldOfView: number,
	ViewportPadding: number,
	AspectRatio: number,
	FarDistance: number
)
	LodDebugOverlay.DisableFrustum()

	local Folder = Instance.new("Folder")
	Folder.Name = "LodFrustumDebug"
	Folder.Parent = Workspace
	__FrustumFolder = Folder

	-- 12 edges: 4 near rect + 4 far rect + 4 connecting
	for _ = 1, 12 do
		local Edge = __CreateEdgePart()
		Edge.Parent = Folder
		table.insert(__FrustumParts, Edge)
	end

	__IsFrustumEnabled = true
	LodDebugOverlay.UpdateFrustum(CameraCFrame, FieldOfView, ViewportPadding, AspectRatio, FarDistance)
end

function LodDebugOverlay.UpdateFrustum(
	CameraCFrame: CFrame,
	FieldOfView: number,
	ViewportPadding: number,
	AspectRatio: number,
	FarDistance: number
)
	if not __IsFrustumEnabled or #__FrustumParts < 12 then
		return
	end

	local NTL, NTR, NBL, NBR =
		__ComputeFrustumCorners(CameraCFrame, FieldOfView, AspectRatio, NEAR_DISTANCE, ViewportPadding)
	local FTL, FTR, FBL, FBR =
		__ComputeFrustumCorners(CameraCFrame, FieldOfView, AspectRatio, FarDistance, ViewportPadding)

	-- Near rectangle (edges 1-4)
	__PositionEdge(__FrustumParts[1], NTL, NTR)
	__PositionEdge(__FrustumParts[2], NBL, NBR)
	__PositionEdge(__FrustumParts[3], NTL, NBL)
	__PositionEdge(__FrustumParts[4], NTR, NBR)

	-- Far rectangle (edges 5-8)
	__PositionEdge(__FrustumParts[5], FTL, FTR)
	__PositionEdge(__FrustumParts[6], FBL, FBR)
	__PositionEdge(__FrustumParts[7], FTL, FBL)
	__PositionEdge(__FrustumParts[8], FTR, FBR)

	-- Connecting edges near->far (edges 9-12)
	__PositionEdge(__FrustumParts[9], NTL, FTL)
	__PositionEdge(__FrustumParts[10], NTR, FTR)
	__PositionEdge(__FrustumParts[11], NBL, FBL)
	__PositionEdge(__FrustumParts[12], NBR, FBR)
end

function LodDebugOverlay.DisableFrustum()
	if __FrustumFolder then
		__FrustumFolder:Destroy()
		__FrustumFolder = nil
	end
	table.clear(__FrustumParts)
	__IsFrustumEnabled = false
end

function LodDebugOverlay.IsFrustumEnabled(): boolean
	return __IsFrustumEnabled
end

return LodDebugOverlay
```

- [ ] **Step 2: Create DebugFreecam.luau**

Ported from LunaAnimator's `DebugFreecam.luau`. WASD movement, QE vertical, right-click mouselook, Shift sprint. Freezes LOD reference CFrame on activation.

```lua
--!strict

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local BASE_SPEED = 50
local SPRINT_MULTIPLIER = 3
local MOUSE_SENSITIVITY = 0.003
local PITCH_LIMIT = math.rad(89)

-- ============================================================================
-- [[ STATE ]]
-- ============================================================================

local __IsEnabled = false
local __OriginalCameraType: Enum.CameraType? = nil
local __OriginalCameraSubject: Instance? = nil
local __FrozenCameraCFrame = CFrame.new()
local __FrozenFov = 70
local __Yaw = 0
local __Pitch = 0
local __WasRootPartAnchored = false

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local DebugFreecam = {}

local function __GetCamera(): Camera?
	return Workspace.CurrentCamera
end

local function __GetRootPart(): BasePart?
	local Player = Players.LocalPlayer
	if Player and Player.Character then
		return Player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

function DebugFreecam.Enable()
	if __IsEnabled then
		return
	end

	local Camera = __GetCamera()
	if not Camera then
		return
	end

	-- Store restore state
	__OriginalCameraType = Camera.CameraType
	__OriginalCameraSubject = Camera.CameraSubject
	__FrozenCameraCFrame = Camera:GetRenderCFrame()
	__FrozenFov = Camera.FieldOfView

	-- Extract initial yaw/pitch from current look direction
	local LookVector = Camera.CFrame.LookVector
	__Yaw = math.atan2(-LookVector.X, -LookVector.Z)
	__Pitch = math.asin(math.clamp(LookVector.Y, -1, 1))

	-- Take full control
	Camera.CameraType = Enum.CameraType.Scriptable
	Camera.CFrame = __FrozenCameraCFrame

	-- Anchor character so physics doesn't drift
	local RootPart = __GetRootPart()
	if RootPart then
		__WasRootPartAnchored = RootPart.Anchored
		RootPart.Anchored = true
	else
		__WasRootPartAnchored = false
	end

	__IsEnabled = true
end

function DebugFreecam.Disable()
	if not __IsEnabled then
		return
	end

	local Camera = __GetCamera()
	if Camera then
		Camera.CameraType = __OriginalCameraType :: Enum.CameraType
		Camera.CameraSubject = __OriginalCameraSubject
	end

	local RootPart = __GetRootPart()
	if RootPart then
		RootPart.Anchored = __WasRootPartAnchored
	end

	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	__IsEnabled = false
end

function DebugFreecam.Update(DeltaTime: number)
	if not __IsEnabled then
		return
	end

	local Camera = __GetCamera()
	if not Camera then
		return
	end

	-- Mouse look — only while right mouse button is held
	local IsRightMouseHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
	if IsRightMouseHeld then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		local Delta = UserInputService:GetMouseDelta()
		__Yaw -= Delta.X * MOUSE_SENSITIVITY
		__Pitch -= Delta.Y * MOUSE_SENSITIVITY
		__Pitch = math.clamp(__Pitch, -PITCH_LIMIT, PITCH_LIMIT)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	-- Build orientation from yaw/pitch
	local Rotation = CFrame.fromEulerAnglesYXZ(__Pitch, __Yaw, 0)

	-- Poll movement keys
	local MoveX = 0
	local MoveY = 0
	local MoveZ = 0

	if UserInputService:IsKeyDown(Enum.KeyCode.W) then MoveZ -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then MoveZ += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then MoveX -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then MoveX += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.E) then MoveY += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) then MoveY -= 1 end

	local MoveDirection = Vector3.new(MoveX, MoveY, MoveZ)
	if MoveDirection.Magnitude > 0 then
		MoveDirection = MoveDirection.Unit
	end

	-- Sprint check
	local IsSprinting = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	local Speed = BASE_SPEED * (if IsSprinting then SPRINT_MULTIPLIER else 1)

	-- Transform local movement to world space and apply
	local CurrentPosition = Camera.CFrame.Position
	local WorldMovement = Rotation:VectorToWorldSpace(MoveDirection) * Speed * DeltaTime
	Camera.CFrame = CFrame.new(CurrentPosition + WorldMovement) * Rotation
end

function DebugFreecam.IsEnabled(): boolean
	return __IsEnabled
end

--- Returns the camera CFrame/FOV at the moment freecam was activated.
--- Use this as the LOD reference point while freecam is active.
function DebugFreecam.GetFrozenCFrame(): CFrame
	return __FrozenCameraCFrame
end

function DebugFreecam.GetFrozenFov(): number
	return __FrozenFov
end

return DebugFreecam
```

- [ ] **Step 3: Wire overlays into LodPanel and BenchmarkRunner**

In `benchmark/Panels/LodPanel.luau`, add requires at the top:
```lua
local LodDebugOverlay = require(Benchmark.Harness.LodDebugOverlay)
local DebugFreecam = require(Benchmark.Harness.DebugFreecam)
```

Replace the checkbox/button stubs for billboards, frustum, and freecam with actual calls to enable/disable the overlays. Wire `DebugFreecam.Update(DeltaTime)` into the BenchmarkRunner's `RenderStepped` connection (add it at the top of the frame loop, before the state machine).

In BenchmarkRunner, add at the top of the RenderStepped callback:
```lua
DebugFreecam.Update(DeltaTime)
```

- [ ] **Step 4: Commit**

```bash
git add benchmark/Harness/LodDebugOverlay.luau benchmark/Harness/DebugFreecam.luau benchmark/Panels/LodPanel.luau benchmark/BenchmarkRunner.client.luau
git commit -m "feat(benchmark): add LOD debug overlay (billboards + frustum) and freecam with frozen reference"
```

---

### Task 16: Sequential Comparison Orchestration

**Files:**
- Modify: `benchmark/BenchmarkRunner.client.luau`

Implements the multi-phase sequential comparison state machine: Luna → GC Cooldown → Native Playing → GC Cooldown → Native Idle → GC Cooldown → Compute Results.

- [ ] **Step 1: Add GC cooldown helper to BenchmarkRunner**

Add this function in the BenchmarkRunner above the state machine section:

```lua
--- GC-stabilization-gated cooldown.
--- Yields until gcinfo() delta < 1KB over 1 second, or max timeout reached.
--- Returns true if stabilized, false if timed out.
local function WaitForGcStabilization(): boolean
	local MaxTimeout = BenchmarkConstants.COOLDOWN_MAX_TIMEOUT
	local SampleInterval = BenchmarkConstants.COOLDOWN_SAMPLE_INTERVAL
	local DeltaThreshold = BenchmarkConstants.COOLDOWN_HEAP_DELTA_KB

	local StartTime = os.clock()
	local PreviousHeap = gcinfo()
	local StableStart = os.clock()

	while os.clock() - StartTime < MaxTimeout do
		task.wait(SampleInterval)
		local CurrentHeap = gcinfo()
		local HeapDelta = math.abs(CurrentHeap - PreviousHeap)

		if HeapDelta < DeltaThreshold then
			-- Check if stable for 1 second
			if os.clock() - StableStart >= 1 then
				return true
			end
		else
			StableStart = os.clock()
		end
		PreviousHeap = CurrentHeap
	end

	return false -- timed out
end
```

- [ ] **Step 2: Add sequential comparison coroutine**

Add this function to BenchmarkRunner, called from the ComparisonPanel when "Enable Comparison Mode" is toggled and Start is pressed:

```lua
local __ComparisonLunaTiming: TimingSnapshot? = nil
local __ComparisonNativePlayingTiming: TimingSnapshot? = nil
local __ComparisonNativeIdleTiming: TimingSnapshot? = nil
local __ComparisonDuration = 15 -- seconds

local function RunSequentialComparison()
	local NativeAnimatorRunner = require(Benchmark.Harness.NativeAnimatorRunner)

	-- Phase 1: Luna
	State.TransitionState = "ComparisonLuna"
	SpawnAndStart() -- spawns Luna NPCs, enters warmup

	-- Wait for warmup to complete, then measure
	while State.TransitionState == "WarmingUp" do
		RunService.RenderStepped:Wait()
	end

	-- Measure for ComparisonDuration seconds
	TimingCollectorModule.Reset(TimingCollector)
	local MeasureStart = os.clock()
	while os.clock() - MeasureStart < __ComparisonDuration do
		RunService.RenderStepped:Wait()
	end
	__ComparisonLunaTiming = TimingCollectorModule.GetSnapshot(TimingCollector)

	-- Cleanup Luna
	NpcSpawner.Cleanup()
	LunaRuntimeWrapper.Reset()

	-- Cooldown
	State.TransitionState = "Cooldown"
	local GcStabilized = WaitForGcStabilization()
	State.GcWarning = not GcStabilized

	-- Phase 2: Native Playing
	State.TransitionState = "ComparisonNativePlaying"
	local Templates = Workspace:FindFirstChild("Templates")
	local Template = Templates and Templates:FindFirstChild(State.RigType)
	if not Template then
		State.TransitionState = "ComparisonDone"
		return
	end

	-- Get animation source for native
	local AnimSource: Instance? = nil
	if State.AnimationSource.Kind == "FromPlace" and State.AnimationSource.KeyframeSequence then
		-- For KeyframeSequence, we need to create an Animation — native needs AssetId
		-- This is a limitation: log it
	elseif State.AnimationSource.Kind == "AssetId" and State.AnimationSource.AssetId then
		AnimSource = AnimationProvider.FromAssetId(State.AnimationSource.AssetId)
	end

	if AnimSource then
		NativeAnimatorRunner.Spawn(Template :: Model, State.NpcCount, State.Density, AnimSource)
		NativeAnimatorRunner.PlayAll()
	end

	-- Warmup (fixed 60 frames for native — can't do variance-based on C++ internals)
	for _ = 1, 60 do
		RunService.RenderStepped:Wait()
	end

	-- Measure Native Playing
	local NativePlayingCollector = TimingCollectorModule.new()
	TimingCollectorModule.SetCounts(NativePlayingCollector, State.NpcCount, 0, 0)
	MeasureStart = os.clock()
	while os.clock() - MeasureStart < __ComparisonDuration do
		TimingCollectorModule.BeginFrame(NativePlayingCollector)
		RunService.RenderStepped:Wait()
		TimingCollectorModule.MarkEvalEnd(NativePlayingCollector)
		TimingCollectorModule.EndFrame(NativePlayingCollector)
	end
	__ComparisonNativePlayingTiming = TimingCollectorModule.GetSnapshot(NativePlayingCollector)

	-- Phase 3: Native Idle (stop animations, rigs stay)
	State.TransitionState = "Cooldown"
	NativeAnimatorRunner.StopAll()
	local GcStabilized2 = WaitForGcStabilization()
	if not GcStabilized2 then
		State.GcWarning = true
	end

	State.TransitionState = "ComparisonNativeIdle"
	local NativeIdleCollector = TimingCollectorModule.new()
	TimingCollectorModule.SetCounts(NativeIdleCollector, State.NpcCount, 0, 0)
	MeasureStart = os.clock()
	while os.clock() - MeasureStart < __ComparisonDuration do
		TimingCollectorModule.BeginFrame(NativeIdleCollector)
		RunService.RenderStepped:Wait()
		TimingCollectorModule.MarkEvalEnd(NativeIdleCollector)
		TimingCollectorModule.EndFrame(NativeIdleCollector)
	end
	__ComparisonNativeIdleTiming = TimingCollectorModule.GetSnapshot(NativeIdleCollector)

	-- Cleanup native
	NativeAnimatorRunner.Cleanup()

	-- Final cooldown
	State.TransitionState = "Cooldown"
	local GcStabilized3 = WaitForGcStabilization()
	if not GcStabilized3 then
		State.GcWarning = true
	end

	-- Compute isolated native cost: Playing - Idle
	if __ComparisonNativePlayingTiming and __ComparisonNativeIdleTiming then
		State.NativeStats = {
			AvgTotalMs = __ComparisonNativePlayingTiming.AvgTotalMs - __ComparisonNativeIdleTiming.AvgTotalMs,
			PeakTotalMs = __ComparisonNativePlayingTiming.PeakTotalMs - __ComparisonNativeIdleTiming.PeakTotalMs,
			PerNpcUs = if State.NpcCount > 0 then
				((__ComparisonNativePlayingTiming.AvgTotalMs - __ComparisonNativeIdleTiming.AvgTotalMs) * 1000) / State.NpcCount
				else 0,
			CurrentFps = __ComparisonNativePlayingTiming.CurrentFps,
			HeapKb = __ComparisonNativePlayingTiming.HeapKb,
		}
	end

	State.Timing = __ComparisonLunaTiming
	State.TransitionState = "ComparisonDone"
	State.IsRunning = false
end
```

- [ ] **Step 3: Wire comparison into RequestStart**

In BenchmarkRunner's `State.RequestStart` callback, add a branch:

```lua
State.RequestStart = function()
	if State.IsRunning then
		return
	end
	State.IsRunning = true
	if State.IsComparisonMode and State.ComparisonMode == "Sequential" then
		task.spawn(RunSequentialComparison)
	else
		SpawnAndStart()
	end
end
```

- [ ] **Step 4: Commit**

```bash
git add benchmark/BenchmarkRunner.client.luau
git commit -m "feat(benchmark): add sequential comparison orchestration with GC-gated cooldown and two-run native isolation"
```

---

### Task 17: Automated Suite Runner

**Files:**
- Modify: `benchmark/BenchmarkRunner.client.luau`

Implements the config matrix iteration loop that cycles through animation types, NPC counts, eval modes, and isolation modes. Uses `task.spawn` so the UI stays responsive.

- [ ] **Step 1: Add automated suite function to BenchmarkRunner**

```lua
local function RunAutomatedSuite()
	local AnimTypes = { "Simple", "WalkCycle" }
	local NpcCounts = { 50, 100, 200 }
	local EvalModes = { "Sampled", "Live" }
	local IsolationModes = { "Full", "No Render", "No Apply", "No Eval" }

	-- Count valid combinations (skip nonsensical)
	local TotalCombinations = 0
	for _, _AnimType in AnimTypes do
		for _, _NpcCount in NpcCounts do
			for _, _EvalMode in EvalModes do
				for _, IsolationMode in IsolationModes do
					if IsolationMode == "No Eval" and _EvalMode == "Live" then continue end
					if IsolationMode == "No Eval" and _AnimType == "WalkCycle" then continue end
					TotalCombinations += 1
				end
			end
		end
	end

	local CurrentRun = 0
	local Results: { BenchmarkTypes.SuiteResult } = {}
	State.IsRunning = true

	for _, AnimType in AnimTypes do
		for _, NpcCount in NpcCounts do
			for _, EvalMode in EvalModes do
				for _, IsolationMode in IsolationModes do
					if IsolationMode == "No Eval" and EvalMode == "Live" then continue end
					if IsolationMode == "No Eval" and AnimType == "WalkCycle" then continue end

					CurrentRun += 1
					State.TransitionState = "Running"

					-- Set config
					State.NpcCount = NpcCount
					State.EvalMode = EvalMode
					State.IsolationMode = IsolationMode
					State.AnimationSource = { Kind = "Synthetic", SyntheticType = AnimType }
					State.RigType = "R15"
					State.LayerCount = 1
					State.LodEnabled = false

					-- Spawn
					SpawnAndStart()

					-- Wait for warmup to complete
					while State.TransitionState == "WarmingUp" or State.TransitionState == "Respawning" do
						RunService.RenderStepped:Wait()
					end

					-- Measure for 5 seconds (time-based, matches TimingCollector)
					TimingCollectorModule.Reset(TimingCollector)
					local MeasureStart = os.clock()
					while os.clock() - MeasureStart < BenchmarkConstants.DEFAULT_WINDOW_SECONDS do
						RunService.RenderStepped:Wait()
					end

					-- Collect
					local Snapshot = TimingCollectorModule.GetSnapshot(TimingCollector)
					table.insert(Results, {
						Config = {
							NpcCount = NpcCount,
							RigType = "R15",
							EvalMode = EvalMode,
							SampleRate = State.SampleRate,
							LayerCount = 1,
							IsolationMode = IsolationMode,
							AnimationSourceKind = "Synthetic",
							SyntheticType = AnimType,
							LodEnabled = false,
						},
						Timing = Snapshot,
					})

					-- Cleanup + cooldown
					NpcSpawner.Cleanup()
					LunaRuntimeWrapper.Reset()
					State.TransitionState = "Cooldown"
					local _Stabilized = WaitForGcStabilization()
				end
			end
		end
	end

	-- Store results
	State.SuiteResults = Results
	State.IsRunning = false
	State.TransitionState = "Idle"
end
```

- [ ] **Step 2: Wire into callbacks**

```lua
State.RequestRunSuite = function()
	if State.IsRunning then
		return
	end
	task.spawn(RunAutomatedSuite)
end

State.RequestSaveBaseline = function()
	if #State.SuiteResults > 0 then
		BaselineStore.Save(State.SuiteResults, State.RunNote)
		State.Baseline = BaselineStore.Load()
	elseif State.Timing then
		-- Save single config as 1-entry suite
		local SingleResult: BenchmarkTypes.SuiteResult = {
			Config = {
				NpcCount = State.NpcCount,
				RigType = State.RigType,
				EvalMode = State.EvalMode,
				SampleRate = State.SampleRate,
				LayerCount = State.LayerCount,
				IsolationMode = State.IsolationMode,
				AnimationSourceKind = State.AnimationSource.Kind,
				SyntheticType = State.AnimationSource.SyntheticType,
				LodEnabled = State.LodEnabled,
			},
			Timing = State.Timing,
		}
		BaselineStore.Save({ SingleResult }, State.RunNote)
		State.Baseline = BaselineStore.Load()
	end
end
```

- [ ] **Step 3: Add BaselineStore require to BenchmarkRunner**

Add at the top of BenchmarkRunner:
```lua
local BaselineStore = require(Benchmark.Harness.BaselineStore)
```

- [ ] **Step 4: Commit**

```bash
git add benchmark/BenchmarkRunner.client.luau
git commit -m "feat(benchmark): add automated suite runner with config matrix and baseline save wiring"
```

---

### Task 18: End-to-End Verification of All Features

**Files:** All from previous tasks

- [ ] **Step 1: Test sequential comparison**

1. Drop a KeyframeSequence into `Workspace.Animations` in Studio (or use Asset ID).
2. Select "From Place" or "Asset ID" source in ControlPanel.
3. Enable Comparison Mode (Sequential) in ComparisonPanel.
4. Start → verify progress bar shows phases: ComparisonLuna → Cooldown → ComparisonNativePlaying → Cooldown → ComparisonNativeIdle → Cooldown → ComparisonDone.
5. Verify x factor and results table appear in ComparisonPanel.

- [ ] **Step 2: Test automated suite**

1. Type a run note: "baseline test".
2. Click "Run Suite" in RegressionPanel.
3. Verify it cycles through configs (status updates in ControlPanel).
4. After completion, click "Save Baseline".
5. Modify a config, run again → verify delta display in RegressionPanel.

- [ ] **Step 3: Test LOD debug overlays**

1. Enable LOD, start with 200 NPCs.
2. Toggle "Tier Billboards" → verify colored labels above NPC heads.
3. Toggle "Frustum Visualization" → verify cyan wireframe in world.
4. Enable Freecam → fly around → verify tiers stay frozen, frustum stays at activation position.
5. Disable Freecam → verify camera restores, tiers update normally.

- [ ] **Step 4: Test MicroProfiler labels**

1. Set `DEBUG_PROFILING = true` in BenchmarkConstants.
2. Run benchmark → open MicroProfiler (Ctrl+F6).
3. Verify "Luna:Step", "Luna:Evaluate", "Luna:Apply" labels appear.
4. Set `DEBUG_PROFILING_GRANULAR = true` → verify per-operation labels appear.
5. Verify yellow warning text in TimingPanel about granular distortion.

- [ ] **Step 5: Commit any fixes**

```bash
git add -A benchmark/
git commit -m "fix(benchmark): integration fixes from end-to-end verification"
```
