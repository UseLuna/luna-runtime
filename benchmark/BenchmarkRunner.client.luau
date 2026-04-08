--!strict

--[[
	BenchmarkRunner — Entry point for the Luna benchmark harness.

	Runs as a LocalScript in StarterPlayerScripts. Initializes Iris UI, discovers
	panel modules, manages a state machine for benchmark lifecycle, and wires
	SharedState to all harness modules.

	Rojo mapping:
	  StarterPlayer.StarterPlayerScripts.BenchmarkRunner → this file
	  ReplicatedStorage.LunaRuntime                      → runtime (Core, Solver, Types, Shared)
	  ReplicatedStorage.Packages                         → iris, janitor, etc.
	  ReplicatedStorage.Benchmark                        → Panels/, Harness/, BenchmarkConstants, BenchmarkTypes
]]

-- ── Services ────────────────────────────────────────────────────────────────

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ── Memory Category ─────────────────────────────────────────────────────────

debug.setmemorycategory("LunaBenchmark")

-- ── Requires ────────────────────────────────────────────────────────────────

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local Packages = ReplicatedStorage:WaitForChild("Packages")
local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")

local Logger = require(LunaRuntime.Shared.Logger)
local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)

local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

local Harness = Benchmark:WaitForChild("Harness")
local TimingCollector = require(Harness.TimingCollector)
local NpcSpawner = require(Harness.NpcSpawner)
local AnimationProvider = require(Harness.AnimationProvider)
local NativeAnimatorRunner = require(Harness.NativeAnimatorRunner)
local BaselineStore = require(Harness.BaselineStore)
local ProfilerInjector = require(Harness.ProfilerInjector)

local Iris = require(Packages:WaitForChild("iris"))

-- ── Types ───────────────────────────────────────────────────────────────────

type SharedState = BenchmarkTypes.SharedState
type Panel = BenchmarkTypes.Panel
type TransitionState = BenchmarkTypes.TransitionState
type TimingSnapshot = BenchmarkTypes.TimingSnapshot
type SpawnConfig = BenchmarkTypes.SpawnConfig
type AnimationSource = BenchmarkTypes.AnimationSource

-- ── Profiler Injection (compile-time flags) ─────────────────────────────────

if BenchmarkConstants.DEBUG_PROFILING_GRANULAR then
	ProfilerInjector.InstallGranular()
elseif BenchmarkConstants.DEBUG_PROFILING then
	ProfilerInjector.InstallCoarse()
end

-- ── Timing Collector ────────────────────────────────────────────────────────

local Collector = TimingCollector.new()
Collector.SetWindow(Collector, BenchmarkConstants.DEFAULT_WINDOW_SECONDS)

-- ── SharedState ─────────────────────────────────────────────────────────────

-- Forward-declared callbacks; wired after SharedState creation.
local function __Noop() end

local State: SharedState = {
	-- Config
	NpcCount = BenchmarkConstants.DEFAULT_NPC_COUNT,
	Density = BenchmarkConstants.DEFAULT_DENSITY,
	RigType = BenchmarkConstants.DEFAULT_RIG_TYPE,
	EvalMode = BenchmarkConstants.DEFAULT_EVAL_MODE,
	SampleRate = BenchmarkConstants.DEFAULT_SAMPLE_RATE,
	LayerCount = BenchmarkConstants.DEFAULT_LAYER_COUNT,
	IsolationMode = BenchmarkConstants.DEFAULT_ISOLATION_MODE,
	AnimationSource = {
		Kind = "Synthetic",
		SyntheticType = "WalkCycle",
		KeyframeSequence = nil,
		AssetId = nil,
	},
	RigVariants = {
		PristinePercent = 100,
		MissingLimbPercent = 0,
		ToolEquippedPercent = 0,
	},

	-- LOD
	LodEnabled = false,
	LodPreset = "Default",

	-- Runtime
	IsRunning = false,
	TransitionState = "Idle" :: TransitionState,
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

	-- Flags
	IsTimingEnabled = true,
	IsComparisonMode = false,
	ComparisonMode = "Sequential",
	GcWarning = false,

	-- Callbacks (wired below)
	RequestStart = __Noop,
	RequestStop = __Noop,
	RequestConfigChange = __Noop,
	RequestSnapshot = __Noop,
	RequestSaveBaseline = __Noop,
	RequestRunSuite = __Noop,
}

-- ── Panel Discovery ─────────────────────────────────────────────────────────

local PANEL_ORDER: { string } = {
	"ControlPanel",
	"TimingPanel",
	"ComparisonPanel",
	"CachePanel",
	"RegressionPanel",
	"LodPanel",
}

local Panels: { Panel } = {}
local PanelCount: number = 0

local function DiscoverPanels()
	local PanelsFolder = Benchmark:FindFirstChild("Panels")
	if not PanelsFolder then
		Logger.Warn("BenchmarkRunner: Panels folder not found under Benchmark")
		return
	end

	for _, PanelName in PANEL_ORDER do
		local Module = PanelsFolder:FindFirstChild(PanelName)
		if not Module then
			Logger.Debug(`BenchmarkRunner: Panel "{PanelName}" not found, skipping`)
			continue
		end

		local Success, Result = pcall(require, Module)
		if not Success then
			Logger.Warn(`BenchmarkRunner: Failed to require panel "{PanelName}": {tostring(Result)}`)
			continue
		end

		local PanelModule = Result :: Panel
		PanelCount += 1
		Panels[PanelCount] = PanelModule

		-- Call Init if present
		if PanelModule.Init then
			local InitSuccess, InitError = pcall(PanelModule.Init :: any, State)
			if not InitSuccess then
				Logger.Warn(`BenchmarkRunner: Panel "{PanelName}" Init failed: {tostring(InitError)}`)
			end
		end

		Logger.Debug(`BenchmarkRunner: Loaded panel "{PanelName}"`)
	end

	Logger.Info(`BenchmarkRunner: Discovered {PanelCount} panel(s)`)
end

-- ── Animation Loading ───────────────────────────────────────────────────────

--[[
	Loads an animation from the current AnimationSource config and returns a
	preloaded LoadedAnimation (or nil on failure).
]]
local function LoadAnimation(): any?
	local Source = State.AnimationSource

	if Source.Kind == "Synthetic" then
		local SyntheticType = Source.SyntheticType or "WalkCycle"
		local EditAnim = AnimationProvider.GetSynthetic(SyntheticType, State.RigType)
		local Key = `Synthetic_{SyntheticType}_{State.RigType}`
		return LunaRuntimeWrapper.Preload(Key, EditAnim)

	elseif Source.Kind == "FromPlace" then
		if Source.KeyframeSequence then
			return LunaRuntimeWrapper.FromKeyframeSequence(Source.KeyframeSequence :: KeyframeSequence)
		end
		Logger.Warn("BenchmarkRunner: AnimationSource is FromPlace but KeyframeSequence is nil")
		return nil

	elseif Source.Kind == "AssetId" then
		-- AssetId animations are handled via LoadAndPlay directly; return nil here
		-- and use a different code path in PlayOnModels.
		return nil
	end

	Logger.Warn(`BenchmarkRunner: Unknown AnimationSource kind "{Source.Kind}"`)
	return nil
end

--[[
	Plays the loaded animation on all spawned models. For each model, plays
	LayerCount layers with staggered time offsets.
]]
local function PlayOnModels(LoadedAnim: any?)
	local Models = NpcSpawner.GetSpawnedModels()
	local LayerCount = State.LayerCount
	local Source = State.AnimationSource

	for ModelIndex, Model in Models do
		for LayerIndex = 1, LayerCount do
			local Weight = 1 / LayerCount
			local TimeOffset = (LayerIndex - 1) * 0.1 + (ModelIndex - 1) * 0.01

			if Source.Kind == "AssetId" and Source.AssetId then
				-- AssetId path: use LoadAndPlay directly
				LunaRuntimeWrapper.LoadAndPlay(Model, Source.AssetId, {
					Looping = true,
					Weight = Weight,
					Speed = 1,
				})
			elseif LoadedAnim then
				local Handle = LunaRuntimeWrapper.Play(Model, LoadedAnim, {
					Looping = true,
					Weight = Weight,
					Speed = 1,
				})
				-- Stagger playback by offsetting time (if the handle supports it)
				if Handle and TimeOffset > 0 then
					-- AnimationPlayer has a LocalTime field; advance it for stagger
					if Handle.LocalTime ~= nil then
						Handle.LocalTime = TimeOffset
					end
				end
			end
		end
	end
end

-- ── GC Stabilization Helper ─────────────────────────────────────────────────

--- GC-stabilization-gated cooldown.
--- Yields until gcinfo() delta < COOLDOWN_HEAP_DELTA_KB over 1 second, or max timeout reached.
--- Returns true if stabilized, false if timed out.
local function WaitForGcStabilization(): boolean
	local MaxTimeout = BenchmarkConstants.COOLDOWN_MAX_TIMEOUT
	local SampleInterval = BenchmarkConstants.COOLDOWN_SAMPLE_INTERVAL
	local HeapDeltaThreshold = BenchmarkConstants.COOLDOWN_HEAP_DELTA_KB

	local Elapsed = 0
	local PreviousHeap = gcinfo()

	while Elapsed < MaxTimeout do
		task.wait(SampleInterval)
		Elapsed += SampleInterval

		local CurrentHeap = gcinfo()
		local Delta = math.abs(CurrentHeap - PreviousHeap)
		PreviousHeap = CurrentHeap

		-- Check if heap has stabilized: delta < threshold over at least 1 second of samples.
		-- We need two consecutive stable readings (2 * SampleInterval >= 1s at 0.5s interval).
		if Delta < HeapDeltaThreshold and Elapsed >= 1 then
			Logger.Info(`BenchmarkRunner: GC stabilized after {string.format("%.1f", Elapsed)}s (delta={string.format("%.1f", Delta)}KB)`)
			return true
		end
	end

	Logger.Warn(`BenchmarkRunner: GC stabilization timed out after {MaxTimeout}s`)
	return false
end

-- ── Spawn + Start ───────────────────────────────────────────────────────────

local function SpawnAndStart()
	State.TransitionState = "Respawning"

	-- Cleanup previous state
	NpcSpawner.Cleanup()
	LunaRuntimeWrapper.Reset()

	-- Spawn NPCs
	local Config: SpawnConfig = {
		Count = State.NpcCount,
		Density = State.Density,
		RigType = State.RigType,
		Variants = State.RigVariants,
		IsolationMode = State.IsolationMode,
	}
	NpcSpawner.Spawn(Config)

	-- Apply LOD if enabled
	if State.LodEnabled then
		LunaRuntimeWrapper.SetGlobalLod(State.LodPreset)
	else
		LunaRuntimeWrapper.DisableLod()
	end

	-- Load animation
	local LoadedAnim = LoadAnimation()

	-- Resolve rigs for all spawned models
	local Models = NpcSpawner.GetSpawnedModels()
	for _, Model in Models do
		LunaRuntimeWrapper.ResolveRig(Model)
	end

	-- Play on all models
	PlayOnModels(LoadedAnim)

	-- Update TimingCollector counts
	-- Estimate track/bone counts based on rig type and config
	local BonesPerRig = if State.RigType == "R6" then 6 else 15
	local TracksPerRig = BonesPerRig * State.LayerCount
	local TotalNpcs = NpcSpawner.GetSpawnedCount()
	Collector.SetCounts(Collector, TotalNpcs, TracksPerRig * TotalNpcs, BonesPerRig * TotalNpcs)
	Collector.Reset(Collector)

	-- Enter warmup
	State.TransitionState = "WarmingUp"
	State.WarmupFrame = 0

	Logger.Info(`BenchmarkRunner: Spawned {TotalNpcs} NPCs, entering warmup`)
end

-- ── Cleanup ─────────────────────────────────────────────────────────────────

local function CleanupBenchmark()
	NpcSpawner.Cleanup()
	LunaRuntimeWrapper.Reset()
	Collector.Reset(Collector)
	State.Timing = nil
	State.TransitionState = "Idle"
	State.IsRunning = false
	State.WarmupFrame = 0
end

-- ── Sequential Comparison Orchestration ─────────────────────────────────────

--[[
	Multi-phase sequential comparison state machine. Measures Luna, then native
	Animator (playing vs idle) to isolate engine animation cost. Runs in a
	spawned coroutine so UI stays responsive during the multi-minute process.
]]
local function RunSequentialComparison()
	local MeasureDuration = BenchmarkConstants.DEFAULT_WINDOW_SECONDS * 3 -- 15 seconds
	local WarmupMinFrames = BenchmarkConstants.WARMUP_MIN_FRAMES

	State.IsRunning = true
	State.GcWarning = false
	Collector.SetEnabled(Collector, true)

	-- ── Phase 1: Luna ───────────────────────────────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Phase 1 — Luna")
	State.TransitionState = "ComparisonLuna"

	SpawnAndStart()

	-- Wait for warmup to complete
	while State.TransitionState == "Respawning" or State.TransitionState == "WarmingUp" do
		RunService.RenderStepped:Wait()
	end

	-- Measure for MeasureDuration seconds
	Collector.Reset(Collector)
	local LunaMeasureStart = os.clock()
	while os.clock() - LunaMeasureStart < MeasureDuration do
		RunService.RenderStepped:Wait()
	end

	local LunaTiming = Collector.GetSnapshot(Collector)
	State.Timing = LunaTiming
	Logger.Info(`BenchmarkRunner: [Comparison] Luna done — Avg={string.format("%.2f", LunaTiming.AvgTotalMs)}ms`)

	-- ── Cooldown 1: Cleanup Luna ────────────────────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Cooldown 1 — cleaning up Luna")
	State.TransitionState = "Cooldown"
	NpcSpawner.Cleanup()
	LunaRuntimeWrapper.Reset()
	Collector.Reset(Collector)

	if not WaitForGcStabilization() then
		State.GcWarning = true
	end

	-- ── Phase 2: Native Playing ─────────────────────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Phase 2 — Native Playing")
	State.TransitionState = "ComparisonNativePlaying"

	-- Find template model for native spawning
	local Templates = workspace:FindFirstChild("Templates")
	local Template = if Templates then Templates:FindFirstChild(State.RigType) :: Model? else nil

	if not Template then
		Logger.Warn("BenchmarkRunner: [Comparison] Cannot find template for native spawning — aborting")
		State.TransitionState = "ComparisonDone"
		State.IsRunning = false
		return
	end

	-- Create an Animation instance for native playback
	local Source = State.AnimationSource
	local NativeAnimSource: Animation?

	if Source.Kind == "AssetId" and Source.AssetId then
		NativeAnimSource = AnimationProvider.FromAssetId(Source.AssetId)
	else
		-- For synthetic animations, we need an asset ID — native Animator cannot play EditAnimations.
		-- Use a default walk animation asset as fallback.
		Logger.Warn("BenchmarkRunner: [Comparison] Native phase requires an AssetId animation source. Using default walk anim.")
		NativeAnimSource = AnimationProvider.FromAssetId("rbxassetid://180426354") -- Default R15 walk
	end

	NativeAnimatorRunner.Spawn(Template :: Model, State.NpcCount, State.Density, NativeAnimSource :: Animation)
	NativeAnimatorRunner.PlayAll()

	-- Warmup: wait WarmupMinFrames frames (60 default)
	for _ = 1, WarmupMinFrames * 2 do
		RunService.RenderStepped:Wait()
	end

	-- Measure native playing
	local NativePlayingStart = os.clock()
	local NativePlayingSumMs = 0
	local NativePlayingPeakMs = 0
	local NativePlayingFrames = 0
	local NativePlayingHeapKb = 0

	while os.clock() - NativePlayingStart < MeasureDuration do
		local FrameStart = os.clock()
		RunService.RenderStepped:Wait()
		local FrameMs = (os.clock() - FrameStart) * 1000

		NativePlayingFrames += 1
		NativePlayingSumMs += FrameMs
		if FrameMs > NativePlayingPeakMs then
			NativePlayingPeakMs = FrameMs
		end
		NativePlayingHeapKb = gcinfo()
	end

	local NativePlayingAvgMs = if NativePlayingFrames > 0 then NativePlayingSumMs / NativePlayingFrames else 0
	local NativePlayingFps = if NativePlayingFrames > 0 then NativePlayingFrames / MeasureDuration else 0

	Logger.Info(`BenchmarkRunner: [Comparison] Native Playing done — Avg={string.format("%.2f", NativePlayingAvgMs)}ms`)

	-- ── Cooldown 2: Stop animations (rigs stay) ─────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Cooldown 2 — stopping native animations")
	State.TransitionState = "Cooldown"
	NativeAnimatorRunner.StopAll()

	if not WaitForGcStabilization() then
		State.GcWarning = true
	end

	-- ── Phase 3: Native Idle ────────────────────────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Phase 3 — Native Idle")
	State.TransitionState = "ComparisonNativeIdle"

	local NativeIdleStart = os.clock()
	local NativeIdleSumMs = 0
	local NativeIdleFrames = 0

	while os.clock() - NativeIdleStart < MeasureDuration do
		local FrameStart = os.clock()
		RunService.RenderStepped:Wait()
		local FrameMs = (os.clock() - FrameStart) * 1000

		NativeIdleFrames += 1
		NativeIdleSumMs += FrameMs
	end

	local NativeIdleAvgMs = if NativeIdleFrames > 0 then NativeIdleSumMs / NativeIdleFrames else 0

	Logger.Info(`BenchmarkRunner: [Comparison] Native Idle done — Avg={string.format("%.2f", NativeIdleAvgMs)}ms`)

	-- ── Cooldown 3: Cleanup native ──────────────────────────────────────
	Logger.Info("BenchmarkRunner: [Comparison] Cooldown 3 — cleaning up native")
	State.TransitionState = "Cooldown"
	NativeAnimatorRunner.Cleanup()

	if not WaitForGcStabilization() then
		State.GcWarning = true
	end

	-- ── Compute Results ─────────────────────────────────────────────────
	-- Native Animator cost = Playing - Idle (isolates animation cost from rig presence cost)
	local NativeAnimatorCostMs = math.max(0, NativePlayingAvgMs - NativeIdleAvgMs)
	local NpcCount = State.NpcCount
	local NativePerNpcUs = if NpcCount > 0 then NativeAnimatorCostMs / NpcCount * 1000 else 0

	State.NativeStats = {
		AvgTotalMs = NativeAnimatorCostMs,
		PeakTotalMs = NativePlayingPeakMs,
		PerNpcUs = NativePerNpcUs,
		CurrentFps = NativePlayingFps,
		HeapKb = NativePlayingHeapKb,
	} :: BenchmarkTypes.NativeTimingSnapshot

	State.Timing = LunaTiming

	Logger.Info(
		`BenchmarkRunner: [Comparison] Complete — Luna Avg={string.format("%.2f", LunaTiming.AvgTotalMs)}ms, `
			.. `Native Animator Cost={string.format("%.2f", NativeAnimatorCostMs)}ms `
			.. `(Playing={string.format("%.2f", NativePlayingAvgMs)}ms - Idle={string.format("%.2f", NativeIdleAvgMs)}ms)`
	)

	State.TransitionState = "ComparisonDone"
	State.IsRunning = false
end

-- ── Automated Suite Runner ──────────────────────────────────────────────────

--[[
	Runs a matrix of benchmark configurations automatically, collecting timing
	snapshots for each. Spawned in a coroutine so UI stays responsive.
]]
local function RunAutomatedSuite()
	State.IsRunning = true
	State.GcWarning = false
	Collector.SetEnabled(Collector, true)

	local AnimTypes = { "Simple", "WalkCycle" }
	local NpcCounts = { 50, 100, 200 }
	local EvalModes = { "Sampled", "Live" }
	local IsolationModes = { "Full", "No Render", "No Apply", "No Eval" }

	local SuiteResults: { BenchmarkTypes.SuiteResult } = {}
	local ResultCount = 0
	local MeasureSeconds = BenchmarkConstants.DEFAULT_WINDOW_SECONDS

	local TotalConfigs = 0
	local CompletedConfigs = 0

	-- Pre-count total configs (excluding skipped combos) for progress logging
	for _, AnimType in AnimTypes do
		for _, _ in NpcCounts do
			for _, EvalMode in EvalModes do
				for _, IsolationMode in IsolationModes do
					-- Skip nonsensical combos
					local ShouldSkip = false
					if IsolationMode == "No Eval" and EvalMode == "Live" then
						ShouldSkip = true
					end
					if IsolationMode == "No Eval" and AnimType == "WalkCycle" then
						ShouldSkip = true
					end
					if not ShouldSkip then
						TotalConfigs += 1
					end
				end
			end
		end
	end

	Logger.Info(`BenchmarkRunner: [Suite] Starting automated suite with {TotalConfigs} configurations`)

	for _, AnimType in AnimTypes do
		for _, NpcCount in NpcCounts do
			for _, EvalMode in EvalModes do
				for _, IsolationMode in IsolationModes do
					-- Skip nonsensical combos:
					-- "No Eval" + "Live" — No Eval doesn't evaluate, eval mode irrelevant
					if IsolationMode == "No Eval" and EvalMode == "Live" then
						continue
					end
					-- "No Eval" + "WalkCycle" — only need one No Eval baseline, use Simple
					if IsolationMode == "No Eval" and AnimType == "WalkCycle" then
						continue
					end

					CompletedConfigs += 1
					Logger.Info(
						`BenchmarkRunner: [Suite] Config {CompletedConfigs}/{TotalConfigs} — `
							.. `Anim={AnimType} NPCs={NpcCount} Eval={EvalMode} Isolation={IsolationMode}`
					)

					-- Set State config fields
					State.NpcCount = NpcCount
					State.EvalMode = EvalMode
					State.IsolationMode = IsolationMode
					State.AnimationSource = {
						Kind = "Synthetic",
						SyntheticType = AnimType,
						KeyframeSequence = nil,
						AssetId = nil,
					}

					-- Spawn and start
					SpawnAndStart()

					-- Wait for warmup to complete (poll TransitionState)
					while State.TransitionState == "Respawning" or State.TransitionState == "WarmingUp" do
						RunService.RenderStepped:Wait()
					end

					-- Reset collector and measure for MeasureSeconds
					Collector.Reset(Collector)
					local MeasureStart = os.clock()
					while os.clock() - MeasureStart < MeasureSeconds do
						RunService.RenderStepped:Wait()
					end

					-- Collect TimingSnapshot and build SuiteResult
					local Snapshot = Collector.GetSnapshot(Collector)

					local ConfigRecord: BenchmarkTypes.SuiteResultConfig = {
						NpcCount = NpcCount,
						RigType = State.RigType,
						EvalMode = EvalMode,
						SampleRate = State.SampleRate,
						LayerCount = State.LayerCount,
						IsolationMode = IsolationMode,
						AnimationSourceKind = "Synthetic",
						SyntheticType = AnimType,
						LodEnabled = State.LodEnabled,
						LodPreset = if State.LodEnabled then State.LodPreset else nil,
					}

					ResultCount += 1
					SuiteResults[ResultCount] = {
						Config = ConfigRecord,
						Timing = Snapshot,
						NativeTiming = nil,
						GcWarning = false,
					}

					Logger.Info(
						`BenchmarkRunner: [Suite] Result — Avg={string.format("%.2f", Snapshot.AvgTotalMs)}ms `
							.. `Peak={string.format("%.2f", Snapshot.PeakTotalMs)}ms `
							.. `PerNpc={string.format("%.1f", Snapshot.PerNpcUs)}us`
					)

					-- Cleanup + cooldown
					NpcSpawner.Cleanup()
					LunaRuntimeWrapper.Reset()
					Collector.Reset(Collector)

					local IsStable = WaitForGcStabilization()
					if not IsStable then
						-- Mark the last result with GcWarning
						SuiteResults[ResultCount].GcWarning = true
						State.GcWarning = true
					end
				end
			end
		end
	end

	-- Store results and transition to idle
	State.SuiteResults = SuiteResults
	State.TransitionState = "Idle"
	State.IsRunning = false

	Logger.Info(`BenchmarkRunner: [Suite] Complete — {ResultCount} result(s) collected`)
end

-- ── Callback Wiring ─────────────────────────────────────────────────────────

State.RequestStart = function()
	if State.IsRunning then
		return
	end

	-- Sequential comparison mode: run the multi-phase comparison coroutine
	if State.IsComparisonMode and State.ComparisonMode == "Sequential" then
		task.spawn(RunSequentialComparison)
		return
	end

	State.IsRunning = true
	Collector.SetEnabled(Collector, true)
	SpawnAndStart()
end

State.RequestStop = function()
	CleanupBenchmark()
	Logger.Info("BenchmarkRunner: Stopped")
end

State.RequestConfigChange = function()
	if not State.IsRunning then
		return
	end

	-- Check if this is an LOD-only change (no respawn needed)
	-- The caller should set State.LodEnabled/LodPreset before calling this.
	-- For now, we always respawn on config change. LOD-only optimization
	-- can be added by panels that know they only changed LOD fields.
	Collector.SetEnabled(Collector, false)
	SpawnAndStart()
	Collector.SetEnabled(Collector, true)
end

State.RequestSnapshot = function()
	local Snapshot = Collector.GetSnapshot(Collector)
	if Snapshot.FrameCount == 0 then
		Logger.Warn("BenchmarkRunner: No timing data to snapshot")
		return
	end

	local LogEntry = string.format(
		"[%s] NPCs=%d Rig=%s Eval=%s Rate=%d Layers=%d | Avg=%.2fms Peak=%.2fms FPS=%.0f PerNpc=%.1fus",
		os.date("%H:%M:%S"),
		State.NpcCount,
		State.RigType,
		State.EvalMode,
		State.SampleRate,
		State.LayerCount,
		Snapshot.AvgTotalMs,
		Snapshot.PeakTotalMs,
		Snapshot.CurrentFps,
		Snapshot.PerNpcUs
	)

	table.insert(State.ComparisonLog, LogEntry)
	Logger.Info(`BenchmarkRunner: Snapshot recorded — {LogEntry}`)
end

State.RequestSaveBaseline = function()
	local Results: { BenchmarkTypes.SuiteResult } = {}

	if #State.SuiteResults > 0 then
		-- If suite results exist, save those
		Results = State.SuiteResults
	elseif State.Timing then
		-- If only current timing exists, save as single-entry suite
		local ConfigRecord: BenchmarkTypes.SuiteResultConfig = {
			NpcCount = State.NpcCount,
			RigType = State.RigType,
			EvalMode = State.EvalMode,
			SampleRate = State.SampleRate,
			LayerCount = State.LayerCount,
			IsolationMode = State.IsolationMode,
			AnimationSourceKind = State.AnimationSource.Kind,
			SyntheticType = State.AnimationSource.SyntheticType,
			LodEnabled = State.LodEnabled,
			LodPreset = if State.LodEnabled then State.LodPreset else nil,
		}

		Results = {
			{
				Config = ConfigRecord,
				Timing = State.Timing :: BenchmarkTypes.TimingSnapshot,
				NativeTiming = State.NativeStats,
				GcWarning = State.GcWarning,
			},
		}
	else
		Logger.Warn("BenchmarkRunner: RequestSaveBaseline — no timing data or suite results to save")
		return
	end

	BaselineStore.Save(Results, State.RunNote)
	local LoadedBaseline, LoadError = BaselineStore.Load()
	if LoadedBaseline then
		State.Baseline = LoadedBaseline
		Logger.Info(`BenchmarkRunner: Baseline saved and reloaded ({#Results} result(s))`)
	else
		Logger.Warn(`BenchmarkRunner: Baseline saved but reload failed — {tostring(LoadError)}`)
	end
end

State.RequestRunSuite = function()
	if State.IsRunning then
		return
	end
	task.spawn(RunAutomatedSuite)
end

-- ── Panel Discovery (after callbacks are wired) ─────────────────────────────

DiscoverPanels()

-- ── Iris Initialization ─────────────────────────────────────────────────────

-- Initialize Iris with no automatic cycle — we drive it from RenderStepped.
-- Passing false for eventConnection means we call Internal._cycle manually.
Iris.Init(nil, false)

-- Register the Iris render callback once. This function runs inside each _cycle call.
Iris:Connect(function()
	Iris.Window({ "Luna Benchmark" })

	if PanelCount == 0 then
		Iris.Text({ "No panels loaded. Add panel modules to Benchmark/Panels/." })
	else
		for PanelIndex = 1, PanelCount do
			local PanelDef = Panels[PanelIndex]
			Iris.SeparatorText({ PanelDef.Name })

			local RenderSuccess, RenderError = pcall(PanelDef.Render, Iris, State)
			if not RenderSuccess then
				Iris.Text({ `[Panel Error: {tostring(RenderError)}]` })
			end
		end
	end

	Iris.End()
end)

-- ── Main Loop ───────────────────────────────────────────────────────────────

local function OnRenderStepped(DeltaTime: number)
	local CurrentState = State.TransitionState

	-- ── State Machine: Warmup / Running ─────────────────────────────────

	if CurrentState == "WarmingUp" then
		-- Collect timing around Step for variance analysis (not reported as metrics)
		Collector.BeginFrame(Collector)
		LunaRuntimeWrapper.Step(DeltaTime)
		Collector.EndFrame(Collector)

		State.WarmupFrame += 1

		-- Check if warmup is complete
		local IsComplete = Collector.IsWarmupComplete(Collector)
		local IsMaxReached = State.WarmupFrame >= State.WarmupMaxFrames

		if IsComplete or IsMaxReached then
			Collector.Reset(Collector)
			State.TransitionState = "Running"
			Logger.Info(
				`BenchmarkRunner: Warmup complete after {State.WarmupFrame} frames`
					.. (if IsMaxReached then " (max reached)" else " (CV stable)")
			)
			State.WarmupFrame = 0
		end

	elseif CurrentState == "Running" or CurrentState == "ComparisonLuna" then
		-- Full measurement cycle: BeginFrame → Step → MarkEvalEnd → EndFrame
		-- Used for both normal running and the Luna phase of sequential comparison.
		Collector.BeginFrame(Collector)
		LunaRuntimeWrapper.Step(DeltaTime)
		Collector.MarkEvalEnd(Collector)
		Collector.EndFrame(Collector)

		-- Update SharedState.Timing from latest snapshot
		State.Timing = Collector.GetSnapshot(Collector)
	end

	-- States not listed above (Cooldown, ComparisonNativePlaying, ComparisonNativeIdle,
	-- ComparisonDone) require no per-frame work — their coroutines drive transitions.

	-- ── Iris Rendering ──────────────────────────────────────────────────
	-- Drive one Iris cycle. This calls all registered Iris:Connect callbacks.
	Iris.Internal._cycle(DeltaTime)
end

RunService.RenderStepped:Connect(OnRenderStepped)

Logger.Info("BenchmarkRunner: Initialized")
