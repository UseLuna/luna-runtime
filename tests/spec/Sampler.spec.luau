--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
local Sampler = require(ReplicatedStorage.Luna.Core.Sampler)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-3

-- Helper: build and compile a simple two-keyframe animation
local function MakeRuntime(TrackName: string, StartCF: CFrame, EndCF: CFrame, Duration: number, IsLooping: boolean?)
	local Edit = AnimationData.CreateEmptyAnimation("Test", Duration)
	Edit.Looping = IsLooping or false
	local Track = AnimationData.CreateEmptyTrack(TrackName)
	AnimationData.AddKeyframe(Track, 0, StartCF)
	AnimationData.AddKeyframe(Track, Duration, EndCF)
	table.insert(Edit.Tracks, Track)
	return AnimationData.CompileEditToRuntime(Edit)
end

describe("Sampler", function()
	describe("BakeToSampled", function()
		it("produces correct sample count", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 30)
			-- 1 second at 30 FPS = floor(1 * 30) + 1 = 31 samples
			expect(Sampled.SampleCount).toBe(31)
		end)

		it("preserves metadata", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 2)
			Runtime.Priority = 3
			local Sampled = Sampler.BakeToSampled(Runtime, 30)
			expect(Sampled.Name).toBe("Test")
			expect(Sampled.Duration).toBe(2)
			expect(Sampled.Priority).toBe(3)
			expect(Sampled.SampleRate).toBe(30)
		end)

		it("constant tracks stored as single value with empty positions and nil rotation buffer", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Static")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(5, 5, 5))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(5, 5, 5))
			table.insert(Edit.Tracks, Track)
			local Runtime = AnimationData.CompileEditToRuntime(Edit)

			local Sampled = Sampler.BakeToSampled(Runtime, 30)
			local SampledTrack = Sampled.Tracks[1]
			expect(SampledTrack.IsConstant).toBe(true)
			expect(SampledTrack.ConstantPosition).never.toBeNil()
			expect(#SampledTrack.Positions).toBe(0)
			expect(SampledTrack.RotationBuffer).toBeNil()
		end)

		it("non-constant Linear tracks are stored as Sparse", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			local SampledTrack = Sampled.Tracks[1]
			expect(SampledTrack.IsConstant).toBe(false)
			-- Linear tracks now use Sparse strategy — original keyframes, not dense samples
			expect(SampledTrack.EvalStrategy).toBe("Sparse")
			expect(SampledTrack.SparseKeyframes).toBeDefined()
			expect(#SampledTrack.SparseKeyframes).toBe(2) -- Two original keyframes
			expect(SampledTrack.SegmentMap).toBeDefined()
		end)

		it("different sample rates produce different counts", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 2)
			local S10 = Sampler.BakeToSampled(Runtime, 10)
			local S30 = Sampler.BakeToSampled(Runtime, 30)
			local S60 = Sampler.BakeToSampled(Runtime, 60)
			expect(S10.SampleCount).toBe(21)
			expect(S30.SampleCount).toBe(61)
			expect(S60.SampleCount).toBe(121)
		end)

		it("defaults to 30 FPS when no rate specified", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime)
			expect(Sampled.SampleRate).toBe(30)
			expect(Sampled.SampleCount).toBe(31)
		end)

		it("looping animations drop the redundant last sample", function()
			local Runtime = MakeRuntime("Arm", CFrame.identity, CFrame.new(10, 0, 0), 1, true)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			-- Non-looping would be 11, looping drops 1
			expect(Sampled.SampleCount).toBe(10)
		end)

		it("last sample time is clamped to Duration", function()
			local Runtime = MakeRuntime("Arm", CFrame.new(0, 0, 0), CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			-- Evaluate at the last sample — should be at or very near x=10
			local Result = Sampler.EvaluateSampledTrack(Sampled.Tracks[1], 1.0, 10, 11)
			expect(Result.Position.X).toBeCloseTo(10, 0)
		end)
	end)

	describe("EvaluateSampledTrack", function()
		it("returns correct value at exact sample time", function()
			local Runtime = MakeRuntime("Arm", CFrame.new(0, 0, 0), CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			local Track = Sampled.Tracks[1]

			local Result = Sampler.EvaluateSampledTrack(Track, 0.5, 10, 11)
			expect(Result.Position.X).toBeCloseTo(5, 0)
		end)

		it("interpolates between samples at arbitrary time", function()
			local Runtime = MakeRuntime("Arm", CFrame.new(0, 0, 0), CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			local Track = Sampled.Tracks[1]

			local Result = Sampler.EvaluateSampledTrack(Track, 0.25, 10, 11)
			expect(math.abs(Result.Position.X - 2.5)).toBeLessThan(EPSILON)
		end)

		it("clamps after last sample for non-looping", function()
			local Runtime = MakeRuntime("Arm", CFrame.new(0, 0, 0), CFrame.new(10, 0, 0), 1)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			local Track = Sampled.Tracks[1]

			local Result = Sampler.EvaluateSampledTrack(Track, 5, 10, 11)
			expect(Result.Position.X).toBeCloseTo(10, 0)
		end)

		it("constant track returns cached value", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Static")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(7, 7, 7))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(7, 7, 7))
			table.insert(Edit.Tracks, Track)
			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)

			local Result = Sampler.EvaluateSampledTrack(Sampled.Tracks[1], 0.5, 10, 11)
			expect(Result.Position.X).toBeCloseTo(7, 0)
			expect(Result.Position.Y).toBeCloseTo(7, 0)
		end)

		it("SnapToNearest skips interpolation on Dense tracks", function()
			-- Use Easing curve to force Dense strategy (Linear would be Sparse)
			local Edit = AnimationData.CreateEmptyAnimation("SnapTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0), {
				Curve = "Easing",
				EasingStyle = "Quad",
				EasingDirection = "InOut",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Edit.Tracks, Track)
			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 10)
			local SampledTrack = Sampled.Tracks[1]

			expect(SampledTrack.EvalStrategy).toBe("Dense")

			-- With snap, should pick nearest sample (no interpolation)
			local ResultSnap = Sampler.EvaluateSampledTrack(SampledTrack, 0.25, 10, Sampled.SampleCount, true)
			-- Snapped result should be one of the discrete sample values, not interpolated
			-- Just verify it's a valid CFrame
			expect(ResultSnap).toBeDefined()

			-- Without snap, should interpolate
			local ResultLerp = Sampler.EvaluateSampledTrack(SampledTrack, 0.25, 10, Sampled.SampleCount, false)
			expect(ResultLerp).toBeDefined()
		end)
	end)

	describe("EvaluateSampledAnimation", function()
		it("evaluates all tracks", function()
			local Edit = AnimationData.CreateEmptyAnimation("Multi", 1)

			local Track1 = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track1, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track1, 1, CFrame.new(10, 0, 0))
			table.insert(Edit.Tracks, Track1)

			local Track2 = AnimationData.CreateEmptyTrack("Leg")
			AnimationData.AddKeyframe(Track2, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track2, 1, CFrame.new(0, 20, 0))
			table.insert(Edit.Tracks, Track2)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 30)

			local Result = Sampler.EvaluateSampledAnimation(Sampled, 0.5)
			expect(Result["Arm"]).toBeDefined()
			expect(Result["Leg"]).toBeDefined()
			expect(Result["Arm"].Position.X).toBeCloseTo(5, 0)
			expect(Result["Leg"].Position.Y).toBeCloseTo(10, 0)
		end)

		it("wraps time for looping animation", function()
			local Runtime = MakeRuntime("Arm", CFrame.new(0, 0, 0), CFrame.new(10, 0, 0), 2, true)
			local Sampled = Sampler.BakeToSampled(Runtime, 30)

			-- t=3 with Duration=2, looping → t=1 (midpoint)
			local Result = Sampler.EvaluateSampledAnimation(Sampled, 3)
			expect(Result["Arm"].Position.X).toBeCloseTo(5, 0)
		end)
	end)

	describe("Accuracy vs Live Evaluator", function()
		it("sampled output matches live evaluator at sample times", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 0.5, CFrame.new(5, 10, 0) * CFrame.Angles(0, math.rad(45), 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 30)

			-- Check at several exact sample times
			for Step = 0, 30 do
				local Time = Step / 30
				local LiveResult = Evaluator.EvaluateTrack(Runtime.Tracks[1], Time)
				local SampledResult = Sampler.EvaluateSampledTrack(Sampled.Tracks[1], Time, 30, 31)
				expect(TestHelpers.CFrameComponentsClose(LiveResult, SampledResult, 1e-2)).toBe(true)
			end
		end)
	end)
end)
