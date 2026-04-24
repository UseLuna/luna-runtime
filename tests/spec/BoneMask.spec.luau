--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local BoneMask = require(ReplicatedStorage.Luna.Solver.BoneMask)

local EPSILON = 1e-6

-- Helper to read a bone weight from a buffer-backed BoneMask (1-based index)
local function __ReadWeight(Mask: BoneMask.BoneMask, Index: number): number
	return buffer.readf32(Mask.Weights, (Index - 1) * 4)
end

-- Simulated R15-like hierarchy:
-- HumanoidRootPart → LowerTorso → UpperTorso → Head
--                                              → RightUpperArm → RightLowerArm
--                                              → LeftUpperArm → LeftLowerArm
--                   LowerTorso → RightUpperLeg → RightLowerLeg
--                              → LeftUpperLeg → LeftLowerLeg

local BONE_NAMES = {
	"LowerTorso",
	"UpperTorso",
	"Head",
	"RightUpperArm",
	"RightLowerArm",
	"LeftUpperArm",
	"LeftLowerArm",
	"RightUpperLeg",
	"RightLowerLeg",
	"LeftUpperLeg",
	"LeftLowerLeg",
}

local NAME_TO_INDEX: { [string]: number } = {}
for Index, Name in BONE_NAMES do
	NAME_TO_INDEX[Name] = Index
end

local CHILDREN_MAP: { [string]: { string } } = {
	["HumanoidRootPart"] = { "LowerTorso" },
	["LowerTorso"] = { "UpperTorso", "RightUpperLeg", "LeftUpperLeg" },
	["UpperTorso"] = { "Head", "RightUpperArm", "LeftUpperArm" },
	["RightUpperArm"] = { "RightLowerArm" },
	["LeftUpperArm"] = { "LeftLowerArm" },
	["RightUpperLeg"] = { "RightLowerLeg" },
	["LeftUpperLeg"] = { "LeftLowerLeg" },
}

local BONE_COUNT = #BONE_NAMES

describe("BoneMask", function()
	describe("FullBody", function()
		it("creates mask with all weights at 1.0", function()
			local Mask = BoneMask.FullBody(BONE_COUNT)
			expect(Mask.BoneCount).toBe(BONE_COUNT)
			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Mask, Index)).toBe(1.0)
			end
		end)
	end)

	describe("Empty", function()
		it("creates mask with all weights at 0.0", function()
			local Mask = BoneMask.Empty(BONE_COUNT)
			expect(Mask.BoneCount).toBe(BONE_COUNT)
			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Mask, Index)).toBe(0.0)
			end
		end)
	end)

	describe("FromBone", function()
		it("marks UpperTorso and descendants at 1.0, rest at 0.0", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "UpperTorso", CHILDREN_MAP, NAME_TO_INDEX)

			-- UpperTorso and descendants should be 1.0
			expect(__ReadWeight(Mask, NAME_TO_INDEX["UpperTorso"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["Head"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightUpperArm"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightLowerArm"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LeftUpperArm"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LeftLowerArm"])).toBe(1.0)

			-- Not descendants — should be 0.0
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LowerTorso"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightUpperLeg"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightLowerLeg"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LeftUpperLeg"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LeftLowerLeg"])).toBe(0.0)
		end)

		it("marks RightUpperArm branch only", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "RightUpperArm", CHILDREN_MAP, NAME_TO_INDEX)

			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightUpperArm"])).toBe(1.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["RightLowerArm"])).toBe(1.0)

			-- Everything else 0.0
			expect(__ReadWeight(Mask, NAME_TO_INDEX["Head"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["UpperTorso"])).toBe(0.0)
			expect(__ReadWeight(Mask, NAME_TO_INDEX["LeftUpperArm"])).toBe(0.0)
		end)

		it("marks single leaf bone", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "Head", CHILDREN_MAP, NAME_TO_INDEX)

			expect(__ReadWeight(Mask, NAME_TO_INDEX["Head"])).toBe(1.0)

			-- All others 0.0
			for Index = 1, BONE_COUNT do
				if BONE_NAMES[Index] ~= "Head" then
					expect(__ReadWeight(Mask, Index)).toBe(0.0)
				end
			end
		end)

		it("marks entire hierarchy from LowerTorso", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "LowerTorso", CHILDREN_MAP, NAME_TO_INDEX)

			-- LowerTorso is parent of everything in this test hierarchy
			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Mask, Index)).toBe(1.0)
			end
		end)

		it("handles unknown bone name gracefully (all zeros)", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "NonexistentBone", CHILDREN_MAP, NAME_TO_INDEX)

			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Mask, Index)).toBe(0.0)
			end
		end)
	end)

	describe("Invert", function()
		it("inverts FullBody to Empty", function()
			local Full = BoneMask.FullBody(BONE_COUNT)
			local Inverted = BoneMask.Invert(Full)

			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Inverted, Index)).toBe(0.0)
			end
		end)

		it("inverts Empty to FullBody", function()
			local EmptyMask = BoneMask.Empty(BONE_COUNT)
			local Inverted = BoneMask.Invert(EmptyMask)

			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Inverted, Index)).toBe(1.0)
			end
		end)

		it("UpperTorso mask inverted gives lower body", function()
			local UpperBody = BoneMask.FromBone(BONE_COUNT, "UpperTorso", CHILDREN_MAP, NAME_TO_INDEX)
			local LowerBody = BoneMask.Invert(UpperBody)

			-- Lower body bones should be 1.0
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["LowerTorso"])).toBe(1.0)
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["RightUpperLeg"])).toBe(1.0)
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["LeftUpperLeg"])).toBe(1.0)

			-- Upper body bones should be 0.0
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["UpperTorso"])).toBe(0.0)
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["Head"])).toBe(0.0)
			expect(__ReadWeight(LowerBody, NAME_TO_INDEX["RightUpperArm"])).toBe(0.0)
		end)
	end)

	describe("Combine", function()
		it("combines two disjoint masks", function()
			local RightArm = BoneMask.FromBone(BONE_COUNT, "RightUpperArm", CHILDREN_MAP, NAME_TO_INDEX)
			local LeftArm = BoneMask.FromBone(BONE_COUNT, "LeftUpperArm", CHILDREN_MAP, NAME_TO_INDEX)
			local BothArms = BoneMask.Combine(RightArm, LeftArm)

			expect(__ReadWeight(BothArms, NAME_TO_INDEX["RightUpperArm"])).toBe(1.0)
			expect(__ReadWeight(BothArms, NAME_TO_INDEX["RightLowerArm"])).toBe(1.0)
			expect(__ReadWeight(BothArms, NAME_TO_INDEX["LeftUpperArm"])).toBe(1.0)
			expect(__ReadWeight(BothArms, NAME_TO_INDEX["LeftLowerArm"])).toBe(1.0)

			-- Non-arm bones still 0.0
			expect(__ReadWeight(BothArms, NAME_TO_INDEX["Head"])).toBe(0.0)
			expect(__ReadWeight(BothArms, NAME_TO_INDEX["RightUpperLeg"])).toBe(0.0)
		end)

		it("combine with FullBody returns FullBody", function()
			local Partial = BoneMask.FromBone(BONE_COUNT, "Head", CHILDREN_MAP, NAME_TO_INDEX)
			local Combined = BoneMask.Combine(Partial, BoneMask.FullBody(BONE_COUNT))

			for Index = 1, BONE_COUNT do
				expect(__ReadWeight(Combined, Index)).toBe(1.0)
			end
		end)
	end)

	describe("MaxWeight", function()
		it("returns 1.0 for FullBody", function()
			expect(BoneMask.MaxWeight(BoneMask.FullBody(BONE_COUNT))).toBe(1.0)
		end)

		it("returns 0.0 for Empty", function()
			expect(BoneMask.MaxWeight(BoneMask.Empty(BONE_COUNT))).toBe(0.0)
		end)

		it("returns 1.0 for partial mask", function()
			local Mask = BoneMask.FromBone(BONE_COUNT, "Head", CHILDREN_MAP, NAME_TO_INDEX)
			expect(BoneMask.MaxWeight(Mask)).toBe(1.0)
		end)
	end)
end)
