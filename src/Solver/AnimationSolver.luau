--!strict
--!optimize 2
--!native
--[[
	AnimationSolver — orchestrates multi-layer animation blending for one rig.

	Pipeline per frame:
	1. Advance time on all layers
	2. Update fade weights (crossfade ramp)
	3. Update LiveBoneWeights transitions (snap/lerp/spring)
	4. Remove dead layers (auto-revert if flagged)
	5. PreSolve hooks (game state → layer weights/speeds)
	6. Cull imperceptible layers (BEFORE evaluation)
	7. Evaluate surviving layers into pre-allocated Pose buffers
	8. Blend Replace layers via N-way weighted Nlerp accumulation
	9. Apply Additive layers on top
	10. PostSolve hooks (modify final pose buffers)
	11. Apply final Pose to rig via PoseApplier

	Stability Invariants:
	- BlendLayer table identity is stable for the lifetime of the layer.
	  AddLayer's table.sort permutes _Layers indices but never reallocates the
	  Layer tables themselves. Caching a Layer reference (or Layer.Player ref)
	  from AddLayer's return value is safe until RemoveLayer is called for
	  that specific layer. Verified by tests/spec/AnimationSolver.spec.luau
	  "BlendLayer identity stability (modifier-cache contract)".
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local SolverTypes = require(Luna.Types.SolverTypes)
local Constants = require(Luna.Core.Constants)
local AnimationData = require(Luna.Core.AnimationData)
local Logger = require(Luna.Shared.Logger)
local Signal = require(Luna.Shared.Signal)
local AnimationPlayer = require(script.Parent.AnimationPlayer)
local RigResolver = require(script.Parent.RigResolver)
local Pose = require(script.Parent.Pose)
local PoseApplier = require(script.Parent.PoseApplier)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type RigBinding = RigResolver.RigBinding
type RigInfo = RigResolver.RigInfo
type SkeletonInfo = RigResolver.SkeletonInfo
type BlendMode = SolverTypes.BlendMode
type LayerConfig = SolverTypes.LayerConfig
type LiveBoneWeights = SolverTypes.LiveBoneWeights
type TransitionMethod = SolverTypes.TransitionMethod
type OwnedWeightChange = SolverTypes.OwnedWeightChange
type AnimationMarker = AnimationData.AnimationMarker
type HookConfig = SolverTypes.HookConfig

local POS_STRIDE = Constants.POS_STRIDE
local ROT_STRIDE = Constants.ROTATION_BUFFER_STRIDE
local BW_TRANSITION_STRIDE = Constants.BONE_WEIGHT_TRANSITION_STRIDE
local BW_SNAP = Constants.BONE_WEIGHT_SNAP
local BW_LERP = Constants.BONE_WEIGHT_LERP
local BW_SPRING = Constants.BONE_WEIGHT_SPRING
local EPSILON = Constants.EPSILON

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local PERCEPTUAL_CULL_THRESHOLD = Constants.PERCEPTUAL_CULL_THRESHOLD
local DEAD_LAYER_THRESHOLD = Constants.DEAD_LAYER_THRESHOLD
local CROSSFADE_KILL_THRESHOLD = Constants.CROSSFADE_KILL_THRESHOLD

-- ============================================================================
-- [[ BLEND LAYER ]]
-- ============================================================================

export type BlendLayer = {
	Name: string?,
	Player: AnimationPlayer.AnimationPlayer,
	Weight: number,
	BlendMode: BlendMode,
	BoneWeights: LiveBoneWeights,
	Priority: number,
	AutoRevert: boolean,
	Markers: Array<AnimationMarker>,
	LodTier: number,
	-- Internal fade state
	__FadeTarget: number,
	__FadeDuration: number,
	__FadeSpeed: number,
	__RemoveOnFadeOut: boolean,
	-- Pre-allocated pose buffer (one per layer, buffer-backed)
	__Pose: Pose.Pose,
	-- Auto-revert ownership tracking
	__OwnedWeightChanges: Array<OwnedWeightChange>,
	-- Marker crossing detection
	__PreviousTime: number,
}

type HookEntry = {
	Name: string,
	Priority: number,
	LodTier: number,
	State: any,
	Run: (...any) -> (),
}

-- ============================================================================
-- [[ LIVE BONE WEIGHTS (buffer-backed) ]]
-- ============================================================================

-- Derive an implicit per-bone mask from a layer's RuntimeAnimation: 1.0 for bones
-- with tracks, 0.0 for absent. Caller passes nil if no Animation is available
-- (e.g., sampled-only layers); in that case AddLayer falls back to the historical
-- 1.0-everywhere default.
local function __DeriveAutoMaskBuffer(Animation: AnimationData.RuntimeAnimation, Skeleton: SkeletonInfo): buffer
	local BoneCount = #Skeleton.BoneNames
	local Mask = buffer.create(BoneCount * 4)
	-- buffer.create zeroes the contents, so untracked bones default to 0.

	for _, Track in Animation.Tracks do
		local Index = Skeleton.NameToIndex[Track.Name]
		if Index then
			buffer.writef32(Mask, (Index - 1) * 4, 1.0)
		end
	end

	return Mask
end

local function __CreateLiveBoneWeights(BoneCount: number, InitialMaskWeights: buffer?): LiveBoneWeights
	local CurrentWeights = buffer.create(BoneCount * 4)
	local TransitionState = buffer.create(BoneCount * BW_TRANSITION_STRIDE)
	local Methods = buffer.create(BoneCount)

	for Index = 0, BoneCount - 1 do
		local InitialWeight = if InitialMaskWeights then buffer.readf32(InitialMaskWeights, Index * 4) else 1.0
		-- CurrentWeights: f32 at stride 4
		buffer.writef32(CurrentWeights, Index * 4, InitialWeight)
		-- TransitionState: Target at +0, Speed at +4, Velocity at +8 (stride 12)
		local TransOff = Index * BW_TRANSITION_STRIDE
		buffer.writef32(TransitionState, TransOff, InitialWeight) -- Target
		-- Speed and Velocity default to 0 from buffer.create
		-- Methods: u8 SNAP=0 (default from buffer.create)
	end

	return {
		CurrentWeights = CurrentWeights,
		TransitionState = TransitionState,
		Methods = Methods,
		BoneCount = BoneCount,
		_HasActiveTransitions = false,
		_CachedMaxWeight = if InitialMaskWeights then 0 else 1.0,
		_MaxWeightDirty = InitialMaskWeights ~= nil, -- force scan if custom weights
	}
end

local function __UpdateLiveBoneWeights(Weights: LiveBoneWeights, DeltaTime: number)
	-- Skip entirely when no transitions are active (steady state optimization)
	if not Weights._HasActiveTransitions then
		return
	end

	local CurrentBuf = Weights.CurrentWeights
	local TransBuf = Weights.TransitionState
	local MethodsBuf = Weights.Methods
	local StillActive = false

	for Index = 0, Weights.BoneCount - 1 do
		local CurrOff = Index * 4
		local TransOff = Index * BW_TRANSITION_STRIDE
		local Method = buffer.readu8(MethodsBuf, Index)
		local Target = buffer.readf32(TransBuf, TransOff)
		local Current = buffer.readf32(CurrentBuf, CurrOff)

		if math.abs(Current - Target) < DEAD_LAYER_THRESHOLD then
			buffer.writef32(CurrentBuf, CurrOff, Target)
			buffer.writef32(TransBuf, TransOff + 8, 0) -- Velocity = 0
			continue
		end

		-- At least one bone hasn't converged
		StillActive = true
		Weights._MaxWeightDirty = true

		if Method == BW_SNAP then
			buffer.writef32(CurrentBuf, CurrOff, Target)
			buffer.writef32(TransBuf, TransOff + 8, 0)
		elseif Method == BW_LERP then
			local Speed = buffer.readf32(TransBuf, TransOff + 4)
			buffer.writef32(CurrentBuf, CurrOff, Current + (Target - Current) * (1 - math.exp(-Speed * DeltaTime)))
		elseif Method == BW_SPRING then
			local Speed = buffer.readf32(TransBuf, TransOff + 4)
			local Velocity = buffer.readf32(TransBuf, TransOff + 8)
			local Omega = Speed * 2
			local Exp = math.exp(-Omega * DeltaTime)
			local Diff = Current - Target
			buffer.writef32(CurrentBuf, CurrOff, Target + (Diff + (Velocity + Omega * Diff) * DeltaTime) * Exp)
			buffer.writef32(TransBuf, TransOff + 8, (Velocity - Omega * (Velocity + Omega * Diff) * DeltaTime) * Exp)
		end
	end

	Weights._HasActiveTransitions = StillActive
end

local function __GetMaxBoneWeight(Weights: LiveBoneWeights): number
	if not Weights._MaxWeightDirty then
		return Weights._CachedMaxWeight
	end
	local Max = 0
	local CurrentBuf = Weights.CurrentWeights
	for Index = 0, Weights.BoneCount - 1 do
		local Value = buffer.readf32(CurrentBuf, Index * 4)
		if Value > Max then
			Max = Value
		end
	end
	Weights._CachedMaxWeight = Max
	Weights._MaxWeightDirty = false
	return Max
end

-- ============================================================================
-- [[ AUTO-REVERT ]]
-- ============================================================================

local function __RevertOwnedWeightChanges(Layer: BlendLayer)
	local Weights = Layer.BoneWeights
	local CurrentBuf = Weights.CurrentWeights
	local TransBuf = Weights.TransitionState
	local MethodsBuf = Weights.Methods

	for _, Change in Layer.__OwnedWeightChanges do
		local BoneIndex = Change.BoneIndex
		local CurrOff = (BoneIndex - 1) * 4
		local TransOff = (BoneIndex - 1) * BW_TRANSITION_STRIDE
		local CurrentTarget = buffer.readf32(TransBuf, TransOff)
		-- Only revert if the current target still matches what this layer set
		if CurrentTarget ~= Change.PreviousTarget then
			buffer.writef32(TransBuf, TransOff, Change.PreviousTarget)
			buffer.writeu8(MethodsBuf, BoneIndex - 1, BW_SNAP)
			buffer.writef32(CurrentBuf, CurrOff, Change.PreviousTarget)
		end
	end
	table.clear(Layer.__OwnedWeightChanges)
end

-- ============================================================================
-- [[ ANIMATION SOLVER ]]
-- ============================================================================

local AnimationSolver = {}
AnimationSolver.__index = AnimationSolver

export type self = {
	_Binding: RigBinding,
	_RigInfo: RigBinding, -- Legacy alias
	_Skeleton: SkeletonInfo,
	_BoneCount: number,
	_Layers: Array<BlendLayer>,
	_LayerNameMap: StringIndexable<BlendLayer>,
	-- Marker event signal: fires (MarkerName: string, MarkerValue: string, Layer: BlendLayer)
	OnMarkerReached: any, -- Signal<string, string, BlendLayer>
	-- Pre-allocated buffer accumulators (rewritten every frame, never reallocated)
	_PosAccum: buffer,
	_QuatAccum: buffer,
	_WeightAccum: buffer,
	-- Pre-allocated temp arrays (reused every frame via count + direct index)
	_TempLayersToRemove: Array<BlendLayer>,
	_TempActiveLayers: Array<BlendLayer>,
	_PrevActiveCount: number,
	_PrevRemoveCount: number,
	-- Evaluate/Apply split state
	_HasPendingPose: boolean,
	-- Pre-allocated scratch buffers for additive step
	_TempAddA: buffer,
	_TempAddB: buffer,
	-- Output pose (buffer-backed)
	_OutputPose: Pose.Pose,
	_PreSolveHooks: Array<HookEntry>,
	_PostSolveHooks: Array<HookEntry>,
	_Payload: any,
}

export type AnimationSolver = typeof(setmetatable({} :: self, AnimationSolver))

function AnimationSolver.new(RigInfo: RigBinding): AnimationSolver
	local self = setmetatable({}, AnimationSolver) :: any

	local Skeleton = RigInfo.Skeleton
	local BoneCount = #Skeleton.BoneNames

	self._Binding = RigInfo
	self._RigInfo = RigInfo -- Legacy alias
	self._Skeleton = Skeleton
	self._BoneCount = BoneCount
	self._Layers = {}
	self._LayerNameMap = {}
	self.OnMarkerReached = Signal.new()

	-- Pre-allocate output pose (buffer-backed)
	self._OutputPose = Pose.Create(BoneCount)

	-- Pre-allocate blend accumulators
	self._PosAccum = buffer.create(BoneCount * POS_STRIDE)
	self._QuatAccum = buffer.create(BoneCount * ROT_STRIDE)
	self._WeightAccum = buffer.create(BoneCount * 4)

	-- Pre-allocate temp arrays (reused via count + direct index, no table.insert)
	self._TempLayersToRemove = table.create(8)
	self._TempActiveLayers = table.create(8)
	self._PrevActiveCount = 0
	self._PrevRemoveCount = 0
	self._HasPendingPose = false

	-- Pre-allocate scratch buffers for additive blend step (16 bytes each = 1 quat)
	self._TempAddA = buffer.create(16)
	self._TempAddB = buffer.create(16)

	self._PreSolveHooks = {}
	self._PostSolveHooks = {}
	self._Payload = nil

	return self
end

-- ============================================================================
-- [[ REBIND ]]
-- ============================================================================

function AnimationSolver.Rebind(self: AnimationSolver, NewBinding: RigBinding)
	local Skeleton = NewBinding.Skeleton
	local NewCount = #Skeleton.BoneNames

	self._Binding = NewBinding
	self._RigInfo = NewBinding
	self._Skeleton = Skeleton
	self._BoneCount = NewCount
	self._OutputPose = Pose.Create(NewCount)
	self._PosAccum = buffer.create(NewCount * POS_STRIDE)
	self._QuatAccum = buffer.create(NewCount * ROT_STRIDE)
	self._WeightAccum = buffer.create(NewCount * 4)
end

-- ============================================================================
-- [[ LAYER MANAGEMENT ]]
-- ============================================================================

function AnimationSolver.AddLayer(self: AnimationSolver, Config: LayerConfig): BlendLayer
	local Player = AnimationPlayer.new({
		Animation = Config.Animation,
		SampledAnimation = Config.SampledAnimation,
		RigInfo = self._Binding,
	})

	local InitialWeight = Config.Weight or 1.0

	-- Mask resolution priority:
	--   1. Explicit InitialMaskWeights (BoneMask.Weights or hand-built buffer)
	--   2. Auto-mask from Config.Animation.Tracks (Replace layers with partial track sets
	--      no longer overwrite untouched bones at non-zero weight)
	--   3. Historical 1.0-everywhere default (sampled-only layers, no track list to derive from)
	local MaskBuffer: buffer? = Config.InitialMaskWeights :: buffer?
	if MaskBuffer == nil and Config.Animation then
		MaskBuffer = __DeriveAutoMaskBuffer(Config.Animation :: AnimationData.RuntimeAnimation, self._Skeleton)
	end
	local BoneWeights = __CreateLiveBoneWeights(self._BoneCount, MaskBuffer)

	local LayerName = Config.Name

	local Layer: BlendLayer = {
		Name = LayerName,
		Player = Player,
		Weight = InitialWeight,
		BlendMode = Config.BlendMode or "Replace",
		BoneWeights = BoneWeights,
		Priority = Config.Priority or 1,
		AutoRevert = Config.AutoRevert or false,
		Markers = Config.Markers or {},
		LodTier = Config.LodTier or 0,
		__FadeTarget = InitialWeight,
		__FadeDuration = 0,
		__FadeSpeed = 0,
		__RemoveOnFadeOut = false,
		__Pose = Pose.Create(self._BoneCount),
		__OwnedWeightChanges = {},
		__PreviousTime = 0,
		__NextMarkerIndex = 1,
		__MarkerCount = #(Config.Markers or {}),
	} :: any

	table.insert(self._Layers, Layer)
	if LayerName then
		self._LayerNameMap[LayerName] = Layer
	end

	-- Sort by Priority (lower first)
	table.sort(self._Layers, function(A: any, B: any)
		return A.Priority < B.Priority
	end)

	return Layer
end

function AnimationSolver.RemoveLayer(self: AnimationSolver, Layer: BlendLayer)
	for Index, Existing in self._Layers do
		if Existing == Layer then
			if Layer.Name then
				self._LayerNameMap[Layer.Name] = nil
			end
			Layer.Player.Destroy(Layer.Player)
			table.remove(self._Layers, Index)
			return
		end
	end
end

function AnimationSolver.GetLayers(self: AnimationSolver): Array<BlendLayer>
	return self._Layers
end

function AnimationSolver.GetLayer(self: AnimationSolver, Name: string): BlendLayer?
	return self._LayerNameMap[Name]
end

-- ============================================================================
-- [[ CONVENIENCE: PLAY / CROSSFADE ]]
-- ============================================================================

function AnimationSolver.Play(self: AnimationSolver, Config: LayerConfig): BlendLayer
	local Layer = AnimationSolver.AddLayer(self, Config)
	Layer.Player.IsLooping = true
	Layer.Player.Play(Layer.Player)
	return Layer
end

function AnimationSolver.Crossfade(self: AnimationSolver, Config: LayerConfig?, FadeDuration: number): BlendLayer
	-- 1. Kill layers already fading out below threshold (rapid-fire cull)
	local LayersToKill: Array<BlendLayer> = {}
	for _, Layer in self._Layers do
		if Layer.__FadeTarget == 0 and Layer.Weight < CROSSFADE_KILL_THRESHOLD then
			table.insert(LayersToKill, Layer)
		else
			-- Fade out surviving layers
			Layer.__FadeTarget = 0
			Layer.__FadeDuration = FadeDuration
			Layer.__FadeSpeed = if FadeDuration > 0 then 1 / FadeDuration else math.huge
			Layer.__RemoveOnFadeOut = true
		end
	end
	for _, Layer in LayersToKill do
		AnimationSolver.RemoveLayer(self, Layer)
	end

	-- 2. Add new layer at weight 0, fade in (clone config to avoid mutating caller's table)
	local NewConfig: LayerConfig = if Config then table.clone(Config) :: any else {} :: any
	NewConfig.Weight = 0
	local NewLayer = AnimationSolver.AddLayer(self, NewConfig)
	NewLayer.__FadeTarget = 1
	NewLayer.__FadeDuration = FadeDuration
	NewLayer.__FadeSpeed = if FadeDuration > 0 then 1 / FadeDuration else math.huge
	NewLayer.Player.IsLooping = true
	NewLayer.Player.Play(NewLayer.Player)

	return NewLayer
end

-- ============================================================================
-- [[ PER-BONE WEIGHT CONTROL ]]
-- ============================================================================

function AnimationSolver.SetBoneWeight(
	self: AnimationSolver,
	Layer: BlendLayer,
	BoneName: string,
	Weight: number,
	Method: TransitionMethod?,
	Params: { Speed: number? }?
)
	local BoneIndex = self._Skeleton.NameToIndex[BoneName]
	if not BoneIndex then
		Logger.Warn(`SetBoneWeight: bone "{BoneName}" not found in rig`)
		return
	end

	local FinalMethod = Method or "Snap"
	local Speed = if Params then (Params.Speed or 15) else 15
	local Weights = Layer.BoneWeights
	local CurrOff = (BoneIndex - 1) * 4
	local TransOff = (BoneIndex - 1) * BW_TRANSITION_STRIDE

	-- Track ownership for auto-revert
	if Layer.AutoRevert then
		table.insert(Layer.__OwnedWeightChanges, {
			BoneIndex = BoneIndex,
			PreviousTarget = buffer.readf32(Weights.TransitionState, TransOff),
		})
	end

	-- Set target
	buffer.writef32(Weights.TransitionState, TransOff, Weight)
	-- Set speed
	buffer.writef32(Weights.TransitionState, TransOff + 4, Speed)
	-- Set method
	local MethodU8 = if FinalMethod == "Snap" then BW_SNAP elseif FinalMethod == "Lerp" then BW_LERP else BW_SPRING
	buffer.writeu8(Weights.Methods, BoneIndex - 1, MethodU8)

	-- Mark transitions active + max weight dirty
	Weights._HasActiveTransitions = true
	Weights._MaxWeightDirty = true

	if FinalMethod == "Snap" then
		buffer.writef32(Weights.CurrentWeights, CurrOff, Weight)
		buffer.writef32(Weights.TransitionState, TransOff + 8, 0) -- Velocity = 0
	end
end

-- Set weight for BoneName and all its descendants (uses rig hierarchy).
function AnimationSolver.SetBoneWeightFromBone(
	self: AnimationSolver,
	Layer: BlendLayer,
	RootBoneName: string,
	Weight: number,
	Method: TransitionMethod?,
	Params: { Speed: number? }?
)
	local function __SetRecursive(BoneName: string)
		AnimationSolver.SetBoneWeight(self, Layer, BoneName, Weight, Method, Params)
		local Children = self._Skeleton.ChildrenMap[BoneName]
		if Children then
			for _, ChildName in Children do
				__SetRecursive(ChildName)
			end
		end
	end

	__SetRecursive(RootBoneName)
end

function AnimationSolver.SetPayload(self: AnimationSolver, Payload: any)
	self._Payload = Payload
end

-- ============================================================================
-- [[ GAME MODIFIER HOOKS ]]
-- ============================================================================

local function __InsertHookSorted(HookArray: Array<HookEntry>, Entry: HookEntry)
	for Index, Existing in HookArray do
		if Entry.Priority < Existing.Priority then
			table.insert(HookArray, Index, Entry)
			return
		end
	end
	table.insert(HookArray, Entry)
end

local function __RemoveHookByName(HookArray: Array<HookEntry>, Name: string): boolean
	for Index, Hook in HookArray do
		if Hook.Name == Name then
			table.remove(HookArray, Index)
			return true
		end
	end
	return false
end

function AnimationSolver.AddPreSolveHook(self: AnimationSolver, Name: string, Config: HookConfig)
	if __RemoveHookByName(self._PreSolveHooks, Name) then
		Logger.Warn(`AddPreSolveHook: replacing existing hook "{Name}"`)
	end

	local Entry: HookEntry = {
		Name = Name,
		Priority = Config.Priority or 1,
		LodTier = Config.LodTier or 0,
		State = if Config.Init then Config.Init() else nil,
		Run = Config.Run,
	}
	__InsertHookSorted(self._PreSolveHooks, Entry)
end

function AnimationSolver.AddPostSolveHook(self: AnimationSolver, Name: string, Config: HookConfig)
	if __RemoveHookByName(self._PostSolveHooks, Name) then
		Logger.Warn(`AddPostSolveHook: replacing existing hook "{Name}"`)
	end

	local Entry: HookEntry = {
		Name = Name,
		Priority = Config.Priority or 1,
		LodTier = Config.LodTier or 0,
		State = if Config.Init then Config.Init() else nil,
		Run = Config.Run,
	}
	__InsertHookSorted(self._PostSolveHooks, Entry)
end

function AnimationSolver.RemovePreSolveHook(self: AnimationSolver, Name: string)
	__RemoveHookByName(self._PreSolveHooks, Name)
end

function AnimationSolver.RemovePostSolveHook(self: AnimationSolver, Name: string)
	__RemoveHookByName(self._PostSolveHooks, Name)
end

-- ============================================================================
-- [[ BLEND HELPERS (called from Update, extracted for readability) ]]
-- ============================================================================

-- Accumulate Replace layers into PosAccum/QuatAccum/WeightAccum, then normalize
-- into OutputPose. Fills rest pose for bones with insufficient weight.
function AnimationSolver.__BlendReplaceLayers(self: AnimationSolver, ActiveLayers: Array<BlendLayer>, BoneCount: number)
	local PosAccum = self._PosAccum
	local QuatAccum = self._QuatAccum
	local WeightAccum = self._WeightAccum

	-- Reset accumulators
	buffer.fill(PosAccum, 0, 0)
	buffer.fill(QuatAccum, 0, 0)
	buffer.fill(WeightAccum, 0, 0)

	for _, Layer in ActiveLayers do
		if Layer.BlendMode ~= "Replace" then
			continue
		end

		local LayerWeight = Layer.Weight
		local BWCurrent = Layer.BoneWeights.CurrentWeights
		local LayerPos = Layer.__Pose.Positions
		local LayerRot = Layer.__Pose.Rotations

		for BoneIdx = 0, BoneCount - 1 do
			local EffWeight = LayerWeight * buffer.readf32(BWCurrent, BoneIdx * 4)
			if EffWeight < 0.001 then
				continue
			end

			local PosOff = BoneIdx * POS_STRIDE
			local RotOff = BoneIdx * ROT_STRIDE

			-- Accumulate position (cache reads to avoid redundant buffer access)
			local AccPX = buffer.readf32(PosAccum, PosOff)
			local AccPY = buffer.readf32(PosAccum, PosOff + 4)
			local AccPZ = buffer.readf32(PosAccum, PosOff + 8)
			local LayPX = buffer.readf32(LayerPos, PosOff)
			local LayPY = buffer.readf32(LayerPos, PosOff + 4)
			local LayPZ = buffer.readf32(LayerPos, PosOff + 8)
			buffer.writef32(PosAccum, PosOff, AccPX + LayPX * EffWeight)
			buffer.writef32(PosAccum, PosOff + 4, AccPY + LayPY * EffWeight)
			buffer.writef32(PosAccum, PosOff + 8, AccPZ + LayPZ * EffWeight)

			-- Quaternion sign flip: compare against running accumulator
			local AccRX = buffer.readf32(QuatAccum, RotOff)
			local AccRY = buffer.readf32(QuatAccum, RotOff + 4)
			local AccRZ = buffer.readf32(QuatAccum, RotOff + 8)
			local AccRW = buffer.readf32(QuatAccum, RotOff + 12)
			local LRX = buffer.readf32(LayerRot, RotOff)
			local LRY = buffer.readf32(LayerRot, RotOff + 4)
			local LRZ = buffer.readf32(LayerRot, RotOff + 8)
			local LRW = buffer.readf32(LayerRot, RotOff + 12)
			local Dot = AccRX * LRX + AccRY * LRY + AccRZ * LRZ + AccRW * LRW
			local Sign = if Dot < 0 then -1 else 1

			buffer.writef32(QuatAccum, RotOff, AccRX + LRX * EffWeight * Sign)
			buffer.writef32(QuatAccum, RotOff + 4, AccRY + LRY * EffWeight * Sign)
			buffer.writef32(QuatAccum, RotOff + 8, AccRZ + LRZ * EffWeight * Sign)
			buffer.writef32(QuatAccum, RotOff + 12, AccRW + LRW * EffWeight * Sign)

			-- Weight accumulate (single read, not read-modify-write)
			local AccW = buffer.readf32(WeightAccum, BoneIdx * 4)
			buffer.writef32(WeightAccum, BoneIdx * 4, AccW + EffWeight)
		end
	end

	-- Normalize per bone and write into output pose
	local OutPos = self._OutputPose.Positions
	local OutRot = self._OutputPose.Rotations
	local RestPos = self._Skeleton.RestPositions
	local RestRot = self._Skeleton.RestRotations

	for BoneIdx = 0, BoneCount - 1 do
		local TotalWeight = buffer.readf32(WeightAccum, BoneIdx * 4)
		local PosOff = BoneIdx * POS_STRIDE
		local RotOff = BoneIdx * ROT_STRIDE

		if TotalWeight < DEAD_LAYER_THRESHOLD then
			-- No layers contribute to this bone — use rest pose
			buffer.copy(OutPos, PosOff, RestPos, PosOff, POS_STRIDE)
			buffer.copy(OutRot, RotOff, RestRot, RotOff, ROT_STRIDE)
			continue
		end

		-- Fill gap with rest pose if total weight < 1.0
		if TotalWeight < 0.999 then
			local RestWeight = 1.0 - TotalWeight

			-- Accumulate rest position (cache reads)
			local AccPX = buffer.readf32(PosAccum, PosOff)
			local AccPY = buffer.readf32(PosAccum, PosOff + 4)
			local AccPZ = buffer.readf32(PosAccum, PosOff + 8)
			local RestPX = buffer.readf32(RestPos, PosOff)
			local RestPY = buffer.readf32(RestPos, PosOff + 4)
			local RestPZ = buffer.readf32(RestPos, PosOff + 8)
			buffer.writef32(PosAccum, PosOff, AccPX + RestPX * RestWeight)
			buffer.writef32(PosAccum, PosOff + 4, AccPY + RestPY * RestWeight)
			buffer.writef32(PosAccum, PosOff + 8, AccPZ + RestPZ * RestWeight)

			-- Accumulate rest rotation with hemisphere check
			local AccRX = buffer.readf32(QuatAccum, RotOff)
			local AccRY = buffer.readf32(QuatAccum, RotOff + 4)
			local AccRZ = buffer.readf32(QuatAccum, RotOff + 8)
			local AccRW = buffer.readf32(QuatAccum, RotOff + 12)
			local RRX = buffer.readf32(RestRot, RotOff)
			local RRY = buffer.readf32(RestRot, RotOff + 4)
			local RRZ = buffer.readf32(RestRot, RotOff + 8)
			local RRW = buffer.readf32(RestRot, RotOff + 12)
			local Dot = AccRX * RRX + AccRY * RRY + AccRZ * RRZ + AccRW * RRW
			local RestSign = if Dot < 0 then -1 else 1

			buffer.writef32(QuatAccum, RotOff, AccRX + RRX * RestWeight * RestSign)
			buffer.writef32(QuatAccum, RotOff + 4, AccRY + RRY * RestWeight * RestSign)
			buffer.writef32(QuatAccum, RotOff + 8, AccRZ + RRZ * RestWeight * RestSign)
			buffer.writef32(QuatAccum, RotOff + 12, AccRW + RRW * RestWeight * RestSign)

			TotalWeight = 1.0
		end

		-- Normalize position (cache accumulator reads)
		local InvWeight = 1 / TotalWeight
		local FinalPX = buffer.readf32(PosAccum, PosOff) * InvWeight
		local FinalPY = buffer.readf32(PosAccum, PosOff + 4) * InvWeight
		local FinalPZ = buffer.readf32(PosAccum, PosOff + 8) * InvWeight
		buffer.writef32(OutPos, PosOff, FinalPX)
		buffer.writef32(OutPos, PosOff + 4, FinalPY)
		buffer.writef32(OutPos, PosOff + 8, FinalPZ)

		-- Normalize quaternion
		local QX = buffer.readf32(QuatAccum, RotOff)
		local QY = buffer.readf32(QuatAccum, RotOff + 4)
		local QZ = buffer.readf32(QuatAccum, RotOff + 8)
		local QW = buffer.readf32(QuatAccum, RotOff + 12)
		local Len = math.sqrt(QX * QX + QY * QY + QZ * QZ + QW * QW)
		if Len < EPSILON then
			buffer.writef32(OutRot, RotOff, 0)
			buffer.writef32(OutRot, RotOff + 4, 0)
			buffer.writef32(OutRot, RotOff + 8, 0)
			buffer.writef32(OutRot, RotOff + 12, 1)
		else
			local InvLen = 1 / Len
			buffer.writef32(OutRot, RotOff, QX * InvLen)
			buffer.writef32(OutRot, RotOff + 4, QY * InvLen)
			buffer.writef32(OutRot, RotOff + 8, QZ * InvLen)
			buffer.writef32(OutRot, RotOff + 12, QW * InvLen)
		end
	end
end

-- Apply Additive layers on top of the blended output pose.
function AnimationSolver.__ApplyAdditiveLayers(
	self: AnimationSolver,
	ActiveLayers: Array<BlendLayer>,
	BoneCount: number
)
	local OutPos = self._OutputPose.Positions
	local OutRot = self._OutputPose.Rotations

	for _, Layer in ActiveLayers do
		if Layer.BlendMode ~= "Additive" then
			continue
		end

		local LayerWeight = Layer.Weight
		local BWCurrent = Layer.BoneWeights.CurrentWeights
		local LayerPos = Layer.__Pose.Positions
		local LayerRot = Layer.__Pose.Rotations

		for BoneIdx = 0, BoneCount - 1 do
			local EffWeight = LayerWeight * buffer.readf32(BWCurrent, BoneIdx * 4)
			if EffWeight < 0.001 then
				continue
			end

			local PosOff = BoneIdx * POS_STRIDE
			local RotOff = BoneIdx * ROT_STRIDE

			-- Additive position: base + delta * weight (cache reads)
			local BasePX = buffer.readf32(OutPos, PosOff)
			local BasePY = buffer.readf32(OutPos, PosOff + 4)
			local BasePZ = buffer.readf32(OutPos, PosOff + 8)
			local DeltaPX = buffer.readf32(LayerPos, PosOff)
			local DeltaPY = buffer.readf32(LayerPos, PosOff + 4)
			local DeltaPZ = buffer.readf32(LayerPos, PosOff + 8)
			buffer.writef32(OutPos, PosOff, BasePX + DeltaPX * EffWeight)
			buffer.writef32(OutPos, PosOff + 4, BasePY + DeltaPY * EffWeight)
			buffer.writef32(OutPos, PosOff + 8, BasePZ + DeltaPZ * EffWeight)

			-- Additive rotation: base * Nlerp(identity, deltaRot, weight)
			-- Hemisphere check: ensure deltaRot W > 0
			local DX = buffer.readf32(LayerRot, RotOff)
			local DY = buffer.readf32(LayerRot, RotOff + 4)
			local DZ = buffer.readf32(LayerRot, RotOff + 8)
			local DW = buffer.readf32(LayerRot, RotOff + 12)
			if DW < 0 then
				DX = -DX
				DY = -DY
				DZ = -DZ
				DW = -DW
			end

			-- Nlerp(identity, delta, weight) simplified: identity = (0,0,0,1)
			local RX = DX * EffWeight
			local RY = DY * EffWeight
			local RZ = DZ * EffWeight
			local RW = 1 + (DW - 1) * EffWeight
			local NLen = math.sqrt(RX * RX + RY * RY + RZ * RZ + RW * RW)
			if NLen > EPSILON then
				local InvLen = 1 / NLen
				RX *= InvLen
				RY *= InvLen
				RZ *= InvLen
				RW *= InvLen
			else
				RX = 0
				RY = 0
				RZ = 0
				RW = 1
			end

			-- Multiply base * weightedDelta (inline quaternion multiply)
			local BX = buffer.readf32(OutRot, RotOff)
			local BY = buffer.readf32(OutRot, RotOff + 4)
			local BZ = buffer.readf32(OutRot, RotOff + 8)
			local BW = buffer.readf32(OutRot, RotOff + 12)

			local MX = BW * RX + BX * RW + BY * RZ - BZ * RY
			local MY = BW * RY - BX * RZ + BY * RW + BZ * RX
			local MZ = BW * RZ + BX * RY - BY * RX + BZ * RW
			local MW = BW * RW - BX * RX - BY * RY - BZ * RZ

			-- Normalize and write
			local MLen = math.sqrt(MX * MX + MY * MY + MZ * MZ + MW * MW)
			if MLen < EPSILON then
				buffer.writef32(OutRot, RotOff, 0)
				buffer.writef32(OutRot, RotOff + 4, 0)
				buffer.writef32(OutRot, RotOff + 8, 0)
				buffer.writef32(OutRot, RotOff + 12, 1)
			else
				local MInv = 1 / MLen
				buffer.writef32(OutRot, RotOff, MX * MInv)
				buffer.writef32(OutRot, RotOff + 4, MY * MInv)
				buffer.writef32(OutRot, RotOff + 8, MZ * MInv)
				buffer.writef32(OutRot, RotOff + 12, MW * MInv)
			end
		end
	end
end

-- ============================================================================
-- [[ UPDATE (the per-frame pipeline) ]]
-- ============================================================================

-- Evaluate all animation layers into output pose buffers. Does NOT write to motors.
-- Call Apply() after to write the final pose to the rig.
function AnimationSolver.Evaluate(self: AnimationSolver, DeltaTime: number, MaxLodTier: number?)
	local BoneCount = self._BoneCount

	-- 1. Advance time + update fade weights on all layers
	local LayersToRemove = self._TempLayersToRemove
	local RemoveCount = 0

	for _, Layer in self._Layers do
		-- Advance animation time (don't apply — we do that after blending)
		local Player = Layer.Player
		if Player.State == "Playing" then
			Player.TimePosition += DeltaTime * Player.Speed

			-- Handle looping/clamping
			local Duration = if Player._IsSampled and Player._SampledAnimation
				then Player._SampledAnimation.Duration
				else if Player._Animation then Player._Animation.Duration else 0

			if Duration > 0 then
				if Player.IsLooping then
					if Player.TimePosition >= Duration then
						Player.TimePosition = Player.TimePosition % Duration
					elseif Player.TimePosition < 0 then
						Player.TimePosition = Duration + (Player.TimePosition % Duration)
					end
				else
					if Player.TimePosition >= Duration then
						Player.TimePosition = Duration
						Player.State = "Stopped"
					elseif Player.TimePosition < 0 then
						Player.TimePosition = 0
						Player.State = "Stopped"
					end
				end
			end
		end

		-- 1b. Fire marker events using cached index (O(1) for sequential playback)
		if Layer.__MarkerCount > 0 and Player.State == "Playing" then
			local PrevTime = Layer.__PreviousTime
			local CurrTime = Player.TimePosition
			local Markers = Layer.Markers
			local MarkerCount = Layer.__MarkerCount

			if CurrTime < PrevTime then
				-- Loop wrap: fire markers in two ranges
				-- Range 1: (PrevTime, end] — markers between old position and animation end
				local Index = Layer.__NextMarkerIndex
				while Index <= MarkerCount do
					if Markers[Index].Time > PrevTime then
						Signal.Fire(self.OnMarkerReached, Markers[Index].Name, Markers[Index].Value, Layer)
					end
					Index += 1
				end
				-- Range 2: [0, CurrTime] — markers between start and new wrapped position
				Layer.__NextMarkerIndex = 1
				Index = 1
				while Index <= MarkerCount do
					if Markers[Index].Time > CurrTime then
						break
					end
					Signal.Fire(self.OnMarkerReached, Markers[Index].Name, Markers[Index].Value, Layer)
					Index += 1
				end
				Layer.__NextMarkerIndex = Index
			else
				-- Sequential playback: scan from cached index
				local Index = Layer.__NextMarkerIndex
				while Index <= MarkerCount do
					local MarkerTime = Markers[Index].Time
					if MarkerTime > CurrTime then
						break
					end
					if MarkerTime > PrevTime then
						Signal.Fire(self.OnMarkerReached, Markers[Index].Name, Markers[Index].Value, Layer)
					end
					Index += 1
				end
				Layer.__NextMarkerIndex = Index
			end
		end
		Layer.__PreviousTime = Player.TimePosition

		-- 2. Update fade weight
		if Layer.__FadeSpeed > 0 and math.abs(Layer.Weight - Layer.__FadeTarget) > DEAD_LAYER_THRESHOLD then
			local Direction = if Layer.__FadeTarget > Layer.Weight then 1 else -1
			if Layer.__FadeSpeed == math.huge then
				Layer.Weight = Layer.__FadeTarget
			else
				local Change = DeltaTime * Layer.__FadeSpeed * Direction
				if Direction == 1 then
					Layer.Weight = math.min(Layer.Weight + Change, Layer.__FadeTarget)
				else
					Layer.Weight = math.max(Layer.Weight + Change, Layer.__FadeTarget)
				end
			end
		end

		-- 3. Update LiveBoneWeights transitions (skips if no active transitions)
		__UpdateLiveBoneWeights(Layer.BoneWeights, DeltaTime)

		-- 4. Mark dead layers for removal
		local IsDead = (Layer.__RemoveOnFadeOut and Layer.Weight < DEAD_LAYER_THRESHOLD)
			or (Player.State == "Stopped" and Layer.Weight < DEAD_LAYER_THRESHOLD)

		if IsDead then
			if Layer.AutoRevert then
				__RevertOwnedWeightChanges(Layer)
			end
			RemoveCount += 1
			LayersToRemove[RemoveCount] = Layer
		end
	end

	-- Nil out trailing slots from previous frame
	for I = RemoveCount + 1, self._PrevRemoveCount do
		LayersToRemove[I] = nil
	end
	self._PrevRemoveCount = RemoveCount

	-- Remove dead layers
	for I = 1, RemoveCount do
		AnimationSolver.RemoveLayer(self, LayersToRemove[I])
	end

	if #self._Layers == 0 then
		self._HasPendingPose = false
		return
	end

	-- 5. PreSolve hooks
	local PreHooks = self._PreSolveHooks
	local PreHookCount = #PreHooks
	if PreHookCount == 1 then
		local Hook = PreHooks[1]
		if not MaxLodTier or Hook.LodTier <= MaxLodTier then
			Hook.Run(self, self._Payload, Hook.State, DeltaTime)
		end
	elseif PreHookCount > 1 then
		for _, Hook in PreHooks do
			if MaxLodTier and Hook.LodTier > MaxLodTier then
				continue
			end
			Hook.Run(self, self._Payload, Hook.State, DeltaTime)
		end
	end

	-- 6. Cull imperceptible layers + 7. Evaluate surviving layers
	local ActiveLayers = self._TempActiveLayers
	local ActiveCount = 0

	for _, Layer in self._Layers do
		local MaxBoneWt = __GetMaxBoneWeight(Layer.BoneWeights)
		if Layer.Weight * MaxBoneWt < PERCEPTUAL_CULL_THRESHOLD then
			continue
		end

		-- LOD tier cull (nil = no manager, math.huge = all tiers allowed)
		if MaxLodTier and Layer.LodTier > MaxLodTier then
			continue
		end

		-- Evaluate into this layer's pre-allocated buffer-backed Pose
		local LayerPose = Layer.__Pose
		Pose.Reset(LayerPose)
		Layer.Player.EvaluateInto(
			Layer.Player,
			LayerPose.Positions,
			LayerPose.Rotations,
			self._Skeleton.NameToIndex,
			Layer.BoneWeights.CurrentWeights
		)

		ActiveCount += 1
		ActiveLayers[ActiveCount] = Layer
	end

	-- Nil out trailing slots from previous frame
	for I = ActiveCount + 1, self._PrevActiveCount do
		ActiveLayers[I] = nil
	end
	self._PrevActiveCount = ActiveCount

	if ActiveCount == 0 then
		self._HasPendingPose = false
		return
	end

	-- 8. Blend Replace layers + normalize into output pose
	AnimationSolver.__BlendReplaceLayers(self, ActiveLayers, BoneCount)

	-- 9. Apply Additive layers on top
	AnimationSolver.__ApplyAdditiveLayers(self, ActiveLayers, BoneCount)

	-- 10. PostSolve hooks
	local OutPos = self._OutputPose.Positions
	local OutRot = self._OutputPose.Rotations
	local PostHooks = self._PostSolveHooks
	local PostHookCount = #PostHooks
	if PostHookCount == 1 then
		local Hook = PostHooks[1]
		if not MaxLodTier or Hook.LodTier <= MaxLodTier then
			Hook.Run(self, self._Payload, Hook.State, DeltaTime, OutPos, OutRot, BoneCount)
		end
	elseif PostHookCount > 1 then
		for _, Hook in PostHooks do
			if MaxLodTier and Hook.LodTier > MaxLodTier then
				continue
			end
			Hook.Run(self, self._Payload, Hook.State, DeltaTime, OutPos, OutRot, BoneCount)
		end
	end

	self._HasPendingPose = true
end

-- Write the evaluated output pose to the rig's motors.
-- Safe to call without a preceding Evaluate (no-op if no pending pose).
function AnimationSolver.Apply(self: AnimationSolver)
	if not self._HasPendingPose then
		return
	end
	PoseApplier.ApplyPoseBuf(self._Binding.Motors, self._OutputPose.Positions, self._OutputPose.Rotations, self._BoneCount)
	self._HasPendingPose = false
end

-- Backward compatible: evaluate + apply in one call.
function AnimationSolver.Update(self: AnimationSolver, DeltaTime: number, MaxLodTier: number?)
	AnimationSolver.Evaluate(self, DeltaTime, MaxLodTier)
	AnimationSolver.Apply(self)
end

-- ============================================================================
-- [[ CLEANUP ]]
-- ============================================================================

function AnimationSolver.Destroy(self: AnimationSolver)
	for _, Layer in self._Layers do
		Layer.Player.Destroy(Layer.Player)
	end
	table.clear(self._Layers)
	table.clear(self._LayerNameMap)
	table.clear(self._PreSolveHooks)
	table.clear(self._PostSolveHooks)
	self._Payload = nil
	Signal.Destroy(self.OnMarkerReached)
	RigResolver.RestoreDefaultPose(self._Binding)
end

return AnimationSolver
