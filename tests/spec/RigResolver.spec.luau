--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect
local beforeEach = JestGlobals.beforeEach

local RigResolver = require(ReplicatedStorage.Luna.Solver.RigResolver)
local Constants = require(ReplicatedStorage.Luna.Core.Constants)

-- ============================================================================
-- [[ HELPERS ]]
-- ============================================================================

--- Create a mock rig Model with HumanoidRootPart and Motor6Ds.
--- BoneNames[i] is driven by a Motor6D whose Part0 name is ParentNames[i].
local function __CreateMockRig(BoneNames: { string }, ParentNames: { string }): Model
	local Model = Instance.new("Model")
	Model.Name = "MockRig"

	local RootPart = Instance.new("Part")
	RootPart.Name = "HumanoidRootPart"
	RootPart.Parent = Model

	-- Create a part for each unique parent that isn't already a bone
	local PartsByName: { [string]: BasePart } = {}
	PartsByName["HumanoidRootPart"] = RootPart

	-- Pre-create all bone parts
	for _, BoneName in BoneNames do
		if not PartsByName[BoneName] then
			local Part = Instance.new("Part")
			Part.Name = BoneName
			Part.Parent = Model
			PartsByName[BoneName] = Part
		end
	end

	-- Create parent parts that might not be bones themselves
	for _, ParentName in ParentNames do
		if not PartsByName[ParentName] then
			local Part = Instance.new("Part")
			Part.Name = ParentName
			Part.Parent = Model
			PartsByName[ParentName] = Part
		end
	end

	-- Create Motor6Ds
	for Index, BoneName in BoneNames do
		local Motor = Instance.new("Motor6D")
		Motor.Name = BoneName
		Motor.Part0 = PartsByName[ParentNames[Index]]
		Motor.Part1 = PartsByName[BoneName]
		Motor.Parent = PartsByName[ParentNames[Index]]
	end

	return Model
end

-- ============================================================================
-- [[ TESTS ]]
-- ============================================================================

describe("RigResolver", function()
	beforeEach(function()
		RigResolver.ClearCache()
	end)

	describe("Resolve", function()
		it("returns a RigBinding with a SkeletonInfo", function()
			local Rig = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })
			local Binding = RigResolver.Resolve(Rig)

			expect(Binding.Skeleton).toBeDefined()
			expect(Binding.Motors).toBeDefined()
			expect(Binding.RootPart).toBeDefined()
			expect(Binding.Model).toBe(Rig)

			-- Skeleton fields
			expect(#Binding.Skeleton.BoneNames).toBe(2)
			expect(Binding.Skeleton.Fingerprint).toBeDefined()
			expect(Binding.Skeleton.RefCount).toBe(1)

			Rig:Destroy()
		end)

		it("shares SkeletonInfo for identical rigs", function()
			local RigA = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })
			local RigB = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })

			local BindingA = RigResolver.Resolve(RigA)
			local BindingB = RigResolver.Resolve(RigB)

			-- Same table reference for shared skeleton
			expect(BindingA.Skeleton).toBe(BindingB.Skeleton)
			expect(BindingA.Skeleton.RefCount).toBe(2)

			-- But different motor arrays (each NPC has its own Motor6Ds)
			expect(BindingA.Motors).never.toBe(BindingB.Motors)

			RigA:Destroy()
			RigB:Destroy()
		end)

		it("creates separate SkeletonInfo for different hierarchies", function()
			local RigA = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })
			local RigB = __CreateMockRig({ "Torso", "RightArm", "Head" }, { "HumanoidRootPart", "Torso", "Torso" })

			local BindingA = RigResolver.Resolve(RigA)
			local BindingB = RigResolver.Resolve(RigB)

			expect(BindingA.Skeleton).never.toBe(BindingB.Skeleton)
			expect(BindingA.Skeleton.Fingerprint).never.toBe(BindingB.Skeleton.Fingerprint)

			RigA:Destroy()
			RigB:Destroy()
		end)

		it("stores rest pose in buffer format", function()
			local Rig = __CreateMockRig({ "Torso" }, { "HumanoidRootPart" })
			local Binding = RigResolver.Resolve(Rig)

			-- Identity transform: rotation quaternion W component should be ~1
			local RotOffset = 0 * Constants.ROTATION_BUFFER_STRIDE
			local W = buffer.readf32(Binding.Skeleton.RestRotations, RotOffset + 12)
			-- Identity quaternion is (0, 0, 0, 1)
			expect(math.abs(W - 1)).toBeLessThan(0.001)

			Rig:Destroy()
		end)

		it("freezes SkeletonInfo sub-tables", function()
			local Rig = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })
			local Binding = RigResolver.Resolve(Rig)

			expect(table.isfrozen(Binding.Skeleton.BoneNames)).toBe(true)
			expect(table.isfrozen(Binding.Skeleton.NameToIndex)).toBe(true)
			expect(table.isfrozen(Binding.Skeleton.ChildrenMap)).toBe(true)
			expect(table.isfrozen(Binding.Skeleton.ParentMap)).toBe(true)

			Rig:Destroy()
		end)
	end)

	describe("ReleaseBinding", function()
		it("decrements RefCount and evicts at zero", function()
			local Rig = __CreateMockRig({ "Torso" }, { "HumanoidRootPart" })
			local Binding = RigResolver.Resolve(Rig)

			local Fingerprint = Binding.Skeleton.Fingerprint
			expect(Binding.Skeleton.RefCount).toBe(1)

			RigResolver.ReleaseBinding(Binding)

			expect(Binding.Skeleton.RefCount).toBe(0)
			expect(RigResolver.GetCachedSkeleton(Fingerprint)).toBeNil()

			Rig:Destroy()
		end)

		it("keeps cache when other bindings remain", function()
			local RigA = __CreateMockRig({ "Torso" }, { "HumanoidRootPart" })
			local RigB = __CreateMockRig({ "Torso" }, { "HumanoidRootPart" })

			local BindingA = RigResolver.Resolve(RigA)
			local BindingB = RigResolver.Resolve(RigB)

			expect(BindingA.Skeleton.RefCount).toBe(2)

			RigResolver.ReleaseBinding(BindingA)
			expect(BindingB.Skeleton.RefCount).toBe(1)

			local Fingerprint = BindingB.Skeleton.Fingerprint
			expect(RigResolver.GetCachedSkeleton(Fingerprint)).toBeDefined()

			RigA:Destroy()
			RigB:Destroy()
		end)
	end)

	describe("RebindMotor", function()
		it("updates motor reference", function()
			local Rig = __CreateMockRig({ "Torso" }, { "HumanoidRootPart" })
			local Binding = RigResolver.Resolve(Rig)

			-- Create a new Motor6D with matching Part1 name
			local NewMotor = Instance.new("Motor6D")
			local NewPart = Instance.new("Part")
			NewPart.Name = "Torso"
			NewMotor.Part1 = NewPart

			local OldMotor = Binding.Motors[1]
			expect(OldMotor).toBeDefined()

			RigResolver.RebindMotor(Binding, "Torso", NewMotor)

			expect(Binding.Motors[1]).toBe(NewMotor)
			expect(Binding.Motors[1]).never.toBe(OldMotor)

			NewPart:Destroy()
			NewMotor:Destroy()
			Rig:Destroy()
		end)
	end)

	describe("GetDefaultPose", function()
		it("returns CFrame dictionary from buffer data", function()
			local Rig = __CreateMockRig({ "Torso", "LeftArm" }, { "HumanoidRootPart", "Torso" })
			local Binding = RigResolver.Resolve(Rig)

			local Pose = RigResolver.GetDefaultPose(Binding)

			-- Should have entries for each bone
			local Count = 0
			for _ in Pose do
				Count += 1
			end
			expect(Count).toBe(2)

			-- Default Motor6D Transform is identity, so pose CFrames should be near identity
			local TorsoPose = Pose["Torso"]
			expect(TorsoPose).toBeDefined()

			-- Identity position should be near zero
			expect(math.abs(TorsoPose.Position.X)).toBeLessThan(0.001)
			expect(math.abs(TorsoPose.Position.Y)).toBeLessThan(0.001)
			expect(math.abs(TorsoPose.Position.Z)).toBeLessThan(0.001)

			Rig:Destroy()
		end)
	end)
end)
