--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local StorageService = require(ReplicatedStorage.Luna.Solver.StorageService)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

-- Helper: build a non-trivial animation with mixed curve modes
local function MakeTestAnimation(): AnimationData.EditAnimation
	local Edit = AnimationData.CreateEmptyAnimation("StorageTest", 2)
	Edit.Looping = true
	Edit.Priority = 3
	Edit.FrameRate = 24

	-- Linear track
	local Track1 = AnimationData.CreateEmptyTrack("Arm")
	AnimationData.AddKeyframe(Track1, 0, CFrame.new(0, 0, 0))
	AnimationData.AddKeyframe(Track1, 1, CFrame.new(5, 10, 0) * CFrame.Angles(0, math.rad(45), 0))
	AnimationData.AddKeyframe(Track1, 2, CFrame.new(10, 0, 0))
	table.insert(Edit.Tracks, Track1)

	-- Easing track
	local Track2 = AnimationData.CreateEmptyTrack("Leg")
	AnimationData.AddKeyframe(Track2, 0, CFrame.identity, {
		Curve = "Easing",
		EasingStyle = "Bounce",
		EasingDirection = "Out",
		LeftHandle = nil,
		RightHandle = nil,
		HandleType = nil,
	})
	AnimationData.AddKeyframe(Track2, 2, CFrame.new(0, 5, 0))
	table.insert(Edit.Tracks, Track2)

	-- Bezier track
	local Track3 = AnimationData.CreateEmptyTrack("Head")
	AnimationData.AddKeyframe(Track3, 0, CFrame.identity, {
		Curve = "Bezier",
		EasingStyle = nil,
		EasingDirection = nil,
		LeftHandle = nil,
		RightHandle = { TimeOffset = 0.4, ValueOffset = 0.2 },
		HandleType = "Free",
	})
	AnimationData.AddKeyframe(Track3, 2, CFrame.Angles(0, math.rad(30), 0), {
		Curve = "Linear",
		EasingStyle = nil,
		EasingDirection = nil,
		LeftHandle = { TimeOffset = -0.3, ValueOffset = -0.1 },
		RightHandle = nil,
		HandleType = nil,
	})
	table.insert(Edit.Tracks, Track3)

	return Edit
end

describe("StorageService", function()
	describe("Compress / Decompress", function()
		it("round-trips buffer content exactly", function()
			local Original = buffer.create(64)
			for Index = 0, 63 do
				buffer.writeu8(Original, Index, Index)
			end

			local Compressed, CompressErr = StorageService.Compress(Original)
			expect(CompressErr).toBeNil()
			expect(Compressed).never.toBeNil()

			if Compressed then
				local Decompressed, DecompressErr = StorageService.Decompress(Compressed)
				expect(DecompressErr).toBeNil()
				expect(Decompressed).never.toBeNil()

				if Decompressed then
					expect(buffer.len(Decompressed)).toBe(64)
					for Index = 0, 63 do
						expect(buffer.readu8(Decompressed, Index)).toBe(Index)
					end
				end
			end
		end)
	end)

	describe("PrepareForDataStore / RestoreFromDataStore", function()
		it("round-trips a serialized animation buffer", function()
			local Edit = MakeTestAnimation()
			local Serialized = require(ReplicatedStorage.Luna.Core.Serializer).SerializeEdit(Edit)

			local Packed, PackErr = StorageService.PrepareForDataStore(Serialized)
			expect(PackErr).toBeNil()
			expect(Packed).never.toBeNil()

			if Packed then
				local Restored, RestoreErr = StorageService.RestoreFromDataStore(Packed)
				expect(RestoreErr).toBeNil()
				expect(Restored).never.toBeNil()

				if Restored then
					-- Restored buffer should match original serialized buffer
					expect(buffer.len(Restored)).toBe(buffer.len(Serialized))
				end
			end
		end)
	end)

	describe("EncodeToString / DecodeFromString", function()
		it("produces a valid UTF-8 string and round-trips", function()
			local Original = buffer.create(32)
			for Index = 0, 31 do
				buffer.writeu8(Original, Index, Index * 8)
			end

			local Encoded, EncodeErr = StorageService.EncodeToString(Original)
			expect(EncodeErr).toBeNil()
			expect(Encoded).never.toBeNil()
			expect(typeof(Encoded)).toBe("string")

			if Encoded then
				local Decoded, DecodeErr = StorageService.DecodeFromString(Encoded)
				expect(DecodeErr).toBeNil()
				expect(Decoded).never.toBeNil()

				if Decoded then
					expect(buffer.len(Decoded)).toBe(32)
					for Index = 0, 31 do
						expect(buffer.readu8(Decoded, Index)).toBe(Index * 8)
					end
				end
			end
		end)
	end)

	describe("PackEdit / UnpackEdit", function()
		it("full pipeline round-trip preserves animation data", function()
			local Edit = MakeTestAnimation()

			local Packed, PackErr = StorageService.PackEdit(Edit)
			expect(PackErr).toBeNil()
			expect(Packed).never.toBeNil()

			if Packed then
				local Unpacked, UnpackErr = StorageService.UnpackEdit(Packed)
				expect(UnpackErr).toBeNil()
				expect(Unpacked).never.toBeNil()

				if Unpacked then
					expect(Unpacked.Name).toBe("StorageTest")
					expect(Unpacked.Duration).toBeCloseTo(2)
					expect(Unpacked.Looping).toBe(true)
					expect(Unpacked.Priority).toBe(3)
					expect(Unpacked.FrameRate).toBeCloseTo(24)
					expect(#Unpacked.Tracks).toBe(3)
					expect(Unpacked.Tracks[1].Name).toBe("Arm")
					expect(Unpacked.Tracks[2].Name).toBe("Leg")
					expect(Unpacked.Tracks[2].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Easing")
					expect(Unpacked.Tracks[2].Channels.PositionX.Keyframes[1].Interpolation.EasingStyle).toBe("Bounce")
					expect(Unpacked.Tracks[3].Channels.PositionX.Keyframes[1].Interpolation.Curve).toBe("Bezier")
				end
			end
		end)
	end)

	describe("PackEditToString / UnpackEditFromString", function()
		it("string pipeline round-trip preserves animation data", function()
			local Edit = MakeTestAnimation()

			local PackedString, PackErr = StorageService.PackEditToString(Edit)
			expect(PackErr).toBeNil()
			expect(PackedString).never.toBeNil()
			expect(typeof(PackedString)).toBe("string")

			if PackedString then
				local Unpacked, UnpackErr = StorageService.UnpackEditFromString(PackedString)
				expect(UnpackErr).toBeNil()
				expect(Unpacked).never.toBeNil()

				if Unpacked then
					expect(Unpacked.Name).toBe("StorageTest")
					expect(#Unpacked.Tracks).toBe(3)
				end
			end
		end)
	end)

	describe("Empty animation", function()
		it("round-trips an empty animation", function()
			local Edit = AnimationData.CreateEmptyAnimation("Empty", 0)

			local Packed, PackErr = StorageService.PackEdit(Edit)
			expect(PackErr).toBeNil()
			expect(Packed).never.toBeNil()

			if Packed then
				local Unpacked, UnpackErr = StorageService.UnpackEdit(Packed)
				expect(UnpackErr).toBeNil()
				expect(Unpacked).never.toBeNil()
				if Unpacked then
					expect(Unpacked.Name).toBe("Empty")
					expect(#Unpacked.Tracks).toBe(0)
				end
			end
		end)
	end)

	describe("Error handling", function()
		it("UnpackEdit returns nil + error for corrupted data", function()
			local Garbage = buffer.create(16)
			buffer.fill(Garbage, 0, 0xFF)

			local Result, Error = StorageService.UnpackEdit(Garbage)
			expect(Result).toBeNil()
			expect(Error).never.toBeNil()
		end)

		it("UnpackEditFromString returns nil + error for invalid string", function()
			local Result, Error = StorageService.UnpackEditFromString("not_valid_base64!!!")
			expect(Result).toBeNil()
			expect(Error).never.toBeNil()
		end)
	end)

	describe("Full pipeline evaluation", function()
		it("pack → unpack → compile → evaluate matches original", function()
			local Edit = MakeTestAnimation()
			local Evaluator = require(ReplicatedStorage.Luna.Core.Evaluator)

			-- Original
			local OriginalRuntime = AnimationData.CompileEditToRuntime(Edit)
			local OriginalPose = Evaluator.EvaluateAnimation(OriginalRuntime, 1)

			-- Round-trip through storage
			local Packed, _ = StorageService.PackEdit(Edit)
			expect(Packed).never.toBeNil()
			if not Packed then
				return
			end

			local Unpacked, _ = StorageService.UnpackEdit(Packed)
			expect(Unpacked).never.toBeNil()
			if not Unpacked then
				return
			end

			local RestoredRuntime = AnimationData.CompileEditToRuntime(Unpacked)
			local RestoredPose = Evaluator.EvaluateAnimation(RestoredRuntime, 1)

			-- Compare
			for TrackName, OriginalCF in OriginalPose do
				local RestoredCF = RestoredPose[TrackName]
				expect(RestoredCF).toBeDefined()
				if RestoredCF then
					-- f32 round-trip loses some precision, use wider tolerance
					expect(TestHelpers.CFrameComponentsClose(OriginalCF, RestoredCF, 1e-2)).toBe(true)
				end
			end
		end)
	end)
end)
