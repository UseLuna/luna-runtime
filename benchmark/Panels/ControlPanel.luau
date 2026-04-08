--!strict

--[[
	ControlPanel — Benchmark configuration panel.

	Renders all run parameters: NPC count, density, rig type, rig variants,
	animation source, eval mode, blend layers, isolation mode, quick presets,
	and the Start / Stop control.
]]

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

-- ── Types ────────────────────────────────────────────────────────────────────

type SharedState = BenchmarkTypes.SharedState

-- ── Panel ────────────────────────────────────────────────────────────────────

local ControlPanel: BenchmarkTypes.Panel = {
	Name = "Control",
}

-- ── Render ───────────────────────────────────────────────────────────────────

function ControlPanel.Render(Iris: any, State: SharedState)
	-- ── NPC & Layout ─────────────────────────────────────────────────────

	Iris.SeparatorText({ "NPC & Layout" })

	-- NpcCount
	do
		local NpcCountState = Iris.State(State.NpcCount)
		-- Sync from SharedState (e.g. after a preset is applied)
		if NpcCountState.value ~= State.NpcCount then
			NpcCountState:set(State.NpcCount)
		end
		local InputWidget = Iris.InputNum(
			{ "NPC Count", 1, 1, 2000 },
			{ number = NpcCountState }
		)
		if InputWidget.numberChanged() then
			State.NpcCount = NpcCountState.value
		end
	end

	-- Density
	do
		local DensityState = Iris.State(State.Density)
		if DensityState.value ~= State.Density then
			DensityState:set(State.Density)
		end
		local InputWidget = Iris.InputNum(
			{ "Density", 1, 1, 20 },
			{ number = DensityState }
		)
		if InputWidget.numberChanged() then
			State.Density = DensityState.value
		end
	end

	-- RigType
	Iris.Text({ "Rig Type" })
	Iris.SameLine()
	do
		local IsR6Active = State.RigType == "R6"
		if IsR6Active then
			Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
		end
		local R6Button = Iris.Button({ "R6" })
		if IsR6Active then
			Iris.PopConfig()
		end
		if R6Button.clicked() then
			State.RigType = "R6"
		end

		local IsR15Active = State.RigType == "R15"
		if IsR15Active then
			Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
		end
		local R15Button = Iris.Button({ "R15" })
		if IsR15Active then
			Iris.PopConfig()
		end
		if R15Button.clicked() then
			State.RigType = "R15"
		end
	end
	Iris.End()

	-- ── Rig Variants ─────────────────────────────────────────────────────

	Iris.Tree({ "Rig Variants", false, false, false })
	do
		-- MissingLimbPercent slider
		do
			local MissingState = Iris.State(State.RigVariants.MissingLimbPercent)
			if MissingState.value ~= State.RigVariants.MissingLimbPercent then
				MissingState:set(State.RigVariants.MissingLimbPercent)
			end
			local SliderWidget = Iris.SliderNum(
				{ "Missing Limb %", 1, 0, 100 },
				{ number = MissingState }
			)
			if SliderWidget.numberChanged() then
				local NewMissing = MissingState.value
				-- Clamp: MissingLimb + ToolEquipped must not exceed 100
				local ToolEquipped = State.RigVariants.ToolEquippedPercent
				if NewMissing + ToolEquipped > 100 then
					ToolEquipped = 100 - NewMissing
				end
				State.RigVariants = {
					MissingLimbPercent = NewMissing,
					ToolEquippedPercent = ToolEquipped,
					PristinePercent = 100 - NewMissing - ToolEquipped,
				}
			end
		end

		-- ToolEquippedPercent slider
		do
			local ToolState = Iris.State(State.RigVariants.ToolEquippedPercent)
			if ToolState.value ~= State.RigVariants.ToolEquippedPercent then
				ToolState:set(State.RigVariants.ToolEquippedPercent)
			end
			local SliderWidget = Iris.SliderNum(
				{ "Tool Equipped %", 1, 0, 100 },
				{ number = ToolState }
			)
			if SliderWidget.numberChanged() then
				local NewTool = ToolState.value
				-- Clamp: MissingLimb + ToolEquipped must not exceed 100
				local MissingLimb = State.RigVariants.MissingLimbPercent
				if MissingLimb + NewTool > 100 then
					MissingLimb = 100 - NewTool
				end
				State.RigVariants = {
					MissingLimbPercent = MissingLimb,
					ToolEquippedPercent = NewTool,
					PristinePercent = 100 - MissingLimb - NewTool,
				}
			end
		end

		-- Effective percentages and NPC counts
		local MissingPct = State.RigVariants.MissingLimbPercent
		local ToolPct = State.RigVariants.ToolEquippedPercent
		local PristinePct = State.RigVariants.PristinePercent
		local TotalNpcs = State.NpcCount

		local MissingCount = math.round(TotalNpcs * MissingPct / 100)
		local ToolCount = math.round(TotalNpcs * ToolPct / 100)
		local PristineCount = TotalNpcs - MissingCount - ToolCount

		Iris.Text({
			`  Pristine:     {PristinePct}% ({PristineCount} NPCs)`,
		})
		Iris.Text({
			`  MissingLimb:  {MissingPct}% ({MissingCount} NPCs)`,
		})
		Iris.Text({
			`  ToolEquipped: {ToolPct}% ({ToolCount} NPCs)`,
		})

		-- Unique fingerprints = distinct non-zero variant combinations
		local UniquePrints = 0
		if PristinePct > 0 then UniquePrints += 1 end
		if MissingPct > 0 then UniquePrints += 1 end
		if ToolPct > 0 then UniquePrints += 1 end

		Iris.Text({ `  {UniquePrints} unique fingerprint(s) expected` })
	end
	Iris.End()

	-- ── Animation ────────────────────────────────────────────────────────

	Iris.SeparatorText({ "Animation" })

	-- Source buttons
	Iris.Text({ "Source" })
	Iris.SameLine()
	do
		local Kinds: { string } = { "Synthetic", "FromPlace", "AssetId" }
		for _, Kind in Kinds do
			local IsActive = State.AnimationSource.Kind == Kind
			if IsActive then
				Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
			end
			local KindButton = Iris.Button({ Kind })
			if IsActive then
				Iris.PopConfig()
			end
			if KindButton.clicked() then
				local NewSource: BenchmarkTypes.AnimationSource = {
					Kind = Kind :: BenchmarkTypes.AnimationSourceKind,
					SyntheticType = if Kind == "Synthetic" then (State.AnimationSource.SyntheticType or "WalkCycle") else nil,
					KeyframeSequence = if Kind == "FromPlace" then State.AnimationSource.KeyframeSequence else nil,
					AssetId = if Kind == "AssetId" then State.AnimationSource.AssetId else nil,
				}
				State.AnimationSource = NewSource
			end
		end
	end
	Iris.End()

	-- Synthetic sub-type buttons (only when source is Synthetic)
	if State.AnimationSource.Kind == "Synthetic" then
		Iris.Text({ "  Variant" })
		Iris.SameLine()
		do
			local SubTypes: { string } = { "Simple", "WalkCycle", "Heavy" }
			for _, SubType in SubTypes do
				local IsActive = State.AnimationSource.SyntheticType == SubType
				if IsActive then
					Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
				end
				local SubButton = Iris.Button({ SubType })
				if IsActive then
					Iris.PopConfig()
				end
				if SubButton.clicked() then
					State.AnimationSource = {
						Kind = "Synthetic",
						SyntheticType = SubType :: "Simple" | "WalkCycle" | "Heavy",
						KeyframeSequence = nil,
						AssetId = nil,
					}
				end
			end
		end
		Iris.End()
	end

	-- EvalMode
	Iris.Text({ "Eval Mode" })
	Iris.SameLine()
	do
		local Modes: { string } = { "Sampled", "Live" }
		for _, Mode in Modes do
			local IsActive = State.EvalMode == Mode
			if IsActive then
				Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
			end
			local ModeButton = Iris.Button({ Mode })
			if IsActive then
				Iris.PopConfig()
			end
			if ModeButton.clicked() then
				State.EvalMode = Mode
			end
		end
	end
	Iris.End()

	-- SampleRate (only when Sampled)
	if State.EvalMode == "Sampled" then
		local SampleRateState = Iris.State(State.SampleRate)
		if SampleRateState.value ~= State.SampleRate then
			SampleRateState:set(State.SampleRate)
		end
		local SampleWidget = Iris.InputNum(
			{ "Sample Rate", 1, 1, 240 },
			{ number = SampleRateState }
		)
		if SampleWidget.numberChanged() then
			State.SampleRate = SampleRateState.value
		end
	end

	-- ── Blend ────────────────────────────────────────────────────────────

	Iris.SeparatorText({ "Blend" })

	do
		local LayerState = Iris.State(State.LayerCount)
		if LayerState.value ~= State.LayerCount then
			LayerState:set(State.LayerCount)
		end
		local LayerWidget = Iris.InputNum(
			{ "Layer Count", 1, 1, 16 },
			{ number = LayerState }
		)
		if LayerWidget.numberChanged() then
			State.LayerCount = LayerState.value
		end
	end

	-- ── Isolation Mode ───────────────────────────────────────────────────

	Iris.SeparatorText({ "Isolation Mode" })

	Iris.SameLine()
	do
		local IsoModes: { string } = { "Full", "No Render", "No Apply", "No Eval" }
		local IsoKeys: { string } = { "Full", "NoRender", "NoApply", "NoEval" }
		for Index = 1, 4 do
			local IsActive = State.IsolationMode == IsoKeys[Index]
			if IsActive then
				Iris.PushConfig({ ButtonColor = BenchmarkConstants.COLOR_CYAN })
			end
			local IsoButton = Iris.Button({ IsoModes[Index] })
			if IsActive then
				Iris.PopConfig()
			end
			if IsoButton.clicked() then
				State.IsolationMode = IsoKeys[Index]
			end
		end
	end
	Iris.End()

	-- ── Quick Presets ────────────────────────────────────────────────────

	Iris.SeparatorText({ "Quick Presets" })

	Iris.SameLine()
	do
		-- "100 R15 Walk"
		local Preset1 = Iris.Button({ "100 R15 Walk" })
		if Preset1.clicked() then
			State.NpcCount = 100
			State.RigType = "R15"
			State.EvalMode = "Sampled"
			State.SampleRate = 30
			State.LayerCount = 1
			State.IsolationMode = "Full"
			State.AnimationSource = {
				Kind = "Synthetic",
				SyntheticType = "WalkCycle",
				KeyframeSequence = nil,
				AssetId = nil,
			}
			State.RigVariants = {
				PristinePercent = 100,
				MissingLimbPercent = 0,
				ToolEquippedPercent = 0,
			}
		end

		-- "1000 R6 Simple"
		local Preset2 = Iris.Button({ "1000 R6 Simple" })
		if Preset2.clicked() then
			State.NpcCount = 1000
			State.RigType = "R6"
			State.EvalMode = "Sampled"
			State.SampleRate = 30
			State.LayerCount = 1
			State.IsolationMode = "Full"
			State.AnimationSource = {
				Kind = "Synthetic",
				SyntheticType = "Simple",
				KeyframeSequence = nil,
				AssetId = nil,
			}
			State.RigVariants = {
				PristinePercent = 100,
				MissingLimbPercent = 0,
				ToolEquippedPercent = 0,
			}
		end
	end
	Iris.End()

	Iris.SameLine()
	do
		-- "Stress Test"
		local Preset3 = Iris.Button({ "Stress Test" })
		if Preset3.clicked() then
			State.NpcCount = 2000
			State.RigType = "R15"
			State.EvalMode = "Sampled"
			State.SampleRate = 60
			State.LayerCount = 4
			State.IsolationMode = "Full"
			State.AnimationSource = {
				Kind = "Synthetic",
				SyntheticType = "Heavy",
				KeyframeSequence = nil,
				AssetId = nil,
			}
			State.RigVariants = {
				PristinePercent = 70,
				MissingLimbPercent = 20,
				ToolEquippedPercent = 10,
			}
		end

		-- "Cache Test"
		local Preset4 = Iris.Button({ "Cache Test" })
		if Preset4.clicked() then
			State.NpcCount = 500
			State.RigType = "R15"
			State.EvalMode = "Sampled"
			State.SampleRate = 30
			State.LayerCount = 1
			State.IsolationMode = "Full"
			State.AnimationSource = {
				Kind = "Synthetic",
				SyntheticType = "WalkCycle",
				KeyframeSequence = nil,
				AssetId = nil,
			}
			State.RigVariants = {
				PristinePercent = 50,
				MissingLimbPercent = 30,
				ToolEquippedPercent = 20,
			}
		end
	end
	Iris.End()

	-- ── Start / Stop ─────────────────────────────────────────────────────

	Iris.SeparatorText({ "Run" })

	if not State.IsRunning then
		local StartButton = Iris.Button({ "  Start  " })
		if StartButton.clicked() then
			State.RequestStart()
		end
	else
		-- Show transition state while stopping or warming up
		local TransitionLabel = State.TransitionState
		if TransitionLabel ~= "Running" then
			Iris.Text({ `State: {TransitionLabel}`, nil, BenchmarkConstants.COLOR_YELLOW })
		end

		local StopButton = Iris.Button({ "  Stop  " })
		if StopButton.clicked() then
			State.RequestStop()
		end
	end
end

return ControlPanel
