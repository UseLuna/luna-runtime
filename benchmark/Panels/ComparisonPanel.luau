--!strict

--[[
	ComparisonPanel — Luna vs Roblox native head-to-head comparison.

	Shows a timing results table with x-factor color coding, mode selector,
	enable toggle, GC warnings, and a collapsible Limitations section.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

-- ── Types ─────────────────────────────────────────────────────────────────────

type SharedState = BenchmarkTypes.SharedState

-- ── Constants ─────────────────────────────────────────────────────────────────

local COLOR_GREEN = BenchmarkConstants.COLOR_GREEN
local COLOR_YELLOW = BenchmarkConstants.COLOR_YELLOW
local COLOR_RED = BenchmarkConstants.COLOR_RED
local COLOR_GRAY = BenchmarkConstants.COLOR_GRAY
local COLOR_ORANGE = BenchmarkConstants.COLOR_ORANGE
local COLOR_WHITE = BenchmarkConstants.COLOR_WHITE

local FACTOR_PARITY_MAX = BenchmarkConstants.FACTOR_PARITY_MAX
local FACTOR_ACCEPTABLE_MAX = BenchmarkConstants.FACTOR_ACCEPTABLE_MAX

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function GetFactorColor(Factor: number): Color3
	if Factor <= FACTOR_PARITY_MAX then
		return COLOR_GREEN
	elseif Factor <= FACTOR_ACCEPTABLE_MAX then
		return COLOR_YELLOW
	else
		return COLOR_RED
	end
end

local function FormatDelta(Delta: number, Unit: string): string
	if Delta > 0 then
		return string.format("+%.2f%s", Delta, Unit)
	else
		return string.format("%.2f%s", Delta, Unit)
	end
end

-- ── Panel ─────────────────────────────────────────────────────────────────────

local ComparisonPanel = {}
ComparisonPanel.Name = "Comparison"

function ComparisonPanel.Render(Iris: any, State: SharedState)
	-- Synthetic animation warning
	if State.AnimationSource.Kind == "Synthetic" then
		Iris.Text({
			"Comparison unavailable with Synthetic animations. Use 'From Place' or 'Asset ID' source.",
			nil,
			COLOR_YELLOW,
		})
		return
	end

	-- GC warning
	if State.GcWarning then
		Iris.Text({
			"Warning: GC activity detected during comparison — results may be skewed.",
			nil,
			COLOR_ORANGE,
		})
	end

	-- Mode selector
	Iris.SameLine()
	do
		Iris.Text({ "Mode:" })
		if Iris.Button({ "Sequential" }).clicked() then
			State.ComparisonMode = "Sequential"
		end
		if Iris.Button({ "Simultaneous" }).clicked() then
			State.ComparisonMode = "Simultaneous"
		end
	end
	Iris.End()
	Iris.Text({ `  Active: {State.ComparisonMode}`, nil, COLOR_GRAY })

	-- Enable comparison checkbox
	local IsComparisonCheckbox = Iris.Checkbox({ "Enable Comparison" }, { isChecked = Iris.State(State.IsComparisonMode) })
	if IsComparisonCheckbox.checked() then
		State.IsComparisonMode = true
	elseif IsComparisonCheckbox.unchecked() then
		State.IsComparisonMode = false
	end

	-- Comparison progress
	local TransitionState = State.TransitionState
	if TransitionState == "ComparisonLuna" then
		Iris.Text({ "Running Luna phase...", nil, COLOR_YELLOW })
	elseif TransitionState == "ComparisonNativePlaying" then
		Iris.Text({ "Running Native phase (playing)...", nil, COLOR_YELLOW })
	elseif TransitionState == "ComparisonNativeIdle" then
		Iris.Text({ "Running Native phase (idle)...", nil, COLOR_YELLOW })
	elseif TransitionState == "ComparisonDone" then
		Iris.Text({ "Comparison complete.", nil, COLOR_GREEN })
	end

	-- Results table
	local Timing = State.Timing
	local NativeStats = State.NativeStats

	if Timing and NativeStats then
		local LunaMs = Timing.AvgTotalMs
		local NativeMs = NativeStats.AvgTotalMs
		local Factor = if NativeMs > 0 then LunaMs / NativeMs else 0

		local LunaPerNpcUs = Timing.PerNpcUs
		local NativePerNpcUs = NativeStats.PerNpcUs

		local LunaFps = Timing.CurrentFps
		local NativeFps = NativeStats.CurrentFps

		local FactorColor = GetFactorColor(Factor)

		Iris.Separator()
		Iris.Text({ "Results" })

		-- Table: header + 3 data rows, 5 columns
		Iris.Table({ 5, true, false, true, false })
		do
			-- Header row
			Iris.SetHeaderColumnIndex(1)
			Iris.Text({ "" })
			Iris.NextHeaderColumn()
			Iris.Text({ "Luna" })
			Iris.NextHeaderColumn()
			Iris.Text({ "Native" })
			Iris.NextHeaderColumn()
			Iris.Text({ "Factor" })
			Iris.NextHeaderColumn()
			Iris.Text({ "Delta" })

			-- Row 1: Anim cost (ms)
			Iris.NextColumn()
			Iris.Text({ "Anim cost (ms):" })
			Iris.NextColumn()
			Iris.Text({ string.format("%.2f", LunaMs) })
			Iris.NextColumn()
			Iris.Text({ string.format("%.2f", NativeMs) })
			Iris.NextColumn()
			Iris.Text({ string.format("%.2fx", Factor), nil, FactorColor })
			Iris.NextColumn()
			Iris.Text({ FormatDelta(LunaMs - NativeMs, "ms") })

			-- Row 2: Per NPC (us)
			Iris.NextColumn()
			Iris.Text({ "Per NPC (us):" })
			Iris.NextColumn()
			Iris.Text({ string.format("%.1f", LunaPerNpcUs) })
			Iris.NextColumn()
			Iris.Text({ string.format("%.1f", NativePerNpcUs) })
			Iris.NextColumn()
			local PerNpcFactor = if NativePerNpcUs > 0 then LunaPerNpcUs / NativePerNpcUs else 0
			Iris.Text({ string.format("%.2fx", PerNpcFactor), nil, GetFactorColor(PerNpcFactor) })
			Iris.NextColumn()
			Iris.Text({ FormatDelta(LunaPerNpcUs - NativePerNpcUs, "us") })

			-- Row 3: FPS (full)
			Iris.NextColumn()
			Iris.Text({ "FPS (full):" })
			Iris.NextColumn()
			Iris.Text({ string.format("%.0f", LunaFps) })
			Iris.NextColumn()
			Iris.Text({ string.format("%.0f", NativeFps) })
			Iris.NextColumn()
			-- FPS factor: inverse (higher FPS = better for Luna)
			local FpsFactor = if NativeFps > 0 then LunaFps / NativeFps else 0
			Iris.Text({ string.format("%.2fx", FpsFactor), nil, GetFactorColor(1 / math.max(FpsFactor, 0.001)) })
			Iris.NextColumn()
			Iris.Text({ FormatDelta(LunaFps - NativeFps, "") })
		end
		Iris.End()

		-- Summary line
		Iris.Separator()
		local IsFaster = Factor < 1
		local SummaryFactor = if IsFaster then 1 / math.max(Factor, 0.001) else Factor
		local SpeedWord = if IsFaster then "faster" else "slower"
		Iris.Text({
			string.format("Luna is %.2fx %s than Roblox native Animator.", SummaryFactor, SpeedWord),
			nil,
			FactorColor,
		})

		-- Heap disclaimer
		Iris.Text({
			"Note: gcinfo() only captures Luau heap, not C++ engine memory.",
			nil,
			COLOR_GRAY,
		})
	else
		Iris.Text({ "No comparison data yet. Enable Comparison and run a benchmark.", nil, COLOR_GRAY })
	end

	-- Limitations collapsible tree
	Iris.Separator()
	local LimitationsTree = Iris.Tree({ "Limitations", false, false, false })
	if LimitationsTree.state.isUncollapsed.value then
		Iris.Text({
			"- Native timing includes Roblox Animator C++ overhead not captured by Luau profiler.",
			nil,
			COLOR_GRAY,
		})
		Iris.Text({
			"- gcinfo() measures total Luau heap, not animation-specific allocations.",
			nil,
			COLOR_GRAY,
		})
		Iris.Text({
			"- Sequential mode introduces warm/cold cache effects between phases.",
			nil,
			COLOR_GRAY,
		})
		Iris.Text({
			"- Simultaneous mode may cause CPU contention affecting both measurements.",
			nil,
			COLOR_GRAY,
		})
		Iris.Text({
			"- FPS measurements include all render and script overhead, not just animation.",
			nil,
			COLOR_GRAY,
		})
	end
	Iris.End()
end

return ComparisonPanel
