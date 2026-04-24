--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local CFrameUtils = require(ReplicatedStorage.Luna.Core.CFrameUtils)
local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

describe("CFrameUtils", function()
	describe("Decompose and Compose", function()
		it("round-trips CFrame.identity", function()
			local Original = CFrame.identity
			local Decomposed = CFrameUtils.Decompose(Original)
			local Recomposed = CFrameUtils.Compose(Decomposed)
			expect(TestHelpers.CFrameComponentsClose(Recomposed, Original)).toBe(true)
		end)

		it("round-trips pure translation", function()
			local Original = CFrame.new(10, 20, 30)
			local Decomposed = CFrameUtils.Decompose(Original)
			local Recomposed = CFrameUtils.Compose(Decomposed)
			expect(TestHelpers.CFrameComponentsClose(Recomposed, Original)).toBe(true)
		end)

		it("round-trips translation + rotation", function()
			local Original = CFrame.new(5, -3, 8) * CFrame.Angles(math.rad(45), math.rad(90), math.rad(30))
			local Decomposed = CFrameUtils.Decompose(Original)
			local Recomposed = CFrameUtils.Compose(Decomposed)
			expect(TestHelpers.CFrameComponentsClose(Recomposed, Original)).toBe(true)
		end)

		it("extracts correct position", function()
			local CF = CFrame.new(7, 11, 13)
			local Decomposed = CFrameUtils.Decompose(CF)
			expect(Decomposed.Position.X).toBeCloseTo(7)
			expect(Decomposed.Position.Y).toBeCloseTo(11)
			expect(Decomposed.Position.Z).toBeCloseTo(13)
		end)
	end)

	describe("Lerp", function()
		it("at alpha=0 returns A", function()
			local A = CFrameUtils.Decompose(CFrame.new(0, 0, 0))
			local B = CFrameUtils.Decompose(CFrame.new(10, 10, 10))
			local Result = CFrameUtils.Lerp(A, B, 0)
			local ResultCF = CFrameUtils.Compose(Result)
			expect(TestHelpers.CFrameComponentsClose(ResultCF, CFrame.new(0, 0, 0))).toBe(true)
		end)

		it("at alpha=1 returns B", function()
			local A = CFrameUtils.Decompose(CFrame.new(0, 0, 0))
			local B = CFrameUtils.Decompose(CFrame.new(10, 10, 10))
			local Result = CFrameUtils.Lerp(A, B, 1)
			local ResultCF = CFrameUtils.Compose(Result)
			expect(TestHelpers.CFrameComponentsClose(ResultCF, CFrame.new(10, 10, 10))).toBe(true)
		end)

		it("at alpha=0.5 position is midpoint", function()
			local A = CFrameUtils.Decompose(CFrame.new(0, 0, 0))
			local B = CFrameUtils.Decompose(CFrame.new(10, 20, 30))
			local Result = CFrameUtils.Lerp(A, B, 0.5)
			expect(Result.Position.X).toBeCloseTo(5)
			expect(Result.Position.Y).toBeCloseTo(10)
			expect(Result.Position.Z).toBeCloseTo(15)
		end)
	end)

	describe("Identity", function()
		it("returns zero position and identity quaternion", function()
			local I = CFrameUtils.Identity()
			expect(I.Position).toEqual(Vector3.zero)
			expect(TestHelpers.QuatClose(I.Rotation, Quaternion.Identity())).toBe(true)
		end)
	end)
end)
