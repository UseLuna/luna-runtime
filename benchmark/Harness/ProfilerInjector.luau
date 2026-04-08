--!strict

--[[
	ProfilerInjector — Two-tier MicroProfiler label injection for Luna benchmarking.

	Tier 1 (Coarse): Wraps top-level per-frame/per-rig functions. Negligible overhead.
	  - LunaRuntimeWrapper.Step         → "Luna:Step"
	  - SolverLodManager.Step           → "Luna:LOD"
	  - AnimationSolver.Evaluate        → "Luna:Evaluate"
	  - AnimationSolver.Apply           → "Luna:Apply"
	  - AnimationSolver.Update          → "Luna:Solver:Update"

	Tier 2 (Granular): Wraps per-operation functions called thousands of times per frame.
	  Distorts timings — use only for profiling call sites, not wall-clock measurement.
	  - Curves.RemapAlpha               → "Luna:Eval:Bezier"
	  - Quaternion.Slerp                → "Luna:Eval:Slerp"
	  - Quaternion.Nlerp                → "Luna:Eval:Nlerp"
	  - SearchUtils.FindLastAtOrBefore  → "Luna:Eval:BinarySearch"
	  - Evaluator.EvaluateTrackInto     → "Luna:Eval:TrackInto"

	Guards against double-installation. InstallGranular() implies InstallCoarse().
	IsGranularActive() allows callers (e.g. TimingPanel) to surface a warning.
]]

local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")

local LunaRuntimeWrapper = require(LunaRuntime.Solver.LunaRuntimeWrapper)
local SolverLodManager   = require(LunaRuntime.Solver.SolverLodManager)
local AnimationSolver    = require(LunaRuntime.Solver.AnimationSolver)
local Curves             = require(LunaRuntime.Core.Curves)
local Quaternion         = require(LunaRuntime.Core.Quaternion)
local SearchUtils        = require(LunaRuntime.Core.SearchUtils)
local Evaluator          = require(LunaRuntime.Core.Evaluator)

-- ── Private State ────────────────────────────────────────────────────────────

-- Tracks whether each tier has been installed to prevent double-patching.
local __IsCoarseInstalled: boolean   = false
local __IsGranularInstalled: boolean = false

-- Stores original function references keyed by "ModuleName.FunctionName".
-- Retained for potential future uninstall support and debugging.
local __OriginalFunctions: { [string]: (...any) -> ...any } = {}

-- ── Internal Helpers ─────────────────────────────────────────────────────────

--[[
	Replaces Module[FunctionName] with a wrapper that calls debug.profilebegin/end
	around the original function. The original is stored in __OriginalFunctions.

	No-ops silently if the function does not exist on the module, so callers do
	not need to guard existence checks externally.
]]
local function WrapFunction(Module: { [string]: any }, ModuleName: string, FunctionName: string, Label: string)
	local Original = Module[FunctionName]
	if not Original then
		return
	end

	local Key = `{ModuleName}.{FunctionName}`
	__OriginalFunctions[Key] = Original

	Module[FunctionName] = function(...)
		debug.profilebegin(Label)
		local Results = table.pack(Original(...))
		debug.profileend()
		return table.unpack(Results, 1, Results.n)
	end
end

-- ── Module ───────────────────────────────────────────────────────────────────

local ProfilerInjector = {}

--[[
	Installs Tier 1 (coarse) MicroProfiler labels on the top-level per-frame
	and per-rig functions. Safe to call multiple times — subsequent calls are
	no-ops.
]]
function ProfilerInjector.InstallCoarse()
	if __IsCoarseInstalled then
		return
	end
	__IsCoarseInstalled = true

	WrapFunction(LunaRuntimeWrapper, "LunaRuntimeWrapper", "Step",     "Luna:Step")
	WrapFunction(SolverLodManager,   "SolverLodManager",   "Step",     "Luna:LOD")
	WrapFunction(AnimationSolver,    "AnimationSolver",    "Evaluate", "Luna:Evaluate")
	WrapFunction(AnimationSolver,    "AnimationSolver",    "Apply",    "Luna:Apply")
	WrapFunction(AnimationSolver,    "AnimationSolver",    "Update",   "Luna:Solver:Update")
end

--[[
	Installs Tier 2 (granular) MicroProfiler labels on per-operation functions
	that fire thousands of times per frame. Also installs Tier 1 if not already
	installed.

	WARNING: Granular labels significantly distort wall-clock timings due to
	the overhead of debug.profilebegin/end at high call rates. Use only for
	call-site profiling, not for performance measurement.

	Safe to call multiple times — subsequent calls are no-ops.
]]
function ProfilerInjector.InstallGranular()
	-- Coarse must be in place before granular.
	ProfilerInjector.InstallCoarse()

	if __IsGranularInstalled then
		return
	end
	__IsGranularInstalled = true

	WrapFunction(Curves,       "Curves",       "RemapAlpha",          "Luna:Eval:Bezier")
	WrapFunction(Quaternion,   "Quaternion",   "Slerp",               "Luna:Eval:Slerp")
	WrapFunction(Quaternion,   "Quaternion",   "Nlerp",               "Luna:Eval:Nlerp")
	WrapFunction(SearchUtils,  "SearchUtils",  "FindLastAtOrBefore",  "Luna:Eval:BinarySearch")
	WrapFunction(Evaluator,    "Evaluator",    "EvaluateTrackInto",   "Luna:Eval:TrackInto")
end

--[[
	Returns true when Tier 2 (granular) labels are active. Used by TimingPanel
	to surface a warning that wall-clock measurements are unreliable.
]]
function ProfilerInjector.IsGranularActive(): boolean
	return __IsGranularInstalled
end

return ProfilerInjector
