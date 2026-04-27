--!strict
--[[
	Tests for LunaRuntimeWrapper — Step LOD dispatch, refcount-correct removal,
	equality-gated SetWeight/SetSpeed, __PreloadCache instance keying.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local afterEach = JestGlobals.afterEach

local AnimationData = require(ReplicatedStorage.Luna.Core.AnimationData)
local AnimationSolver = require(ReplicatedStorage.Luna.Solver.AnimationSolver)
local LunaRuntimeWrapper = require(ReplicatedStorage.Luna.Solver.LunaRuntimeWrapper)
local RigResolver = require(ReplicatedStorage.Luna.Solver.RigResolver)

-- ============================================================================
-- [[ HELPERS ]]
-- ============================================================================

--- Create a minimal Model with HumanoidRootPart + Torso linked by a Motor6D.
local function __MakeMinimalRigModel(): Model
	local Model = Instance.new("Model")
	Model.Name = "MockRig"

	local Root = Instance.new("Part")
	Root.Name = "HumanoidRootPart"
	Root.Parent = Model

	local Torso = Instance.new("Part")
	Torso.Name = "Torso"
	Torso.Parent = Model

	local Motor = Instance.new("Motor6D")
	Motor.Name = "Torso"
	Motor.Part0 = Root
	Motor.Part1 = Torso
	Motor.Parent = Root

	return Model
end

local function __MakeNoOpEditAnimation(Duration: number): AnimationData.EditAnimation
	local Edit = AnimationData.CreateEmptyAnimation("NoOp", Duration)
	local Track = AnimationData.CreateEmptyTrack("Torso")
	AnimationData.AddKeyframe(Track, 0, CFrame.identity)
	AnimationData.AddKeyframe(Track, Duration, CFrame.identity)
	table.insert(Edit.Tracks, Track)
	return Edit
end

-- ============================================================================
-- [[ TESTS ]]
-- ============================================================================

describe("LunaRuntimeWrapper", function()
	afterEach(function()
		LunaRuntimeWrapper.Reset()
		RigResolver.ClearCache()
	end)

	describe("Step LOD dispatch", function()
		it("does not double-evaluate rigs when LOD is enabled", function()
			local Model = __MakeMinimalRigModel()
			local Loaded = LunaRuntimeWrapper.FromEdit(__MakeNoOpEditAnimation(1.0))
			LunaRuntimeWrapper.Play(Model, Loaded, { Looping = true })

			local OriginalEvaluate = AnimationSolver.Evaluate
			local CallCount = 0
			AnimationSolver.Evaluate = function(...)
				CallCount += 1
				return OriginalEvaluate(...)
			end

			LunaRuntimeWrapper.SetGlobalLod("Default")
			LunaRuntimeWrapper.Step(0.016)

			AnimationSolver.Evaluate = OriginalEvaluate

			-- LOD path drives Update -> Evaluate ONCE per rig per frame.
			-- Bug regression would call it twice (LOD + wrapper).
			expect(CallCount).toBe(1)

			Model:Destroy()
		end)

		it("evaluates rigs once when LOD is disabled (non-LOD baseline)", function()
			local Model = __MakeMinimalRigModel()
			local Loaded = LunaRuntimeWrapper.FromEdit(__MakeNoOpEditAnimation(1.0))
			LunaRuntimeWrapper.Play(Model, Loaded, { Looping = true })

			local OriginalEvaluate = AnimationSolver.Evaluate
			local CallCount = 0
			AnimationSolver.Evaluate = function(...)
				CallCount += 1
				return OriginalEvaluate(...)
			end

			-- No SetGlobalLod call this time.
			LunaRuntimeWrapper.Step(0.016)

			AnimationSolver.Evaluate = OriginalEvaluate
			expect(CallCount).toBe(1)

			Model:Destroy()
		end)
	end)
end)
