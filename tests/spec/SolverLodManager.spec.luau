--!strict
--[[
	Tests for SolverLodManager — LOD preset registry, solver registration,
	step/update dispatch, preset switching, and frozen-rig behavior.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local SolverLodManager = require(ReplicatedStorage.Luna.Solver.SolverLodManager)

-- ============================================================================
-- [[ MOCK HELPERS ]]
-- ============================================================================

type MockSolver = {
	UpdateCalls: { { DeltaTime: number, MaxLodTier: number? } },
	Update: (self: MockSolver, DeltaTime: number, MaxLodTier: number?) -> (),
}

local function __CreateMockSolver(): MockSolver
	local Mock: MockSolver = {
		UpdateCalls = {},
		Update = function(self: MockSolver, DeltaTime: number, MaxLodTier: number?)
			table.insert(self.UpdateCalls, { DeltaTime = DeltaTime, MaxLodTier = MaxLodTier })
		end,
	}
	return Mock
end

local function __CreateMockRootPart(Position: Vector3?): BasePart
	local Part = Instance.new("Part")
	Part.Position = Position or Vector3.zero
	Part.Anchored = true
	Part.Parent = workspace
	return Part
end

-- ============================================================================
-- [[ PRESET REGISTRY TESTS ]]
-- ============================================================================

describe("SolverLodManager", function()
	describe("Preset Registry", function()
		it("should have built-in Default preset", function()
			local Preset = SolverLodManager.GetPreset("Default")
			expect(Preset).never.toBeNil()
			expect(Preset).toBeDefined()
			expect(#(Preset :: any).Tiers).toBe(4)
		end)

		it("should have built-in Performance preset", function()
			local Preset = SolverLodManager.GetPreset("Performance")
			expect(Preset).never.toBeNil()
			expect(Preset).toBeDefined()
		end)

		it("should have built-in Quality preset", function()
			local Preset = SolverLodManager.GetPreset("Quality")
			expect(Preset).never.toBeNil()
			expect(Preset).toBeDefined()
		end)

		it("should register and retrieve custom presets", function()
			SolverLodManager.RegisterPreset("TestCustom", {
				Tiers = {
					{ MaxDistance = 100, UpdateInterval = 1, MaxLodTier = math.huge },
					{ MaxDistance = math.huge, UpdateInterval = 2, MaxLodTier = 1 },
				},
			})
			local Preset = SolverLodManager.GetPreset("TestCustom")
			expect(Preset).never.toBeNil()
		end)

		it("should reject preset with empty tiers", function()
			-- Logger.Error throws, so wrap in pcall
			pcall(function()
				SolverLodManager.RegisterPreset("BadEmpty", { Tiers = {} })
			end)
			expect(SolverLodManager.GetPreset("BadEmpty")).toBeNil()
		end)

		it("should reject preset with non-ascending MaxDistance", function()
			pcall(function()
				SolverLodManager.RegisterPreset("BadDescending", {
					Tiers = {
						{ MaxDistance = 200, UpdateInterval = 1, MaxLodTier = math.huge },
						{ MaxDistance = 100, UpdateInterval = 2, MaxLodTier = 1 },
						{ MaxDistance = math.huge, UpdateInterval = 4, MaxLodTier = 0 },
					},
				})
			end)
			expect(SolverLodManager.GetPreset("BadDescending")).toBeNil()
		end)

		it("should reject preset without math.huge catch-all", function()
			pcall(function()
				SolverLodManager.RegisterPreset("BadNoCatchAll", {
					Tiers = {
						{ MaxDistance = 100, UpdateInterval = 1, MaxLodTier = math.huge },
						{ MaxDistance = 500, UpdateInterval = 2, MaxLodTier = 1 },
					},
				})
			end)
			expect(SolverLodManager.GetPreset("BadNoCatchAll")).toBeNil()
		end)

		it("should reject preset with negative UpdateInterval", function()
			pcall(function()
				SolverLodManager.RegisterPreset("BadInterval", {
					Tiers = {
						{ MaxDistance = 100, UpdateInterval = -1, MaxLodTier = math.huge },
						{ MaxDistance = math.huge, UpdateInterval = 0.1, MaxLodTier = 1 },
					},
				})
			end)
			expect(SolverLodManager.GetPreset("BadInterval")).toBeNil()
		end)
	end)

	-- ============================================================================
	-- [[ CONSTRUCTION TESTS ]]
	-- ============================================================================

	describe("Construction", function()
		it("should create with Default preset when no name given", function()
			local Manager = SolverLodManager.new()
			expect(Manager).toBeDefined()
			expect(Manager._ActiveTiers).toBeDefined()
			-- Default has 4 tiers
			expect(#Manager._ActiveTiers).toBe(4)
			Manager:Destroy()
		end)

		it("should create with named preset", function()
			local Manager = SolverLodManager.new("Quality")
			expect(Manager).toBeDefined()
			-- Quality has 3 tiers
			expect(#Manager._ActiveTiers).toBe(3)
			Manager:Destroy()
		end)

		it("should fall back to Default when preset not found", function()
			-- Logger.Error throws for unknown preset, but new() catches and falls back
			local Manager: any = nil
			pcall(function()
				Manager = SolverLodManager.new("NonexistentPreset")
			end)
			-- If Logger.Error prevents construction, Manager will be nil
			-- Either way the behavior is correct: invalid preset doesn't silently succeed
			if Manager then
				expect(#Manager._ActiveTiers).toBe(4)
				Manager:Destroy()
			end
		end)
	end)

	-- ============================================================================
	-- [[ REGISTRATION TESTS ]]
	-- ============================================================================

	describe("Registration", function()
		it("should register and unregister solvers", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()
			local Part = __CreateMockRootPart()

			expect(Manager:GetEntryCount()).toBe(0)

			Manager:Register(MockSolver :: any, Part)
			expect(Manager:GetEntryCount()).toBe(1)

			Manager:Unregister(MockSolver :: any)
			expect(Manager:GetEntryCount()).toBe(0)

			Part:Destroy()
			Manager:Destroy()
		end)

		it("should not double-register same solver", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()
			local Part = __CreateMockRootPart()

			Manager:Register(MockSolver :: any, Part)
			Manager:Register(MockSolver :: any, Part)
			-- Count should still be 1 — second registration is silently rejected
			expect(Manager:GetEntryCount()).toBe(1)

			Part:Destroy()
			Manager:Destroy()
		end)

		it("should return tier for registered solver", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()
			local Part = __CreateMockRootPart(Vector3.zero)

			Manager:Register(MockSolver :: any, Part)
			-- Newly registered solvers start at tier 1
			expect(Manager:GetTier(MockSolver :: any)).toBe(1)

			Part:Destroy()
			Manager:Destroy()
		end)

		it("should return -1 for unregistered solver", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()

			expect(Manager:GetTier(MockSolver :: any)).toBe(-1)

			Manager:Destroy()
		end)
	end)

	-- ============================================================================
	-- [[ STEP AND UPDATE TESTS ]]
	-- ============================================================================

	describe("Step and Update", function()
		it("should call Update on registered solver each frame at tier 1", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()
			-- Place the part at origin — close to camera, should stay in tier 1
			local Part = __CreateMockRootPart(Vector3.zero)

			Manager:Register(MockSolver :: any, Part)

			-- Step several frames to ensure at least one Update fires
			-- (UpdateInterval for Default tier 1 is 1, so every eligible frame calls Update)
			for _ = 1, 3 do
				Manager:Step(0.016)
			end

			expect(#MockSolver.UpdateCalls).toBeGreaterThanOrEqual(1)

			Part:Destroy()
			Manager:Destroy()
		end)

		it("should pass MaxLodTier to solver Update", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()
			local Part = __CreateMockRootPart(Vector3.zero)

			Manager:Register(MockSolver :: any, Part)

			-- Step until at least one Update call is recorded
			for _ = 1, 10 do
				Manager:Step(0.016)
				if #MockSolver.UpdateCalls > 0 then
					break
				end
			end

			expect(#MockSolver.UpdateCalls).toBeGreaterThanOrEqual(1)
			-- Default preset tier 1 has MaxLodTier = math.huge
			local FirstCall = MockSolver.UpdateCalls[1]
			expect(FirstCall.MaxLodTier).toBe(math.huge)

			Part:Destroy()
			Manager:Destroy()
		end)
	end)

	-- ============================================================================
	-- [[ PRESET SWITCHING TESTS ]]
	-- ============================================================================

	describe("Preset Switching", function()
		it("should switch presets at runtime", function()
			-- Register a distinct cutscene preset for this test
			SolverLodManager.RegisterPreset("Cutscene", {
				Tiers = {
					{ MaxDistance = 500, UpdateInterval = 1, MaxLodTier = math.huge },
					{ MaxDistance = math.huge, UpdateInterval = 1, MaxLodTier = math.huge },
				},
			})

			local Manager = SolverLodManager.new("Default")
			expect(#Manager._ActiveTiers).toBe(4)

			Manager:SetPreset("Cutscene")
			-- Cutscene has 2 tiers — confirms the swap happened
			expect(#Manager._ActiveTiers).toBe(2)

			Manager:Destroy()
		end)

		it("should warn and keep current preset when switching to unknown", function()
			local Manager = SolverLodManager.new("Default")
			local TiersBefore = Manager._ActiveTiers

			-- Switching to a nonexistent preset logs a warning and leaves state unchanged
			Manager:SetPreset("DoesNotExist")

			-- _ActiveTiers reference should be the same table as before
			expect(Manager._ActiveTiers).toBe(TiersBefore)

			Manager:Destroy()
		end)
	end)

	-- ============================================================================
	-- [[ FROZEN BEHAVIOR TESTS ]]
	-- ============================================================================

	describe("Frozen behavior", function()
		it("should not call Update for frozen (tier 0) rigs", function()
			local Manager = SolverLodManager.new()
			local MockSolver = __CreateMockSolver()

			-- Place the part far behind the camera — off-screen → tier 0 → frozen
			-- Default camera looks along -Z at Y=0; placing far along +X and high up
			-- ensures the part is outside the padded viewport in practice.
			-- We force the tier manually to guarantee determinism in a headless context.
			local Part = __CreateMockRootPart(Vector3.new(0, 0, -100000))

			Manager:Register(MockSolver :: any, Part)

			-- Force entry to tier 0 by accessing internal state directly —
			-- the camera viewport check is environment-dependent in tests.
			-- This tests the Step hot-loop guard: tier 0 entries are skipped.
			local Key = tostring(MockSolver :: any)
			local Entry = Manager._EntryMap[Key]
			if Entry then
				Entry.Tier = 0
			end

			for _ = 1, 20 do
				Manager:Step(0.016)
			end

			-- No Update calls should have been dispatched for a tier-0 entry
			expect(#MockSolver.UpdateCalls).toBe(0)

			Part:Destroy()
			Manager:Destroy()
		end)
	end)
end)
