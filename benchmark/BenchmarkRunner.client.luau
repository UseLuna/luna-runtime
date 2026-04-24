--!strict
--[[
	BenchmarkRunner — Orchestrator for the Luna Runtime benchmark.
	Drives a single Iris window (BenchmarkPanel), manages NPC spawning via
	NpcSpawner, and runs animation through LunaRuntimeWrapper via WrapperAdapter.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)
local Logger = require(LunaRuntime.Shared.Logger)

local Iris = require(LunaRuntime.Packages.iris)

local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")
local BenchmarkPanel = require(Benchmark.Panels.BenchmarkPanel)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

local Harness = Benchmark:WaitForChild("Harness")
local NpcSpawner = require(Harness.NpcSpawner)
local AnimationProvider = require(Harness.AnimationProvider)
local TimingCollectorModule = require(Harness.TimingCollector)
local WrapperAdapter = require(Harness.WrapperAdapter)
local ProfilerInjector = require(Harness.ProfilerInjector)

type BenchmarkConfig = BenchmarkTypes.BenchmarkConfig
type TimingSnapshot = BenchmarkTypes.TimingSnapshot
type TransitionState = BenchmarkTypes.TransitionState
type TimingCollector = TimingCollectorModule.TimingCollector

-- ============================================================================
-- [[ STATE ]]
-- ============================================================================

local __Collector: TimingCollector = TimingCollectorModule.new()
local __TransitionState: TransitionState = "Idle"
local __CurrentConfig: BenchmarkConfig? = nil
local __WarmupFrame: number = 0

-- ============================================================================
-- [[ HELPERS ]]
-- ============================================================================

local function __SetState(NewState: TransitionState)
	__TransitionState = NewState
	BenchmarkPanel.SetTransitionState(NewState)
end

--- Load animation from config source. Returns a LoadedAnimation or nil.
local function __LoadAnimation(Config: BenchmarkConfig): any
	local Source = Config.AnimationSource

	if Source.Kind == "Synthetic" then
		local SyntheticType = Source.SyntheticType or "WalkCycle"
		local Edit = AnimationProvider.GetSynthetic(SyntheticType, Config.RigType)
		return LunaRuntimeWrapper.FromEdit(Edit)
	elseif Source.Kind == "FromPlace" and Source.KeyframeSequence then
		return LunaRuntimeWrapper.FromKeyframeSequence(Source.KeyframeSequence :: KeyframeSequence)
	end

	Logger.Warn("BenchmarkRunner: Unsupported animation source")
	return nil
end

--- Compute track and bone counts for a loaded animation and rig type.
local function __ComputeCounts(Config: BenchmarkConfig, LoadedAnim: any): (number, number)
	local TrackCount = #LoadedAnim.Edit.Tracks
	local BoneCount = if Config.RigType == "R6" then 6 else 15
	return TrackCount * Config.NpcCount * Config.LayerCount, BoneCount * Config.NpcCount
end

-- ============================================================================
-- [[ START / STOP ]]
-- ============================================================================

local function __StartBenchmark()
	if __TransitionState ~= "Idle" then
		Logger.Warn("BenchmarkRunner: Cannot start — not idle")
		return
	end

	local Config = BenchmarkPanel.GetConfig()
	__CurrentConfig = Config
	__SetState("Respawning")

	-- Load animation
	local LoadedAnim = __LoadAnimation(Config)
	if not LoadedAnim then
		Logger.Warn("BenchmarkRunner: Failed to load animation — aborting")
		__SetState("Idle")
		return
	end

	-- Spawn NPC models via NpcSpawner (pcall to catch missing templates)
	local SpawnSuccess, SpawnResult = pcall(NpcSpawner.Spawn, {
		Count = Config.NpcCount,
		Density = Config.Density,
		RigType = Config.RigType,
		Variants = Config.RigVariants,
		IsolationMode = Config.IsolationMode,
	})

	if not SpawnSuccess then
		Logger.Warn(`BenchmarkRunner: Spawn failed — {tostring(SpawnResult)}`)
		__SetState("Idle")
		return
	end

	-- Setup rigs + animation via WrapperAdapter (uses LunaRuntimeWrapper internally)
	TimingCollectorModule.Reset(__Collector)
	local TotalTracks, TotalBones = __ComputeCounts(Config, LoadedAnim)
	TimingCollectorModule.SetCounts(__Collector, Config.NpcCount, TotalTracks, TotalBones)

	WrapperAdapter.Setup(SpawnResult.Models, LoadedAnim, Config, __Collector)

	-- Install profiler labels
	if BenchmarkConstants.DEBUG_PROFILING then
		ProfilerInjector.InstallCoarse()
		if BenchmarkConstants.DEBUG_PROFILING_GRANULAR then
			ProfilerInjector.InstallGranular()
		end
	end

	-- Transition to warmup
	__WarmupFrame = 0
	__SetState("WarmingUp")

	Logger.Info(`BenchmarkRunner: Started — {Config.NpcCount} {Config.RigType} NPCs, {Config.LayerCount} layers, {Config.EvalMode}`)
end

local function __StopBenchmark()
	if __TransitionState == "Idle" then
		return
	end

	WrapperAdapter.Teardown()
	NpcSpawner.Cleanup()

	__CurrentConfig = nil
	__SetState("Idle")

	Logger.Info("BenchmarkRunner: Stopped")
end

-- ============================================================================
-- [[ SNAPSHOT ]]
-- ============================================================================

local function __TakeSnapshot()
	local Timing = TimingCollectorModule.GetSnapshot(__Collector)
	local Config = __CurrentConfig
	if not Config then
		return
	end

	local NoteLabel = if Config.AnimationSource.SyntheticType
		then Config.AnimationSource.SyntheticType
		else "FromPlace"

	local Entry = string.format(
		"%s | %d %s | %s | x%d | %s | Avg %.2fms | Peak %.2fms | FPS %.0f",
		os.date("%H:%M:%S"),
		Config.NpcCount,
		Config.RigType,
		NoteLabel,
		Config.LayerCount,
		Config.IsolationMode,
		Timing.AvgTotalMs,
		Timing.PeakTotalMs,
		Timing.CurrentFps
	)

	BenchmarkPanel.AddSnapshotLog(Entry)
	Logger.Info(`Snapshot: {Entry}`)
end

-- ============================================================================
-- [[ PER-FRAME UPDATE ]]
-- ============================================================================

local function __OnRenderStepped(DeltaTime: number)
	if __TransitionState == "Idle" then
		return
	end

	local Config = __CurrentConfig
	if not Config then
		return
	end

	-- Run the instrumented step (eval + apply with timing marks)
	WrapperAdapter.Step(DeltaTime, Config.IsolationMode)

	-- Read timing snapshot
	local Timing = TimingCollectorModule.GetSnapshot(__Collector)
	local LodStats = WrapperAdapter.GetLodSnapshot()

	BenchmarkPanel.UpdateStats(Timing, LodStats, nil)

	-- Warmup detection
	if __TransitionState == "WarmingUp" then
		__WarmupFrame += 1
		if TimingCollectorModule.IsWarmupComplete(__Collector) then
			__SetState("Running")
			Logger.Info(`BenchmarkRunner: Warmup complete after {__WarmupFrame} frames`)
		elseif __WarmupFrame >= BenchmarkConstants.WARMUP_MAX_FRAMES then
			__SetState("Running")
			Logger.Warn(`BenchmarkRunner: Warmup timed out at {__WarmupFrame} frames`)
		end
	end
end

-- ============================================================================
-- [[ SCAN PLACE ANIMATIONS ]]
-- ============================================================================

local function __ScanPlaceAnimations()
	local Results = AnimationProvider.ScanPlaceAnimations()
	local Kfs: { KeyframeSequence } = {}
	for _, Item in Results do
		if typeof(Item) == "Instance" and Item:IsA("KeyframeSequence") then
			table.insert(Kfs, Item :: KeyframeSequence)
		end
	end
	BenchmarkPanel.SetPlaceAnimations(Kfs)
end

-- ============================================================================
-- [[ INITIALIZATION ]]
-- ============================================================================

-- Initialize Iris
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui")
Iris.Init(PlayerGui, nil, true)

-- Scan place animations on startup
__ScanPlaceAnimations()

-- Set up panel callbacks
BenchmarkPanel.SetCallbacks({
	OnStart = __StartBenchmark,
	OnStop = __StopBenchmark,
	OnSnapshot = __TakeSnapshot,
	OnSaveBaseline = function()
		__TakeSnapshot()
		Logger.Info("BenchmarkRunner: Baseline saved (snapshot logged)")
	end,
	OnRunSuite = function()
		Logger.Info("BenchmarkRunner: Automated suite not yet implemented")
	end,
})

-- Connect Iris render loop
Iris:Connect(function()
	BenchmarkPanel.Render(Iris)
end)

-- Connect per-frame update
RunService.RenderStepped:Connect(__OnRenderStepped)

Logger.Info("BenchmarkRunner: Initialized")
