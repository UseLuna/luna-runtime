--!strict
--!optimize 2
--!native
--[[
	SolverLodManager — batch-oriented LOD manager for AnimationSolvers.

	Reduces animation evaluation cost by throttling update rate based on distance,
	FOV, dot product, and viewport visibility. Fully opt-in.

	Usage:
		local Manager = SolverLodManager.new() -- uses "Default" preset
		SolverLodManager.Register(Manager, Solver, RootPart)
		-- Connect to RunService.PreAnimation (recommended) or Heartbeat:
		RunService.PreAnimation:Connect(function(DeltaTime)
			SolverLodManager.Step(Manager, DeltaTime)
		end)
]]

local Workspace = game:GetService("Workspace")

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local SolverTypes = require(Luna.Types.SolverTypes)
local Logger = require(Luna.Shared.Logger)
-- Note: we do NOT require AnimationSolver here. Step() calls Entry.Solver.Update()
-- via dot-syntax dispatch, which works with any object that has an Update method.
-- This avoids circular dependency and allows mock solvers in tests.

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type LodTierConfig = SolverTypes.LodTierConfig
type LodPreset = SolverTypes.LodPreset

-- ============================================================================
-- Constants
-- ============================================================================

local DEFAULT_VIEWPORT_PADDING = 0.15
local DEFAULT_RECALC_INTERVAL = 4
local REFERENCE_FOV = 70
local DOT_EDGE_THRESHOLD = 0.3
local DOT_EDGE_PENALTY = 1.5
local HYSTERESIS_PROMOTE = 0.95
local HYSTERESIS_DEMOTE = 1.05
local FAST_PROMOTE_MIN_TIER = 3

local DEFAULT_HALF_DISTANCE = 50
local DEFAULT_FACING_POWER = 0.5
local DEFAULT_COOLDOWN_PERIOD = 0.5
local DEFAULT_BONE_COST_ESTIMATE = 0.001
local CALIBRATION_FRAME_COUNT = 60
local RECALIBRATION_INTERVAL = 300
local RECALIBRATION_SAMPLE_COUNT = 10
local FPS_SHIFT_THRESHOLD = 0.2
local EMA_FAST_ALPHA = 0.3
local EMA_SLOW_ALPHA = 0.1
local QUALITY_FULL = 0
local QUALITY_REDUCED = 1
local QUALITY_LOW = 2
local QUALITY_MINIMAL = 3
local QUALITY_FROZEN = 4
local COST_RATIO_REDUCED = 0.3
local COST_RATIO_LOW = 0.1
local COST_RATIO_MINIMAL = 0.03
local FULL_UPDATE_INTERVAL = 0
local LOW_UPDATE_INTERVAL = 0.066
local MINIMAL_UPDATE_INTERVAL = 0.133
local FULL_MAX_LOD_TIER = math.huge
local REDUCED_MAX_LOD_TIER = 2
local LOW_MAX_LOD_TIER = 1
local MINIMAL_MAX_LOD_TIER = 0

-- Significance thresholds (raw, not normalized)
-- These are the BASE thresholds. Pressure multiplier adjusts them.
local DEFAULT_FULL_THRESHOLD = 0.4 -- significance >= this → Full (tier 1, every frame)
local DEFAULT_REDUCED_THRESHOLD = 0.2 -- significance >= this → Reduced (tier 2, ~30Hz)
local DEFAULT_LOW_THRESHOLD = 0.1 -- significance >= this → Low (tier 3, ~15Hz)
-- Below LOW_THRESHOLD → Minimal (tier 4, ~7.5Hz, base layer only)

-- Pressure adjustment
local PRESSURE_TIGHTEN_RATE = 0.03 -- per recalc when over budget
local PRESSURE_LOOSEN_RATE = 0.01 -- per recalc when under budget
local PRESSURE_MIN = 0.1 -- thresholds can't shrink below 10% of base
local PRESSURE_MAX = 3.0 -- thresholds can't grow above 300% of base
local BUDGET_TOLERANCE = 0.1 -- 10% tolerance band — don't adjust if within

-- ============================================================================
-- Local Types
-- ============================================================================

type LodEntry = {
	Solver: any,
	RootPart: BasePart,
	Tier: number,
	UpdateInterval: number,
	AccumulatedDt: number,
	MaxLodTier: number,
	EstimatedCostMs: number,
	SignificanceBoost: number,
	Significance: number,
	NormalizedSignificance: number,
	QualityLevel: number,
	LastQualityChangeTime: number,
	BoneCount: number,
}

-- ============================================================================
-- Module-level preset registry (shared across all manager instances)
-- ============================================================================

local PresetRegistry: StringIndexable<LodPreset> = {}

-- ============================================================================
-- Private helpers
-- ============================================================================

local function __ValidatePreset(Name: string, Config: LodPreset): boolean
	local Tiers = Config.Tiers
	if not Tiers or #Tiers == 0 then
		Logger.Error(`Preset "{Name}" has empty Tiers array`)
		return false
	end

	local PreviousMaxDistance = -1
	for Index = 1, #Tiers do
		local TierConfig = Tiers[Index]

		if TierConfig.MaxDistance <= PreviousMaxDistance then
			Logger.Error(
				`Preset "{Name}" tier {Index}: MaxDistance must be ascending (got {TierConfig.MaxDistance} after {PreviousMaxDistance})`
			)
			return false
		end

		if TierConfig.UpdateInterval < 0 then
			Logger.Error(`Preset "{Name}" tier {Index}: UpdateInterval must be >= 0 (got {TierConfig.UpdateInterval})`)
			return false
		end

		if TierConfig.MaxLodTier < 0 then
			Logger.Error(`Preset "{Name}" tier {Index}: MaxLodTier must be >= 0 (got {TierConfig.MaxLodTier})`)
			return false
		end

		PreviousMaxDistance = TierConfig.MaxDistance
	end

	local LastTier = Tiers[#Tiers]
	if LastTier.MaxDistance ~= math.huge then
		Logger.Error(`Preset "{Name}": last tier MaxDistance must be math.huge (got {LastTier.MaxDistance})`)
		return false
	end

	return true
end

local function __IsWithinPaddedViewport(
	ScreenPos: Vector3,
	ViewportSizeX: number,
	ViewportSizeY: number,
	Padding: number
): boolean
	local PadX = ViewportSizeX * Padding
	local PadY = ViewportSizeY * Padding
	return ScreenPos.X >= -PadX
		and ScreenPos.X <= ViewportSizeX + PadX
		and ScreenPos.Y >= -PadY
		and ScreenPos.Y <= ViewportSizeY + PadY
end

-- ============================================================================
-- SolverLodManager class
-- ============================================================================

local SolverLodManager = {}
SolverLodManager.__index = SolverLodManager

export type self = {
	_Entries: Array<LodEntry>,
	_EntryMap: StringIndexable<LodEntry>,
	_ActivePreset: LodPreset,
	_ActiveTiers: Array<LodTierConfig>,
	_ViewportPadding: number,
	_RecalcInterval: number,
	_FrameCount: number,
	_CachedCamPos: Vector3,
	_CachedTier1MaxDist: number,
	_OverrideCFrame: CFrame?,
	_OverrideFov: number?,
	_LastUpdateCount: number,
	_TierCountsCache: Array<number>,
	_IsAutoMode: boolean,
	_BudgetMs: number?,
	_BudgetFraction: number?,
	_IsCalibrating: boolean,
	_CalibrationSamples: Array<number>,
	_DetectedMaxFps: number,
	_IsRecalibrating: boolean,
	_RecalibrationSamples: Array<number>,
	_HalfDistance: number,
	_FacingPower: number,
	_CooldownPeriod: number,
	_CurrentTotalCostMs: number,
	_Pressure: number,
}

export type SolverLodManager = typeof(setmetatable({} :: self, SolverLodManager))

-- ============================================================================
-- Module-level functions (no self)
-- ============================================================================

function SolverLodManager.RegisterPreset(Name: string, Config: LodPreset)
	if not __ValidatePreset(Name, Config) then
		return
	end
	PresetRegistry[Name] = Config
	Logger.Info(`Registered LOD preset "{Name}" with {#Config.Tiers} tiers`)
end

function SolverLodManager.GetPreset(Name: string): LodPreset?
	return PresetRegistry[Name]
end

function SolverLodManager.BudgetFromFps(TargetFps: number, Fraction: number): number
	return (1000 / TargetFps) * Fraction
end

-- ============================================================================
-- Built-in presets
-- ============================================================================

-- UpdateInterval is in seconds: 0 = every frame, 0.033 = ~30Hz, 0.066 = ~15Hz, 0.133 = ~7.5Hz

SolverLodManager.RegisterPreset("Quality", {
	Tiers = {
		{ MaxDistance = 100, UpdateInterval = 0, MaxLodTier = math.huge }, -- every frame
		{ MaxDistance = 300, UpdateInterval = 0.033, MaxLodTier = 2 }, -- ~30Hz
		{ MaxDistance = math.huge, UpdateInterval = 0.066, MaxLodTier = 1 }, -- ~15Hz
	},
})

SolverLodManager.RegisterPreset("Default", {
	Tiers = {
		{ MaxDistance = 50, UpdateInterval = 0, MaxLodTier = math.huge }, -- every frame
		{ MaxDistance = 150, UpdateInterval = 0.033, MaxLodTier = 2 }, -- ~30Hz
		{ MaxDistance = 300, UpdateInterval = 0.066, MaxLodTier = 1 }, -- ~15Hz
		{ MaxDistance = math.huge, UpdateInterval = 0.133, MaxLodTier = 0 }, -- ~7.5Hz
	},
})

SolverLodManager.RegisterPreset("Performance", {
	Tiers = {
		{ MaxDistance = 30, UpdateInterval = 0, MaxLodTier = math.huge }, -- every frame
		{ MaxDistance = 80, UpdateInterval = 0.050, MaxLodTier = 2 }, -- ~20Hz
		{ MaxDistance = 150, UpdateInterval = 0.100, MaxLodTier = 1 }, -- ~10Hz
		{ MaxDistance = math.huge, UpdateInterval = 0.200, MaxLodTier = 0 }, -- ~5Hz
	},
})

SolverLodManager.RegisterPreset("Aggressive", {
	Tiers = {
		{ MaxDistance = 20, UpdateInterval = 0, MaxLodTier = math.huge }, -- every frame, very close only
		{ MaxDistance = 60, UpdateInterval = 0.066, MaxLodTier = 1 }, -- ~15Hz, base anim + important only
		{ MaxDistance = 120, UpdateInterval = 0.133, MaxLodTier = 0 }, -- ~7.5Hz, base anim only
		{ MaxDistance = math.huge, UpdateInterval = 0.250, MaxLodTier = 0 }, -- ~4Hz, bare minimum
	},
})

-- ============================================================================
-- Instance methods
-- ============================================================================

function SolverLodManager.new(PresetName: string?): SolverLodManager
	local ResolvedName = PresetName or "Default"
	local Preset = PresetRegistry[ResolvedName]

	if not Preset then
		Logger.Error(`LOD preset "{ResolvedName}" not found, falling back to "Default"`)
		ResolvedName = "Default"
		Preset = PresetRegistry["Default"]
	end

	local self = setmetatable({}, SolverLodManager) :: any

	self._Entries = {}
	self._EntryMap = {}
	self._ActivePreset = Preset
	self._ActiveTiers = Preset.Tiers
	self._ViewportPadding = Preset.ViewportPadding or DEFAULT_VIEWPORT_PADDING
	self._RecalcInterval = Preset.RecalcInterval or DEFAULT_RECALC_INTERVAL
	self._FrameCount = 0
	self._CachedCamPos = Vector3.zero
	self._CachedTier1MaxDist = Preset.Tiers[1].MaxDistance
	self._OverrideCFrame = nil
	self._OverrideFov = nil
	self._LastUpdateCount = 0
	self._TierCountsCache = { 0, 0, 0, 0, 0, 0 }
	self._IsAutoMode = false
	self._BudgetMs = nil
	self._BudgetFraction = nil
	self._IsCalibrating = false
	self._CalibrationSamples = {}
	self._DetectedMaxFps = 60
	self._IsRecalibrating = false
	self._RecalibrationSamples = {}
	self._HalfDistance = DEFAULT_HALF_DISTANCE
	self._FacingPower = DEFAULT_FACING_POWER
	self._CooldownPeriod = DEFAULT_COOLDOWN_PERIOD
	self._CurrentTotalCostMs = 0
	self._Pressure = 1.0 -- 1.0 = neutral, >1 = tighter thresholds, <1 = looser

	return self
end

function SolverLodManager.SetPreset(self: SolverLodManager, Name: string)
	local Preset = PresetRegistry[Name]
	if not Preset then
		Logger.Warn(`LOD preset "{Name}" not found, keeping current preset`)
		return
	end

	self._ActivePreset = Preset
	self._ActiveTiers = Preset.Tiers
	self._ViewportPadding = Preset.ViewportPadding or DEFAULT_VIEWPORT_PADDING
	self._RecalcInterval = Preset.RecalcInterval or DEFAULT_RECALC_INTERVAL
	self._CachedTier1MaxDist = Preset.Tiers[1].MaxDistance
	Logger.Info(`Switched LOD preset to "{Name}"`)
end

function SolverLodManager.SetOverrideCamera(self: SolverLodManager, OverrideCFrame: CFrame?, OverrideFov: number?)
	self._OverrideCFrame = OverrideCFrame
	self._OverrideFov = OverrideFov
end

function SolverLodManager.SetBudget(self: SolverLodManager, BudgetMs: number?)
	if BudgetMs then
		self._IsAutoMode = true
		self._BudgetMs = BudgetMs
	else
		self._IsAutoMode = false
		self._BudgetMs = nil
		self._BudgetFraction = nil
		self._IsCalibrating = false
	end
end

-- EXPERIMENTAL: Auto-budget dynamically calibrates from FPS. Works but thresholds
-- need tuning — can oscillate under pressure. Use SetBudget() with a fixed value
-- for production. See internal/shelved/ for disabled test files.
function SolverLodManager.SetAutoBudget(self: SolverLodManager, Fraction: number)
	self._IsAutoMode = true
	self._BudgetFraction = Fraction

	if self._DetectedMaxFps > 0 and not self._IsCalibrating then
		-- Already calibrated — just update the budget from the new fraction
		self._BudgetMs = (1000 / self._DetectedMaxFps) * Fraction
		Logger.Info(
			`Auto budget updated: {string.format("%.2f", self._BudgetMs)}ms ({math.floor(Fraction * 100)}% of {self._DetectedMaxFps} FPS)`
		)
	else
		-- First time — start calibration
		self._IsCalibrating = true
		self._CalibrationSamples = {}
		Logger.Info(`Auto budget mode: calibrating FPS over {CALIBRATION_FRAME_COUNT} frames (fraction: {Fraction})`)
	end
end

function SolverLodManager.SetSignificanceBoost(self: SolverLodManager, Solver: any, Boost: number?)
	local Key = tostring(Solver)
	local Entry = self._EntryMap[Key]
	if Entry then
		Entry.SignificanceBoost = Boost or 1.0
	end
end

function SolverLodManager.SetHalfDistance(self: SolverLodManager, HalfDistance: number)
	self._HalfDistance = HalfDistance
end

function SolverLodManager.SetFacingPower(self: SolverLodManager, Power: number)
	self._FacingPower = Power
end

function SolverLodManager.SetCooldownPeriod(self: SolverLodManager, Seconds: number)
	self._CooldownPeriod = Seconds
end

function SolverLodManager.GetBudgetMs(self: SolverLodManager): number?
	return self._BudgetMs
end

function SolverLodManager.GetCurrentCostMs(self: SolverLodManager): number
	return self._CurrentTotalCostMs
end

function SolverLodManager.GetSignificance(self: SolverLodManager, Solver: any): number
	local Key = tostring(Solver)
	local Entry = self._EntryMap[Key]
	if Entry then
		return Entry.Significance
	end
	return 0
end

function SolverLodManager.IsAutoMode(self: SolverLodManager): boolean
	return self._IsAutoMode
end

function SolverLodManager.Register(self: SolverLodManager, Solver: any, RootPart: BasePart)
	local Key = tostring(Solver)
	if self._EntryMap[Key] then
		Logger.Warn(`Solver already registered in LOD manager: {Key}`)
		return
	end

	-- Stagger initial AccumulatedDt so NPCs don't all update on the same frame
	local Interval = self._ActiveTiers[1].UpdateInterval
	local StaggeredDt = if Interval > 0 then math.random() * Interval else 0

	local Entry: LodEntry = {
		Solver = Solver,
		RootPart = RootPart,
		Tier = 1,
		UpdateInterval = Interval,
		AccumulatedDt = StaggeredDt,
		MaxLodTier = self._ActiveTiers[1].MaxLodTier,
		EstimatedCostMs = 0,
		SignificanceBoost = 1.0,
		Significance = 0,
		NormalizedSignificance = 0,
		QualityLevel = QUALITY_FULL,
		LastQualityChangeTime = 0,
		BoneCount = 0,
	}

	local SolverAny = Solver :: any
	if SolverAny._BoneCount then
		Entry.BoneCount = SolverAny._BoneCount
		Entry.EstimatedCostMs = Entry.BoneCount * DEFAULT_BONE_COST_ESTIMATE
	end

	table.insert(self._Entries, Entry)
	self._EntryMap[Key] = Entry
end

function SolverLodManager.Unregister(self: SolverLodManager, Solver: any)
	local Key = tostring(Solver)
	local Entry = self._EntryMap[Key]
	if not Entry then
		return
	end

	self._EntryMap[Key] = nil

	-- Remove from _Entries array
	local Entries = self._Entries
	for Index = #Entries, 1, -1 do
		if Entries[Index] == Entry then
			table.remove(Entries, Index)
			break
		end
	end
end

function SolverLodManager.GetTier(self: SolverLodManager, Solver: any): number
	local Key = tostring(Solver)
	local Entry = self._EntryMap[Key]
	if not Entry then
		return -1
	end
	return Entry.Tier
end

function SolverLodManager.GetEntryCount(self: SolverLodManager): number
	return #self._Entries
end

-- Returns tier counts: [1]=T0, [2]=T1, ..., [5]=T4+.
-- WARNING: Returns a reused internal table — do not cache across frames.
function SolverLodManager.GetTierCounts(self: SolverLodManager): Array<number>
	local Counts = self._TierCountsCache
	for Index = 1, 6 do
		Counts[Index] = 0
	end
	for _, Entry in self._Entries do
		local Bucket = math.clamp(Entry.Tier + 1, 1, 6)
		Counts[Bucket] += 1
	end
	return Counts
end

function SolverLodManager.GetLastUpdateCount(self: SolverLodManager): number
	return self._LastUpdateCount
end

function SolverLodManager.GetViewportPadding(self: SolverLodManager): number
	return self._ViewportPadding
end

-- Returns the largest finite MaxDistance from the active preset (for frustum visualization).
function SolverLodManager.GetMaxFiniteDistance(self: SolverLodManager): number
	local Tiers = self._ActiveTiers
	for Index = #Tiers, 1, -1 do
		if Tiers[Index].MaxDistance < math.huge then
			return Tiers[Index].MaxDistance
		end
	end
	return 300 -- fallback
end

function SolverLodManager.__RecalcTiers(self: SolverLodManager)
	-- 1. Get camera
	local Camera = Workspace.CurrentCamera
	if not Camera then
		return
	end

	-- 2. Read camera properties (GetRenderCFrame is VR-compatible)
	local CameraCFrame = self._OverrideCFrame or Camera:GetRenderCFrame()
	local CamPos = CameraCFrame.Position
	local LookVector = CameraCFrame.LookVector
	local FieldOfView = self._OverrideFov or Camera.FieldOfView
	local ViewportSize = Camera.ViewportSize

	-- 3. Compute FOV scale and cache values
	local FovScale = FieldOfView / REFERENCE_FOV
	local ViewportSizeX = ViewportSize.X
	local ViewportSizeY = ViewportSize.Y
	self._CachedCamPos = CamPos
	self._CachedTier1MaxDist = self._ActiveTiers[1].MaxDistance * FovScale

	local Tiers = self._ActiveTiers
	local TierCount = #Tiers
	local Padding = self._ViewportPadding
	local Entries = self._Entries

	-- 4. Recalculate tier for each entry
	for EntryIndex = 1, #Entries do
		local Entry = Entries[EntryIndex]
		local RootPart = Entry.RootPart

		-- Safety: skip if root part was destroyed
		if not RootPart or not RootPart.Parent then
			continue
		end

		local RigPos = RootPart.Position

		-- 4a. Viewport check FIRST
		local ScreenPos, _IsOnScreen = Camera:WorldToViewportPoint(RigPos)
		if ScreenPos.Z < 0 or not __IsWithinPaddedViewport(ScreenPos, ViewportSizeX, ViewportSizeY, Padding) then
			-- Off-screen → freeze at tier 0
			if Entry.Tier ~= 0 then
				Entry.Tier = 0
				Entry.MaxLodTier = 0
			end
			continue
		end

		-- 4b. Distance with FOV scaling
		local Delta = RigPos - CamPos
		local Distance = Delta.Magnitude * FovScale

		-- 4c. Dot product penalty for peripheral vision
		if Delta.Magnitude > 0.001 then
			local DotProduct = LookVector:Dot(Delta.Unit)
			if DotProduct < DOT_EDGE_THRESHOLD then
				Distance *= DOT_EDGE_PENALTY
			end
		end

		-- 4d. Map to tier with hysteresis
		local CurrentTier = Entry.Tier
		for TierIndex = 1, TierCount do
			local TierConfig = Tiers[TierIndex]
			local Threshold = TierConfig.MaxDistance

			-- Apply hysteresis (skip for math.huge — sentinel value)
			if Threshold ~= math.huge then
				if CurrentTier <= TierIndex then
					-- Already at or above this tier (lower number = higher fidelity) → harder to demote (push further out)
					Threshold *= HYSTERESIS_DEMOTE
				else
					-- Below this tier (worse fidelity) → easier to promote (pull closer in)
					Threshold *= HYSTERESIS_PROMOTE
				end
			end

			if Distance <= Threshold then
				local NewTier = TierIndex

				if NewTier ~= CurrentTier then
					Entry.Tier = NewTier
					-- On tier change, reset AccumulatedDt with random stagger
					-- to avoid all rigs in the same tier updating on the same frame
					local NewInterval = TierConfig.UpdateInterval
					Entry.AccumulatedDt = if NewInterval > 0 then math.random() * NewInterval else 0
				end

				Entry.UpdateInterval = TierConfig.UpdateInterval
				Entry.MaxLodTier = TierConfig.MaxLodTier
				break
			end
		end
	end
end

function SolverLodManager.__RecalcSignificance(self: SolverLodManager)
	-- 1. Get camera
	local Camera = Workspace.CurrentCamera
	if not Camera then
		return
	end

	-- 2. Read camera properties
	local CameraCFrame = self._OverrideCFrame or Camera:GetRenderCFrame()
	local CamPos = CameraCFrame.Position
	local LookVector = CameraCFrame.LookVector
	local FieldOfView = self._OverrideFov or Camera.FieldOfView
	local ViewportSize = Camera.ViewportSize

	-- 3. Compute FOV scale, cache values
	local FovScale = FieldOfView / REFERENCE_FOV
	local ViewportSizeX = ViewportSize.X
	local ViewportSizeY = ViewportSize.Y
	self._CachedCamPos = CamPos
	self._CachedTier1MaxDist = self._ActiveTiers[1].MaxDistance * FovScale

	local Entries = self._Entries
	local Padding = self._ViewportPadding
	local HalfDistance = self._HalfDistance
	local FacingPower = self._FacingPower

	-- 4. Calculate RAW significance for each entry (no normalization)
	for EntryIndex = 1, #Entries do
		local Entry = Entries[EntryIndex]
		local RootPart = Entry.RootPart

		if not RootPart or not RootPart.Parent then
			continue
		end

		local RigPos = RootPart.Position

		-- Viewport check
		local ScreenPos, _IsOnScreen = Camera:WorldToViewportPoint(RigPos)
		if ScreenPos.Z < 0 or not __IsWithinPaddedViewport(ScreenPos, ViewportSizeX, ViewportSizeY, Padding) then
			Entry.Tier = 0
			Entry.QualityLevel = QUALITY_FROZEN
			Entry.Significance = 0
			continue
		end

		-- Distance factor: 1/(1 + dist/halfDist) — raw [0, 1]
		local Delta = RigPos - CamPos
		local RawDistance = Delta.Magnitude
		local EffectiveDistance = RawDistance * FovScale
		local DistanceFactor = 1 / (1 + EffectiveDistance / HalfDistance)

		-- Facing factor: gentle penalty for peripheral NPCs
		-- Floor of 0.3 ensures NPCs on-screen always have meaningful significance
		-- The facing factor is a soft bonus for center-screen NPCs, not a harsh penalty for edges
		local FacingFactor = 0.3
		if RawDistance > 0.001 then
			local DotProduct = LookVector:Dot(Delta / RawDistance)
			local RawFacing = math.clamp(DotProduct, 0, 1) ^ FacingPower
			FacingFactor = 0.3 + RawFacing * 0.7 -- range: [0.3, 1.0]
		end

		-- Raw significance (NOT normalized) — range depends on distance and facing
		-- At 0 studs, facing camera: ~1.0
		-- At HalfDistance studs, facing camera: ~0.5
		-- At 3x HalfDistance studs, facing camera: ~0.25
		Entry.Significance = DistanceFactor * FacingFactor * Entry.SignificanceBoost
	end
end

-- ============================================================================
-- [[ AUTO MODE: THRESHOLD + PRESSURE QUALITY ASSIGNMENT ]]
-- ============================================================================
--
-- Instead of a greedy knapsack (which causes boundary flickering), we use:
-- 1. Significance thresholds to map each NPC to a quality level
-- 2. A pressure multiplier that slowly adjusts thresholds to fit the budget
--
-- Each NPC's quality depends ONLY on its own significance (stable), not on
-- the accumulated cost of every NPC before it (unstable).
-- Pressure adjusts slowly over many recalcs — no per-frame oscillation.

function SolverLodManager.__AssignQualityLevels(self: SolverLodManager)
	if not self._BudgetMs then
		return
	end

	local Entries = self._Entries
	local CooldownPeriod = self._CooldownPeriod
	local Now = os.clock()
	local BudgetMs = self._BudgetMs :: number
	local Pressure = self._Pressure

	-- Compute effective thresholds (base × pressure)
	-- Higher pressure = higher thresholds = fewer NPCs at Full = tighter
	local FullThreshold = DEFAULT_FULL_THRESHOLD * Pressure
	local ReducedThreshold = DEFAULT_REDUCED_THRESHOLD * Pressure
	local LowThreshold = DEFAULT_LOW_THRESHOLD * Pressure

	-- Assign quality based on raw significance vs thresholds
	local TotalEstimatedCost = 0
	for Index = 1, #Entries do
		local Entry = Entries[Index]

		-- Skip off-screen (significance = 0, frozen by __RecalcSignificance viewport check)
		if Entry.Significance <= 0 then
			continue
		end

		local Sig = Entry.Significance
		local NewQuality: number

		if Sig >= FullThreshold then
			NewQuality = QUALITY_FULL
		elseif Sig >= ReducedThreshold then
			NewQuality = QUALITY_REDUCED
		elseif Sig >= LowThreshold then
			NewQuality = QUALITY_LOW
		else
			NewQuality = QUALITY_MINIMAL
		end

		-- Asymmetric cooldown: downgrades instant, upgrades delayed
		if NewQuality < Entry.QualityLevel then
			-- Upgrade: check cooldown
			if Now - Entry.LastQualityChangeTime < CooldownPeriod then
				NewQuality = Entry.QualityLevel
			end
		end

		if NewQuality ~= Entry.QualityLevel then
			Entry.LastQualityChangeTime = Now
		end

		-- Apply quality
		Entry.QualityLevel = NewQuality
		if NewQuality == QUALITY_FULL then
			Entry.Tier = 1
			Entry.UpdateInterval = FULL_UPDATE_INTERVAL
			Entry.MaxLodTier = FULL_MAX_LOD_TIER
		elseif NewQuality == QUALITY_REDUCED then
			-- Continuous interval: lerp within Reduced band
			local Range = FullThreshold - ReducedThreshold
			local Position = if Range > 0.001 then (Sig - ReducedThreshold) / Range else 0.5
			Position = math.clamp(Position, 0, 1)
			Entry.Tier = 2
			Entry.UpdateInterval = LOW_UPDATE_INTERVAL + Position * (FULL_UPDATE_INTERVAL - LOW_UPDATE_INTERVAL)
			Entry.MaxLodTier = REDUCED_MAX_LOD_TIER
		elseif NewQuality == QUALITY_LOW then
			-- Continuous interval: lerp within Low band
			local Range = ReducedThreshold - LowThreshold
			local Position = if Range > 0.001 then (Sig - LowThreshold) / Range else 0.5
			Position = math.clamp(Position, 0, 1)
			Entry.Tier = 3
			Entry.UpdateInterval = MINIMAL_UPDATE_INTERVAL + Position * (LOW_UPDATE_INTERVAL - MINIMAL_UPDATE_INTERVAL)
			Entry.MaxLodTier = LOW_MAX_LOD_TIER
		elseif NewQuality == QUALITY_MINIMAL then
			Entry.Tier = 4
			Entry.UpdateInterval = MINIMAL_UPDATE_INTERVAL
			Entry.MaxLodTier = MINIMAL_MAX_LOD_TIER
		end

		-- Accumulate estimated cost for pressure feedback
		local CostFull = math.max(Entry.EstimatedCostMs, Entry.BoneCount * DEFAULT_BONE_COST_ESTIMATE)
		if NewQuality == QUALITY_FULL then
			TotalEstimatedCost += CostFull
		elseif NewQuality == QUALITY_REDUCED then
			TotalEstimatedCost += CostFull * COST_RATIO_REDUCED
		elseif NewQuality == QUALITY_LOW then
			TotalEstimatedCost += CostFull * COST_RATIO_LOW
		elseif NewQuality == QUALITY_MINIMAL then
			TotalEstimatedCost += CostFull * COST_RATIO_MINIMAL
		end
	end

	-- Adjust pressure based on budget feedback
	-- Over budget → increase pressure (tighten thresholds) → fewer Full NPCs
	-- Under budget → decrease pressure (loosen thresholds) → more Full NPCs
	-- Within tolerance band → do nothing
	local BudgetRatio = TotalEstimatedCost / math.max(BudgetMs, 0.001)

	if BudgetRatio > (1 + BUDGET_TOLERANCE) then
		-- Over budget: tighten
		self._Pressure = math.min(Pressure + PRESSURE_TIGHTEN_RATE, PRESSURE_MAX)
	elseif BudgetRatio < (1 - BUDGET_TOLERANCE) then
		-- Under budget: loosen
		self._Pressure = math.max(Pressure - PRESSURE_LOOSEN_RATE, PRESSURE_MIN)
	end
	-- else: within tolerance, don't adjust

	self._CurrentTotalCostMs = TotalEstimatedCost
end

function SolverLodManager.Step(self: SolverLodManager, DeltaTime: number)
	-- 1. Increment frame count
	self._FrameCount += 1
	self._LastUpdateCount = 0

	-- 2a. Calibration: collect initial DeltaTime samples to detect max FPS after SetAutoBudget
	if self._IsCalibrating then
		table.insert(self._CalibrationSamples, DeltaTime)
		if #self._CalibrationSamples >= CALIBRATION_FRAME_COUNT then
			local Samples = table.clone(self._CalibrationSamples)
			table.sort(Samples)
			local PercentileIndex = math.max(1, math.floor(#Samples * 0.05))
			local Percentile5th = Samples[PercentileIndex]
			self._DetectedMaxFps = math.round(1 / Percentile5th)
			if self._BudgetFraction then
				self._BudgetMs = (1000 / self._DetectedMaxFps) * self._BudgetFraction
			end
			self._IsCalibrating = false
			Logger.Info(
				`Auto budget calibrated: {self._DetectedMaxFps} FPS detected, budget = {string.format(
					"%.2f",
					self._BudgetMs or 0
				)}ms`
			)
		end
	end

	-- 2b. Re-calibration: periodically check if the FPS cap has shifted significantly
	if self._IsRecalibrating then
		table.insert(self._RecalibrationSamples, DeltaTime)
		if #self._RecalibrationSamples >= RECALIBRATION_SAMPLE_COUNT then
			local Samples = table.clone(self._RecalibrationSamples)
			table.sort(Samples)
			local NewP5 = Samples[1]
			local NewFps = math.round(1 / NewP5)
			if math.abs(NewFps - self._DetectedMaxFps) / math.max(self._DetectedMaxFps, 1) > FPS_SHIFT_THRESHOLD then
				self._DetectedMaxFps = NewFps
				if self._BudgetFraction then
					self._BudgetMs = (1000 / self._DetectedMaxFps) * self._BudgetFraction
					Logger.Info(
						`Auto budget recalibrated: {NewFps} FPS, budget = {string.format("%.2f", self._BudgetMs or 0)}ms`
					)
				end
			end
			self._IsRecalibrating = false
		end
	elseif self._FrameCount % RECALIBRATION_INTERVAL == 0 and self._IsAutoMode and not self._IsCalibrating then
		self._IsRecalibrating = true
		table.clear(self._RecalibrationSamples)
	end

	-- 2c. Periodically recalculate tiers (or significance + quality levels in auto mode)
	-- Auto mode uses 2x longer interval — significance changes slowly, frequent recalc causes oscillation
	local RecalcInterval = if self._IsAutoMode then self._RecalcInterval * 2 else self._RecalcInterval
	if self._FrameCount % RecalcInterval == 0 then
		if self._IsAutoMode and self._BudgetMs then
			SolverLodManager.__RecalcSignificance(self)
			SolverLodManager.__AssignQualityLevels(self)
		else
			SolverLodManager.__RecalcTiers(self)
		end
	end

	-- 3. Hot loop: update solvers based on their LOD schedule
	local Entries = self._Entries
	local CachedTier1MaxDist = self._CachedTier1MaxDist
	local CachedCamPos = self._CachedCamPos

	for Index = 1, #Entries do
		local Entry = Entries[Index]

		-- Skip tier 0 (frozen) — don't even accumulate DeltaTime
		if Entry.Tier == 0 then
			continue
		end

		-- Fast promote: if far away but suddenly close, promote immediately
		if Entry.Tier >= FAST_PROMOTE_MIN_TIER then
			local RootPart = Entry.RootPart
			if RootPart and RootPart.Parent then
				local Distance = (RootPart.Position - CachedCamPos).Magnitude
				if Distance <= CachedTier1MaxDist then
					Entry.Tier = 1
					Entry.UpdateInterval = self._ActiveTiers[1].UpdateInterval
					Entry.MaxLodTier = self._ActiveTiers[1].MaxLodTier
					Entry.AccumulatedDt = Entry.UpdateInterval -- force update this frame
				end
			end
		end

		-- Accumulate time
		Entry.AccumulatedDt += DeltaTime

		-- Time-based update: fire when accumulated time exceeds the interval
		-- UpdateInterval = 0 means every frame, > 0 means minimum seconds between updates
		if Entry.AccumulatedDt >= Entry.UpdateInterval then
			if self._IsAutoMode then
				local SolveStart = os.clock()
				Entry.Solver.Update(Entry.Solver, Entry.AccumulatedDt, Entry.MaxLodTier)
				local SolveCostMs = (os.clock() - SolveStart) * 1000
				if SolveCostMs > Entry.EstimatedCostMs then
					Entry.EstimatedCostMs = Entry.EstimatedCostMs * (1 - EMA_FAST_ALPHA) + SolveCostMs * EMA_FAST_ALPHA
				else
					Entry.EstimatedCostMs = Entry.EstimatedCostMs * (1 - EMA_SLOW_ALPHA) + SolveCostMs * EMA_SLOW_ALPHA
				end
			else
				Entry.Solver.Update(Entry.Solver, Entry.AccumulatedDt, Entry.MaxLodTier)
			end
			self._LastUpdateCount += 1
			Entry.AccumulatedDt = 0
		end
	end
end

function SolverLodManager.Destroy(self: SolverLodManager)
	table.clear(self._Entries)
	table.clear(self._EntryMap)
end

return SolverLodManager
