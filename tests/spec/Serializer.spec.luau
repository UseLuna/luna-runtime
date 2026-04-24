--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local Serializer = require(ReplicatedStorage.Luna.Core.Serializer)
local Constants = require(ReplicatedStorage.Luna.Core.Constants)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

describe("Serializer", function()
	describe("ReadHeader", function()
		it("reads format type and version from serialized edit animation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Buf = Serializer.SerializeEdit(Edit)
			local FormatType, Version, _Flags = Serializer.ReadHeader(Buf)
			expect(FormatType).toBe(Constants.FORMAT_TYPE_EDIT)
			expect(Version).toBe(Constants.FORMAT_VERSION_EDIT)
		end)

		it("errors on invalid magic", function()
			local Buf = buffer.create(12)
			buffer.writestring(Buf, 0, "NOTLUNA!")
			expect(function()
				Serializer.ReadHeader(Buf)
			end).toThrow()
		end)

		it("errors on buffer too small", function()
			local Buf = buffer.create(4)
			expect(function()
				Serializer.ReadHeader(Buf)
			end).toThrow()
		end)
	end)

	describe("Quaternion Packing", function()
		it("round-trips identity quaternion", function()
			local Q = Quaternion.Identity()
			local Packed = Serializer._PackQuaternion(Q)
			local Unpacked = Serializer._UnpackQuaternion(Packed)
			expect(TestHelpers.QuatClose(Q, Unpacked, 0.01)).toBe(true)
		end)

		it("round-trips arbitrary rotation with < 0.1 degree error", function()
			local Rotations = {
				Quaternion.FromCFrame(CFrame.Angles(1, 2, 3)),
				Quaternion.FromCFrame(CFrame.Angles(0, math.pi, 0)),
				Quaternion.FromCFrame(CFrame.Angles(0.5, -0.3, 1.2)),
				Quaternion.FromCFrame(CFrame.Angles(-1, -2, -3)),
			}

			for _, Q in Rotations do
				local Packed = Serializer._PackQuaternion(Q)
				local Unpacked = Serializer._UnpackQuaternion(Packed)

				local Dot = math.abs(Q.X * Unpacked.X + Q.Y * Unpacked.Y + Q.Z * Unpacked.Z + Q.W * Unpacked.W)
				expect(Dot).toBeGreaterThan(0.9999)
			end
		end)

		it("handles negative largest component", function()
			local Q = Quaternion.FromCFrame(CFrame.Angles(0.1, 0.1, 0.1))
			Q = { X = -Q.X, Y = -Q.Y, Z = -Q.Z, W = -Q.W }
			local Packed = Serializer._PackQuaternion(Q)
			local Unpacked = Serializer._UnpackQuaternion(Packed)

			local Dot = math.abs(Q.X * Unpacked.X + Q.Y * Unpacked.Y + Q.Z * Unpacked.Z + Q.W * Unpacked.W)
			expect(Dot).toBeGreaterThan(0.9999)
		end)
	end)

	describe("SerializeEdit / DeserializeEdit", function()
		it("round-trips empty animation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Empty", 2)
			Edit.Looping = true
			Edit.Priority = 3
			Edit.FrameRate = 24

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			expect(Result.Name).toBe("Empty")
			expect(Result.Duration).toBeCloseTo(2)
			expect(Result.Looping).toBe(true)
			expect(Result.Priority).toBe(3)
			expect(Result.FrameRate).toBeCloseTo(24)
			expect(#Result.Tracks).toBe(0)
		end)

		it("round-trips linear keyframes with scalar value preservation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Walk", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(1, 2, 3))
			AnimationData.AddKeyframe(Track, 0.5, CFrame.new(4, 5, 6) * CFrame.Angles(1, 0, 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(7, 8, 9))
			table.insert(Edit.Tracks, Track)

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			expect(#Result.Tracks).toBe(1)
			expect(Result.Tracks[1].Name).toBe("Arm")
			-- Check per-channel keyframe count and times
			local PosX = Result.Tracks[1].Channels.PositionX
			expect(#PosX.Keyframes).toBe(3)
			expect(PosX.Keyframes[1].Time).toBeCloseTo(0)
			expect(PosX.Keyframes[2].Time).toBeCloseTo(0.5)
			expect(PosX.Keyframes[3].Time).toBeCloseTo(1)

			-- Position values (f32 precision)
			expect(PosX.Keyframes[1].Value).toBeCloseTo(1, 4)
			expect(Result.Tracks[1].Channels.PositionY.Keyframes[1].Value).toBeCloseTo(2, 4)
			expect(Result.Tracks[1].Channels.PositionZ.Keyframes[1].Value).toBeCloseTo(3, 4)
		end)

		it("round-trips Bezier keyframe with handles", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Head")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Bezier",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = { TimeOffset = -0.3, ValueOffset = -0.1 },
				RightHandle = { TimeOffset = 0.4, ValueOffset = 0.2 },
				HandleType = "Aligned",
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(5, 0, 0))
			table.insert(Edit.Tracks, Track)

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			-- Check interpolation on PositionX channel (representative)
			local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
			expect(Interp.Curve).toBe("Bezier")
			expect(Interp.HandleType).toBe("Aligned")
			expect(Interp.LeftHandle).never.toBeNil()
			expect(Interp.RightHandle).never.toBeNil()
			if Interp.LeftHandle and Interp.RightHandle then
				expect(Interp.LeftHandle.TimeOffset).toBeCloseTo(-0.3)
				expect(Interp.LeftHandle.ValueOffset).toBeCloseTo(-0.1)
				expect(Interp.RightHandle.TimeOffset).toBeCloseTo(0.4)
				expect(Interp.RightHandle.ValueOffset).toBeCloseTo(0.2)
			end
		end)

		it("round-trips Easing keyframe with style and direction", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Leg")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity, {
				Curve = "Easing",
				EasingStyle = "Bounce",
				EasingDirection = "InOut",
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(Track, 1, CFrame.new(0, 5, 0))
			table.insert(Edit.Tracks, Track)

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			local Interp = Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation
			expect(Interp.Curve).toBe("Easing")
			expect(Interp.EasingStyle).toBe("Bounce")
			expect(Interp.EasingDirection).toBe("InOut")
		end)

		it("round-trips Stepped and Hermite modes", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 2)

			local SteppedTrack = AnimationData.CreateEmptyTrack("SteppedArm")
			AnimationData.AddKeyframe(SteppedTrack, 0, CFrame.identity, {
				Curve = "Stepped",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(SteppedTrack, 1, CFrame.new(5, 0, 0))
			table.insert(Edit.Tracks, SteppedTrack)

			local HermiteTrack = AnimationData.CreateEmptyTrack("HermiteLeg")
			AnimationData.AddKeyframe(HermiteTrack, 0, CFrame.identity, {
				Curve = "Hermite",
				EasingStyle = nil,
				EasingDirection = nil,
				LeftHandle = nil,
				RightHandle = nil,
				HandleType = nil,
			})
			AnimationData.AddKeyframe(HermiteTrack, 1, CFrame.new(0, 5, 0))
			table.insert(Edit.Tracks, HermiteTrack)

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			expect(Result.Tracks[1].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Stepped")
			expect(Result.Tracks[2].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Hermite")
		end)

		it("round-trips multiple tracks", function()
			local Edit = AnimationData.CreateEmptyAnimation("Multi", 1)
			for Index = 1, 5 do
				local Track = AnimationData.CreateEmptyTrack(`Track{Index}`)
				AnimationData.AddKeyframe(Track, 0, CFrame.identity)
				AnimationData.AddKeyframe(Track, 1, CFrame.new(Index, 0, 0))
				table.insert(Edit.Tracks, Track)
			end

			local Buf = Serializer.SerializeEdit(Edit)
			local Result = Serializer.DeserializeEdit(Buf)

			expect(#Result.Tracks).toBe(5)
			for Index = 1, 5 do
				expect(Result.Tracks[Index].Name).toBe(`Track{Index}`)
			end
		end)

		it("detects corrupted CRC", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.identity)
			table.insert(Edit.Tracks, Track)

			local Buf = Serializer.SerializeEdit(Edit)

			local CorruptOffset = Constants.LUNA_HEADER_SIZE + 6 + 1
			local Original = buffer.readu8(Buf, CorruptOffset)
			buffer.writeu8(Buf, CorruptOffset, bit32.bxor(Original, 0xFF))

			expect(function()
				Serializer.DeserializeEdit(Buf)
			end).toThrow()
		end)

		it("errors on unknown critical chunk", function()
			local Edit = AnimationData.CreateEmptyAnimation("Test", 1)
			local Buf = Serializer.SerializeEdit(Edit)

			local ExtraChunkSize = 8
			local NewBuf = buffer.create(buffer.len(Buf) + ExtraChunkSize)
			buffer.copy(NewBuf, 0, Buf)

			local Offset = buffer.len(Buf)
			buffer.writeu16(NewBuf, Offset, 0x00FF)
			buffer.writeu32(NewBuf, Offset + 2, 0)
			buffer.writeu16(NewBuf, Offset + 6, 0)

			expect(function()
				Serializer.DeserializeEdit(NewBuf)
			end).toThrow()
		end)
	end)

	describe("Full Pipeline Round-Trip", function()
		it("serialize → deserialize → compile → evaluate matches original", function()
			local Edit = AnimationData.CreateEmptyAnimation("Roundtrip", 1)
			local Track = AnimationData.CreateEmptyTrack("Arm")
			AnimationData.AddKeyframe(Track, 0, CFrame.new(0, 0, 0))
			AnimationData.AddKeyframe(Track, 0.5, CFrame.new(5, 10, 0) * CFrame.Angles(0, math.rad(45), 0))
			AnimationData.AddKeyframe(Track, 1, CFrame.new(10, 0, 0))
			table.insert(Edit.Tracks, Track)

			local OriginalRuntime = AnimationData.CompileEditToRuntime(Edit)
			local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)
			local OriginalPose = Evaluator.EvaluateAnimation(OriginalRuntime, 0.5)

			local Buf = Serializer.SerializeEdit(Edit)
			local Deserialized = Serializer.DeserializeEdit(Buf)
			local DeserializedRuntime = AnimationData.CompileEditToRuntime(Deserialized)
			local DeserializedPose = Evaluator.EvaluateAnimation(DeserializedRuntime, 0.5)

			expect(TestHelpers.CFrameComponentsClose(OriginalPose["Arm"], DeserializedPose["Arm"], 1e-3)).toBe(true)
		end)
	end)
end)
