--!strict
--[[
	BenchmarkPanel — Single unified Iris panel for the Luna Runtime benchmark.
	Controls NPC spawning, animation config, LOD, isolation, and live stats.
	All state is module-level; the runner communicates via SetCallbacks/UpdateStats.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

type BenchmarkConfig = BenchmarkTypes.BenchmarkConfig
type TimingSnapshot = BenchmarkTypes.TimingSnapshot
type LodSnapshot = BenchmarkTypes.LodSnapshot
type NativeTimingSnapshot = BenchmarkTypes.NativeTimingSnapshot
type TransitionState = BenchmarkTypes.TransitionState

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local NPC_OPTIONS = BenchmarkConstants.NPC_OPTIONS
local LAYER_OPTIONS = BenchmarkConstants.LAYER_OPTIONS
local SAMPLE_RATE_OPTIONS = BenchmarkConstants.SAMPLE_RATE_OPTIONS
local LOD_PRESETS = BenchmarkConstants.LOD_PRESETS
local SYNTHETIC_TYPES = BenchmarkConstants.SYNTHETIC_TYPES
local ISOLATION_MODES = BenchmarkConstants.ISOLATION_MODES
local ISOLATION_DESCRIPTIONS = BenchmarkConstants.ISOLATION_DESCRIPTIONS
local PRESET_CONFIGS = BenchmarkConstants.PRESET_CONFIGS

local COLOR_GREEN = BenchmarkConstants.COLOR_GREEN
local COLOR_YELLOW = BenchmarkConstants.COLOR_YELLOW
local COLOR_RED = BenchmarkConstants.COLOR_RED
local COLOR_WHITE = BenchmarkConstants.COLOR_WHITE
local COLOR_GRAY = BenchmarkConstants.COLOR_GRAY
local TIER_COLORS = BenchmarkConstants.TIER_COLORS

-- ============================================================================
-- [[ MODULE STATE — Config ]]
-- ============================================================================

local __NpcCount = BenchmarkConstants.DEFAULT_NPC_COUNT
local __Density = BenchmarkConstants.DEFAULT_DENSITY
local __RigType = BenchmarkConstants.DEFAULT_RIG_TYPE
local __EvalMode = BenchmarkConstants.DEFAULT_EVAL_MODE
local __SampleRate = BenchmarkConstants.DEFAULT_SAMPLE_RATE
local __LayerCount = BenchmarkConstants.DEFAULT_LAYER_COUNT
local __IsolationMode = BenchmarkConstants.DEFAULT_ISOLATION_MODE
local __Speed: number = 1.0
local __Weight: number = 1.0

-- Animation source
local __AnimSourceKind: "Synthetic" | "FromPlace" = "Synthetic"
local __SyntheticType = "WalkCycle"
local __SelectedKfs: KeyframeSequence? = nil
local __PlaceAnimations: { KeyframeSequence } = {}
local __HasScannedAnims = false

-- LOD
local __IsLodEnabled = false
local __LodPreset = "Default"

-- Comparison
local __IsComparisonMode = false
local __ComparisonMode = "Sequential"

-- Rig variants
local __MissingLimbPercent: number = 0
local __ToolEquippedPercent: number = 0

-- ============================================================================
-- [[ MODULE STATE — Runtime ]]
-- ============================================================================

local __TransitionState: TransitionState = "Idle"
local __Timing: TimingSnapshot? = nil
local __LodStats: LodSnapshot? = nil
local __NativeStats: NativeTimingSnapshot? = nil
local __RunNote = ""
local __SnapshotLog: { string } = {}

-- ============================================================================
-- [[ CALLBACKS ]]
-- ============================================================================

local __OnStart: (() -> ())?
local __OnStop: (() -> ())?
local __OnSnapshot: (() -> ())?
local __OnSaveBaseline: (() -> ())?
local __OnRunSuite: (() -> ())?

-- Iris state refs (populated on first Render, used to sync presets)
local __IrisSpeedState: any = nil
local __IrisWeightState: any = nil
local __IrisDensityState: any = nil
local __IrisMissingLimbState: any = nil
local __IrisToolEquippedState: any = nil
local __IrisNoteState: any = nil
local __IrisLodCheckState: any = nil

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local BenchmarkPanel = {}

function BenchmarkPanel.SetCallbacks(Callbacks: {
	OnStart: (() -> ())?,
	OnStop: (() -> ())?,
	OnSnapshot: (() -> ())?,
	OnSaveBaseline: (() -> ())?,
	OnRunSuite: (() -> ())?,
})
	__OnStart = Callbacks.OnStart
	__OnStop = Callbacks.OnStop
	__OnSnapshot = Callbacks.OnSnapshot
	__OnSaveBaseline = Callbacks.OnSaveBaseline
	__OnRunSuite = Callbacks.OnRunSuite
end

function BenchmarkPanel.GetConfig(): BenchmarkConfig
	local Source: BenchmarkTypes.AnimationSource
	if __AnimSourceKind == "FromPlace" and __SelectedKfs then
		Source = {
			Kind = "FromPlace",
			SyntheticType = nil,
			KeyframeSequence = __SelectedKfs,
			AssetId = nil,
		}
	else
		Source = {
			Kind = "Synthetic",
			SyntheticType = __SyntheticType,
			KeyframeSequence = nil,
			AssetId = nil,
		}
	end

	return {
		NpcCount = __NpcCount,
		Density = __Density,
		RigType = __RigType,
		EvalMode = __EvalMode,
		SampleRate = __SampleRate,
		LayerCount = __LayerCount,
		Speed = __Speed,
		Weight = __Weight,
		IsolationMode = __IsolationMode,
		AnimationSource = Source,
		RigVariants = {
			PristinePercent = 100 - __MissingLimbPercent - __ToolEquippedPercent,
			MissingLimbPercent = __MissingLimbPercent,
			ToolEquippedPercent = __ToolEquippedPercent,
		},
		IsLodEnabled = __IsLodEnabled,
		LodPreset = __LodPreset,
		IsComparisonMode = __IsComparisonMode,
		ComparisonMode = __ComparisonMode,
	}
end

function BenchmarkPanel.UpdateStats(
	Timing: TimingSnapshot?,
	LodStats: LodSnapshot?,
	NativeStats: NativeTimingSnapshot?
)
	__Timing = Timing
	__LodStats = LodStats
	__NativeStats = NativeStats
end

function BenchmarkPanel.SetTransitionState(State: TransitionState)
	__TransitionState = State
end

function BenchmarkPanel.AddSnapshotLog(Entry: string)
	table.insert(__SnapshotLog, 1, Entry)
	-- Keep last 20 entries
	if #__SnapshotLog > 20 then
		__SnapshotLog[21] = nil
	end
end

function BenchmarkPanel.SetPlaceAnimations(Animations: { KeyframeSequence })
	__PlaceAnimations = Animations
	__HasScannedAnims = true
end

-- ============================================================================
-- [[ RENDER HELPERS ]]
-- ============================================================================

local function __IsRunning(): boolean
	return __TransitionState ~= "Idle" and __TransitionState ~= "Cooldown"
end

local function __ActiveButtonColor(): Color3
	return Color3.fromRGB(60, 120, 200)
end

--- Render a row of toggle buttons inside an existing SameLine block. Returns the selected value.
--- Caller MUST wrap in Iris.SameLine() / Iris.End().
local function __ButtonRow(Iris: any, Options: { any }, Current: any, FormatFn: ((any) -> string)?): any
	local Selected = Current
	for _, Option in Options do
		local Label = if FormatFn then FormatFn(Option) else tostring(Option)
		local IsActive = Current == Option
		if IsActive then
			Iris.PushConfig({ ButtonColor = __ActiveButtonColor() })
		end
		if Iris.SmallButton({ Label }).clicked() then
			Selected = Option
		end
		if IsActive then
			Iris.PopConfig()
		end
	end
	return Selected
end

--- Color code a number: green if good, yellow if okay, red if bad.
local function __FpsColor(Fps: number): Color3
	if Fps >= 55 then
		return COLOR_GREEN
	elseif Fps >= 30 then
		return COLOR_YELLOW
	end
	return COLOR_RED
end

local function __MsColor(Ms: number): Color3
	if Ms < 4 then
		return COLOR_GREEN
	elseif Ms < 10 then
		return COLOR_YELLOW
	end
	return COLOR_RED
end

local function __Fmt2(Value: number): string
	return string.format("%.2f", Value)
end

-- ============================================================================
-- [[ RENDER ]]
-- ============================================================================

function BenchmarkPanel.Render(Iris: any)
	local IsRunning = __IsRunning()

	Iris.Window({ "Luna Benchmark" })

	-- ── NPC Count ──────────────────────────────────────────────────────
	Iris.SeparatorText({ "NPC Count" })

	Iris.SameLine()
	local NewNpcCount = __ButtonRow(Iris, NPC_OPTIONS, __NpcCount)
	Iris.End()
	if NewNpcCount ~= __NpcCount and not IsRunning then
		__NpcCount = NewNpcCount
	end

	if not IsRunning then
		Iris.SameLine()
		Iris.Text({ "Density:" })
		local DensityState = Iris.State(__Density)
		__IrisDensityState = DensityState
		if DensityState:get() ~= __Density then
			DensityState:set(__Density)
		end
		local DensitySlider = Iris.SliderNum({ "##Density", 1, 3, 16 }, { number = DensityState })
		if DensitySlider.numberChanged() then
			__Density = DensityState:get()
		end
		Iris.End()
	end

	-- ── Rig Type ───────────────────────────────────────────────────────
	Iris.SeparatorText({ "Rig & Animation" })

	Iris.SameLine()
	local NewRigType = __ButtonRow(Iris, { "R6", "R15" }, __RigType)
	Iris.End()
	if NewRigType ~= __RigType and not IsRunning then
		__RigType = NewRigType
	end

	-- Animation source
	Iris.SameLine()
	Iris.Text({ "Source:" })
	local NewSourceKind = __ButtonRow(Iris, { "Synthetic", "FromPlace" }, __AnimSourceKind)
	if NewSourceKind ~= __AnimSourceKind and not IsRunning then
		__AnimSourceKind = NewSourceKind :: any
	end
	Iris.End()

	if __AnimSourceKind == "Synthetic" then
		Iris.SameLine()
		local NewSynthType = __ButtonRow(Iris, SYNTHETIC_TYPES, __SyntheticType)
		Iris.End()
		if NewSynthType ~= __SyntheticType and not IsRunning then
			__SyntheticType = NewSynthType
		end
	else
		-- FromPlace: dropdown of KeyframeSequences in workspace.Animations
		if not __HasScannedAnims then
			Iris.Text({ "  (Scanning workspace.Animations...)" })
		elseif #__PlaceAnimations == 0 then
			Iris.PushConfig({ TextColor = COLOR_YELLOW })
			Iris.Text({ "  No KeyframeSequences in workspace.Animations" })
			Iris.PopConfig()
		else
			Iris.Combo({ "Animation##FromPlace" })
			for _, Kfs in __PlaceAnimations do
				local IsSelected = __SelectedKfs == Kfs
				if Iris.Selectable({ Kfs.Name, IsSelected }).clicked() then
					__SelectedKfs = Kfs
				end
			end
			Iris.End()
		end
	end

	-- Eval mode
	Iris.SameLine()
	Iris.Text({ "Eval:" })
	local NewEvalMode = __ButtonRow(Iris, { "Sampled", "Live" }, __EvalMode)
	if NewEvalMode ~= __EvalMode and not IsRunning then
		__EvalMode = NewEvalMode
	end
	Iris.End()

	if __EvalMode == "Sampled" then
		Iris.SameLine()
		Iris.Text({ "Rate:" })
		local NewRate = __ButtonRow(Iris, SAMPLE_RATE_OPTIONS, __SampleRate)
		if NewRate ~= __SampleRate and not IsRunning then
			__SampleRate = NewRate
		end
		Iris.End()
	end

	-- ── Blending ───────────────────────────────────────────────────────
	Iris.SeparatorText({ "Blending" })

	Iris.SameLine()
	Iris.Text({ "Layers:" })
	local NewLayerCount = __ButtonRow(Iris, LAYER_OPTIONS, __LayerCount)
	if NewLayerCount ~= __LayerCount and not IsRunning then
		__LayerCount = NewLayerCount
	end
	Iris.End()

	-- Speed slider
	local SpeedState = Iris.State(__Speed)
	__IrisSpeedState = SpeedState
	if SpeedState:get() ~= __Speed then
		SpeedState:set(__Speed)
	end
	local SpeedSlider = Iris.SliderNum({ "Speed", 0.01, 0.1, 5.0 }, { number = SpeedState })
	if SpeedSlider.numberChanged() then
		__Speed = SpeedState:get()
	end

	-- Weight slider
	local WeightState = Iris.State(__Weight)
	__IrisWeightState = WeightState
	if WeightState:get() ~= __Weight then
		WeightState:set(__Weight)
	end
	local WeightSlider = Iris.SliderNum({ "Weight", 0.01, 0.0, 1.0 }, { number = WeightState })
	if WeightSlider.numberChanged() then
		__Weight = WeightState:get()
	end

	-- ── Isolation ──────────────────────────────────────────────────────
	Iris.SeparatorText({ "Isolation" })

	Iris.SameLine()
	local NewIsolation = __ButtonRow(Iris, ISOLATION_MODES, __IsolationMode)
	Iris.End()
	if NewIsolation ~= __IsolationMode and not IsRunning then
		__IsolationMode = NewIsolation
	end

	Iris.PushConfig({ TextColor = COLOR_GRAY })
	Iris.Text({ `  {ISOLATION_DESCRIPTIONS[__IsolationMode] or ""}` })
	Iris.PopConfig()

	-- ── LOD ────────────────────────────────────────────────────────────
	Iris.SeparatorText({ "LOD" })

	local LodCheckState = Iris.State(__IsLodEnabled)
	__IrisLodCheckState = LodCheckState
	if LodCheckState:get() ~= __IsLodEnabled then
		LodCheckState:set(__IsLodEnabled)
	end
	local LodCheckbox = Iris.Checkbox({ "Enable LOD" }, { isChecked = LodCheckState })
	if LodCheckbox.checked() or LodCheckbox.unchecked() then
		__IsLodEnabled = LodCheckState:get()
	end

	if __IsLodEnabled then
		Iris.SameLine()
		local NewPreset = __ButtonRow(Iris, LOD_PRESETS, __LodPreset)
		Iris.End()
		if NewPreset ~= __LodPreset then
			__LodPreset = NewPreset
		end
	end

	-- ── Rig Variants (collapsible) ────────────────────────────────────
	if Iris.Tree({ "Rig Variants" }).state.isUncollapsed.value then
		local MlState = Iris.State(__MissingLimbPercent)
		__IrisMissingLimbState = MlState
		if MlState:get() ~= __MissingLimbPercent then
			MlState:set(__MissingLimbPercent)
		end
		local MlSlider = Iris.SliderNum({ "Missing Limb %", 1, 0, 50 }, { number = MlState })
		if MlSlider.numberChanged() then
			__MissingLimbPercent = MlState:get()
			if __MissingLimbPercent + __ToolEquippedPercent > 100 then
				__ToolEquippedPercent = 100 - __MissingLimbPercent
			end
		end

		local TeState = Iris.State(__ToolEquippedPercent)
		__IrisToolEquippedState = TeState
		if TeState:get() ~= __ToolEquippedPercent then
			TeState:set(__ToolEquippedPercent)
		end
		local TeSlider = Iris.SliderNum({ "Tool Equipped %", 1, 0, 50 }, { number = TeState })
		if TeSlider.numberChanged() then
			__ToolEquippedPercent = TeState:get()
			if __MissingLimbPercent + __ToolEquippedPercent > 100 then
				__MissingLimbPercent = 100 - __ToolEquippedPercent
			end
		end

		local PristinePercent = 100 - __MissingLimbPercent - __ToolEquippedPercent
		Iris.PushConfig({ TextColor = COLOR_GRAY })
		Iris.Text({ `  Pristine: {PristinePercent}%` })
		Iris.PopConfig()
	end
	Iris.End()

	-- ── Quick Presets ──────────────────────────────────────────────────
	Iris.SeparatorText({ "Quick Presets" })

	Iris.SameLine()
	for PresetName, PresetConfig in PRESET_CONFIGS do
		if Iris.SmallButton({ PresetName }).clicked() and not IsRunning then
			if PresetConfig.NpcCount then __NpcCount = PresetConfig.NpcCount end
			if PresetConfig.RigType then __RigType = PresetConfig.RigType end
			if PresetConfig.AnimationSourceKind then __AnimSourceKind = PresetConfig.AnimationSourceKind :: any end
			if PresetConfig.SyntheticType then __SyntheticType = PresetConfig.SyntheticType end
			if PresetConfig.EvalMode then __EvalMode = PresetConfig.EvalMode end
			if PresetConfig.SampleRate then __SampleRate = PresetConfig.SampleRate end
			if PresetConfig.LayerCount then __LayerCount = PresetConfig.LayerCount end
			if PresetConfig.MissingLimbPercent then __MissingLimbPercent = PresetConfig.MissingLimbPercent end
			if PresetConfig.ToolEquippedPercent then __ToolEquippedPercent = PresetConfig.ToolEquippedPercent end
		end
	end
	Iris.End()

	-- ── Controls ───────────────────────────────────────────────────────
	Iris.SeparatorText({ "Controls" })

	-- Config summary
	local SourceLabel = if __AnimSourceKind == "Synthetic"
		then __SyntheticType
		else (if __SelectedKfs then __SelectedKfs.Name else "none")
	local EvalLabel = if __EvalMode == "Sampled" then `Sampled@{__SampleRate}` else "Live"
	Iris.PushConfig({ TextColor = COLOR_GRAY })
	Iris.Text({ `  {__NpcCount} {__RigType} | {SourceLabel} | {EvalLabel} | x{__LayerCount} | {__IsolationMode}` })
	Iris.PopConfig()

	-- Start / Stop
	Iris.SameLine()
	if IsRunning then
		if Iris.Button({ "Stop" }).clicked() then
			if __OnStop then
				task.defer(__OnStop)
			end
		end
	else
		if Iris.Button({ "Start" }).clicked() then
			if __OnStart then
				task.defer(__OnStart)
			end
		end
	end

	if IsRunning then
		if Iris.SmallButton({ "Snapshot" }).clicked() then
			if __OnSnapshot then
				task.defer(__OnSnapshot)
			end
		end
	end

	if Iris.SmallButton({ "Save Baseline" }).clicked() then
		if __OnSaveBaseline then
			task.defer(__OnSaveBaseline)
		end
	end

	if not IsRunning then
		if Iris.SmallButton({ "Run Suite" }).clicked() then
			if __OnRunSuite then
				task.defer(__OnRunSuite)
			end
		end
	end
	Iris.End()

	-- Run note
	local NoteState = Iris.State(__RunNote)
	__IrisNoteState = NoteState
	if NoteState:get() ~= __RunNote then
		NoteState:set(__RunNote)
	end
	local NoteInput = Iris.InputText({ "Run Note" }, { text = NoteState })
	if NoteInput.textChanged() then
		__RunNote = NoteState:get()
	end

	-- Transition state indicator
	if __TransitionState ~= "Idle" then
		local StateColor = if __TransitionState == "Running" then COLOR_GREEN
			elseif __TransitionState == "WarmingUp" then COLOR_YELLOW
			else COLOR_GRAY
		Iris.PushConfig({ TextColor = StateColor })
		Iris.Text({ `  State: {__TransitionState}` })
		Iris.PopConfig()
	end

	-- ── Live Stats ─────────────────────────────────────────────────────
	if IsRunning and __Timing then
		local T = __Timing :: TimingSnapshot
		Iris.SeparatorText({ "Performance" })

		-- FPS
		Iris.PushConfig({ TextColor = __FpsColor(T.CurrentFps) })
		Iris.Text({ `FPS: {string.format("%.0f", T.CurrentFps)}` })
		Iris.PopConfig()

		-- Timing table
		Iris.Table({ 3 })

		Iris.NextHeaderColumn()
		Iris.Text({ "Metric" })
		Iris.NextHeaderColumn()
		Iris.Text({ "Avg (ms)" })
		Iris.NextHeaderColumn()
		Iris.Text({ "Peak (ms)" })

		-- Eval row
		Iris.NextColumn()
		Iris.Text({ "Eval" })
		Iris.NextColumn()
		Iris.PushConfig({ TextColor = __MsColor(T.AvgEvalMs) })
		Iris.Text({ __Fmt2(T.AvgEvalMs) })
		Iris.PopConfig()
		Iris.NextColumn()
		Iris.Text({ __Fmt2(T.PeakEvalMs) })

		-- Apply row
		Iris.NextColumn()
		Iris.Text({ "Apply" })
		Iris.NextColumn()
		Iris.PushConfig({ TextColor = __MsColor(T.AvgApplyMs) })
		Iris.Text({ __Fmt2(T.AvgApplyMs) })
		Iris.PopConfig()
		Iris.NextColumn()
		Iris.Text({ __Fmt2(T.PeakApplyMs) })

		-- Total row
		Iris.NextColumn()
		Iris.Text({ "Total" })
		Iris.NextColumn()
		Iris.PushConfig({ TextColor = __MsColor(T.AvgTotalMs) })
		Iris.Text({ __Fmt2(T.AvgTotalMs) })
		Iris.PopConfig()
		Iris.NextColumn()
		Iris.Text({ __Fmt2(T.PeakTotalMs) })

		Iris.End() -- Table

		-- Budget split
		Iris.PushConfig({ TextColor = COLOR_GRAY })
		Iris.Text({ `  Eval {string.format("%.0f", T.EvalPercent)}% | Apply {string.format("%.0f", T.ApplyPercent)}%` })
		Iris.PopConfig()

		-- Per-unit costs
		Iris.Text({ `  Per NPC: {__Fmt2(T.PerNpcUs)} us  |  Per Track: {__Fmt2(T.PerTrackUs)} us  |  Per Motor: {__Fmt2(T.PerMotorUs)} us` })

		-- Heap + frames
		Iris.PushConfig({ TextColor = COLOR_GRAY })
		Iris.Text({ `  Heap: {string.format("%.0f", T.HeapKb)} KB  |  Frames: {T.FrameCount}` })
		Iris.PopConfig()
	end

	-- ── LOD Stats ──────────────────────────────────────────────────────
	if IsRunning and __IsLodEnabled and __LodStats then
		local Lod = __LodStats :: LodSnapshot
		Iris.SeparatorText({ "LOD Stats" })

		-- Tier distribution
		Iris.SameLine()
		for TierIndex, Count in Lod.TierCounts do
			local TierColor = TIER_COLORS[TierIndex] or COLOR_WHITE
			Iris.PushConfig({ TextColor = TierColor })
			Iris.Text({ `T{TierIndex - 1}:{Count}` })
			Iris.PopConfig()
		end
		Iris.End()

		-- Updated / savings
		local SavingsColor = if Lod.SavingsPercent >= 50 then COLOR_GREEN
			elseif Lod.SavingsPercent >= 20 then COLOR_YELLOW
			else COLOR_RED
		Iris.Text({ `  Updated: {Lod.SolversUpdated} / {Lod.TotalRegistered}` })
		Iris.PushConfig({ TextColor = SavingsColor })
		Iris.Text({ `  Savings: {string.format("%.0f", Lod.SavingsPercent)}%` })
		Iris.PopConfig()
	end

	-- ── Comparison (collapsible) ───────────────────────────────────────
	if Iris.Tree({ "Comparison" }).state.isUncollapsed.value then
		local CompCheckState = Iris.State(__IsComparisonMode)
		local CompCheckbox = Iris.Checkbox({ "Enable Comparison" }, { isChecked = CompCheckState })
		if CompCheckbox.checked() or CompCheckbox.unchecked() then
			__IsComparisonMode = CompCheckState:get()
		end

		if __IsComparisonMode then
			if __AnimSourceKind == "Synthetic" then
				Iris.PushConfig({ TextColor = COLOR_YELLOW })
				Iris.Text({ "  Comparison unavailable for Synthetic animations" })
				Iris.PopConfig()
			else
				Iris.SameLine()
				local NewCompMode = __ButtonRow(Iris, { "Sequential", "Simultaneous" }, __ComparisonMode)
				Iris.End()
				if NewCompMode ~= __ComparisonMode then
					__ComparisonMode = NewCompMode
				end
			end
		end

		-- Native stats (if available)
		if __NativeStats then
			local N = __NativeStats :: NativeTimingSnapshot
			local T = __Timing
			if T then
				Iris.SeparatorText({ "Luna vs Native" })
				Iris.Table({ 3 })

				Iris.NextHeaderColumn()
				Iris.Text({ "Metric" })
				Iris.NextHeaderColumn()
				Iris.Text({ "Luna" })
				Iris.NextHeaderColumn()
				Iris.Text({ "Native" })

				Iris.NextColumn()
				Iris.Text({ "Avg (ms)" })
				Iris.NextColumn()
				Iris.Text({ __Fmt2(T.AvgTotalMs) })
				Iris.NextColumn()
				Iris.Text({ __Fmt2(N.AvgTotalMs) })

				Iris.NextColumn()
				Iris.Text({ "Per NPC (us)" })
				Iris.NextColumn()
				Iris.Text({ __Fmt2(T.PerNpcUs) })
				Iris.NextColumn()
				Iris.Text({ __Fmt2(N.PerNpcUs) })

				Iris.NextColumn()
				Iris.Text({ "FPS" })
				Iris.NextColumn()
				Iris.Text({ string.format("%.0f", T.CurrentFps) })
				Iris.NextColumn()
				Iris.Text({ string.format("%.0f", N.CurrentFps) })

				Iris.End() -- Table

				-- Factor summary
				if N.AvgTotalMs > 0 then
					local Factor = T.AvgTotalMs / N.AvgTotalMs
					local FactorColor = if Factor <= 1.1 then COLOR_GREEN
						elseif Factor <= 1.5 then COLOR_YELLOW
						else COLOR_RED
					local Label = if Factor <= 1.0
						then `Luna is {__Fmt2(1 / Factor)}x faster`
						else `Luna is {__Fmt2(Factor)}x slower`
					Iris.PushConfig({ TextColor = FactorColor })
					Iris.Text({ `  {Label}` })
					Iris.PopConfig()
				end
			end
		end
	end
	Iris.End() -- Tree: Comparison

	-- ── Snapshot History (collapsible) ─────────────────────────────────
	if #__SnapshotLog > 0 then
		if Iris.Tree({ "Snapshot History" }).state.isUncollapsed.value then
			for _, Entry in __SnapshotLog do
				Iris.PushConfig({ TextColor = COLOR_GRAY })
				Iris.Text({ Entry })
				Iris.PopConfig()
			end
		end
		Iris.End()
	end

	Iris.End() -- Window
end

return BenchmarkPanel
