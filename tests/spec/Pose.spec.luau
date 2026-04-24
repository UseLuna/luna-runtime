--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Pose = require(ReplicatedStorage.Luna.Solver.Pose)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-4

describe("Pose", function()
	local TestNames = { "Head", "UpperTorso", "RightUpperArm" }

	describe("Create", function()
		it("creates a Pose with correct BoneCount", function()
			local P = Pose.Create(#TestNames)
			expect(P.BoneCount).toBe(3)
		end)

		it("initializes positions to Vector3.zero", function()
			local P = Pose.Create(#TestNames)
			for Index = 1, P.BoneCount do
				local Pos = Pose.ReadPosition(P.Positions, Index)
				expect(Pos).toBe(Vector3.zero)
			end
		end)

		it("initializes rotations to identity quaternion", function()
			local P = Pose.Create(#TestNames)
			local Identity = Quaternion.Identity()
			for Index = 1, P.BoneCount do
				local RotOff = (Index - 1) * 16
				local Q = {
					X = buffer.readf32(P.Rotations, RotOff),
					Y = buffer.readf32(P.Rotations, RotOff + 4),
					Z = buffer.readf32(P.Rotations, RotOff + 8),
					W = buffer.readf32(P.Rotations, RotOff + 12),
				}
				expect(TestHelpers.QuatClose(Q, Identity)).toBe(true)
			end
		end)
	end)

	describe("ReadPosition / WritePosition", function()
		it("round-trips a position through write then read", function()
			local P = Pose.Create(3)
			local TestPos = Vector3.new(1.5, -2.75, 100)
			Pose.WritePosition(P.Positions, 2, TestPos)
			local ReadBack = Pose.ReadPosition(P.Positions, 2)
			expect(math.abs(ReadBack.X - TestPos.X)).toBeLessThan(EPSILON)
			expect(math.abs(ReadBack.Y - TestPos.Y)).toBeLessThan(EPSILON)
			expect(math.abs(ReadBack.Z - TestPos.Z)).toBeLessThan(EPSILON)
		end)

		it("does not affect other bone slots", function()
			local P = Pose.Create(3)
			Pose.WritePosition(P.Positions, 2, Vector3.new(10, 20, 30))
			local Pos1 = Pose.ReadPosition(P.Positions, 1)
			local Pos3 = Pose.ReadPosition(P.Positions, 3)
			expect(Pos1).toBe(Vector3.zero)
			expect(Pos3).toBe(Vector3.zero)
		end)
	end)

	describe("Reset", function()
		it("resets positions and rotations to defaults", function()
			local P = Pose.Create(#TestNames)
			-- Dirty the pose
			Pose.WritePosition(P.Positions, 1, Vector3.new(10, 20, 30))
			local RotOff = 0 -- Index 1, offset 0
			buffer.writef32(P.Rotations, RotOff, 1)
			buffer.writef32(P.Rotations, RotOff + 4, 0)
			buffer.writef32(P.Rotations, RotOff + 8, 0)
			buffer.writef32(P.Rotations, RotOff + 12, 0)

			Pose.Reset(P)

			local Pos = Pose.ReadPosition(P.Positions, 1)
			expect(Pos).toBe(Vector3.zero)

			local Identity = Quaternion.Identity()
			local Q = {
				X = buffer.readf32(P.Rotations, RotOff),
				Y = buffer.readf32(P.Rotations, RotOff + 4),
				Z = buffer.readf32(P.Rotations, RotOff + 8),
				W = buffer.readf32(P.Rotations, RotOff + 12),
			}
			expect(TestHelpers.QuatClose(Q, Identity)).toBe(true)
		end)
	end)

	describe("ComposeToCFrames", function()
		it("composes identity pose to identity CFrames", function()
			local P = Pose.Create(#TestNames)
			local CFrames = Pose.ComposeToCFrames(P, TestNames)

			expect(CFrames["Head"]).toBeDefined()
			expect(CFrames["UpperTorso"]).toBeDefined()
			expect(CFrames["RightUpperArm"]).toBeDefined()
			expect(TestHelpers.CFrameComponentsClose(CFrames["Head"], CFrame.identity)).toBe(true)
		end)

		it("composes position + rotation correctly", function()
			local Names = { "Bone" }
			local P = Pose.Create(1)
			Pose.WritePosition(P.Positions, 1, Vector3.new(5, 10, 15))

			local Q = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local RotOff = 0
			buffer.writef32(P.Rotations, RotOff, Q.X)
			buffer.writef32(P.Rotations, RotOff + 4, Q.Y)
			buffer.writef32(P.Rotations, RotOff + 8, Q.Z)
			buffer.writef32(P.Rotations, RotOff + 12, Q.W)

			local CFrames = Pose.ComposeToCFrames(P, Names)
			local Expected = CFrame.new(5, 10, 15) * CFrame.Angles(0, math.rad(90), 0)

			expect(TestHelpers.CFrameComponentsClose(CFrames["Bone"], Expected, 1e-3)).toBe(true)
		end)

		it("uses bone names as keys", function()
			local Names = { "Alpha", "Beta", "Gamma" }
			local P = Pose.Create(#Names)
			local CFrames = Pose.ComposeToCFrames(P, Names)

			expect(CFrames["Alpha"]).toBeDefined()
			expect(CFrames["Beta"]).toBeDefined()
			expect(CFrames["Gamma"]).toBeDefined()
			expect(CFrames["Delta"]).toBeUndefined()
		end)
	end)

	describe("CopyInto", function()
		it("copies position and rotation data", function()
			local Source = Pose.Create(#TestNames)
			local Dest = Pose.Create(#TestNames)

			Pose.WritePosition(Source.Positions, 1, Vector3.new(1, 2, 3))
			local RotOff = 0
			buffer.writef32(Source.Rotations, RotOff, 0.5)
			buffer.writef32(Source.Rotations, RotOff + 4, 0.5)
			buffer.writef32(Source.Rotations, RotOff + 8, 0.5)
			buffer.writef32(Source.Rotations, RotOff + 12, 0.5)

			Pose.CopyInto(Source, Dest)

			local DestPos = Pose.ReadPosition(Dest.Positions, 1)
			expect(DestPos).toBe(Vector3.new(1, 2, 3))
			expect(math.abs(buffer.readf32(Dest.Rotations, RotOff) - 0.5)).toBeLessThan(EPSILON)
			expect(math.abs(buffer.readf32(Dest.Rotations, RotOff + 4) - 0.5)).toBeLessThan(EPSILON)
		end)

		it("does not affect source when dest is modified after copy", function()
			local Source = Pose.Create(#TestNames)
			local Dest = Pose.Create(#TestNames)
			Pose.WritePosition(Source.Positions, 1, Vector3.new(1, 2, 3))

			Pose.CopyInto(Source, Dest)
			Pose.WritePosition(Dest.Positions, 1, Vector3.new(99, 99, 99))

			local SourcePos = Pose.ReadPosition(Source.Positions, 1)
			expect(SourcePos).toBe(Vector3.new(1, 2, 3))
		end)
	end)
end)
