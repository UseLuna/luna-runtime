--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

-- Helper: create a compiled runtime track with given keyframe CFrames at given times
local function MakeRuntimeTrack(
	Name: string,
	TimeValues: { { Time: number, Value: CFrame, Interpolation: AnimationData.InterpolationMode? } }
)
	local Edit = AnimationData.CreateEmptyAnimation("Test", 10)
	local Track = AnimationData.CreateEmptyTrack(Name)
	for _, Pair in TimeValues do
		AnimationData.AddKeyframe(Track, Pair.Time, Pair.Value, Pair.Interpolation)
	end
	table.insert(Edit.Tracks, Track)
	local Runtime = AnimationData.CompileEditToRuntime(Edit)
	return Runtime.Tracks[1]
end

describe("Evaluator", function()
	describe("EvaluateTrack", function()
		it("returns CFrame.identity for empty track", function()
			local Track = AnimationData.CreateEmptyTrack("Empty")
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			table.insert(Edit.Tracks, Track)
			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Result = Evaluator.EvaluateTrack(Runtime.Tracks[1], 0.5)
			expect(TestHelpers.CFrameComponentsClose(Result, CFrame.identity)).toBe(true)
		end)

		it("returns exact value for single keyframe", function()
			local CF = CFrame.new(5, 10, 15)
			local Track = MakeRuntimeTrack("Single", { { Time = 0, Value = CF } })
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			expect(TestHelpers.CFrameComponentsClose(Result, CF)).toBe(true)
		end)

		it("returns ConstantValue for constant track", function()
			local CF = CFrame.new(1, 2, 3)
			local Track = MakeRuntimeTrack("Const", {
				{ Time = 0, Value = CF },
				{ Time = 1, Value = CF },
			})
			expect(Track.IsConstant).toBe(true)
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			expect(TestHelpers.CFrameComponentsClose(Result, CF)).toBe(true)
		end)

		it("linearly interpolates position at midpoint", function()
			local A = CFrame.new(0, 0, 0)
			local B = CFrame.new(10, 20, 30)
			local Track = MakeRuntimeTrack("Lerp", {
				{ Time = 0, Value = A },
				{ Time = 1, Value = B },
			})
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			expect(Result.Position.X).toBeCloseTo(5)
			expect(Result.Position.Y).toBeCloseTo(10)
			expect(Result.Position.Z).toBeCloseTo(15)
		end)

		it("clamps time before first keyframe", function()
			local CF = CFrame.new(7, 7, 7)
			local Track = MakeRuntimeTrack("Clamp", {
				{ Time = 1, Value = CF },
				{ Time = 2, Value = CFrame.new(20, 20, 20) },
			})
			local Result = Evaluator.EvaluateTrack(Track, 0)
			expect(TestHelpers.CFrameComponentsClose(Result, CF)).toBe(true)
		end)

		it("clamps time after last keyframe", function()
			local CF = CFrame.new(99, 99, 99)
			local Track = MakeRuntimeTrack("Clamp", {
				{ Time = 0, Value = CFrame.identity },
				{ Time = 1, Value = CF },
			})
			local Result = Evaluator.EvaluateTrack(Track, 5)
			expect(TestHelpers.CFrameComponentsClose(Result, CF)).toBe(true)
		end)

		it("sequential evaluation uses cached index", function()
			local Track = MakeRuntimeTrack("Seq", {
				{ Time = 0, Value = CFrame.new(0, 0, 0) },
				{ Time = 1, Value = CFrame.new(10, 0, 0) },
				{ Time = 2, Value = CFrame.new(20, 0, 0) },
			})

			-- Sequential calls should hit the cached index fast path
			local R1 = Evaluator.EvaluateTrack(Track, 0.1)
			local R2 = Evaluator.EvaluateTrack(Track, 0.2)
			local R3 = Evaluator.EvaluateTrack(Track, 0.3)

			-- All should produce reasonable X values between 0 and 10
			expect(R1.Position.X).toBeCloseTo(1, 0)
			expect(R2.Position.X).toBeCloseTo(2, 0)
			expect(R3.Position.X).toBeCloseTo(3, 0)

			-- Jump to different segment (binary search fallback)
			local R4 = Evaluator.EvaluateTrack(Track, 1.5)
			expect(R4.Position.X).toBeCloseTo(15, 0)
		end)
	end)

	describe("Curve Dispatch", function()
		it("Stepped interpolation holds at left keyframe value", function()
			local Track = MakeRuntimeTrack("Stepped", {
				{
					Time = 0,
					Value = CFrame.new(0, 0, 0),
					Interpolation = {
						Curve = "Stepped",
						EasingStyle = nil,
						EasingDirection = nil,
						LeftHandle = nil,
						RightHandle = nil,
						HandleType = nil,
					},
				},
				{ Time = 1, Value = CFrame.new(10, 0, 0) },
			})
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			-- Stepped returns alpha=0, so position should be at the left keyframe
			expect(Result.Position.X).toBeCloseTo(0, 0)
		end)

		it("Easing (Quad In) midpoint is less than linear midpoint", function()
			local Track = MakeRuntimeTrack("Easing", {
				{
					Time = 0,
					Value = CFrame.new(0, 0, 0),
					Interpolation = {
						Curve = "Easing",
						EasingStyle = "Quad",
						EasingDirection = "In",
						LeftHandle = nil,
						RightHandle = nil,
						HandleType = nil,
					},
				},
				{ Time = 1, Value = CFrame.new(10, 0, 0) },
			})
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			-- Quad In at 0.5 = 0.25, so position should be ~2.5
			expect(Result.Position.X).toBeCloseTo(2.5, 0)
		end)

		it("Hermite midpoint equals linear midpoint (smoothstep at 0.5 = 0.5)", function()
			local Track = MakeRuntimeTrack("Hermite", {
				{
					Time = 0,
					Value = CFrame.new(0, 0, 0),
					Interpolation = {
						Curve = "Hermite",
						EasingStyle = nil,
						EasingDirection = nil,
						LeftHandle = nil,
						RightHandle = nil,
						HandleType = nil,
					},
				},
				{ Time = 1, Value = CFrame.new(10, 0, 0) },
			})
			local Result = Evaluator.EvaluateTrack(Track, 0.5)
			expect(Result.Position.X).toBeCloseTo(5, 0)
		end)

		it("mixed track: first segment Stepped, second segment Linear", function()
			local Track = MakeRuntimeTrack("Mixed", {
				{
					Time = 0,
					Value = CFrame.new(0, 0, 0),
					Interpolation = {
						Curve = "Stepped",
						EasingStyle = nil,
						EasingDirection = nil,
						LeftHandle = nil,
						RightHandle = nil,
						HandleType = nil,
					},
				},
				{ Time = 1, Value = CFrame.new(10, 0, 0) },
				{ Time = 2, Value = CFrame.new(20, 0, 0) },
			})
			-- First segment (Stepped): midpoint should hold at 0
			local R1 = Evaluator.EvaluateTrack(Track, 0.5)
			expect(R1.Position.X).toBeCloseTo(0, 0)

			-- Second segment (Linear): midpoint should be 15
			local R2 = Evaluator.EvaluateTrack(Track, 1.5)
			expect(R2.Position.X).toBeCloseTo(15, 0)
		end)
	end)

	describe("EvaluateAnimation", function()
		it("returns CFrames for all tracks", function()
			local Edit = AnimationData.CreateEmptyAnimation("Multi", 2)

			local Track1 = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track1, 0, CFrame.new(1, 0, 0))
			AnimationData.AddKeyframe(Track1, 2, CFrame.new(3, 0, 0))
			table.insert(Edit.Tracks, Track1)

			local Track2 = AnimationData.CreateEmptyTrack("Leg")
			AnimationData.AddKeyframe(Track2, 0, CFrame.new(0, 1, 0))
			AnimationData.AddKeyframe(Track2, 2, CFrame.new(0, 5, 0))
			table.insert(Edit.Tracks, Track2)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Result = Evaluator.EvaluateAnimation(Runtime, 1)

			expect(Result["Arm"]).toBeDefined()
			expect(Result["Leg"]).toBeDefined()
			expect(Result["Arm"].Position.X).toBeCloseTo(2)
			expect(Result["Leg"].Position.Y).toBeCloseTo(3)
		end)

		it("wraps time for looping animation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Loop", 2)
			Edit.Looping = true

			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 2, CFrame.new(10, 0, 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)

			-- t=3 with Duration=2, looping → t=1 (midpoint)
			local Result = Evaluator.EvaluateAnimation(Runtime, 3)
			expect(Result["Part"].Position.X).toBeCloseTo(5, 0)
		end)
	end)
end)
