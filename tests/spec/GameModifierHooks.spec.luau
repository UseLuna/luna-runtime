--!strict
--[[
	Tests for AnimationSolver PreSolve/PostSolve game modifier hooks.
	Verifies hook invocation, priority ordering, LOD tier filtering,
	payload/state threading, removal, deduplication, and zero-hook safety.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Sampler = require(ReplicatedStorage.Luna.Core.Sampler)
local AnimationSolver = require(ReplicatedStorage.Luna.Solver.AnimationSolver)
local RigResolver = require(ReplicatedStorage.Luna.Solver.RigResolver)

-- ============================================================================
-- [[ TEST HELPERS ]]
-- ============================================================================

local function __CreateMockBinding(BoneNames: { string }): RigResolver.RigBinding
	local BoneCount = #BoneNames
	local NameToIndex: { [string]: number } = {}
	for Index, Name in BoneNames do
		NameToIndex[Name] = Index
	end

	local RestPos = buffer.create(BoneCount * 12)
	local RestRot = buffer.create(BoneCount * 16)
	for Index = 0, BoneCount - 1 do
		buffer.writef32(RestRot, Index * 16 + 12, 1)
	end

	local Skeleton: RigResolver.SkeletonInfo = {
		BoneNames = BoneNames,
		NameToIndex = NameToIndex,
		ChildrenMap = {},
		ParentMap = {},
		RestPositions = RestPos,
		RestRotations = RestRot,
		Fingerprint = "mock-hooks",
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

local function __MakeSimpleAnimation(BoneName: string, TargetCF: CFrame, Duration: number?): any
	local Dur = Duration or 1
	local Edit = AnimationData.CreateEmptyAnimation("HookTest", Dur)
	local Track = AnimationData.CreateEmptyTrack(BoneName)
	AnimationData.AddKeyframe(Track, 0, TargetCF)
	AnimationData.AddKeyframe(Track, Dur, TargetCF)
	table.insert(Edit.Tracks, Track)
	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Sampler.BakeToSampled(Runtime, 30)
end

-- ============================================================================
-- [[ TESTS ]]
-- ============================================================================

describe("GameModifierHooks", function()
	local MockBinding: RigResolver.RigBinding
	local Solver: AnimationSolver.AnimationSolver
	local Sampled: any

	beforeEach(function()
		MockBinding = __CreateMockBinding({ "Root", "Spine", "Head" })
		Solver = AnimationSolver.new(MockBinding)
		Sampled = __MakeSimpleAnimation("Root", CFrame.identity)
		Solver:Play({ SampledAnimation = Sampled })
	end)

	-- ==========================================================================
	-- [[ PRESOLVE HOOKS ]]
	-- ==========================================================================

	describe("PreSolve", function()
		it("should call PreSolve hook each Update", function()
			local CallCount = 0

			Solver:AddPreSolveHook("Counter", {
				Run = function(_Solver, _Payload, _State, _DeltaTime)
					CallCount += 1
				end,
			})

			Solver:Update(0.016)
			Solver:Update(0.016)

			expect(CallCount).toBe(2)
			Solver:Destroy()
		end)

		it("should pass Payload to PreSolve hook", function()
			local ReceivedPayload: any = nil
			local ExpectedVelocity = Vector3.new(1, 2, 3)

			Solver:AddPreSolveHook("PayloadCheck", {
				Run = function(_Solver, Payload, _State, _DeltaTime)
					ReceivedPayload = Payload
				end,
			})

			Solver:SetPayload({ Velocity = ExpectedVelocity })
			Solver:Update(0.016)

			expect(ReceivedPayload).never.toBeNil()
			expect(ReceivedPayload.Velocity).toEqual(ExpectedVelocity)
			Solver:Destroy()
		end)

		it("should pass persistent State from Init to Run", function()
			local FinalCounter = 0

			Solver:AddPreSolveHook("StatefulCounter", {
				Init = function()
					return { Counter = 0 }
				end,
				Run = function(_Solver, _Payload, State, _DeltaTime)
					State.Counter += 1
					FinalCounter = State.Counter
				end,
			})

			Solver:Update(0.016)
			Solver:Update(0.016)
			Solver:Update(0.016)

			expect(FinalCounter).toBe(3)
			Solver:Destroy()
		end)

		it("should pass nil State when no Init provided", function()
			local ReceivedState: any = "NOT_NIL"

			Solver:AddPreSolveHook("NoInit", {
				Run = function(_Solver, _Payload, State, _DeltaTime)
					ReceivedState = State
				end,
			})

			Solver:Update(0.016)

			expect(ReceivedState).toBeNil()
			Solver:Destroy()
		end)

		it("should run hooks in Priority order", function()
			local Order: { string } = {}

			-- Added out of order intentionally — Priority determines execution order
			Solver:AddPreSolveHook("Second", {
				Priority = 2,
				Run = function()
					table.insert(Order, "Second")
				end,
			})
			Solver:AddPreSolveHook("First", {
				Priority = 1,
				Run = function()
					table.insert(Order, "First")
				end,
			})
			Solver:AddPreSolveHook("Third", {
				Priority = 3,
				Run = function()
					table.insert(Order, "Third")
				end,
			})

			Solver:Update(0.016)

			expect(Order[1]).toBe("First")
			expect(Order[2]).toBe("Second")
			expect(Order[3]).toBe("Third")
			Solver:Destroy()
		end)

		it("should skip hooks above MaxLodTier", function()
			local WasCalled = false

			Solver:AddPreSolveHook("HighLod", {
				LodTier = 3,
				Run = function()
					WasCalled = true
				end,
			})

			-- MaxLodTier = 1: hooks with LodTier > 1 are skipped
			Solver:Update(0.016, 1)

			expect(WasCalled).toBe(false)
			Solver:Destroy()
		end)

		it("should not skip LodTier 0 hooks regardless of MaxLodTier", function()
			local WasCalled = false

			Solver:AddPreSolveHook("AlwaysRun", {
				LodTier = 0,
				Run = function()
					WasCalled = true
				end,
			})

			-- MaxLodTier = 0: LodTier 0 hooks should still run (0 > 0 is false)
			Solver:Update(0.016, 0)

			expect(WasCalled).toBe(true)
			Solver:Destroy()
		end)
	end)

	-- ==========================================================================
	-- [[ POSTSOLVE HOOKS ]]
	-- ==========================================================================

	describe("PostSolve", function()
		it("should call PostSolve hook with pose buffers", function()
			local ReceivedPosBuf: any = nil
			local ReceivedRotBuf: any = nil
			local ReceivedBoneCount: any = nil

			Solver:AddPostSolveHook("PoseCheck", {
				Run = function(_Solver, _Payload, _State, _DeltaTime, PosBuf, RotBuf, BoneCount)
					ReceivedPosBuf = PosBuf
					ReceivedRotBuf = RotBuf
					ReceivedBoneCount = BoneCount
				end,
			})

			Solver:Update(0.016)

			expect(ReceivedPosBuf).never.toBeNil()
			expect(ReceivedRotBuf).never.toBeNil()
			expect(ReceivedBoneCount).toBe(3)
			Solver:Destroy()
		end)

		it("should allow PostSolve to modify pose buffers", function()
			-- Write sentinel values into the output pose via a PostSolve hook,
			-- then verify the solver's internal OutputPose buffer reflects the change.
			Solver:AddPostSolveHook("PoseModifier", {
				Run = function(_Solver, _Payload, _State, _DeltaTime, PosBuf, _RotBuf, _BoneCount)
					buffer.writef32(PosBuf, 0, 99)
					buffer.writef32(PosBuf, 4, 88)
					buffer.writef32(PosBuf, 8, 77)
				end,
			})

			Solver:Update(0.016)

			local OutPos = Solver._OutputPose.Positions
			expect(buffer.readf32(OutPos, 0)).toBe(99)
			expect(buffer.readf32(OutPos, 4)).toBe(88)
			expect(buffer.readf32(OutPos, 8)).toBe(77)
			Solver:Destroy()
		end)
	end)

	-- ==========================================================================
	-- [[ REMOVAL ]]
	-- ==========================================================================

	describe("Removal", function()
		it("should remove PreSolve hook by name", function()
			local WasCalled = false

			Solver:AddPreSolveHook("RemovablePreSolve", {
				Run = function()
					WasCalled = true
				end,
			})

			Solver:RemovePreSolveHook("RemovablePreSolve")
			Solver:Update(0.016)

			expect(WasCalled).toBe(false)
			Solver:Destroy()
		end)

		it("should remove PostSolve hook by name", function()
			local WasCalled = false

			Solver:AddPostSolveHook("RemovablePostSolve", {
				Run = function()
					WasCalled = true
				end,
			})

			Solver:RemovePostSolveHook("RemovablePostSolve")
			Solver:Update(0.016)

			expect(WasCalled).toBe(false)
			Solver:Destroy()
		end)
	end)

	-- ==========================================================================
	-- [[ DUPLICATE NAMES ]]
	-- ==========================================================================

	describe("Duplicate names", function()
		it("should replace existing hook when adding with same name", function()
			local FirstCalled = false
			local SecondCalled = false

			Solver:AddPreSolveHook("Dupe", {
				Run = function()
					FirstCalled = true
				end,
			})

			-- Adding with same name replaces the first
			Solver:AddPreSolveHook("Dupe", {
				Run = function()
					SecondCalled = true
				end,
			})

			Solver:Update(0.016)

			expect(FirstCalled).toBe(false)
			expect(SecondCalled).toBe(true)
			expect(#Solver._PreSolveHooks).toBe(1)
			Solver:Destroy()
		end)
	end)

	-- ==========================================================================
	-- [[ ZERO HOOKS ]]
	-- ==========================================================================

	describe("Zero hooks", function()
		it("should run Update with no hooks without errors", function()
			-- No hooks added — verify solver runs cleanly
			local Success = pcall(function()
				Solver:Update(0.016)
				Solver:Update(0.016)
			end)

			expect(Success).toBe(true)
			Solver:Destroy()
		end)
	end)

	-- ==========================================================================
	-- [[ PAYLOAD NIL ]]
	-- ==========================================================================

	describe("Payload nil", function()
		it("should pass nil Payload when SetPayload not called", function()
			local ReceivedPayload: any = "NOT_NIL"

			Solver:AddPreSolveHook("NilPayload", {
				Run = function(_Solver, Payload, _State, _DeltaTime)
					ReceivedPayload = Payload
				end,
			})

			-- Deliberately do not call SetPayload
			Solver:Update(0.016)

			expect(ReceivedPayload).toBeNil()
			Solver:Destroy()
		end)
	end)
end)
