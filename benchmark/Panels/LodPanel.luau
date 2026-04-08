--!strict

--[[
	LodPanel — LOD configuration and live stats panel for the benchmark harness.

	Controls:
	  - LOD Enable/Disable checkbox
	  - Preset selector: Quality / Default / Performance / Aggressive
	  - Debug overlay toggles: Tier Billboards, Frustum Visualization, Freecam
	  - Live tier distribution and savings stats (when LodStats is present)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")

local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

-- ============================================================================
-- [[ TYPES ]]
-- ============================================================================

type SharedState = BenchmarkTypes.SharedState

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

-- Persistent Iris state objects — created once in Init, reused each frame.
local __LodEnabledState: any = nil
local __TierBillboardsState: any = nil
local __FrustumVisState: any = nil
local __FreecamState: any = nil

-- ============================================================================
-- [[ PANEL ]]
-- ============================================================================

local LodPanel = {}

LodPanel.Name = "LOD"

function LodPanel.Init(State: SharedState)
	-- Pre-create Iris state objects with initial values from SharedState.
	-- These must be created outside the render loop so they persist across frames.
	-- We store them here; Render will use them each cycle.
	-- (Iris.State is created via Iris at render time when Init is not available,
	-- but since we have Init, we defer creation to first Render to have Iris in scope.)
	_ = State -- suppress unused warning; Init is called before first Render
end

function LodPanel.Render(Iris: any, State: SharedState)
	-- ── LOD Enable ──────────────────────────────────────────────────────────

	if not __LodEnabledState then
		__LodEnabledState = Iris.State(State.LodEnabled)
	end

	local LodCheckbox = Iris.Checkbox({ "Enable LOD" }, { isChecked = __LodEnabledState })
	if LodCheckbox.checked() or LodCheckbox.unchecked() then
		State.LodEnabled = __LodEnabledState:get()
		State.RequestConfigChange()
	end

	if not State.LodEnabled then
		return
	end

	-- ── LOD Preset Buttons ───────────────────────────────────────────────────

	Iris.Text({ "Preset:" })
	Iris.SameLine()
	for _, PresetName in { "Quality", "Default", "Performance", "Aggressive" } do
		local IsActive = State.LodPreset == PresetName
		if IsActive then
			Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
		end
		if Iris.SmallButton({ PresetName }).clicked() then
			State.LodPreset = PresetName
			State.RequestConfigChange()
		end
		if IsActive then
			Iris.PopConfig()
		end
	end
	Iris.End()

	-- ── Debug Overlays ───────────────────────────────────────────────────────

	local OverlayTree = Iris.Tree({ "Debug Overlays", false, false, false })
	if OverlayTree.state.isUncollapsed:get() then
		-- Tier Billboards
		if not __TierBillboardsState then
			__TierBillboardsState = Iris.State(false)
		end
		local BillboardCb = Iris.Checkbox({ "Tier Billboards" }, { isChecked = __TierBillboardsState })
		if BillboardCb.checked() or BillboardCb.unchecked() then
			-- Display toggle only — Task 15 wires actual billboard rendering
			_ = __TierBillboardsState:get()
		end

		-- Frustum Visualization
		if not __FrustumVisState then
			__FrustumVisState = Iris.State(false)
		end
		local FrustumCb = Iris.Checkbox({ "Frustum Visualization" }, { isChecked = __FrustumVisState })
		if FrustumCb.checked() or FrustumCb.unchecked() then
			-- Display toggle only — Task 15 wires actual frustum rendering
			_ = __FrustumVisState:get()
		end

		-- Freecam
		if not __FreecamState then
			__FreecamState = Iris.State(false)
		end
		local FreecamCb = Iris.Checkbox({ "Freecam" }, { isChecked = __FreecamState })
		if FreecamCb.checked() or FreecamCb.unchecked() then
			-- Display toggle only — Task 15 wires actual camera control
			_ = __FreecamState:get()
		end
	end
	Iris.End()

	-- ── Live LOD Stats ───────────────────────────────────────────────────────

	local LodStats = State.LodStats
	if not LodStats then
		return
	end

	Iris.SeparatorText({ "LOD Stats" })

	-- Tier distribution
	local TierCounts = LodStats.TierCounts
	Iris.SameLine()
	for TierIndex = 1, #TierCounts do
		local Count = TierCounts[TierIndex]
		local Color = BenchmarkConstants.TIER_COLORS[TierIndex] or BenchmarkConstants.COLOR_GRAY
		Iris.Text({ `T{TierIndex - 1}: {Count}`, false, Color })
	end
	Iris.End()

	-- Solver update counts
	Iris.Text({ `Updated: {LodStats.SolversUpdated} / {LodStats.TotalRegistered} solvers` })

	-- Savings
	local SavingsColor = if LodStats.SavingsPercent >= 50
		then BenchmarkConstants.COLOR_GREEN
		else if LodStats.SavingsPercent >= 20
			then BenchmarkConstants.COLOR_YELLOW
			else BenchmarkConstants.COLOR_RED
	Iris.Text({ `Savings: {string.format("%.0f", LodStats.SavingsPercent)}%`, false, SavingsColor })
end

return LodPanel
