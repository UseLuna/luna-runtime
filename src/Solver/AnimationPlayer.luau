--!strict
--!optimize 2
--!native
local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local SampledTypes = require(Luna.Types.SampledTypes)
local Evaluator = require(Luna.Core.Evaluator)
local Sampler = require(Luna.Core.Sampler)
local AnimationData = require(Luna.Core.AnimationData)
local Janitor = require(Luna.Packages.janitor)
local RigResolver = require(script.Parent.RigResolver)

type StringIndexable<V> = CoreTypes.StringIndexable<V>
type RuntimeAnimation = AnimationData.RuntimeAnimation
type SampledAnimation = SampledTypes.SampledAnimation
type RigInfo = RigResolver.RigInfo
type JointMap = RigResolver.JointMap

local AnimationPlayer = {}
AnimationPlayer.__index = AnimationPlayer

export type PlaybackState = "Stopped" | "Playing" | "Paused"

export type BlendMode = "Replace"

export type AnimationPlayerConfig = {
	Animation: RuntimeAnimation?,
	SampledAnimation: SampledAnimation?,
	RigInfo: RigInfo,
	BlendMode: BlendMode?,
}

export type self = {
	State: PlaybackState,
	TimePosition: number,
	Speed: number,
	IsLooping: boolean,
	Weight: number,
	BlendMode: BlendMode,
	_Animation: RuntimeAnimation?,
	_SampledAnimation: SampledAnimation?,
	_IsSampled: boolean,
	_RigInfo: RigInfo,
	_Janitor: any,
}

export type AnimationPlayer = typeof(setmetatable({} :: self, AnimationPlayer))

function AnimationPlayer.new(Config: AnimationPlayerConfig): AnimationPlayer
	local self = setmetatable({}, AnimationPlayer) :: any

	self.State = "Stopped" :: PlaybackState
	self.TimePosition = 0
	self.Speed = 1
	self.IsLooping = false
	self.Weight = 1
	self.BlendMode = Config.BlendMode or "Replace" :: BlendMode
	self._Animation = Config.Animation
	self._SampledAnimation = Config.SampledAnimation
	self._IsSampled = Config.SampledAnimation ~= nil
	self._RigInfo = Config.RigInfo
	self._Janitor = Janitor.new()

	return self
end

function AnimationPlayer.Play(self: AnimationPlayer, Speed: number?)
	self.State = "Playing"
	self.Speed = Speed or 1
end

function AnimationPlayer.Pause(self: AnimationPlayer)
	if self.State == "Playing" then
		self.State = "Paused"
	end
end

function AnimationPlayer.Stop(self: AnimationPlayer)
	self.State = "Stopped"
	self.TimePosition = 0
	RigResolver.RestoreDefaultPose(self._RigInfo)
end

local function __HandleTimeWrap(self: AnimationPlayer)
	local Duration = if self._IsSampled and self._SampledAnimation
		then self._SampledAnimation.Duration
		else if self._Animation then self._Animation.Duration else 0
	if Duration <= 0 then
		return
	end

	if self.IsLooping then
		if self.TimePosition >= Duration then
			self.TimePosition = self.TimePosition % Duration
		elseif self.TimePosition < 0 then
			self.TimePosition = Duration + (self.TimePosition % Duration)
		end
	else
		if self.TimePosition >= Duration then
			self.TimePosition = Duration
			self.State = "Stopped"
		elseif self.TimePosition < 0 then
			self.TimePosition = 0
			self.State = "Stopped"
		end
	end
end

local function __ApplyPose(self: AnimationPlayer, Pose: StringIndexable<CFrame>)
	local Skeleton = self._RigInfo.Skeleton
	local Motors = self._RigInfo.Motors

	for TrackName, Value in Pose do
		local Index = Skeleton.NameToIndex[TrackName]
		if Index then
			local Motor = Motors[Index]
			if Motor then
				Motor.Transform = Value
			end
		end
	end
end

function AnimationPlayer.Update(self: AnimationPlayer, DeltaTime: number)
	if self.State ~= "Playing" then
		return
	end

	-- 1. Advance time
	self.TimePosition += DeltaTime * self.Speed

	-- 2. Handle looping or clamping
	__HandleTimeWrap(self)

	-- 3. Evaluate animation at current time (sampled O(1) or live eval)
	local Pose
	if self._IsSampled and self._SampledAnimation then
		Pose = Sampler.EvaluateSampledAnimation(self._SampledAnimation, self.TimePosition)
	elseif self._Animation then
		Pose = Evaluator.EvaluateAnimation(self._Animation, self.TimePosition)
	else
		return
	end

	-- 4. Apply to rig
	__ApplyPose(self, Pose)
end

-- Evaluate the current animation into buffer-backed Pose.
-- Does NOT advance time or apply to rig — the AnimationSolver orchestrates that.
-- NameToIndex maps track name → 1-based bone index. BoneMaskWeights is optional buffer.
function AnimationPlayer.EvaluateInto(
	self: AnimationPlayer,
	PosBuf: buffer,
	RotBuf: buffer,
	NameToIndex: CoreTypes.StringIndexable<number>,
	BoneMaskWeights: buffer?
)
	if self._IsSampled and self._SampledAnimation then
		Sampler.EvaluateSampledInto(
			self._SampledAnimation,
			self.TimePosition,
			PosBuf,
			RotBuf,
			NameToIndex,
			BoneMaskWeights
		)
	elseif self._Animation then
		Evaluator.EvaluateAnimationInto(
			self._Animation,
			self.TimePosition,
			PosBuf,
			RotBuf,
			NameToIndex,
			BoneMaskWeights
		)
	end
end

function AnimationPlayer.Destroy(self: AnimationPlayer)
	self.State = "Stopped"
	RigResolver.RestoreDefaultPose(self._RigInfo)
	self._Janitor:Destroy()
end

return AnimationPlayer
