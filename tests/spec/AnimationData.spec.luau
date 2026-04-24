--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Constants = require(ReplicatedStorage.Luna.Core.Constants)

describe("AnimationData", function()
	describe("CreateEmptyAnimation", function()
		it("returns correct defaults", function()
			local Anim = AnimationData.CreateEmptyAnimation("Test", 5)
			expect(Anim.Name).toBe("Test")
			expect(Anim.Duration).toBe(5)
			expect(#Anim.Tracks).toBe(0)
			expect(Anim.Looping).toBe(false)
			expect(Anim.Priority).toBe(0)
		end)
	end)

	describe("CreateEmptyTrack", function()
		it("returns correct name and IsConstant = true", function()
			local Track = AnimationData.CreateEmptyTrack("Arm")
			expect(Track.Name).toBe("Arm")
			expect(Track.IsConstant).toBe(true)
		end)

		it("initializes 6 empty channels", function()
			local Track = AnimationData.CreateEmptyTrack("Arm")
			for _, ChannelId in Constants.CHANNEL_IDS do
				local Channel = Track.Channels[ChannelId]
				expect(Channel).toBeDefined()
				expect(Channel.Id).toBe(ChannelId)
				expect(#Channel.Keyframes).toBe(0)
				expect(Channel.IsConstant).toBe(true)
			end
		end)
	end)

	describe("AddKeyframe (CFrame compat)", function()
		it("inserts in sorted order by time across all channels", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 1.0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.5, CFrame.identity)
			AnimationData.AddKeyframe(Track, 0.0, CFrame.identity)

			local PosX = Track.Channels.PositionX
			expect(PosX.Keyframes[1].Time).toBe(0.0)
			expect(PosX.Keyframes[2].Time).toBe(0.5)
			expect(PosX.Keyframes[3].Time).toBe(1.0)
		end)

		it("returns the insertion index", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			local Idx1 = AnimationData.AddKeyframe(Track, 1.0, CFrame.identity)
			local Idx2 = AnimationData.AddKeyframe(Track, 0.0, CFrame.identity)
			local Idx3 = AnimationData.AddKeyframe(Track, 0.5, CFrame.identity)

			expect(Idx1).toBe(1)
			expect(Idx2).toBe(1)
			expect(Idx3).toBe(2)
		end)

		it("defaults to Linear interpolation", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			expect(Track.Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Linear")
		end)

		it("decomposes CFrame to position (studs) and rotation (degrees)", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(1, 2, 3) * CFrame.Angles(0, math.rad(90), 0))

			expect(Track.Channels.PositionX.Keyframes[1].Value).toBeCloseTo(1, 4)
			expect(Track.Channels.PositionY.Keyframes[1].Value).toBeCloseTo(2, 4)
			expect(Track.Channels.PositionZ.Keyframes[1].Value).toBeCloseTo(3, 4)
			-- Y rotation of 90 degrees
			expect(Track.Channels.RotationY.Keyframes[1].Value).toBeCloseTo(90, 0)
		end)

		it("writes same interpolation to all 6 channels", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Easing",
				EasingStyle = "Quad",
				EasingDirection = "In",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			for _, ChannelId in Constants.CHANNEL_IDS do
				expect(Track.Channels[ChannelId].Keyframes[1].Interpolation.Curve).toBe("Easing")
			end
		end)
	end)

	describe("AddChannelKeyframe", function()
		it("adds to a single channel without affecting others", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			local Channel = Track.Channels.PositionY
			AnimationData.AddChannelKeyframe(Track, Channel, 0.5, 10)

			expect(#Track.Channels.PositionY.Keyframes).toBe(1)
			expect(#Track.Channels.PositionX.Keyframes).toBe(0)
			expect(Track.Channels.PositionY.Keyframes[1].Value).toBe(10)
		end)
	end)

	describe("Euler continuity filter", function()
		it("unwraps angles to prevent 179 to -181 jump", function()
			local Result = AnimationData._EulerContinuityFilter(-175, 170)
			expect(Result).toBeCloseTo(185, 4)
		end)

		it("leaves angles alone when no wrapping needed", function()
			local Result = AnimationData._EulerContinuityFilter(45, 30)
			expect(Result).toBeCloseTo(45, 4)
		end)

		it("unwraps across 360 boundary", function()
			local Result = AnimationData._EulerContinuityFilter(5, 350)
			expect(Result).toBeCloseTo(365, 4)
		end)
	end)

	describe("RemoveKeyframeAtTime", function()
		it("removes from all channels at given time", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)

			AnimationData.RemoveKeyframeAtTime(Track, 0)
			for _, ChannelId in Constants.CHANNEL_IDS do
				expect(#Track.Channels[ChannelId].Keyframes).toBe(1)
				expect(Track.Channels[ChannelId].Keyframes[1].Time).toBe(1)
			end
		end)
	end)

	describe("RemoveChannelKeyframe", function()
		it("removes from single channel only", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)

			local Channel = Track.Channels.PositionX
			AnimationData.RemoveChannelKeyframe(Track, Channel, 1)
			expect(#Track.Channels.PositionX.Keyframes).toBe(1)
			-- Other channels still have 2
			expect(#Track.Channels.PositionY.Keyframes).toBe(2)
		end)
	end)

	describe("Constant track detection", function()
		it("marks track as constant when all keyframes have same CFrame", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			expect(Track.IsConstant).toBe(true)
		end)

		it("marks track as not constant when keyframes differ", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(90), 0))
			expect(Track.IsConstant).toBe(false)
		end)

		it("per-channel constant: position constant but rotation varies", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(90), 0))
			-- Position channels should be constant, rotation channels not
			expect(Track.Channels.PositionX.IsConstant).toBe(true)
			expect(Track.Channels.RotationY.IsConstant).toBe(false)
			expect(Track.IsConstant).toBe(false)
		end)

		it("updates IsConstant when differing keyframe is removed", function()
			local Track = AnimationData.CreateEmptyTrack("Test")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.Angles(0, math.rad(90), 0))
			expect(Track.IsConstant).toBe(false)

			AnimationData.RemoveKeyframeAtTime(Track, 1)
			expect(Track.IsConstant).toBe(true)
		end)
	end)

	describe("CompileEditToRuntime", function()
		it("preserves metadata", function()
			local Edit = AnimationData.CreateEmptyAnimation("Walk", 3)
			Edit.Looping = true
			Edit.Priority = 2

			local Track = AnimationData.CreateEmptyTrack("Leg")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			expect(Runtime.Name).toBe("Walk")
			expect(Runtime.Duration).toBe(3)
			expect(Runtime.Looping).toBe(true)
			expect(Runtime.Priority).toBe(2)
		end)

		it("decomposes channels into Position and Rotation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(1, 2, 3))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local Kf = Runtime.Tracks[1].Keyframes[1]
			expect(Kf.Position.X).toBeCloseTo(1)
			expect(Kf.Position.Y).toBeCloseTo(2)
			expect(Kf.Position.Z).toBeCloseTo(3)
			expect(Kf.Rotation).toBeDefined()
		end)

		it("sets ConstantValue for constant tracks", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			expect(Runtime.Tracks[1].IsConstant).toBe(true)
			expect(Runtime.Tracks[1].ConstantValue).toBeDefined()
		end)

		it("initializes CachedIndex to 1", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			expect(Runtime.Tracks[1].CachedIndex).toBe(1)
		end)

		it("compiles Bezier keyframe with BezierCoeffs in CurveContext", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = { TimeOffset = 0.3, ValueOffset = 0.1 },
				HandleType = "Free",
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(1, 0, 0), {
				Curve = "Linear",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = { TimeOffset = -0.3, ValueOffset = -0.1 },
				RightHandle = nil,
				HandleType = "Free",
			})
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local FirstKf = Runtime.Tracks[1].Keyframes[1]
			expect(FirstKf.CurveMode).toBe("Bezier")
			expect(FirstKf.CurveContext.BezierCoeffs).never.toBeNil()
		end)

		it("compiles Easing keyframe with EasingFn in CurveContext", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Easing",
				EasingStyle = "Quad",
				EasingDirection = "In",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(1, 0, 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local FirstKf = Runtime.Tracks[1].Keyframes[1]
			expect(FirstKf.CurveMode).toBe("Easing")
			expect(FirstKf.CurveContext.EasingFn).never.toBeNil()
		end)

		it("compiles Linear keyframe with nil CurveContext fields", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.new(1, 0, 0))
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local FirstKf = Runtime.Tracks[1].Keyframes[1]
			expect(FirstKf.CurveMode).toBe("Linear")
			expect(FirstKf.CurveContext.BezierCoeffs).toBeNil()
			expect(FirstKf.CurveContext.EasingFn).toBeNil()
		end)

		it("last keyframe has nil BezierCoeffs even for Bezier mode", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Part")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			AnimationData.AddKeyframe(Track, 1, CFrame.new(1, 0, 0), {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = { TimeOffset = 0.3, ValueOffset = 0 },
				HandleType = "Free",
			})
			table.insert(Edit.Tracks, Track)

			local Runtime = AnimationData.CompileEditToRuntime(Edit)
			local LastKf = Runtime.Tracks[1].Keyframes[2]
			expect(LastKf.CurveContext.BezierCoeffs).toBeNil()
		end)
	end)
end)
