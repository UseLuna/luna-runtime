--!strict
--!optimize 2
--[[
	LunaRuntimeWrapper — convenience wrapper for Luna Runtime.

	Wraps AnimationSolver, AnimationPlayer, RigResolver, SolverLodManager, Importer,
	StorageService into a simple functional API with property-style handles.

	Three-tier API:
	  Tier 1: LoadAndPlay (one-liner, auto-detects source type)
	  Tier 2: Play + handle properties (explicit control)
	  Tier 3: GetSolverUnsafe (raw solver access)

	Usage:
	  local Luna = require(LunaRuntime.Solver.LunaRuntimeWrapper)
	  Luna.SetGlobalLod("Default")
	  local Handle = Luna.LoadAndPlay(NpcModel, AnimData.Value, { Looping = true })
	  RunService.RenderStepped:Connect(function(DeltaTime)
	      Luna.Step(DeltaTime)
	  end)
]]

local Luna = script.Parent.Parent

local AnimationData = require(Luna.Core.AnimationData)
local SolverTypes = require(Luna.Types.SolverTypes)
local Logger = require(Luna.Shared.Logger)
local AnimationPlayer = require(script.Parent.AnimationPlayer)
local AnimationSolver = require(script.Parent.AnimationSolver)
local RigResolver = require(script.Parent.RigResolver)
local SolverLodManager = require(script.Parent.SolverLodManager)
local Importer = require(script.Parent.Importer)
local StorageService = require(script.Parent.StorageService)

type EditAnimation = AnimationData.EditAnimation
type RuntimeAnimation = AnimationData.RuntimeAnimation

-- ============================================================================
-- [[ TYPES ]]
-- ============================================================================

export type LoadedAnimation = {
	Name: string,
	Edit: EditAnimation,
	Runtime: RuntimeAnimation,
	Sampled: any?, -- lazy-baked on first LOD tier that needs it
}

export type RigHandle = {
	Id: number?,
	RigInfo: any,
	Model: Model,
	RootPart: BasePart,
}

-- PlaybackHandle IS the AnimationPlayer with extra fields bolted on.
-- Handle.Speed, Handle.Weight, Handle.IsLooping are AnimationPlayer fields.
export type PlaybackHandle = AnimationPlayer.AnimationPlayer & {
	_HandleId: number,
	_Rig: RigHandle,
	_Animation: LoadedAnimation,
	_FadeTarget: number?,
	_FadeDuration: number,
	_FadeElapsed: number,
	_FadeStartWeight: number,
	_AutoStopOnFadeOut: boolean,
}

export type PlayOptions = {
	Speed: number?,
	Weight: number?,
	Looping: boolean?,
	Paused: boolean?,
	FadeIn: number?,
}

type RigEntry = {
	Rig: RigHandle,
	Solver: any, -- AnimationSolver
	Handles: { any }, -- dense array of PlaybackHandles
	HandleCount: number,
	MaxLodTier: number?,
	SkipFrames: number,
}

-- ============================================================================
-- [[ INTERNAL STATE ]]
-- ============================================================================

local __RigArray: { RigEntry } = {}
local __RigCount: number = 0
local __IdToRigIndex: { [number]: number } = {}
local __ModelToRig: { [Model]: RigHandle } = {}
local __ModelToEntry: { [Model]: RigEntry } = {}
local __FadingHandles: { any } = {}
local __FadingCount: number = 0
local __LodManager: any = nil
local __PreloadCache: { [any]: LoadedAnimation } = {}
local __NextId: number = 0
local __DestroyConnections: { [Model]: RBXScriptConnection } = {}

local LunaRuntimeWrapper = {}

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

local function __NextHandleId(): number
	__NextId += 1
	return __NextId
end

local function __GetOrCreateEntry(Rig: RigHandle): RigEntry
	local Existing = __ModelToEntry[Rig.Model]
	if Existing then
		return Existing
	end

	-- Create new solver + entry
	local Solver = AnimationSolver.new(Rig.RigInfo)
	local Entry: RigEntry = {
		Rig = Rig,
		Solver = Solver,
		Handles = {},
		HandleCount = 0,
		MaxLodTier = nil,
		SkipFrames = 0,
	}

	__RigCount += 1
	__RigArray[__RigCount] = Entry
	__IdToRigIndex[Rig.Id :: number] = __RigCount
	__ModelToEntry[Rig.Model] = Entry

	-- Register with LOD manager if active
	if __LodManager and Rig.RootPart then
		SolverLodManager.Register(__LodManager, Solver, Rig.RootPart)
	end

	return Entry
end

local function __RemoveEntry(Entry: RigEntry)
	local Rig = Entry.Rig
	local RigId = Rig.Id
	if not RigId then
		return
	end

	-- Unregister from LOD
	if __LodManager then
		SolverLodManager.Unregister(__LodManager, Entry.Solver)
	end

	-- Destroy solver
	AnimationSolver.Destroy(Entry.Solver)

	-- Swap-remove from dense array
	local Index = __IdToRigIndex[RigId]
	if Index then
		local Last = __RigArray[__RigCount]
		if Index ~= __RigCount then
			__RigArray[Index] = Last
			__IdToRigIndex[Last.Rig.Id :: number] = Index
		end
		__RigArray[__RigCount] = nil :: any
		__RigCount -= 1
		__IdToRigIndex[RigId] = nil
	end

	__ModelToEntry[Rig.Model] = nil
end

local function __AddFading(Handle: any)
	-- Check if already in fading array
	for I = 1, __FadingCount do
		if __FadingHandles[I] == Handle then
			return
		end
	end
	__FadingCount += 1
	__FadingHandles[__FadingCount] = Handle
end

local function __ResolveRigArg(RigOrModel: any): RigHandle
	if typeof(RigOrModel) == "Instance" then
		local Existing = __ModelToRig[RigOrModel :: Model]
		if Existing then
			return Existing
		end
		return LunaRuntimeWrapper.ResolveRig(RigOrModel :: Model)
	end
	return RigOrModel :: RigHandle
end

local function __DetectAndLoad(Source: any): LoadedAnimation?
	if typeof(Source) == "Instance" then
		return LunaRuntimeWrapper.FromKeyframeSequence(Source :: KeyframeSequence)
	elseif type(Source) == "string" then
		return LunaRuntimeWrapper.FromString(Source :: string)
	elseif type(Source) == "buffer" then
		return LunaRuntimeWrapper.FromBuffer(Source :: buffer)
	elseif type(Source) == "table" and (Source :: any).Runtime then
		return Source :: LoadedAnimation
	end
	Logger.Warn("LoadAndPlay: unrecognized source type")
	return nil
end

-- ============================================================================
-- [[ LOADING ]]
-- ============================================================================

function LunaRuntimeWrapper.FromKeyframeSequence(KFS: KeyframeSequence, Name: string?): LoadedAnimation?
	-- Check cache by instance reference
	local Cached = __PreloadCache[KFS]
	if Cached then
		return Cached
	end

	local AnimName = Name or KFS.Name
	local Edit = Importer.Import("KeyframeSequence", KFS)
	if not Edit then
		Logger.Warn(`FromKeyframeSequence: failed to import "{AnimName}"`)
		return nil
	end

	Edit.Name = AnimName
	local Runtime = AnimationData.CompileEditToRuntime(Edit)

	local Loaded: LoadedAnimation = {
		Name = AnimName,
		Edit = Edit,
		Runtime = Runtime,
		Sampled = nil,
	}

	-- Cache by instance reference
	__PreloadCache[KFS] = Loaded
	return Loaded
end

function LunaRuntimeWrapper.FromString(Encoded: string): LoadedAnimation?
	local Edit, Err = StorageService.UnpackEditFromString(Encoded)
	if not Edit then
		Logger.Warn(`FromString: failed to decode — {Err or "unknown error"}`)
		return nil
	end

	local Runtime = AnimationData.CompileEditToRuntime(Edit :: EditAnimation)

	return {
		Name = (Edit :: EditAnimation).Name,
		Edit = Edit :: EditAnimation,
		Runtime = Runtime,
		Sampled = nil,
	}
end

function LunaRuntimeWrapper.FromBuffer(Data: buffer): LoadedAnimation?
	local Edit, Err = StorageService.UnpackEdit(Data)
	if not Edit then
		Logger.Warn(`FromBuffer: failed to decode — {Err or "unknown error"}`)
		return nil
	end

	local Runtime = AnimationData.CompileEditToRuntime(Edit :: EditAnimation)

	return {
		Name = (Edit :: EditAnimation).Name,
		Edit = Edit :: EditAnimation,
		Runtime = Runtime,
		Sampled = nil,
	}
end

function LunaRuntimeWrapper.FromEdit(Edit: EditAnimation): LoadedAnimation
	local Runtime = AnimationData.CompileEditToRuntime(Edit)

	return {
		Name = Edit.Name,
		Edit = Edit,
		Runtime = Runtime,
		Sampled = nil,
	}
end

function LunaRuntimeWrapper.Preload(Key: string, Source: any): LoadedAnimation?
	local Cached = __PreloadCache[Key]
	if Cached then
		return Cached
	end

	local Loaded = __DetectAndLoad(Source)
	if Loaded then
		__PreloadCache[Key] = Loaded
	end
	return Loaded
end

-- ============================================================================
-- [[ RIG SETUP ]]
-- ============================================================================

function LunaRuntimeWrapper.ResolveRig(Model: Model): RigHandle
	local Existing = __ModelToRig[Model]
	if Existing then
		return Existing
	end

	local Binding = RigResolver.Resolve(Model)
	local Handle: RigHandle = {
		Id = __NextHandleId(),
		RigInfo = Binding,
		Model = Model,
		RootPart = Binding.RootPart,
	}

	__ModelToRig[Model] = Handle

	-- Auto-cleanup on Model destroy (prevents memory leaks)
	local Connection = Model.Destroying:Connect(function()
		LunaRuntimeWrapper.RemoveRig(Handle)
	end)
	__DestroyConnections[Model] = Connection

	return Handle
end

function LunaRuntimeWrapper.RecacheDefaults(Rig: RigHandle)
	local Binding = Rig.RigInfo
	for _, Motor in Binding.Motors do
		if Motor and Motor.Parent then
			Motor:SetAttribute("_LunaDefaultC0", Motor.C0)
		end
	end
end

-- ============================================================================
-- [[ PLAYBACK ]]
-- ============================================================================

function LunaRuntimeWrapper.Play(RigOrModel: any, Animation: LoadedAnimation, Options: PlayOptions?): any
	local Rig = __ResolveRigArg(RigOrModel)
	local Entry = __GetOrCreateEntry(Rig)

	-- Add a layer to the solver
	local Layer = AnimationSolver.AddLayer(Entry.Solver, {
		Animation = Animation.Runtime,
		SampledAnimation = Animation.Sampled,
		Weight = if Options and Options.Weight then Options.Weight else 1,
	})

	-- The layer's Player IS the PlaybackHandle — bolt extra fields on
	local Handle = Layer.Player :: any
	Handle._HandleId = __NextHandleId()
	Handle._Rig = Rig
	Handle._LoadedAnimation = Animation  -- store as _LoadedAnimation, NOT _Animation (which is RuntimeAnimation used by AnimationSolver)
	Handle._Layer = Layer
	Handle._FadeTarget = nil
	Handle._FadeDuration = 0
	Handle._FadeElapsed = 0
	Handle._FadeStartWeight = 0
	Handle._AutoStopOnFadeOut = false

	-- Apply options
	if Options then
		if Options.Speed then
			Handle.Speed = Options.Speed
		end
		if Options.Looping then
			Handle.IsLooping = Options.Looping
		end
		if Options.Paused then
			Handle.State = "Paused"
		end
	end

	-- Start playing
	if not (Options and Options.Paused) then
		AnimationPlayer.Play(Handle)
	end

	-- FadeIn: start at weight 0, fade to target
	if Options and Options.FadeIn and Options.FadeIn > 0 then
		local TargetWeight = Layer.Weight
		Layer.Weight = 0
		Handle._FadeTarget = TargetWeight
		Handle._FadeDuration = Options.FadeIn
		Handle._FadeElapsed = 0
		Handle._FadeStartWeight = 0
		Handle._AutoStopOnFadeOut = false
		__AddFading(Handle)
	end

	-- Track in entry
	Entry.HandleCount += 1
	Entry.Handles[Entry.HandleCount] = Handle

	return Handle
end

function LunaRuntimeWrapper.Stop(Handle: any)
	if not Handle or Handle._HandleId == -1 then
		return
	end

	local Rig: RigHandle = Handle._Rig
	if not Rig or not Rig.Id then
		return
	end

	local Entry = __ModelToEntry[Rig.Model]
	if not Entry then
		return
	end

	-- Remove layer from solver
	local Layer = Handle._Layer
	if Layer then
		AnimationSolver.RemoveLayer(Entry.Solver, Layer)
	end

	-- Remove from entry's handle array (swap-remove)
	for I = 1, Entry.HandleCount do
		if Entry.Handles[I] == Handle then
			Entry.Handles[I] = Entry.Handles[Entry.HandleCount]
			Entry.Handles[Entry.HandleCount] = nil
			Entry.HandleCount -= 1
			break
		end
	end

	-- Remove from fading array if present
	for I = 1, __FadingCount do
		if __FadingHandles[I] == Handle then
			__FadingHandles[I] = __FadingHandles[__FadingCount]
			__FadingHandles[__FadingCount] = nil
			__FadingCount -= 1
			break
		end
	end

	-- Invalidate handle
	Handle._HandleId = -1

	-- Auto-remove entry if no handles left
	if Entry.HandleCount == 0 then
		__RemoveEntry(Entry)
	end
end

function LunaRuntimeWrapper.StopAll(RigOrModel: any)
	local Rig = __ResolveRigArg(RigOrModel)
	local Entry = __ModelToEntry[Rig.Model]
	if not Entry then
		return
	end

	-- Stop all handles (iterate backwards since Stop modifies the array)
	while Entry.HandleCount > 0 do
		LunaRuntimeWrapper.Stop(Entry.Handles[Entry.HandleCount])
	end
end

-- ============================================================================
-- [[ HANDLE METHODS ]]
-- ============================================================================

-- These are added to AnimationPlayer's metatable so Handle:FadeTo() works.
-- Safe because Handle IS an AnimationPlayer instance.

function AnimationPlayer.FadeTo(self: any, TargetWeight: number, Duration: number)
	if Duration <= 0 then
		self.Weight = TargetWeight
		if self._Layer then
			self._Layer.Weight = TargetWeight
		end
		return self
	end
	self._FadeTarget = TargetWeight
	self._FadeDuration = Duration
	self._FadeElapsed = 0
	self._FadeStartWeight = self.Weight
	self._AutoStopOnFadeOut = false
	__AddFading(self)
	return self
end

function AnimationPlayer.FadeOut(self: any, Duration: number)
	if Duration <= 0 then
		LunaRuntimeWrapper.Stop(self)
		return self
	end
	self._FadeTarget = 0
	self._FadeDuration = Duration
	self._FadeElapsed = 0
	self._FadeStartWeight = self.Weight
	self._AutoStopOnFadeOut = true
	__AddFading(self)
	return self
end

function AnimationPlayer.SetSpeed(self: any, Speed: number): any
	self.Speed = Speed
	return self
end

function AnimationPlayer.SetWeight(self: any, Weight: number): any
	self.Weight = Weight
	if self._Layer then
		self._Layer.Weight = Weight
	end
	return self
end

function AnimationPlayer.SetLooping(self: any, IsLooping: boolean): any
	self.IsLooping = IsLooping
	return self
end

-- ============================================================================
-- [[ PLAYBACK CONTROL (functional aliases) ]]
-- ============================================================================

function LunaRuntimeWrapper.SetSpeed(Handle: any, Speed: number)
	Handle.Speed = Speed
end

function LunaRuntimeWrapper.SetWeight(Handle: any, Weight: number)
	Handle.Weight = Weight
	if Handle._Layer then
		Handle._Layer.Weight = Weight
	end
end

function LunaRuntimeWrapper.SetLooping(Handle: any, IsLooping: boolean)
	Handle.IsLooping = IsLooping
end

function LunaRuntimeWrapper.Pause(Handle: any)
	Handle.State = "Paused"
end

function LunaRuntimeWrapper.Resume(Handle: any)
	Handle.State = "Playing"
end

function LunaRuntimeWrapper.IsPlaying(Handle: any): boolean
	return Handle and Handle._HandleId ~= -1 and Handle.State == "Playing"
end

-- ============================================================================
-- [[ CROSSFADE ]]
-- ============================================================================

function LunaRuntimeWrapper.Crossfade(RigOrModel: any, Animation: LoadedAnimation, Duration: number, Options: PlayOptions?): any
	local Rig = __ResolveRigArg(RigOrModel)
	local Entry = __ModelToEntry[Rig.Model]

	-- Fade out all existing handles on this rig
	if Entry then
		for I = 1, Entry.HandleCount do
			local OldHandle = Entry.Handles[I]
			if OldHandle and OldHandle._HandleId ~= -1 then
				OldHandle:FadeOut(Duration)
			end
		end
	end

	-- Play new animation, fade in
	local Opts: PlayOptions = if Options then table.clone(Options) :: any else {}
	Opts.FadeIn = Duration
	return LunaRuntimeWrapper.Play(Rig, Animation, Opts)
end

-- ============================================================================
-- [[ LOAD AND PLAY ]]
-- ============================================================================

function LunaRuntimeWrapper.LoadAndPlay(RigOrModel: any, Source: any, Options: PlayOptions?): any
	local Animation = __DetectAndLoad(Source)
	if not Animation then
		return nil
	end

	return LunaRuntimeWrapper.Play(RigOrModel, Animation, Options)
end

-- ============================================================================
-- [[ GLOBAL LOD ]]
-- ============================================================================

function LunaRuntimeWrapper.SetGlobalLod(Preset: string)
	if not __LodManager then
		__LodManager = SolverLodManager.new(Preset)
		-- Register all existing rigs
		for I = 1, __RigCount do
			local Entry = __RigArray[I]
			if Entry.Rig.RootPart then
				SolverLodManager.Register(__LodManager, Entry.Solver, Entry.Rig.RootPart)
			end
		end
	else
		SolverLodManager.SetPreset(__LodManager, Preset)
	end
end

function LunaRuntimeWrapper.SetGlobalLodBudget(BudgetMs: number)
	if not __LodManager then
		__LodManager = SolverLodManager.new("Default")
		for I = 1, __RigCount do
			local Entry = __RigArray[I]
			if Entry.Rig.RootPart then
				SolverLodManager.Register(__LodManager, Entry.Solver, Entry.Rig.RootPart)
			end
		end
	end
	SolverLodManager.SetBudget(__LodManager, BudgetMs)
end

function LunaRuntimeWrapper.DisableLod()
	if __LodManager then
		SolverLodManager.Destroy(__LodManager)
		__LodManager = nil
	end
end

-- ============================================================================
-- [[ BATCH UPDATE ]]
-- ============================================================================

function LunaRuntimeWrapper.Step(DeltaTime: number)
	-- 1. LOD step
	if __LodManager and __RigCount > 0 then
		SolverLodManager.Step(__LodManager, DeltaTime)
		-- Write MaxLodTier into each RigEntry from LOD manager
		for I = 1, __RigCount do
			local Entry = __RigArray[I]
			Entry.MaxLodTier = SolverLodManager.GetTier(__LodManager, Entry.Solver)
		end
	end

	-- 2. Tick active fades (separate dense array, usually empty)
	local I = 1
	while I <= __FadingCount do
		local Handle = __FadingHandles[I]
		Handle._FadeElapsed += DeltaTime
		local Alpha = math.min(Handle._FadeElapsed / Handle._FadeDuration, 1)
		local NewWeight = Handle._FadeStartWeight + (Handle._FadeTarget - Handle._FadeStartWeight) * Alpha
		Handle.Weight = NewWeight
		-- Sync layer weight
		if Handle._Layer then
			Handle._Layer.Weight = NewWeight
		end
		if Alpha >= 1 then
			Handle._FadeTarget = nil
			-- Swap-remove from fading array
			__FadingHandles[I] = __FadingHandles[__FadingCount]
			__FadingHandles[__FadingCount] = nil
			__FadingCount -= 1
			-- Auto-stop if faded to zero
			if NewWeight <= 0.001 and Handle._AutoStopOnFadeOut then
				LunaRuntimeWrapper.Stop(Handle)
			end
			-- Don't increment — swapped element needs processing
		else
			I += 1
		end
	end

	-- 3. Evaluate all rigs (animation data hot in cache)
	for RigIdx = 1, __RigCount do
		local Entry = __RigArray[RigIdx]
		if Entry.SkipFrames > 0 then
			Entry.SkipFrames -= 1
			continue
		end
		AnimationSolver.Evaluate(Entry.Solver, DeltaTime, Entry.MaxLodTier)
	end

	-- 4. Apply all motor writes (batch motor writes)
	for RigIdx = 1, __RigCount do
		local Entry = __RigArray[RigIdx]
		if Entry.SkipFrames <= 0 then
			AnimationSolver.Apply(Entry.Solver)
		end
	end
end

-- ============================================================================
-- [[ QUERY ]]
-- ============================================================================

function LunaRuntimeWrapper.GetAnimations(RigOrModel: any): { any }
	local Rig = __ResolveRigArg(RigOrModel)
	local Entry = __ModelToEntry[Rig.Model]
	if not Entry then
		return {}
	end

	local Result = table.create(Entry.HandleCount)
	for I = 1, Entry.HandleCount do
		Result[I] = Entry.Handles[I]
	end
	return Result
end

function LunaRuntimeWrapper.GetRig(Model: Model): RigHandle?
	return __ModelToRig[Model]
end

function LunaRuntimeWrapper.GetActiveRigCount(): number
	return __RigCount
end

function LunaRuntimeWrapper.GetSolverUnsafe(RigOrModel: any): any
	local Rig = __ResolveRigArg(RigOrModel)
	local Entry = __ModelToEntry[Rig.Model]
	if not Entry then
		return nil
	end
	return Entry.Solver
end

-- ============================================================================
-- [[ HOOK REGISTRATION (passthroughs to AnimationSolver) ]]
-- ============================================================================

function LunaRuntimeWrapper.AddPreSolveHook(RigOrModel: any, Name: string, Config: SolverTypes.HookConfig)
	local Solver = LunaRuntimeWrapper.GetSolverUnsafe(RigOrModel)
	if not Solver then
		Logger.Warn(`AddPreSolveHook: no solver for {RigOrModel}`)
		return
	end
	AnimationSolver.AddPreSolveHook(Solver, Name, Config)
end

function LunaRuntimeWrapper.RemovePreSolveHook(RigOrModel: any, Name: string)
	local Solver = LunaRuntimeWrapper.GetSolverUnsafe(RigOrModel)
	if Solver then
		AnimationSolver.RemovePreSolveHook(Solver, Name)
	end
end

function LunaRuntimeWrapper.AddPostSolveHook(RigOrModel: any, Name: string, Config: SolverTypes.HookConfig)
	local Solver = LunaRuntimeWrapper.GetSolverUnsafe(RigOrModel)
	if not Solver then
		Logger.Warn(`AddPostSolveHook: no solver for {RigOrModel}`)
		return
	end
	AnimationSolver.AddPostSolveHook(Solver, Name, Config)
end

function LunaRuntimeWrapper.RemovePostSolveHook(RigOrModel: any, Name: string)
	local Solver = LunaRuntimeWrapper.GetSolverUnsafe(RigOrModel)
	if Solver then
		AnimationSolver.RemovePostSolveHook(Solver, Name)
	end
end

-- ============================================================================
-- [[ CLEANUP ]]
-- ============================================================================

function LunaRuntimeWrapper.RemoveRig(Rig: RigHandle)
	if not Rig.Id then
		return
	end

	local Entry = __ModelToEntry[Rig.Model]
	if Entry then
		-- Stop all handles
		while Entry.HandleCount > 0 do
			LunaRuntimeWrapper.Stop(Entry.Handles[Entry.HandleCount])
		end
		-- Entry is auto-removed by Stop when last handle is gone
		-- but if it wasn't (edge case), remove explicitly
		if __ModelToEntry[Rig.Model] then
			__RemoveEntry(Entry)
		end
	end

	-- Clean up rig references
	__ModelToRig[Rig.Model] = nil
	local Connection = __DestroyConnections[Rig.Model]
	if Connection then
		Connection:Disconnect()
		__DestroyConnections[Rig.Model] = nil
	end

	-- Invalidate the handle
	Rig.Id = nil
end

function LunaRuntimeWrapper.Reset()
	-- Remove all rigs (makes copies since removal modifies the array)
	local RigsToRemove = table.create(__RigCount)
	for I = 1, __RigCount do
		RigsToRemove[I] = __RigArray[I].Rig
	end
	for _, Rig in RigsToRemove do
		LunaRuntimeWrapper.RemoveRig(Rig)
	end

	-- Clear LOD
	if __LodManager then
		SolverLodManager.Destroy(__LodManager)
		__LodManager = nil
	end

	-- Clear caches
	table.clear(__PreloadCache)
	table.clear(__ModelToRig)
	table.clear(__ModelToEntry)
	table.clear(__IdToRigIndex)
	table.clear(__DestroyConnections)
	__RigCount = 0
	__FadingCount = 0
	__NextId = 0

	Logger.Info("LunaRuntimeWrapper: reset complete")
end

-- ============================================================================

export type LunaRuntimeWrapper = typeof(LunaRuntimeWrapper)

return LunaRuntimeWrapper
