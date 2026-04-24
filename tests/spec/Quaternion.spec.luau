--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Quaternion = require(ReplicatedStorage.Luna.Core.Quaternion)
local TestHelpers = require(ReplicatedStorage.Tests.TestHelpers)

local EPSILON = 1e-5

describe("Quaternion", function()
	describe("Identity", function()
		it("returns {0, 0, 0, 1}", function()
			local Q = Quaternion.Identity()
			expect(Q.X).toBe(0)
			expect(Q.Y).toBe(0)
			expect(Q.Z).toBe(0)
			expect(Q.W).toBe(1)
		end)
	end)

	describe("FromCFrame", function()
		it("extracts identity quaternion from CFrame.identity", function()
			local Q = Quaternion.FromCFrame(CFrame.identity)
			expect(TestHelpers.QuatClose(Q, Quaternion.Identity())).toBe(true)
		end)

		it("produces a unit-length quaternion for arbitrary rotations", function()
			local Q = Quaternion.FromCFrame(CFrame.Angles(1, 2, 3))
			local Length = Quaternion.Length(Q)
			expect(math.abs(Length - 1)).toBeLessThan(EPSILON)
		end)
	end)

	describe("ToCFrame", function()
		it("round-trips through FromCFrame for identity", function()
			local Original = CFrame.identity
			local Q = Quaternion.FromCFrame(Original)
			local Result = Quaternion.ToCFrame(Q, Original.Position)
			expect(TestHelpers.CFrameComponentsClose(Result, Original)).toBe(true)
		end)

		it("round-trips through FromCFrame for arbitrary rotation", function()
			local Original = CFrame.new(3, 5, 7) * CFrame.Angles(math.rad(45), math.rad(90), math.rad(30))
			local Q = Quaternion.FromCFrame(Original)
			local Result = Quaternion.ToCFrame(Q, Original.Position)
			expect(TestHelpers.CFrameComponentsClose(Result, Original)).toBe(true)
		end)
	end)

	describe("Multiply", function()
		it("identity is multiplicative neutral (Q * I = Q)", function()
			local Q = Quaternion.FromCFrame(CFrame.Angles(1, 0.5, 0.3))
			local Result = Quaternion.Multiply(Q, Quaternion.Identity())
			expect(TestHelpers.QuatClose(Result, Q)).toBe(true)
		end)

		it("identity is multiplicative neutral (I * Q = Q)", function()
			local Q = Quaternion.FromCFrame(CFrame.Angles(1, 0.5, 0.3))
			local Result = Quaternion.Multiply(Quaternion.Identity(), Q)
			expect(TestHelpers.QuatClose(Result, Q)).toBe(true)
		end)
	end)

	describe("Conjugate", function()
		it("negates X, Y, Z and preserves W", function()
			local Q = { X = 0.1, Y = 0.2, Z = 0.3, W = 0.9 }
			local C = Quaternion.Conjugate(Q)
			expect(C.X).toBeCloseTo(-0.1)
			expect(C.Y).toBeCloseTo(-0.2)
			expect(C.Z).toBeCloseTo(-0.3)
			expect(C.W).toBeCloseTo(0.9)
		end)
	end)

	describe("Dot", function()
		it("returns 1 for a unit quaternion dotted with itself", function()
			local Q = Quaternion.Identity()
			expect(Quaternion.Dot(Q, Q)).toBeCloseTo(1)
		end)

		it("returns 1 for any unit quaternion dotted with itself", function()
			local Q = Quaternion.Normalize({ X = 1, Y = 2, Z = 3, W = 4 })
			expect(Quaternion.Dot(Q, Q)).toBeCloseTo(1)
		end)
	end)

	describe("Length", function()
		it("identity has length 1", function()
			expect(Quaternion.Length(Quaternion.Identity())).toBeCloseTo(1)
		end)

		it("unit axis quaternion has length 1", function()
			expect(Quaternion.Length({ X = 1, Y = 0, Z = 0, W = 0 })).toBeCloseTo(1)
		end)
	end)

	describe("Normalize", function()
		it("scales a quaternion to unit length", function()
			local Q = Quaternion.Normalize({ X = 2, Y = 0, Z = 0, W = 0 })
			expect(Quaternion.Length(Q)).toBeCloseTo(1)
		end)

		it("returns identity for near-zero quaternion", function()
			local Q = Quaternion.Normalize({ X = 0, Y = 0, Z = 0, W = 0 })
			expect(TestHelpers.QuatClose(Q, Quaternion.Identity())).toBe(true)
		end)
	end)

	describe("Slerp", function()
		it("at alpha=0 returns A", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Result = Quaternion.Slerp(A, B, 0)
			expect(TestHelpers.QuatClose(Result, A)).toBe(true)
		end)

		it("at alpha=1 returns B", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Result = Quaternion.Slerp(A, B, 1)
			expect(TestHelpers.QuatClose(Result, B)).toBe(true)
		end)

		it("takes shortest path when quaternions are negated", function()
			-- A and NegA represent the same rotation (quaternion double-cover)
			-- Slerp should still produce a smooth short-arc interpolation
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(10), 0))
			local NegB = { X = -B.X, Y = -B.Y, Z = -B.Z, W = -B.W }

			local ResultNormal = Quaternion.Slerp(A, B, 0.5)
			local ResultNegated = Quaternion.Slerp(A, NegB, 0.5)

			-- Both should produce the same midpoint rotation (5 degrees)
			-- The negated version should NOT take the 350-degree long path
			local DotNormal = Quaternion.Dot(ResultNormal, ResultNegated)
			expect(math.abs(math.abs(DotNormal) - 1)).toBeLessThan(EPSILON)
		end)
	end)

	describe("Nlerp", function()
		it("at alpha=0.5 produces a reasonable midpoint", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Result = Quaternion.Nlerp(A, B, 0.5)

			-- Result should be unit length
			expect(Quaternion.Length(Result)).toBeCloseTo(1)

			-- Midpoint should be roughly 45 degrees
			local MidCF = Quaternion.ToCFrame(Result, Vector3.zero)
			local ExpectedCF = CFrame.Angles(0, math.rad(45), 0)
			expect(TestHelpers.CFrameComponentsClose(MidCF, ExpectedCF, 0.01)).toBe(true)
		end)
	end)

	-- ========================================================================
	-- [[ INTO VARIANTS (zero-allocation) ]]
	-- ========================================================================

	describe("IdentityInto", function()
		it("writes identity into existing table", function()
			local Out = { X = 5, Y = 6, Z = 7, W = 8 }
			Quaternion.IdentityInto(Out)
			expect(Out.X).toBe(0)
			expect(Out.Y).toBe(0)
			expect(Out.Z).toBe(0)
			expect(Out.W).toBe(1)
		end)
	end)

	describe("ConjugateInto", function()
		it("matches Conjugate result", function()
			local Q = { X = 0.1, Y = 0.2, Z = 0.3, W = 0.9 }
			local Expected = Quaternion.Conjugate(Q)
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.ConjugateInto(Q, Out)
			expect(TestHelpers.QuatClose(Out, Expected)).toBe(true)
		end)

		it("works with self-alias", function()
			local Q = { X = 0.1, Y = 0.2, Z = 0.3, W = 0.9 }
			local Expected = Quaternion.Conjugate(Q)
			Quaternion.ConjugateInto(Q, Q)
			expect(TestHelpers.QuatClose(Q, Expected)).toBe(true)
		end)
	end)

	describe("NormalizeInto", function()
		it("matches Normalize result", function()
			local Q = { X = 2, Y = 3, Z = 4, W = 5 }
			local Expected = Quaternion.Normalize(Q)
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NormalizeInto(Q, Out)
			expect(TestHelpers.QuatClose(Out, Expected)).toBe(true)
		end)

		it("handles near-zero gracefully", function()
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NormalizeInto({ X = 0, Y = 0, Z = 0, W = 0 }, Out)
			expect(Out.W).toBe(1)
		end)
	end)

	describe("NlerpInto", function()
		it("matches Nlerp result at alpha=0.5", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Expected = Quaternion.Nlerp(A, B, 0.5)
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NlerpInto(A, B, 0.5, Out)
			expect(TestHelpers.QuatClose(Out, Expected)).toBe(true)
		end)

		it("handles shortest path with negated quaternion", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(10), 0))
			local NegB = { X = -B.X, Y = -B.Y, Z = -B.Z, W = -B.W }
			local Out1 = { X = 0, Y = 0, Z = 0, W = 0 }
			local Out2 = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NlerpInto(A, B, 0.5, Out1)
			Quaternion.NlerpInto(A, NegB, 0.5, Out2)
			local Dot = math.abs(Quaternion.Dot(Out1, Out2))
			expect(math.abs(Dot - 1)).toBeLessThan(EPSILON)
		end)

		it("at alpha=0 returns A", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0.5, 0.3, 0.1))
			local B = Quaternion.FromCFrame(CFrame.Angles(1, 2, 3))
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NlerpInto(A, B, 0, Out)
			expect(TestHelpers.QuatClose(Out, A, 1e-4)).toBe(true)
		end)

		it("at alpha=1 returns B (or equivalent)", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0.5, 0.3, 0.1))
			local B = Quaternion.FromCFrame(CFrame.Angles(1, 2, 3))
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.NlerpInto(A, B, 1, Out)
			local Dot = math.abs(Quaternion.Dot(Out, B))
			expect(math.abs(Dot - 1)).toBeLessThan(1e-4)
		end)
	end)

	describe("SlerpInto", function()
		it("matches Slerp result at alpha=0.5", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Expected = Quaternion.Slerp(A, B, 0.5)
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.SlerpInto(A, B, 0.5, Out)
			expect(TestHelpers.QuatClose(Out, Expected, 1e-4)).toBe(true)
		end)

		it("at alpha=0 returns A", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.SlerpInto(A, B, 0, Out)
			expect(TestHelpers.QuatClose(Out, A)).toBe(true)
		end)

		it("at alpha=1 returns B", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(0, 0, 0))
			local B = Quaternion.FromCFrame(CFrame.Angles(0, math.rad(90), 0))
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.SlerpInto(A, B, 1, Out)
			expect(TestHelpers.QuatClose(Out, B)).toBe(true)
		end)
	end)

	describe("MultiplyInto", function()
		it("matches Multiply result", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(1, 0.5, 0.3))
			local B = Quaternion.FromCFrame(CFrame.Angles(0.2, 0.7, 0.1))
			local Expected = Quaternion.Multiply(A, B)
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.MultiplyInto(A, B, Out)
			expect(TestHelpers.QuatClose(Out, Expected)).toBe(true)
		end)

		it("identity is neutral (A * I = A)", function()
			local A = Quaternion.FromCFrame(CFrame.Angles(1, 0.5, 0.3))
			local I = Quaternion.Identity()
			local Out = { X = 0, Y = 0, Z = 0, W = 0 }
			Quaternion.MultiplyInto(A, I, Out)
			expect(TestHelpers.QuatClose(Out, A)).toBe(true)
		end)
	end)
end)
