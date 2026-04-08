--!strict

--[[
	TimingPanel — Live timing readout for the Luna benchmark harness.

	Displays FPS, per-phase timing breakdown, per-unit costs, heap usage,
	and granular profiler warnings. Provides Reset and Snapshot controls.
]]

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local ProfilerInjector = require(Benchmark.Harness.ProfilerInjector)

-- ── Types ────────────────────────────────────────────────────────────────────

type SharedState = BenchmarkTypes.SharedState
type TimingSnapshot = BenchmarkTypes.TimingSnapshot

-- ── Helpers ──────────────────────────────────────────────────────────────────

--[[
	Returns the color to use for a given FPS value.
	Green >= 60, Yellow >= 30, Red < 30.
]]
local function FpsColor(Fps: number): Color3
	if Fps >= 60 then
		return BenchmarkConstants.COLOR_GREEN
	elseif Fps >= 30 then
		return BenchmarkConstants.COLOR_YELLOW
	else
		return BenchmarkConstants.COLOR_RED
	end
end

-- ── Panel ────────────────────────────────────────────────────────────────────

local TimingPanel: BenchmarkTypes.Panel = {
	Name = "Timing",
}

-- ── Render ───────────────────────────────────────────────────────────────────

function TimingPanel.Render(Iris: any, State: SharedState)
	local Snapshot: TimingSnapshot? = State.Timing

	-- ── Granular Profiler Warning ─────────────────────────────────────────

	if ProfilerInjector.IsGranularActive() then
		Iris.Text({
			"WARNING: Granular profiler active — timings are distorted.",
			nil,
			BenchmarkConstants.COLOR_YELLOW,
		})
	end

	-- ── FPS Header ───────────────────────────────────────────────────────

	Iris.SeparatorText({ "FPS" })

	if Snapshot then
		local Fps = Snapshot.CurrentFps
		local FrameMs = if Fps > 0 then (1000 / Fps) else 0
		local FpsText = string.format("%.0f FPS (%.1fms)", Fps, FrameMs)
		Iris.Text({ FpsText, nil, FpsColor(Fps) })
	else
		Iris.Text({ "-- FPS", nil, BenchmarkConstants.COLOR_GRAY })
	end

	-- ── Timing Breakdown ─────────────────────────────────────────────────

	Iris.SeparatorText({ "Timing Breakdown" })

	if Snapshot then
		Iris.Text({
			string.format(
				"Eval:   avg %.3fms  peak %.3fms",
				Snapshot.AvgEvalMs,
				Snapshot.PeakEvalMs
			),
		})
		Iris.Text({
			string.format(
				"Apply:  avg %.3fms  peak %.3fms",
				Snapshot.AvgApplyMs,
				Snapshot.PeakApplyMs
			),
		})
		Iris.Text({
			string.format(
				"Total:  avg %.3fms  peak %.3fms",
				Snapshot.AvgTotalMs,
				Snapshot.PeakTotalMs
			),
		})

		-- Budget split
		Iris.Text({
			string.format(
				"Budget: Eval %.0f%%  |  Apply %.0f%%",
				Snapshot.EvalPercent,
				Snapshot.ApplyPercent
			),
			nil,
			BenchmarkConstants.COLOR_GRAY,
		})
	else
		Iris.Text({ "  No data — start the benchmark.", nil, BenchmarkConstants.COLOR_GRAY })
	end

	-- ── Per-Unit Costs ───────────────────────────────────────────────────

	Iris.SeparatorText({ "Per-Unit Costs" })

	if Snapshot then
		Iris.Text({
			string.format("Per Track: %.2f us", Snapshot.PerTrackUs),
		})
		Iris.Text({
			string.format("Per Motor: %.2f us", Snapshot.PerMotorUs),
		})
		Iris.Text({
			string.format("Per NPC:   %.2f us", Snapshot.PerNpcUs),
		})
		Iris.Text({
			string.format(
				"Heap: %.1f KB   Frames: %d",
				Snapshot.HeapKb,
				Snapshot.FrameCount
			),
			nil,
			BenchmarkConstants.COLOR_GRAY,
		})
	else
		Iris.Text({ "  No data.", nil, BenchmarkConstants.COLOR_GRAY })
	end

	-- ── Controls ─────────────────────────────────────────────────────────

	Iris.SeparatorText({ "Controls" })

	Iris.SameLine()
	do
		local ResetButton = Iris.Button({ "Reset" })
		if ResetButton.events.clicked() then
			State.RequestStop()
		end

		local SnapshotButton = Iris.Button({ "Snapshot" })
		if SnapshotButton.events.clicked() then
			State.RequestSnapshot()
		end
	end
	Iris.End()
end

return TimingPanel
