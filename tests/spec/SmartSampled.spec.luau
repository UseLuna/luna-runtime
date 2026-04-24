--!strict
--[[
	Tests for smart sampled tracks (Sparse Linear, Stepped, Dense strategy detection)
	and marker serialization round-trip.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
local Sampler = require(ReplicatedStorage.Luna.Core.Sampler)
local Serializer = require(ReplicatedStorage.Luna.Core.Serializer)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-3

-- ============================================================================
-- [[ MARKER SERIALIZATION ]]
-- ============================================================================

describe("Marker Serialization", function()
	it("round-trips markers through serialize/deserialize", function()
		local Edit = AnimationData.CreateEmptyAnimation("MarkerTest", 2)
		local Track = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(Track, 0, CFrame.identity)
		AnimationData.AddKeyframe(Track, 2, CFrame.identity)
		table.insert(Edit.Tracks, Track)

		Edit.Markers = {
			{ Name = "FootStep", Value = "Left", Time = 0.5 },
			{ Name = "Sound", Value = "Impact", Time = 1.0 },
			{ Name = "VFX", Value = "Spark", Time = 1.75 },
		}

		local Buf = Serializer.SerializeEdit(Edit)
		local Restored = Serializer.DeserializeEdit(Buf)

		expect(#Restored.Markers).toBe(3)
		expect(Restored.Markers[1].Name).toBe("FootStep")
		expect(Restored.Markers[1].Value).toBe("Left")
		expect(math.abs(Restored.Markers[1].Time - 0.5)).toBeLessThan(0.001)
		expect(Restored.Markers[2].Name).toBe("Sound")
		expect(Restored.Markers[3].Name).toBe("VFX")
		expect(Restored.Markers[3].Value).toBe("Spark")
	end)

	it("handles empty markers (no chunk written)", function()
		local Edit = AnimationData.CreateEmptyAnimation("NoMarkers", 1)
		local Track = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(Track, 0, CFrame.identity)
		AnimationData.AddKeyframe(Track, 1, CFrame.identity)
		table.insert(Edit.Tracks, Track)

		local Buf = Serializer.SerializeEdit(Edit)
		local Restored = Serializer.DeserializeEdit(Buf)

		expect(#Restored.Markers).toBe(0)
	end)

	it("handles UTF-8 marker names and values", function()
		local Edit = AnimationData.CreateEmptyAnimation("UTF8Test", 1)
		local Track = AnimationData.CreateEmptyTrack("Head")
		AnimationData.AddKeyframe(Track, 0, CFrame.identity)
		AnimationData.AddKeyframe(Track, 1, CFrame.identity)
		table.insert(Edit.Tracks, Track)

		Edit.Markers = {
			{ Name = "Event_123", Value = "data_abc", Time = 0.5 },
		}

		local Buf = Serializer.SerializeEdit(Edit)
		local Restored = Serializer.DeserializeEdit(Buf)

		expect(Restored.Markers[1].Name).toBe("Event_123")
		expect(Restored.Markers[1].Value).toBe("data_abc")
	end)
end)

-- ============================================================================
-- [[ SMART SAMPLED TRACKS ]]
-- ============================================================================

describe("Smart Sampled Tracks", function()
	describe("Strategy Detection", function()
		it("detects Linear tracks as Sparse", function()
			local Edit = AnimationData.CreateEmptyAnimation("LinearTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			-- Default interpolation is Linear
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.Angles(0, math.rad(45), 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Sparse")
			expect(Sampled.Tracks[1].SparseKeyframes).toBeDefined()
			expect(#Sampled.Tracks[1].SparseKeyframes).toBe(3)
			expect(Sampled.Tracks[1].SegmentMap).toBeDefined()
		end)

		it("detects Stepped tracks as Stepped", function()
			local Edit = AnimationData.CreateEmptyAnimation("SteppedTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			local SteppedInterp = {
				Curve = "Stepped",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			}
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, SteppedInterp)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.Angles(0, math.rad(90), 0), SteppedInterp)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Stepped")
			expect(Sampled.Tracks[1].SparseKeyframes).toBeDefined()
		end)

		it("detects Bezier tracks as Dense", function()
			local Edit = AnimationData.CreateEmptyAnimation("BezierTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = { TimeOffset = 0.2, ValueOffset = 0 },
				HandleType = "Free",
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(45), 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Dense")
			expect(#Sampled.Tracks[1].Positions).toBeGreaterThan(0)
		end)

		it("detects mixed tracks as Dense (conservative)", function()
			local Edit = AnimationData.CreateEmptyAnimation("MixedTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			-- First keyframe linear, second easing
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.Angles(0, math.rad(45), 0), {
				Curve = "Easing",
				EasingStyle = "Quad",
				EasingDirection = "InOut",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Dense")
		end)
	end)

	describe("Sparse (Linear) Evaluation", function()
		it("produces same output as live eval", function()
			local Edit = AnimationData.CreateEmptyAnimation("SparseEval", 2)
			local Track = AnimationData.CreateEmptyTrack("Head")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(90), 0))
			AnimationData.AddKeyframe(Track, 2, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Sparse")

			-- Compare at several time points
			local TestTimes = { 0, 0.25, 0.5, 0.75, 1.0, 1.5, 2.0 }
			for _, Time in TestTimes do
				local LiveResult = Evaluator.EvaluateTrack(Runtime.Tracks[1], Time)
				local SampledResult =
					Sampler.EvaluateSampledTrack(Sampled.Tracks[1], Time, Sampled.SampleRate, Sampled.SampleCount)
				expect(TestHelpers.CFrameComponentsClose(LiveResult, SampledResult, EPSILON)).toBe(true)
			end
		end)
	end)

	describe("Stepped Evaluation", function()
		it("snaps to floor keyframe value without interpolation", function()
			local Edit = AnimationData.CreateEmptyAnimation("SteppedEval", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			local SteppedInterp = {
				Curve = "Stepped",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			}
			local PoseA = CFrame.Angles(0, math.rad(90), 0)
			local PoseB = CFrame.Angles(0, math.rad(-45), 0)
			AnimationData.AddKeyframe(Track, 0, PoseA, SteppedInterp)
			AnimationData.AddKeyframe(Track, 0.5, PoseB, SteppedInterp)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Stepped")

			-- At t=0.25 (between first two keyframes) → should snap to PoseA (floor)
			local Result025 =
				Sampler.EvaluateSampledTrack(Sampled.Tracks[1], 0.25, Sampled.SampleRate, Sampled.SampleCount)
			expect(TestHelpers.CFrameComponentsClose(Result025, PoseA, EPSILON)).toBe(true)

			-- At t=0.75 (between second and third keyframes) → should snap to PoseB (floor)
			local Result075 =
				Sampler.EvaluateSampledTrack(Sampled.Tracks[1], 0.75, Sampled.SampleRate, Sampled.SampleCount)
			expect(TestHelpers.CFrameComponentsClose(Result075, PoseB, EPSILON)).toBe(true)
		end)
	end)

	describe("Segment Map", function()
		it("creates a segment map buffer for sparse tracks", function()
			local Edit = AnimationData.CreateEmptyAnimation("SegMapTest", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.Angles(0, math.rad(45), 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 60)

			local SampledTrack = Sampled.Tracks[1]
			expect(SampledTrack.SegmentMap).toBeDefined()
			expect(SampledTrack.SegmentMapResolution).toBeDefined()
			expect(SampledTrack.SegmentMapResolution).toBeGreaterThanOrEqual(6) -- at least 2 * keyframeCount
		end)
	end)

	describe("Dense tracks unchanged", function()
		it("Dense tracks still have Positions and RotationBuffer", function()
			local Edit = AnimationData.CreateEmptyAnimation("DenseCheck", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Easing",
				EasingStyle = "Bounce",
				EasingDirection = "Out",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(45), 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Sampled = Sampler.BakeToSampled(Runtime, 30)

			expect(Sampled.Tracks[1].EvalStrategy).toBe("Dense")
			expect(#Sampled.Tracks[1].Positions).toBeGreaterThan(0)
			expect(Sampled.Tracks[1].RotationBuffer).toBeDefined()
		end)
	end)
end)
