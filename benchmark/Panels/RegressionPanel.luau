--!strict

--[[
	RegressionPanel — Baseline snapshot system for regression detection.

	Supports saving/loading baselines, running the full suite, exporting,
	and showing per-config deltas against a saved baseline.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

local Harness = Benchmark:WaitForChild("Harness")
local BaselineStore = require(Harness.BaselineStore)

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local Logger = require(LunaRuntime.Shared.Logger)

-- ── Types ─────────────────────────────────────────────────────────────────────

type SharedState = BenchmarkTypes.SharedState
type SuiteResult = BenchmarkTypes.SuiteResult
type SuiteResultConfig = BenchmarkTypes.SuiteResultConfig

-- ── Constants ─────────────────────────────────────────────────────────────────

local COLOR_GREEN = BenchmarkConstants.COLOR_GREEN
local COLOR_YELLOW = BenchmarkConstants.COLOR_YELLOW
local COLOR_RED = BenchmarkConstants.COLOR_RED
local COLOR_GRAY = BenchmarkConstants.COLOR_GRAY
local COLOR_WHITE = BenchmarkConstants.COLOR_WHITE

local REGRESSION_NOISE_PERCENT = BenchmarkConstants.REGRESSION_NOISE_PERCENT
local REGRESSION_WARN_PERCENT = BenchmarkConstants.REGRESSION_WARN_PERCENT

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function ConfigsMatch(A: SuiteResultConfig, B: SuiteResultConfig): boolean
	return A.NpcCount == B.NpcCount
		and A.RigType == B.RigType
		and A.EvalMode == B.EvalMode
		and A.LayerCount == B.LayerCount
		and A.IsolationMode == B.IsolationMode
		and A.AnimationSourceKind == B.AnimationSourceKind
end

local function GetDeltaColor(DeltaPercent: number): Color3
	-- Negative delta = improvement (Luna got faster)
	if DeltaPercent < -REGRESSION_NOISE_PERCENT then
		return COLOR_GREEN
	elseif DeltaPercent <= REGRESSION_NOISE_PERCENT then
		return COLOR_WHITE
	elseif DeltaPercent <= REGRESSION_WARN_PERCENT then
		return COLOR_YELLOW
	else
		return COLOR_RED
	end
end

local function FindMatchingBaseline(Baseline: BenchmarkTypes.BaselineSnapshot, Config: SuiteResultConfig): SuiteResult?
	for _, BaselineResult in Baseline.Results do
		if ConfigsMatch(BaselineResult.Config, Config) then
			return BaselineResult
		end
	end
	return nil
end

-- ── Panel ─────────────────────────────────────────────────────────────────────

local RegressionPanel = {}
RegressionPanel.Name = "Regression"

function RegressionPanel.Init(State: SharedState)
	-- Load baseline from store on init
	local Snapshot, LoadError = BaselineStore.Load()
	if Snapshot then
		State.Baseline = Snapshot
		Logger.Info(`RegressionPanel.Init: baseline loaded ({#Snapshot.Results} result(s))`)
	else
		Logger.Debug(`RegressionPanel.Init: no baseline found — {tostring(LoadError)}`)
	end
end

function RegressionPanel.Render(Iris: any, State: SharedState)
	-- Run Note input
	local NoteState = Iris.State(State.RunNote)
	local NoteInput = Iris.InputText({ "Run Note", "Optional label for this run" }, { text = NoteState })
	if NoteInput.textChanged() then
		State.RunNote = NoteState:get()
	end

	-- Action buttons
	Iris.SameLine()
	do
		if Iris.Button({ "Save Baseline" }).clicked() then
			State.RequestSaveBaseline()
		end
		if Iris.Button({ "Clear Baseline" }).clicked() then
			BaselineStore.Clear()
			State.Baseline = nil
			Logger.Info("RegressionPanel: baseline cleared")
		end
	end
	Iris.End()

	Iris.SameLine()
	do
		if Iris.Button({ "Run Suite" }).clicked() then
			State.RequestRunSuite()
		end
		if Iris.Button({ "Export" }).clicked() then
			local Json = BaselineStore.Export()
			if Json ~= "" then
				local ExportValue = Instance.new("StringValue")
				ExportValue.Name = "BenchmarkExport"
				ExportValue.Value = Json
				ExportValue.Parent = ReplicatedStorage
				Logger.Info("RegressionPanel: exported baseline to ReplicatedStorage.BenchmarkExport")
			else
				Logger.Warn("RegressionPanel: nothing to export — no baseline stored")
			end
		end
	end
	Iris.End()

	-- Baseline info
	Iris.Separator()
	local Baseline = State.Baseline
	if Baseline then
		Iris.Text({
			string.format(
				"Baseline: %d result(s) | %s",
				#Baseline.Results,
				Baseline.Timestamp
			),
			nil,
			COLOR_GREEN,
		})
		if Baseline.Note ~= "" then
			Iris.Text({ `Note: {Baseline.Note}`, nil, COLOR_GREEN })
		end
	else
		Iris.Text({ "No baseline saved.", nil, COLOR_GRAY })
	end

	-- Delta table vs baseline
	local Timing = State.Timing
	if Baseline and Timing then
		-- Build a config from current State to match against baseline
		local CurrentConfig: SuiteResultConfig = {
			NpcCount = State.NpcCount,
			RigType = State.RigType,
			EvalMode = State.EvalMode,
			SampleRate = State.SampleRate,
			LayerCount = State.LayerCount,
			IsolationMode = State.IsolationMode,
			AnimationSourceKind = State.AnimationSource.Kind,
			SyntheticType = State.AnimationSource.SyntheticType,
			LodEnabled = State.LodEnabled,
			LodPreset = State.LodPreset,
		}

		local Match = FindMatchingBaseline(Baseline, CurrentConfig)
		if Match then
			local BaseMs = Match.Timing.AvgTotalMs
			local NowMs = Timing.AvgTotalMs
			local DeltaMs = NowMs - BaseMs
			local DeltaPercent = if BaseMs > 0 then (DeltaMs / BaseMs) * 100 else 0

			local DeltaColor = GetDeltaColor(DeltaPercent)
			local DeltaSign = if DeltaMs > 0 then "+" else ""

			Iris.Separator()
			Iris.Text({ "Delta vs Baseline" })

			Iris.Table({ 3, true, false, true, false })
			do
				Iris.SetHeaderColumnIndex(1)
				Iris.Text({ "Metric" })
				Iris.NextHeaderColumn()
				Iris.Text({ "Baseline" })
				Iris.NextHeaderColumn()
				Iris.Text({ "Now / Delta" })

				Iris.NextColumn()
				Iris.Text({ "Avg Total (ms):" })
				Iris.NextColumn()
				Iris.Text({ string.format("%.2f ms", BaseMs) })
				Iris.NextColumn()
				Iris.Text({
					string.format("%.2f ms (%s%.1f%%)", NowMs, DeltaSign, DeltaPercent),
					nil,
					DeltaColor,
				})

				local BasePerNpc = Match.Timing.PerNpcUs
				local NowPerNpc = Timing.PerNpcUs
				local DeltaPerNpc = NowPerNpc - BasePerNpc
				local DeltaPerNpcPct = if BasePerNpc > 0 then (DeltaPerNpc / BasePerNpc) * 100 else 0
				local DeltaPerNpcSign = if DeltaPerNpc > 0 then "+" else ""

				Iris.NextColumn()
				Iris.Text({ "Per NPC (us):" })
				Iris.NextColumn()
				Iris.Text({ string.format("%.1f us", BasePerNpc) })
				Iris.NextColumn()
				Iris.Text({
					string.format("%.1f us (%s%.1f%%)", NowPerNpc, DeltaPerNpcSign, DeltaPerNpcPct),
					nil,
					GetDeltaColor(DeltaPerNpcPct),
				})

				local BaseFps = Match.Timing.CurrentFps
				local NowFps = Timing.CurrentFps
				local DeltaFps = NowFps - BaseFps
				-- FPS: positive delta is improvement
				local DeltaFpsPct = if BaseFps > 0 then (DeltaFps / BaseFps) * 100 else 0
				local DeltaFpsSign = if DeltaFps > 0 then "+" else ""

				Iris.NextColumn()
				Iris.Text({ "FPS:" })
				Iris.NextColumn()
				Iris.Text({ string.format("%.0f", BaseFps) })
				Iris.NextColumn()
				-- Invert sign: FPS regression means we slowed down (negative delta = bad)
				Iris.Text({
					string.format("%.0f (%s%.1f%%)", NowFps, DeltaFpsSign, DeltaFpsPct),
					nil,
					GetDeltaColor(-DeltaFpsPct),
				})
			end
			Iris.End()
		else
			Iris.Text({ "No matching baseline config for current settings.", nil, COLOR_GRAY })
		end
	end

	-- Snapshot Log
	Iris.Separator()
	local LogTree = Iris.Tree({ "Snapshot Log", false, false, false })
	if LogTree.state.isUncollapsed.value then
		local Log = State.ComparisonLog
		local LogCount = #Log
		if LogCount == 0 then
			Iris.Text({ "No snapshots recorded.", nil, COLOR_GRAY })
		else
			-- Show newest first
			for Index = LogCount, 1, -1 do
				Iris.Text({ Log[Index], nil, COLOR_GRAY })
			end
		end
	end
	Iris.End()
end

return RegressionPanel
