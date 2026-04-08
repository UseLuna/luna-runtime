--!strict

local Workspace = game:GetService("Workspace")
local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local AnimationData = require(LunaRuntime.Core.AnimationData)
local Logger = require(LunaRuntime.Shared.Logger)

type EditAnimation = AnimationData.EditAnimation
type EditTrack = AnimationData.EditTrack
type InterpolationMode = AnimationData.InterpolationMode

-- Bone lists by rig type
local R15_BONES: { string } = {
	"Head",
	"UpperTorso",
	"LowerTorso",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

local R6_BONES: { string } = {
	"Head",
	"Torso",
	"Left Arm",
	"Right Arm",
	"Left Leg",
	"Right Leg",
}

-- Synthetic animation configs: { KeyframeCount, Duration, TrackCount (nil = all bones) }
type SyntheticConfig = {
	KeyframeCount: number,
	Duration: number,
	UseAllBones: boolean,
}

local SYNTHETIC_CONFIGS: { [string]: SyntheticConfig } = {
	Simple = {
		KeyframeCount = 3,
		Duration = 1,
		UseAllBones = false,
	},
	WalkCycle = {
		KeyframeCount = 9,
		Duration = 1,
		UseAllBones = true,
	},
	Heavy = {
		KeyframeCount = 12,
		Duration = 2,
		UseAllBones = true,
	},
}

local AnimationProvider = {}

-- Build a list of bone names for the given rig type.
-- Simple uses only 6 tracks (first 6 of R15 or all of R6).
local function __GetBones(Type: string, RigType: string): { string }
	local Config = SYNTHETIC_CONFIGS[Type]
	if not Config then
		Logger.Warn(`AnimationProvider: Unknown synthetic type "{Type}", defaulting to Simple`)
		return { R15_BONES[1], R15_BONES[2], R15_BONES[3], R15_BONES[4], R15_BONES[5], R15_BONES[6] }
	end

	local Bones: { string }
	if RigType == "R6" then
		Bones = R6_BONES
	else
		Bones = R15_BONES
	end

	if not Config.UseAllBones then
		-- Simple: use first 6 bones (or all available if fewer than 6)
		local Count = math.min(6, #Bones)
		local Subset: { string } = table.create(Count)
		for Index = 1, Count do
			Subset[Index] = Bones[Index]
		end
		return Subset
	end

	return Bones
end

-- Generate a sinusoidal rotation value (degrees) for a given bone index and keyframe.
-- Bones offset by index to produce varied motion across the rig.
local function __SinRotation(BoneIndex: number, KeyframeIndex: number, KeyframeCount: number, Duration: number): number
	local T = (KeyframeIndex - 1) / math.max(KeyframeCount - 1, 1)
	local Phase = (BoneIndex - 1) * (math.pi / 4)
	return math.sin(T * math.pi * 2 + Phase) * 45
end

-- Build an EditAnimation from a config, bone list, and name.
local function __BuildAnimation(
	AnimName: string,
	Config: SyntheticConfig,
	Bones: { string }
): EditAnimation
	local Animation = AnimationData.CreateEmptyAnimation(AnimName, Config.Duration)
	Animation.Looping = true

	local LinearInterp: InterpolationMode = AnimationData.DefaultInterpolation()
	local KeyframeCount = Config.KeyframeCount
	local Duration = Config.Duration

	local TrackCount = #Bones
	local Tracks: { EditTrack } = table.create(TrackCount)

	for BoneIndex, BoneName in Bones do
		local Track = AnimationData.CreateEmptyTrack(BoneName)

		for KeyIndex = 1, KeyframeCount do
			local Time = (KeyIndex - 1) / math.max(KeyframeCount - 1, 1) * Duration
			local RotX = __SinRotation(BoneIndex, KeyIndex, KeyframeCount, Duration)
			-- Position stays at identity; only RotationX varies to keep it lightweight
			local CF = CFrame.fromEulerAnglesYXZ(math.rad(RotX), 0, 0)
			AnimationData.AddKeyframe(Track, Time, CF, LinearInterp)
		end

		Tracks[BoneIndex] = Track
	end

	Animation.Tracks = Tracks
	return Animation
end

-- Returns a synthetic EditAnimation for the given Type ("Simple", "WalkCycle", "Heavy")
-- and RigType ("R15" or "R6").
function AnimationProvider.GetSynthetic(Type: string, RigType: string): EditAnimation
	local Config = SYNTHETIC_CONFIGS[Type]
	if not Config then
		Logger.Warn(`AnimationProvider.GetSynthetic: Unknown type "{Type}", falling back to Simple`)
		Config = SYNTHETIC_CONFIGS.Simple
		Type = "Simple"
	end

	local Bones = __GetBones(Type, RigType)
	local AnimName = `Synthetic_{Type}_{RigType}`
	return __BuildAnimation(AnimName, Config, Bones)
end

-- Scans Workspace.Animations for KeyframeSequence children.
-- Returns an empty array if the folder does not exist.
function AnimationProvider.ScanPlaceAnimations(): { any }
	local AnimationsFolder = Workspace:FindFirstChild("Animations")
	if not AnimationsFolder then
		Logger.Warn("AnimationProvider.ScanPlaceAnimations: Workspace.Animations folder not found")
		return {}
	end

	local Results: { any } = {}
	local Count = 0

	for _, Child in AnimationsFolder:GetChildren() do
		if Child:IsA("KeyframeSequence") then
			Count += 1
			Results[Count] = Child
		end
	end

	Logger.Info(`AnimationProvider.ScanPlaceAnimations: Found {Count} KeyframeSequence(s) in Workspace.Animations`)
	return Results
end

-- Creates an Animation Instance with the given AnimationId asset string.
-- The caller is responsible for parenting and cleanup.
function AnimationProvider.FromAssetId(AssetId: string): Animation
	local Anim = Instance.new("Animation")
	Anim.AnimationId = AssetId
	return Anim
end

return AnimationProvider
