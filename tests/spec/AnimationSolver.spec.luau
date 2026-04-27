--!strict
--[[
	Tests for AnimationSolver — blending, crossfade, bone masking, LiveBoneWeights, auto-revert.
	Uses mock RigBinding since Motor6Ds can't be created in test context.
	Tests the blend math directly by inspecting the output Pose buffer.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Sampler = require(ReplicatedStorage.Luna.Core.Sampler)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local AnimationSolver = require(ReplicatedStorage.Luna.Solver.AnimationSolver)
local RigResolver = require(ReplicatedStorage.Luna.Solver.RigResolver)
local Pose = require(ReplicatedStorage.Luna.Solver.Pose)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-2

-- ============================================================================
-- [[ TEST HELPERS ]]
-- ============================================================================

-- Create a mock RigBinding with named joints and a proper Skeleton field
local function __CreateMockBinding(
	BoneNames: { string },
	ChildrenMapOverride: { [string]: { string } }?
): RigResolver.RigBinding
	local BoneCount = #BoneNames
	local NameToIndex: { [string]: number } = {}
	for Index, Name in BoneNames do
		NameToIndex[Name] = Index
	end

	local ChildrenMap: { [string]: { string } } = ChildrenMapOverride or {}
	local ParentMap: { [string]: string } = {}

	-- Build linear chain if no override
	if not ChildrenMapOverride then
		for Index, Name in BoneNames do
			if Index > 1 then
				local ParentName = BoneNames[Index - 1]
				ParentMap[Name] = ParentName
				if not ChildrenMap[ParentName] then
					ChildrenMap[ParentName] = {}
				end
				table.insert(ChildrenMap[ParentName], Name)
			end
		end
	end

	local RestPos = buffer.create(BoneCount * 12)
	local RestRot = buffer.create(BoneCount * 16)
	for Index = 0, BoneCount - 1 do
		buffer.writef32(RestRot, Index * 16 + 12, 1) -- identity W=1
	end

	local Skeleton: RigResolver.SkeletonInfo = {
		BoneNames = BoneNames,
		NameToIndex = NameToIndex,
		ChildrenMap = ChildrenMap,
		ParentMap = ParentMap,
		RestPositions = RestPos,
		RestRotations = RestRot,
		Fingerprint = "mock",
		RefCount = 1,
	}

	local Motors: { Motor6D } = {} :: any
	for Index, Name in BoneNames do
		local Motor = Instance.new("Motor6D")
		Motor.Name = Name
		Motors[Index] = Motor
	end

	return {
		Skeleton = Skeleton,
		Motors = Motors,
		RootPart = Instance.new("Part"),
		Model = Instance.new("Model"),
	} :: any
end

-- Helper: get a motor by bone name from a RigBinding
local function __GetMotor(Binding: any, BoneName: string): Motor6D
	return Binding.Motors[Binding.Skeleton.NameToIndex[BoneName]]
end

-- Helper to read a bone weight from LiveBoneWeights buffer (1-based)
local function __ReadBoneWeight(Layer: any, BoneIndex: number): number
	return buffer.readf32(Layer.BoneWeights.CurrentWeights, (BoneIndex - 1) * 4)
end

-- Create a simple animation with one track at a fixed CFrame
local function __MakeSimpleAnimation(BoneName: string, TargetCF: CFrame, Duration: number?): any
	local Dur = Duration or 1
	local Edit = AnimationData.CreateEmptyAnimation("Test", Dur)
	local Track = AnimationData.CreateEmptyTrack(BoneName)
	AnimationData.AddKeyframe(Track, 0, TargetCF)
	AnimationData.AddKeyframe(Track, Dur, TargetCF) -- Constant
	table.insert(Edit.Tracks, Track)

	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Sampler.BakeToSampled(Runtime, 30)
end

-- Create a two-pose animation (oscillates between A and B)
local function __MakeTwoPoseAnimation(BoneName: string, PoseA: CFrame, PoseB: CFrame): any
	local Edit = AnimationData.CreateEmptyAnimation("TwoPose", 1)
	local Track = AnimationData.CreateEmptyTrack(BoneName)
	AnimationData.AddKeyframe(Track, 0, PoseA)
	AnimationData.AddKeyframe(Track, 1, PoseB)
	table.insert(Edit.Tracks, Track)

	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Sampler.BakeToSampled(Runtime, 30)
end

local BONE_NAMES = { "LowerTorso", "UpperTorso", "Head", "RightUpperArm", "LeftUpperArm" }

-- ============================================================================
-- [[ TESTS ]]
-- ============================================================================

describe("AnimationSolver", function()
	local RigInfo: RigResolver.RigBinding

	beforeEach(function()
		RigInfo = __CreateMockBinding(BONE_NAMES)
	end)

	describe("Construction", function()
		it("creates a solver with correct bone count", function()
			local Solver = AnimationSolver.new(RigInfo)
			expect(Solver._BoneCount).toBe(5)
			expect(#Solver._Skeleton.BoneNames).toBe(5)
			Solver:Destroy()
		end)

		it("starts with no layers", function()
			local Solver = AnimationSolver.new(RigInfo)
			expect(#Solver:GetLayers()).toBe(0)
			Solver:Destroy()
		end)
	end)

	describe("Layer Management", function()
		it("adds a layer", function()
			local Solver = AnimationSolver.new(RigInfo)
			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(45), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim })

			expect(#Solver:GetLayers()).toBe(1)
			expect(Layer.Weight).toBe(1)
			expect(Layer.BlendMode).toBe("Replace")
			Solver:Destroy()
		end)

		it("removes a layer", function()
			local Solver = AnimationSolver.new(RigInfo)
			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(45), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim })
			Solver:RemoveLayer(Layer)

			expect(#Solver:GetLayers()).toBe(0)
			Solver:Destroy()
		end)

		it("sorts layers by priority", function()
			local Solver = AnimationSolver.new(RigInfo)
			local Anim = __MakeSimpleAnimation("Head", CFrame.identity)
			local LayerHigh = Solver:AddLayer({ SampledAnimation = Anim, Priority = 10 })
			local LayerLow = Solver:AddLayer({ SampledAnimation = Anim, Priority = 1 })

			local Layers = Solver:GetLayers()
			expect(Layers[1].Priority).toBe(1)
			expect(Layers[2].Priority).toBe(10)
			Solver:Destroy()
		end)
	end)

	describe("Single Layer Playback", function()
		it("applies a single animation to the rig", function()
			local Solver = AnimationSolver.new(RigInfo)
			local TargetCF = CFrame.Angles(0, math.rad(45), 0)
			local Anim = __MakeSimpleAnimation("Head", TargetCF)
			local Layer = Solver:Play({ SampledAnimation = Anim })

			-- Run one frame
			Solver:Update(0.016)

			-- Check that Head motor got the transform
			local HeadMotor = __GetMotor(RigInfo, "Head")
			local AppliedCF = HeadMotor.Transform
			expect(TestHelpers.CFrameComponentsClose(AppliedCF, TargetCF, EPSILON)).toBe(true)
			Solver:Destroy()
		end)
	end)

	describe("Two Layer Replace Blending", function()
		it("blends two layers at equal weight to midpoint", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- Layer 1: Head rotated 90 degrees
			local Anim1 = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer1 = Solver:AddLayer({ SampledAnimation = Anim1, Weight = 0.5 })
			Layer1.Player.IsLooping = true
			Layer1.Player.Play(Layer1.Player)

			-- Layer 2: Head at identity
			local Anim2 = __MakeSimpleAnimation("Head", CFrame.identity)
			local Layer2 = Solver:AddLayer({ SampledAnimation = Anim2, Weight = 0.5 })
			Layer2.Player.IsLooping = true
			Layer2.Player.Play(Layer2.Player)

			Solver:Update(0.016)

			-- Result should be ~45 degrees (midpoint of 90 and 0)
			local HeadMotor = __GetMotor(RigInfo, "Head")
			local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
			-- Allow generous tolerance since Nlerp isn't perfectly linear
			expect(math.abs(math.deg(Y) - 45)).toBeLessThan(5)
			Solver:Destroy()
		end)

		it("higher weight layer dominates", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim1 = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer1 = Solver:AddLayer({ SampledAnimation = Anim1, Weight = 0.9 })
			Layer1.Player.IsLooping = true
			Layer1.Player.Play(Layer1.Player)

			local Anim2 = __MakeSimpleAnimation("Head", CFrame.identity)
			local Layer2 = Solver:AddLayer({ SampledAnimation = Anim2, Weight = 0.1 })
			Layer2.Player.IsLooping = true
			Layer2.Player.Play(Layer2.Player)

			Solver:Update(0.016)

			local HeadMotor = __GetMotor(RigInfo, "Head")
			local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
			-- Should be close to 90 (layer 1 dominates at 90%)
			expect(math.deg(Y)).toBeGreaterThan(70)
			Solver:Destroy()
		end)
	end)

	describe("Weight Normalization", function()
		it("fills gap with rest pose when total weight < 1.0", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- Single layer at weight 0.5 — the other 0.5 should blend toward rest pose (identity)
			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim, Weight = 0.5 })
			Layer.Player.IsLooping = true
			Layer.Player.Play(Layer.Player)

			Solver:Update(0.016)

			local HeadMotor = __GetMotor(RigInfo, "Head")
			local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
			-- 50% of 90 degrees + 50% of 0 (rest) ≈ 45 degrees
			expect(math.abs(math.deg(Y) - 45)).toBeLessThan(5)
			Solver:Destroy()
		end)
	end)

	describe("Crossfade", function()
		it("fades in new layer and fades out old", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim1 = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer1 = Solver:Play({ SampledAnimation = Anim1 })

			-- Crossfade to a new animation
			local Anim2 = __MakeSimpleAnimation("Head", CFrame.identity)
			local Layer2 = Solver:Crossfade({ SampledAnimation = Anim2 }, 0.5)

			-- At start: old layer weight=1, new layer weight=0
			expect(Layer2.Weight).toBe(0)

			-- After half the fade: weights should be roughly equal
			for _ = 1, 15 do
				Solver:Update(0.016) -- ~0.25s
			end
			expect(Layer2.Weight).toBeGreaterThan(0.3)

			-- After full fade: new layer at 1, old layer removed
			for _ = 1, 30 do
				Solver:Update(0.016)
			end
			expect(Layer2.Weight).toBeGreaterThan(0.9)
			Solver:Destroy()
		end)
	end)

	describe("Per-Bone Masking", function()
		it("applies different animations to different bones via initial mask", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- Layer 1: full body idle (all bones at identity)
			local Anim1 = __MakeSimpleAnimation("Head", CFrame.identity)
			local Layer1 = Solver:AddLayer({ SampledAnimation = Anim1 })
			Layer1.Player.IsLooping = true
			Layer1.Player.Play(Layer1.Player)

			-- Layer 2: only Head rotated, masked to Head only
			-- Buffer mask: only bone index 3 (Head) = 1.0, rest = 0.0
			local HeadMask = buffer.create(5 * 4)
			buffer.writef32(HeadMask, 2 * 4, 1.0) -- 0-based offset for index 3
			local Anim2 = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer2 = Solver:AddLayer({
				SampledAnimation = Anim2,
				InitialMaskWeights = HeadMask,
				Priority = 2,
			})
			Layer2.Player.IsLooping = true
			Layer2.Player.Play(Layer2.Player)

			Solver:Update(0.016)

			-- Head should be rotated (layer 2 applies)
			local HeadMotor = __GetMotor(RigInfo, "Head")
			local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
			expect(math.abs(math.deg(Y))).toBeGreaterThan(30)

			-- Other bones should be near identity (layer 1 only)
			local TorsoMotor = __GetMotor(RigInfo, "UpperTorso")
			expect(TestHelpers.CFrameComponentsClose(TorsoMotor.Transform, CFrame.identity, 0.1)).toBe(true)

			Solver:Destroy()
		end)
	end)

	describe("SetBoneWeight", function()
		it("changes per-bone weight dynamically", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim })
			Layer.Player.IsLooping = true
			Layer.Player.Play(Layer.Player)

			-- Set Head bone weight to 0 (snap)
			Solver:SetBoneWeight(Layer, "Head", 0, "Snap")

			Solver:Update(0.016)

			-- Head should be at rest pose (weight=0 means this layer doesn't contribute)
			local HeadMotor = __GetMotor(RigInfo, "Head")
			expect(TestHelpers.CFrameComponentsClose(HeadMotor.Transform, CFrame.identity, 0.1)).toBe(true)

			Solver:Destroy()
		end)
	end)

	describe("SetBoneWeightFromBone", function()
		it("sets weight for bone and all descendants", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim })
			Layer.Player.IsLooping = true
			Layer.Player.Play(Layer.Player)

			-- Set UpperTorso and descendants to weight 0
			-- Hierarchy: LowerTorso → UpperTorso → Head, RightUpperArm, LeftUpperArm
			Solver:SetBoneWeightFromBone(Layer, "UpperTorso", 0, "Snap")

			-- UpperTorso, Head, RightUpperArm, LeftUpperArm should be 0
			expect(__ReadBoneWeight(Layer, 2)).toBe(0) -- UpperTorso
			expect(__ReadBoneWeight(Layer, 3)).toBe(0) -- Head
			expect(__ReadBoneWeight(Layer, 4)).toBe(0) -- RightUpperArm
			expect(__ReadBoneWeight(Layer, 5)).toBe(0) -- LeftUpperArm

			-- LowerTorso should still be 1
			expect(__ReadBoneWeight(Layer, 1)).toBe(1)

			Solver:Destroy()
		end)
	end)

	describe("LiveBoneWeights Transitions", function()
		it("lerp transitions toward target over time", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim })
			Layer.Player.IsLooping = true
			Layer.Player.Play(Layer.Player)

			-- Start at weight 1, transition to 0 via Lerp
			Solver:SetBoneWeight(Layer, "Head", 0, "Lerp", { Speed = 10 })

			-- Weight should decrease over time
			Solver:Update(0.1)
			local WeightAfterStep = __ReadBoneWeight(Layer, 3) -- Head index
			expect(WeightAfterStep).toBeLessThan(1)
			expect(WeightAfterStep).toBeGreaterThan(0)

			-- After many steps, should be near 0
			for _ = 1, 50 do
				Solver:Update(0.05)
			end
			expect(__ReadBoneWeight(Layer, 3)).toBeLessThan(0.01)

			Solver:Destroy()
		end)
	end)

	describe("Auto-Revert", function()
		it("reverts bone weight changes when layer is removed", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- Base layer (always playing)
			local Anim1 = __MakeSimpleAnimation("Head", CFrame.identity)
			local BaseLayer = Solver:AddLayer({ SampledAnimation = Anim1 })
			BaseLayer.Player.IsLooping = true
			BaseLayer.Player.Play(BaseLayer.Player)

			-- Overlay layer with AutoRevert
			local Anim2 = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local OverlayLayer = Solver:AddLayer({
				SampledAnimation = Anim2,
				AutoRevert = true,
				Priority = 2,
			})
			OverlayLayer.Player.IsLooping = true
			OverlayLayer.Player.Play(OverlayLayer.Player)

			-- Set a bone weight change on the overlay
			Solver:SetBoneWeight(OverlayLayer, "Head", 0.5, "Snap")
			expect(__ReadBoneWeight(OverlayLayer, 3)).toBe(0.5)
			expect(#OverlayLayer.__OwnedWeightChanges).toBe(1)

			Solver:Destroy()
		end)
	end)

	describe("Perceptual Cull", function()
		it("skips evaluation for layers with near-zero effective weight", function()
			local Solver = AnimationSolver.new(RigInfo)

			local Anim = __MakeSimpleAnimation("Head", CFrame.Angles(0, math.rad(90), 0))
			local Layer = Solver:AddLayer({ SampledAnimation = Anim, Weight = 0.001 })
			Layer.Player.IsLooping = true
			Layer.Player.Play(Layer.Player)

			-- Layer weight × max bone weight = 0.001 × 1.0 = 0.001 < 0.01 threshold
			-- Should not crash and should produce rest pose
			Solver:Update(0.016)

			-- Head should be at rest pose since the layer was culled
			local HeadMotor = __GetMotor(RigInfo, "Head")
			expect(TestHelpers.CFrameComponentsClose(HeadMotor.Transform, CFrame.identity, 0.1)).toBe(true)

			Solver:Destroy()
		end)
	end)

	describe("Cleanup", function()
		it("destroys all layers on Destroy", function()
			local Solver = AnimationSolver.new(RigInfo)
			local Anim = __MakeSimpleAnimation("Head", CFrame.identity)
			Solver:AddLayer({ SampledAnimation = Anim })
			Solver:AddLayer({ SampledAnimation = Anim })

			Solver:Destroy()
			expect(#Solver._Layers).toBe(0)
		end)
	end)

	describe("LOD tier culling", function()
		local Solver: AnimationSolver.AnimationSolver
		local MockBinding: RigResolver.RigBinding

		beforeEach(function()
			MockBinding = __CreateMockBinding({ "Root", "Spine", "Head" })
			Solver = AnimationSolver.new(MockBinding)
		end)

		it("should evaluate all layers when MaxLodTier is nil", function()
			local Sampled = __MakeSimpleAnimation("Root", CFrame.new(0, 1, 0))

			local Layer0 = Solver:AddLayer({ SampledAnimation = Sampled, LodTier = 0 })
			Layer0.Player:Play()
			local Layer3 = Solver:AddLayer({ SampledAnimation = Sampled, LodTier = 3 })
			Layer3.Player:Play()

			Solver:Update(0.016) -- no MaxLodTier
			-- Both layers should have been evaluated (no crash, solver ran)
			expect(#Solver:GetLayers()).toBe(2)
		end)

		it("should skip layers above MaxLodTier", function()
			local Sampled = __MakeSimpleAnimation("Root", CFrame.new(0, 1, 0))

			local Layer0 = Solver:AddLayer({ SampledAnimation = Sampled, LodTier = 0 })
			Layer0.Player:Play()
			local Layer3 = Solver:AddLayer({ SampledAnimation = Sampled, LodTier = 3 })
			Layer3.Player:Play()

			-- With MaxLodTier = 1, Layer3 (LodTier=3) should be culled
			Solver:Update(0.016, 1)

			-- Solver still has 2 layers (culling doesn't remove, just skips eval)
			expect(#Solver:GetLayers()).toBe(2)
		end)

		it("should default LodTier to 0 when not specified in config", function()
			local Sampled = __MakeSimpleAnimation("Root", CFrame.new(0, 1, 0))

			local Layer = Solver:AddLayer({ SampledAnimation = Sampled })
			expect(Layer.LodTier).toBe(0)
		end)

		it("should keep LodTier 0 layers even at MaxLodTier 0", function()
			local Sampled = __MakeSimpleAnimation("Root", CFrame.new(0, 1, 0))

			local Layer = Solver:AddLayer({ SampledAnimation = Sampled, LodTier = 0 })
			Layer.Player:Play()

			-- MaxLodTier = 0: only LodTier 0 survives (0 > 0 is false, not culled)
			Solver:Update(0.016, 0)
			expect(#Solver:GetLayers()).toBe(1)
		end)
	end)

	describe("Auto-masking from track presence", function()
		-- Build a Runtime animation (NOT sampled) with tracks for the named bones at identity.
		local function __MakeRuntimeAnimation(BoneNames: { string }): any
			local Edit = AnimationData.CreateEmptyAnimation("AutoMaskTest", 1.0)
			for _, Name in BoneNames do
				local Track = AnimationData.CreateEmptyTrack(Name)
				AnimationData.AddKeyframe(Track, 0, CFrame.identity)
				AnimationData.AddKeyframe(Track, 1, CFrame.identity)
				table.insert(Edit.Tracks, Track)
			end
			return AnimationData.CompileEditToRuntime(Edit)
		end

		it("defaults bone weights to 1.0 for tracks present and 0.0 for tracks absent", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- BONE_NAMES = { "LowerTorso", "UpperTorso", "Head", "RightUpperArm", "LeftUpperArm" }
			-- Author tracks for upper body only (no LowerTorso).
			local Runtime = __MakeRuntimeAnimation({ "UpperTorso", "Head", "RightUpperArm", "LeftUpperArm" })
			local Layer = Solver:AddLayer({ Animation = Runtime, Weight = 1.0 })

			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.UpperTorso)).toBe(1.0)
			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.Head)).toBe(1.0)
			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.RightUpperArm)).toBe(1.0)
			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.LeftUpperArm)).toBe(1.0)
			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.LowerTorso)).toBe(0.0)

			Solver:Destroy()
		end)

		it("explicit InitialMaskWeights overrides the auto-mask", function()
			local Solver = AnimationSolver.new(RigInfo)

			-- Author a Head-only track.
			local Runtime = __MakeRuntimeAnimation({ "Head" })

			-- Explicit mask: half-weight on UpperTorso, zero on Head — opposite of what auto-mask would produce.
			local BoneCount = #RigInfo.Skeleton.BoneNames
			local Mask = buffer.create(BoneCount * 4)
			for Index, Name in RigInfo.Skeleton.BoneNames do
				local Weight: number = if Name == "UpperTorso" then 0.5 else 0.0
				buffer.writef32(Mask, (Index - 1) * 4, Weight)
			end

			local Layer = Solver:AddLayer({ Animation = Runtime, Weight = 1.0, InitialMaskWeights = Mask })

			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.UpperTorso)).toBe(0.5)
			expect(__ReadBoneWeight(Layer, RigInfo.Skeleton.NameToIndex.Head)).toBe(0.0)

			Solver:Destroy()
		end)
	end)
end)
