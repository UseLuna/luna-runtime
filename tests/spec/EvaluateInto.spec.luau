--!strict
--[[
	Tests that EvaluateInto (direct Pose buffer write) produces identical results
	to the original EvaluateAnimation (StringIndexable<CFrame> return).

	Both sampled and live eval paths are tested.
	Verifies: correctness, partial eval skip, constant track handling.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
local Sampler = require(ReplicatedStorage.Luna.Core.Sampler)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local Pose = require(ReplicatedStorage.Luna.Solver.Pose)
local RigResolver = require(ReplicatedStorage.Luna.Solver.RigResolver)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-3 -- Slightly loose for CFrame round-trip tolerance

-- Build a test animation with mixed curves
local function __BuildTestAnimation(): (AnimationData.EditAnimation, AnimationData.RuntimeAnimation)
	local Duration = 2
	local Edit = AnimationData.CreateEmptyAnimation("TestEvalInto", Duration)

	-- Track 1: Linear (RightUpperArm)
	local Track1 = AnimationData.CreateEmptyTrack("RightUpperArm")
	AnimationData.AddKeyframe(Track1, 0, CFrame.identity)
	AnimationData.AddKeyframe(Track1, 1, CFrame.Angles(0, 0, -math.rad(90)))
	AnimationData.AddKeyframe(Track1, 2, CFrame.identity)
	table.insert(Edit.Tracks, Track1)

	-- Track 2: Easing (Head)
	local Track2 = AnimationData.CreateEmptyTrack("Head")
	AnimationData.AddKeyframe(Track2, 0, CFrame.identity, {
		Curve = "Easing",
		EasingStyle = "Quad",
		EasingDirection = "InOut",
		LeftHandle = nil,
		RightHandle = nil,
		HandleType = nil,
	})
	AnimationData.AddKeyframe(Track2, 1, CFrame.Angles(0, math.rad(45), 0), {
		Curve = "Easing",
		EasingStyle = "Quad",
		EasingDirection = "InOut",
		LeftHandle = nil,
		RightHandle = nil,
		HandleType = nil,
	})
	AnimationData.AddKeyframe(Track2, 2, CFrame.identity)
	table.insert(Edit.Tracks, Track2)

	-- Track 3: Constant (UpperTorso — same CFrame at all keyframes)
	local Track3 = AnimationData.CreateEmptyTrack("UpperTorso")
	AnimationData.AddKeyframe(Track3, 0, CFrame.new(0, 0.5, 0))
	AnimationData.AddKeyframe(Track3, 2, CFrame.new(0, 0.5, 0))
	table.insert(Edit.Tracks, Track3)

	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Edit, Runtime
end

describe("EvaluateInto", function()
	local _, Runtime = __BuildTestAnimation()
	local BoneNames = { "RightUpperArm", "Head", "UpperTorso" }
	local NameToIndex: { [string]: number } = {}
	for Index, Name in BoneNames do
		NameToIndex[Name] = Index
	end

	describe("Live Eval — EvaluateAnimationInto", function()
		it("matches EvaluateAnimation at t=0", function()
			local OldResult = Evaluator.EvaluateAnimation(Runtime, 0)
			local P = Pose.Create(#BoneNames)
			Evaluator.EvaluateAnimationInto(Runtime, 0, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("matches EvaluateAnimation at t=0.5", function()
			local OldResult = Evaluator.EvaluateAnimation(Runtime, 0.5)
			local P = Pose.Create(#BoneNames)
			Evaluator.EvaluateAnimationInto(Runtime, 0.5, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("matches EvaluateAnimation at t=1.0 (mid-keyframe)", function()
			local OldResult = Evaluator.EvaluateAnimation(Runtime, 1.0)
			local P = Pose.Create(#BoneNames)
			Evaluator.EvaluateAnimationInto(Runtime, 1.0, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("matches EvaluateAnimation at t=1.75 (between keyframes)", function()
			local OldResult = Evaluator.EvaluateAnimation(Runtime, 1.75)
			local P = Pose.Create(#BoneNames)
			Evaluator.EvaluateAnimationInto(Runtime, 1.75, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("skips bones with zero mask weight (partial eval)", function()
			local P = Pose.Create(#BoneNames)
			-- Set some initial values so we can verify they're untouched
			Pose.WritePosition(P.Positions, 1, Vector3.new(999, 999, 999))
			local RotOff = 0 -- Index 1
			buffer.writef32(P.Rotations, RotOff, 0.5)
			buffer.writef32(P.Rotations, RotOff + 4, 0.5)
			buffer.writef32(P.Rotations, RotOff + 8, 0.5)
			buffer.writef32(P.Rotations, RotOff + 12, 0.5)

			-- Mask: only Head (index 2) and UpperTorso (index 3) have weight
			local MaskWeights = buffer.create(3 * 4)
			buffer.writef32(MaskWeights, 0, 0) -- RightUpperArm = 0
			buffer.writef32(MaskWeights, 4, 1) -- Head = 1
			buffer.writef32(MaskWeights, 8, 1) -- UpperTorso = 1
			Evaluator.EvaluateAnimationInto(Runtime, 0.5, P.Positions, P.Rotations, NameToIndex, MaskWeights)

			-- Bone 1 (RightUpperArm) should be untouched
			local Pos1 = Pose.ReadPosition(P.Positions, 1)
			expect(Pos1).toBe(Vector3.new(999, 999, 999))
			expect(buffer.readf32(P.Rotations, 0)).toBe(0.5)

			-- Bone 2 (Head) should be evaluated — check rotation changed from identity
			local Identity = Quaternion.Identity()
			local HeadQ = {
				X = buffer.readf32(P.Rotations, 16),
				Y = buffer.readf32(P.Rotations, 20),
				Z = buffer.readf32(P.Rotations, 24),
				W = buffer.readf32(P.Rotations, 28),
			}
			local HeadRotChanged = not TestHelpers.QuatClose(HeadQ, Identity, 0.01)
			expect(HeadRotChanged).toBe(true)
		end)
	end)

	describe("Sampled Eval — EvaluateSampledInto", function()
		local Sampled = Sampler.BakeToSampled(Runtime, 60)

		it("matches EvaluateSampledAnimation at t=0", function()
			local OldResult = Sampler.EvaluateSampledAnimation(Sampled, 0)
			local P = Pose.Create(#BoneNames)
			Sampler.EvaluateSampledInto(Sampled, 0, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("matches EvaluateSampledAnimation at t=0.5", function()
			local OldResult = Sampler.EvaluateSampledAnimation(Sampled, 0.5)
			local P = Pose.Create(#BoneNames)
			Sampler.EvaluateSampledInto(Sampled, 0.5, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("matches EvaluateSampledAnimation at t=1.5", function()
			local OldResult = Sampler.EvaluateSampledAnimation(Sampled, 1.5)
			local P = Pose.Create(#BoneNames)
			Sampler.EvaluateSampledInto(Sampled, 1.5, P.Positions, P.Rotations, NameToIndex)
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("skips bones with zero mask weight (partial eval)", function()
			local P = Pose.Create(#BoneNames)
			Pose.WritePosition(P.Positions, 1, Vector3.new(999, 999, 999))

			local MaskWeights = buffer.create(3 * 4)
			buffer.writef32(MaskWeights, 0, 0) -- RightUpperArm = 0
			buffer.writef32(MaskWeights, 4, 1) -- Head = 1
			buffer.writef32(MaskWeights, 8, 1) -- UpperTorso = 1
			Sampler.EvaluateSampledInto(Sampled, 0.5, P.Positions, P.Rotations, NameToIndex, MaskWeights)

			-- Bone 1 (RightUpperArm) should be untouched
			local Pos1 = Pose.ReadPosition(P.Positions, 1)
			expect(Pos1).toBe(Vector3.new(999, 999, 999))
		end)
	end)

	describe("AnimationPlayer.EvaluateInto", function()
		local AnimationPlayer = require(ReplicatedStorage.Luna.Solver.AnimationPlayer)

		-- Build a mock RigBinding with proper Skeleton field
		local function __CreateMockBinding(): RigResolver.RigBinding
			local MockBoneNames = { "RightUpperArm", "Head", "UpperTorso" }
			local BoneCount = #MockBoneNames
			local MockNameToIndex: { [string]: number } = {}
			for Index, Name in MockBoneNames do
				MockNameToIndex[Name] = Index
			end

			local RestPos = buffer.create(BoneCount * 12)
			local RestRot = buffer.create(BoneCount * 16)
			for Index = 0, BoneCount - 1 do
				buffer.writef32(RestRot, Index * 16 + 12, 1)
			end

			return {
				Skeleton = {
					BoneNames = MockBoneNames,
					NameToIndex = MockNameToIndex,
					ChildrenMap = {},
					ParentMap = {},
					RestPositions = RestPos,
					RestRotations = RestRot,
					Fingerprint = "mock",
					RefCount = 1,
				},
				Motors = {} :: any,
				RootPart = Instance.new("Part"),
				Model = Instance.new("Model"),
			} :: any
		end

		it("evaluates live animation into pose buffer", function()
			local MockBinding = __CreateMockBinding()
			local Player = AnimationPlayer.new({
				Animation = Runtime,
				RigInfo = MockBinding,
			})
			Player.TimePosition = 0.5

			local P = Pose.Create(#BoneNames)
			Player.EvaluateInto(Player, P.Positions, P.Rotations, NameToIndex)

			-- Should have non-zero values for animated bones
			local NewResult = Pose.ComposeToCFrames(P, BoneNames)
			local OldResult = Evaluator.EvaluateAnimation(Runtime, 0.5)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)

		it("evaluates sampled animation into pose buffer", function()
			local MockBinding = __CreateMockBinding()
			local SampledAnim = Sampler.BakeToSampled(Runtime, 60)
			local Player = AnimationPlayer.new({
				SampledAnimation = SampledAnim,
				RigInfo = MockBinding,
			})
			Player.TimePosition = 1.0

			local P = Pose.Create(#BoneNames)
			Player.EvaluateInto(Player, P.Positions, P.Rotations, NameToIndex)

			local NewResult = Pose.ComposeToCFrames(P, BoneNames)
			local OldResult = Sampler.EvaluateSampledAnimation(SampledAnim, 1.0)

			for _, Name in BoneNames do
				expect(TestHelpers.CFrameComponentsClose(OldResult[Name], NewResult[Name], EPSILON)).toBe(true)
			end
		end)
	end)
end)
