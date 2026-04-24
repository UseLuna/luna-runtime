--!strict
--[[
	Tests for animation markers (event firing) and additive blending.
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
local Signal = require(ReplicatedStorage.Luna.Shared.Signal)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-2

-- ============================================================================
-- [[ HELPERS ]]
-- ============================================================================

local BONE_NAMES = { "LowerTorso", "UpperTorso", "Head", "RightUpperArm", "LeftUpperArm" }

local function __CreateMockBinding(): RigResolver.RigBinding
	local BoneCount = #BONE_NAMES
	local NameToIndex: { [string]: number } = {}
	for Index, Name in BONE_NAMES do
		NameToIndex[Name] = Index
	end

	local ChildrenMap: { [string]: { string } } = {}
	local ParentMap: { [string]: string } = {}

	for Index, Name in BONE_NAMES do
		if Index > 1 then
			local ParentName = BONE_NAMES[Index - 1]
			ParentMap[Name] = ParentName
			if not ChildrenMap[ParentName] then
				ChildrenMap[ParentName] = {}
			end
			table.insert(ChildrenMap[ParentName], Name)
		end
	end

	local RestPos = buffer.create(BoneCount * 12)
	local RestRot = buffer.create(BoneCount * 16)
	for Index = 0, BoneCount - 1 do
		buffer.writef32(RestRot, Index * 16 + 12, 1) -- identity W=1
	end

	local Skeleton: RigResolver.SkeletonInfo = {
		BoneNames = BONE_NAMES,
		NameToIndex = NameToIndex,
		ChildrenMap = ChildrenMap,
		ParentMap = ParentMap,
		RestPositions = RestPos,
		RestRotations = RestRot,
		Fingerprint = "mock",
		RefCount = 1,
	}

	local Motors: { Motor6D } = {} :: any
	for Index, Name in BONE_NAMES do
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

local function __GetMotor(Binding: any, BoneName: string): Motor6D
	return Binding.Motors[Binding.Skeleton.NameToIndex[BoneName]]
end

local function __MakeSimpleAnimation(BoneName: string, TargetCF: CFrame, Duration: number?): any
	local Dur = Duration or 1
	local Edit = AnimationData.CreateEmptyAnimation("Test", Dur)
	local Track = AnimationData.CreateEmptyTrack(BoneName)
	AnimationData.AddKeyframe(Track, 0, TargetCF)
	AnimationData.AddKeyframe(Track, Dur, TargetCF)
	table.insert(Edit.Tracks, Track)
	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Sampler.BakeToSampled(Runtime, 30)
end

-- Build rest pose arrays (Array<Vector3>, Array<Quat>) from the mock binding's Skeleton
local function __BuildRestPoseArrays(
	Binding: RigResolver.RigBinding
): ({ Vector3 }, { Quaternion.Quat }, { [string]: number })
	local Skel = Binding.Skeleton
	local BoneCount = #Skel.BoneNames
	local RestPositions = table.create(BoneCount)
	local RestRotations = table.create(BoneCount)
	for Index = 1, BoneCount do
		RestPositions[Index] = Vector3.zero
		RestRotations[Index] = Quaternion.Identity()
	end
	return RestPositions, RestRotations, Skel.NameToIndex
end

-- ============================================================================
-- [[ MARKER TESTS ]]
-- ============================================================================

describe("Animation Markers", function()
	local RigInfo: RigResolver.RigBinding

	beforeEach(function()
		RigInfo = __CreateMockBinding()
	end)

	it("fires OnMarkerReached when TimePosition crosses marker time", function()
		local Solver = AnimationSolver.new(RigInfo)
		local Anim = __MakeSimpleAnimation("Head", CFrame.identity, 1)

		local FiredMarkers: { { Name: string, Value: string } } = {}
		Signal.Connect(Solver.OnMarkerReached, function(MarkerName: string, MarkerValue: string)
			table.insert(FiredMarkers, { Name = MarkerName, Value = MarkerValue })
		end)

		local Layer = AnimationSolver.Play(Solver, {
			SampledAnimation = Anim,
			Markers = {
				{ Name = "FootStep", Value = "Left", Time = 0.5 },
			},
		})

		-- Advance past the marker
		AnimationSolver.Update(Solver, 0.6)

		expect(#FiredMarkers).toBe(1)
		expect(FiredMarkers[1].Name).toBe("FootStep")
		expect(FiredMarkers[1].Value).toBe("Left")

		AnimationSolver.Destroy(Solver)
	end)

	it("does not fire marker when time does not cross it", function()
		local Solver = AnimationSolver.new(RigInfo)
		local Anim = __MakeSimpleAnimation("Head", CFrame.identity, 1)

		local FiredCount = 0
		Signal.Connect(Solver.OnMarkerReached, function()
			FiredCount += 1
		end)

		AnimationSolver.Play(Solver, {
			SampledAnimation = Anim,
			Markers = {
				{ Name = "FootStep", Value = "Left", Time = 0.5 },
			},
		})

		-- Advance but NOT past the marker
		AnimationSolver.Update(Solver, 0.3)
		expect(FiredCount).toBe(0)

		AnimationSolver.Destroy(Solver)
	end)

	it("fires multiple markers when crossing multiple in one frame", function()
		local Solver = AnimationSolver.new(RigInfo)
		local Anim = __MakeSimpleAnimation("Head", CFrame.identity, 1)

		local FiredNames: { string } = {}
		Signal.Connect(Solver.OnMarkerReached, function(MarkerName: string)
			table.insert(FiredNames, MarkerName)
		end)

		AnimationSolver.Play(Solver, {
			SampledAnimation = Anim,
			Markers = {
				{ Name = "A", Value = "", Time = 0.1 },
				{ Name = "B", Value = "", Time = 0.2 },
				{ Name = "C", Value = "", Time = 0.3 },
			},
		})

		-- Big frame that crosses all three
		AnimationSolver.Update(Solver, 0.35)
		expect(#FiredNames).toBe(3)

		AnimationSolver.Destroy(Solver)
	end)

	it("fires marker on loop wrap", function()
		local Solver = AnimationSolver.new(RigInfo)
		local Anim = __MakeSimpleAnimation("Head", CFrame.identity, 1)

		local FiredCount = 0
		Signal.Connect(Solver.OnMarkerReached, function()
			FiredCount += 1
		end)

		local Layer = AnimationSolver.Play(Solver, {
			SampledAnimation = Anim,
			Markers = {
				{ Name = "LoopStart", Value = "", Time = 0.1 },
			},
		})

		-- Advance to near end
		AnimationSolver.Update(Solver, 0.95)
		expect(FiredCount).toBe(1) -- crossed 0.1 on first pass

		-- Advance past loop point — should wrap and cross 0.1 again
		AnimationSolver.Update(Solver, 0.2)
		expect(FiredCount).toBe(2)

		AnimationSolver.Destroy(Solver)
	end)
end)

-- ============================================================================
-- [[ ADDITIVE BLENDING TESTS ]]
-- ============================================================================

describe("Additive Blending", function()
	local RigInfo: RigResolver.RigBinding

	beforeEach(function()
		RigInfo = __CreateMockBinding()
	end)

	it("BakeToSampledAdditive produces delta samples", function()
		-- Create an animation where Head rotates 45 degrees from identity
		local Edit = AnimationData.CreateEmptyAnimation("TestAdditive", 1)
		local Track = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(Track, 0, CFrame.identity)
		AnimationData.AddKeyframe(Track, 0.5, CFrame.Angles(0, math.rad(45), 0))
		AnimationData.AddKeyframe(Track, 1, CFrame.identity)
		table.insert(Edit.Tracks, Track)

		local Runtime = AnimationData.CompileEditToRuntime(Edit)

		-- Rest pose arrays for BakeToSampledAdditive
		local RestPositions, RestRotations, NameToIndex = __BuildRestPoseArrays(RigInfo)

		local SampledAdditive = Sampler.BakeToSampledAdditive(Runtime, RestPositions, RestRotations, NameToIndex, 30)

		expect(SampledAdditive.IsAdditive).toBe(true)
		expect(SampledAdditive.SampleCount).toBeGreaterThan(0)
	end)

	it("additive layer adds rotation on top of base pose", function()
		local Solver = AnimationSolver.new(RigInfo)

		-- Base: Head at identity
		local BaseAnim = __MakeSimpleAnimation("Head", CFrame.identity, 1)
		AnimationSolver.Play(Solver, { SampledAnimation = BaseAnim, Priority = 1 })

		-- Additive: Head rotated 45 degrees (as delta from rest)
		local AdditiveEdit = AnimationData.CreateEmptyAnimation("Additive", 1)
		local AdditiveTrack = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(AdditiveTrack, 0, CFrame.Angles(0, math.rad(45), 0))
		AnimationData.AddKeyframe(AdditiveTrack, 1, CFrame.Angles(0, math.rad(45), 0))
		table.insert(AdditiveEdit.Tracks, AdditiveTrack)

		local AdditiveRuntime = AnimationData.CompileEditToRuntime(AdditiveEdit)
		local RestPositions, RestRotations, NameToIndex = __BuildRestPoseArrays(RigInfo)

		local AdditiveSampled =
			Sampler.BakeToSampledAdditive(AdditiveRuntime, RestPositions, RestRotations, NameToIndex, 30)

		AnimationSolver.Play(Solver, {
			SampledAnimation = AdditiveSampled,
			BlendMode = "Additive",
			Priority = 2,
		})

		AnimationSolver.Update(Solver, 0.016)

		-- Head should be rotated ~45 degrees (base identity + additive 45 degrees)
		local HeadMotor = __GetMotor(RigInfo, "Head")
		local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
		expect(math.abs(math.deg(Y) - 45)).toBeLessThan(5)

		AnimationSolver.Destroy(Solver)
	end)

	it("additive layer respects weight", function()
		local Solver = AnimationSolver.new(RigInfo)

		local BaseAnim = __MakeSimpleAnimation("Head", CFrame.identity, 1)
		AnimationSolver.Play(Solver, { SampledAnimation = BaseAnim, Priority = 1 })

		local AdditiveEdit = AnimationData.CreateEmptyAnimation("Additive", 1)
		local AdditiveTrack = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(AdditiveTrack, 0, CFrame.Angles(0, math.rad(90), 0))
		AnimationData.AddKeyframe(AdditiveTrack, 1, CFrame.Angles(0, math.rad(90), 0))
		table.insert(AdditiveEdit.Tracks, AdditiveTrack)

		local AdditiveRuntime = AnimationData.CompileEditToRuntime(AdditiveEdit)
		local RestPositions, RestRotations, NameToIndex = __BuildRestPoseArrays(RigInfo)

		local AdditiveSampled =
			Sampler.BakeToSampledAdditive(AdditiveRuntime, RestPositions, RestRotations, NameToIndex, 30)

		-- Additive at 50% weight — should give ~45 degrees (half of 90)
		AnimationSolver.Play(Solver, {
			SampledAnimation = AdditiveSampled,
			BlendMode = "Additive",
			Weight = 0.5,
			Priority = 2,
		})

		AnimationSolver.Update(Solver, 0.016)

		local HeadMotor = __GetMotor(RigInfo, "Head")
		local _, Y, _ = HeadMotor.Transform:ToEulerAnglesYXZ()
		expect(math.abs(math.deg(Y) - 45)).toBeLessThan(8)

		AnimationSolver.Destroy(Solver)
	end)
end)
