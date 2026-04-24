--!strict
--[[
	WrapperAdapter — Bridges NpcSpawner output to LunaRuntimeWrapper with
	instrumented Step that splits Evaluate/Apply for timing measurement.

	Uses LunaRuntimeWrapper for rig resolution and playback setup, but bypasses
	LunaRuntimeWrapper.Step() to insert TimingCollector marks between phases.
	Manages its own SolverLodManager instance for benchmark LOD control.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local AnimationSolver = require(LunaRuntime.Solver.AnimationSolver)
local SolverLodManager = require(LunaRuntime.Solver.SolverLodManager)
local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)
local Sampler = require(LunaRuntime.Core.Sampler)
local Logger = require(LunaRuntime.Shared.Logger)

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local TimingCollectorModule = require(Benchmark.Harness.TimingCollector)

type BenchmarkConfig = BenchmarkTypes.BenchmarkConfig
type LodSnapshot = BenchmarkTypes.LodSnapshot
type TimingCollector = TimingCollectorModule.TimingCollector

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

local WrapperAdapter = {}

local __Solvers: { any } = {}
local __SolverCount: number = 0
local __Handles: { any } = {}
local __HandleCount: number = 0
local __LodManager: any = nil
local __Collector: TimingCollector? = nil

-- ============================================================================
-- [[ SETUP ]]
-- ============================================================================

--[[
	Setup rigs on spawned models using LunaRuntimeWrapper.
	Models: array from NpcSpawner.Spawn().Models
	LoadedAnimation: from LunaRuntimeWrapper.FromEdit() or FromKeyframeSequence()
	Config: BenchmarkConfig for layer count, speed, weight, LOD, eval mode
	Collector: TimingCollector for instrumented Step
]]
function WrapperAdapter.Setup(
	Models: { Model },
	LoadedAnimation: any,
	Config: BenchmarkConfig,
	Collector: TimingCollector
)
	WrapperAdapter.Teardown()
	__Collector = Collector

	-- Shallow-copy to avoid mutating the caller's LoadedAnimation
	LoadedAnimation = {
		Name = LoadedAnimation.Name,
		Edit = LoadedAnimation.Edit,
		Runtime = LoadedAnimation.Runtime,
		Sampled = LoadedAnimation.Sampled,
	}

	-- Pre-bake sampled animation if in Sampled mode
	if Config.EvalMode == "Sampled" and LoadedAnimation.Sampled == nil then
		LoadedAnimation.Sampled = Sampler.BakeToSampled(LoadedAnimation.Runtime, Config.SampleRate)
	elseif Config.EvalMode == "Live" then
		LoadedAnimation.Sampled = nil
	end

	local Duration = LoadedAnimation.Runtime.Duration
	local NpcCount = #Models
	local LayerWeight = 1 / Config.LayerCount

	-- Pre-allocate
	__Solvers = table.create(NpcCount)
	__Handles = table.create(NpcCount * Config.LayerCount)
	__SolverCount = 0
	__HandleCount = 0

	for NpcIndex, Model in Models do
		-- Skip rig resolution for "No Eval" mode (models exist but no animation)
		if Config.IsolationMode == "No Eval" then
			continue
		end

		local Rig = LunaRuntimeWrapper.ResolveRig(Model)

		-- Play LayerCount layers per rig
		for LayerIndex = 1, Config.LayerCount do
			local Handle = LunaRuntimeWrapper.Play(Rig, LoadedAnimation, {
				Speed = Config.Speed,
				Weight = if Config.LayerCount > 1 then LayerWeight else Config.Weight,
				Looping = true,
			})

			-- Stagger TimePosition for varied motion across NPCs and layers
			local Stagger = ((NpcIndex - 1) * Config.LayerCount + (LayerIndex - 1))
				/ (NpcCount * Config.LayerCount)
			Handle.TimePosition = Stagger * Duration

			__HandleCount += 1
			__Handles[__HandleCount] = Handle
		end

		-- Cache solver reference for instrumented Step
		local Solver = LunaRuntimeWrapper.GetSolverUnsafe(Rig)
		if Solver then
			__SolverCount += 1
			__Solvers[__SolverCount] = Solver
		end
	end

	-- Setup LOD if enabled
	if Config.IsLodEnabled then
		__LodManager = SolverLodManager.new(Config.LodPreset)
		for I = 1, __SolverCount do
			local Solver = __Solvers[I]
			local RootPart = Solver._Binding and Solver._Binding.RootPart
			if RootPart then
				SolverLodManager.Register(__LodManager, Solver, RootPart)
			end
		end
	end

	Logger.Info(`WrapperAdapter: Setup {__SolverCount} solvers, {__HandleCount} handles, {Config.LayerCount} layers/rig`)
end

-- ============================================================================
-- [[ INSTRUMENTED STEP ]]
-- ============================================================================

--[[
	Instrumented update loop that splits Evaluate and Apply with timing marks.
	Bypasses LunaRuntimeWrapper.Step() to insert TimingCollector boundaries.
]]
function WrapperAdapter.Step(DeltaTime: number, IsolationMode: string)
	local Collector = __Collector
	if not Collector then
		return
	end

	TimingCollectorModule.BeginFrame(Collector)

	-- LOD step (if active)
	if __LodManager and __SolverCount > 0 then
		SolverLodManager.Step(__LodManager, DeltaTime)
	end

	-- Phase 1: Evaluate all solvers
	if IsolationMode ~= "No Eval" then
		for I = 1, __SolverCount do
			local Solver = __Solvers[I]
			local Tier = if __LodManager then SolverLodManager.GetTier(__LodManager, Solver) else nil
			AnimationSolver.Evaluate(Solver, DeltaTime, Tier)
		end
	end

	TimingCollectorModule.MarkEvalEnd(Collector)

	-- Phase 2: Apply all motor writes
	if IsolationMode ~= "No Apply" and IsolationMode ~= "No Eval" then
		for I = 1, __SolverCount do
			AnimationSolver.Apply(__Solvers[I])
		end
	end

	TimingCollectorModule.EndFrame(Collector)
end

-- ============================================================================
-- [[ LOD STATS ]]
-- ============================================================================

function WrapperAdapter.GetLodSnapshot(): LodSnapshot?
	if not __LodManager then
		return nil
	end

	local TierCounts = SolverLodManager.GetTierCounts(__LodManager)
	local UpdateCount = SolverLodManager.GetLastUpdateCount(__LodManager)
	local TotalRegistered = SolverLodManager.GetEntryCount(__LodManager)
	local SavingsPercent = if TotalRegistered > 0
		then (1 - UpdateCount / TotalRegistered) * 100
		else 0

	return {
		TierCounts = TierCounts,
		SolversUpdated = UpdateCount,
		TotalRegistered = TotalRegistered,
		SavingsPercent = SavingsPercent,
	}
end

-- ============================================================================
-- [[ HANDLE CONTROL ]]
-- ============================================================================

function WrapperAdapter.SetAllSpeed(Speed: number)
	for I = 1, __HandleCount do
		__Handles[I].Speed = Speed
	end
end

function WrapperAdapter.SetAllWeight(Weight: number)
	for I = 1, __HandleCount do
		LunaRuntimeWrapper.SetWeight(__Handles[I], Weight)
	end
end

function WrapperAdapter.GetHandles(): { any }
	return __Handles
end

function WrapperAdapter.GetSolverCount(): number
	return __SolverCount
end

function WrapperAdapter.GetHandleCount(): number
	return __HandleCount
end

-- ============================================================================
-- [[ TEARDOWN ]]
-- ============================================================================

function WrapperAdapter.Teardown()
	if __LodManager then
		SolverLodManager.Destroy(__LodManager)
		__LodManager = nil
	end

	LunaRuntimeWrapper.Reset()

	table.clear(__Solvers)
	table.clear(__Handles)
	__SolverCount = 0
	__HandleCount = 0
	__Collector = nil

	Logger.Info("WrapperAdapter: Teardown complete")
end

return WrapperAdapter
