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

-- ── Callback Wiring ─────────────────────────────────────────────────────────

State.RequestStart = function()
	if State.IsRunning then
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
	-- Stub: Task 17 wires this
	Logger.Info("BenchmarkRunner: RequestSaveBaseline — not yet implemented")
end

State.RequestRunSuite = function()
	-- Stub: Task 17 wires this
	Logger.Info("BenchmarkRunner: RequestRunSuite — not yet implemented")
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

	elseif CurrentState == "Running" then
		-- Full measurement cycle: BeginFrame → Step → MarkEvalEnd → EndFrame
		Collector.BeginFrame(Collector)
		LunaRuntimeWrapper.Step(DeltaTime)
		Collector.MarkEvalEnd(Collector)
		Collector.EndFrame(Collector)

		-- Update SharedState.Timing from latest snapshot
		State.Timing = Collector.GetSnapshot(Collector)

	elseif CurrentState == "Cooldown" then
		-- GC stabilization — stub for now (Task 16 fills in full logic)
		State.TransitionState = "Idle"

	elseif CurrentState == "ComparisonLuna"
		or CurrentState == "ComparisonNativePlaying"
		or CurrentState == "ComparisonNativeIdle"
		or CurrentState == "ComparisonDone"
	then
		-- Comparison phases — stub for now (Task 16 fills in full logic)
		-- Still step animation if running
		if State.IsRunning then
			LunaRuntimeWrapper.Step(DeltaTime)
		end
	end

	-- ── Iris Rendering ──────────────────────────────────────────────────
	-- Drive one Iris cycle. This calls all registered Iris:Connect callbacks.
	Iris.Internal._cycle(DeltaTime)
end

RunService.RenderStepped:Connect(OnRenderStepped)

Logger.Info("BenchmarkRunner: Initialized")
