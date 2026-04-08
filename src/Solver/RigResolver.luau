--!strict
local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local Constants = require(Luna.Core.Constants)
local Quaternion = require(Luna.Core.Quaternion)
local Logger = require(Luna.Shared.Logger)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type Quat = Quaternion.Quat

-- ============================================================================
-- [[ TYPES ]]
-- ============================================================================

export type JointInfo = {
	Name: string,
	Motor: Motor6D,
	Part0Name: string,
	Part1Name: string,
	DefaultTransform: CFrame,
}

export type JointMap = StringIndexable<Motor6D>

--- Shared, immutable skeleton data. Cached by fingerprint so identical rigs
--- share the same table. Frozen after creation — never mutate.
export type SkeletonInfo = {
	BoneNames: Array<string>,
	NameToIndex: StringIndexable<number>,
	ChildrenMap: StringIndexable<Array<string>>,
	ParentMap: StringIndexable<string>,
	RestPositions: buffer,
	RestRotations: buffer,
	Fingerprint: string,
	RefCount: number, -- mutable counter; only field that changes after freeze
}

--- Per-NPC lightweight binding. Points to a shared SkeletonInfo.
export type RigBinding = {
	Skeleton: SkeletonInfo,
	Motors: Array<Motor6D>,
	RootPart: BasePart,
	Model: Model,
}

--- Legacy alias so downstream code that imports `RigResolver.RigInfo` keeps compiling.
export type RigInfo = RigBinding

-- ============================================================================
-- [[ MODULE ]]
-- ============================================================================

local RigResolver = {}

--- Fingerprint → SkeletonInfo cache
local __SkeletonCache: StringIndexable<SkeletonInfo> = {}

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

--- Build a deterministic fingerprint from bone hierarchy.
--- Sorts `boneName:parentName` pairs by Luau byte-order `<`, joins with `\n`.
local function __BuildFingerprint(Joints: Array<JointInfo>): string
	local Pairs: Array<string> = table.create(#Joints)
	for Index, Joint in Joints do
		Pairs[Index] = `{Joint.Part1Name}:{Joint.Part0Name}`
	end
	table.sort(Pairs, function(A: string, B: string)
		return A < B
	end)
	return table.concat(Pairs, "\n")
end

--- Decompose an array of JointInfo rest CFrames into position and rotation buffers.
local function __BuildRestPose(Joints: Array<JointInfo>): (buffer, buffer)
	local Count = #Joints
	local PositionBuffer = buffer.create(Count * Constants.POS_STRIDE)
	local RotationBuffer = buffer.create(Count * Constants.ROTATION_BUFFER_STRIDE)

	for Index, Joint in Joints do
		local CF = Joint.DefaultTransform
		local Position = CF.Position
		local Offset = (Index - 1) * Constants.POS_STRIDE
		buffer.writef32(PositionBuffer, Offset, Position.X)
		buffer.writef32(PositionBuffer, Offset + 4, Position.Y)
		buffer.writef32(PositionBuffer, Offset + 8, Position.Z)

		local Q = Quaternion.FromCFrame(CF)
		local RotOffset = (Index - 1) * Constants.ROTATION_BUFFER_STRIDE
		buffer.writef32(RotationBuffer, RotOffset, Q.X)
		buffer.writef32(RotationBuffer, RotOffset + 4, Q.Y)
		buffer.writef32(RotationBuffer, RotOffset + 8, Q.Z)
		buffer.writef32(RotationBuffer, RotOffset + 12, Q.W)
	end

	return PositionBuffer, RotationBuffer
end

--- Look up or create a shared SkeletonInfo for the given joints.
local function __GetOrCreateSkeleton(Joints: Array<JointInfo>): SkeletonInfo
	local Fingerprint = __BuildFingerprint(Joints)

	local Cached = __SkeletonCache[Fingerprint]
	if Cached then
		-- RefCount is the one mutable field; we track it outside the frozen table
		-- by storing a wrapper. Since Luau freezes deeply, we keep RefCount in a
		-- separate tracking table instead. But for simplicity in this implementation,
		-- the SkeletonInfo is NOT frozen if RefCount needs mutation.
		-- We freeze the sub-tables instead.
		Cached.RefCount += 1
		return Cached
	end

	-- 1. Build bone name list and index lookup
	local BoneNames: Array<string> = table.create(#Joints)
	local NameToIndex: StringIndexable<number> = {}
	for Index, Joint in Joints do
		BoneNames[Index] = Joint.Part1Name
		NameToIndex[Joint.Part1Name] = Index
	end

	-- 2. Build hierarchy maps
	local ChildrenMap: StringIndexable<Array<string>> = {}
	local ParentMap: StringIndexable<string> = {}
	for _, Joint in Joints do
		local Parent = Joint.Part0Name
		local Child = Joint.Part1Name
		if Parent ~= "" then
			ParentMap[Child] = Parent
			if not ChildrenMap[Parent] then
				ChildrenMap[Parent] = {}
			end
			table.insert(ChildrenMap[Parent], Child)
		end
	end

	-- 3. Build rest pose buffers
	local RestPositions, RestRotations = __BuildRestPose(Joints)

	-- 4. Freeze immutable sub-tables
	table.freeze(BoneNames)
	table.freeze(NameToIndex)
	for _, Children in ChildrenMap do
		table.freeze(Children)
	end
	table.freeze(ChildrenMap)
	table.freeze(ParentMap)

	local Skeleton: SkeletonInfo = {
		BoneNames = BoneNames,
		NameToIndex = NameToIndex,
		ChildrenMap = ChildrenMap,
		ParentMap = ParentMap,
		RestPositions = RestPositions,
		RestRotations = RestRotations,
		Fingerprint = Fingerprint,
		RefCount = 1,
	}

	__SkeletonCache[Fingerprint] = Skeleton
	return Skeleton
end

--- Find the root part of a model: HumanoidRootPart > PrimaryPart > first BasePart.
local function __FindRootPart(Model: Model): BasePart
	local RootPart = Model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not RootPart then
		RootPart = Model.PrimaryPart
	end
	if not RootPart then
		for _, Child in Model:GetChildren() do
			if Child:IsA("BasePart") then
				RootPart = Child :: BasePart
				break
			end
		end
	end
	return RootPart :: BasePart
end

-- ============================================================================
-- [[ PUBLIC API ]]
-- ============================================================================

--- Scan Motor6Ds in Model, build hierarchy, return a RigBinding with a shared SkeletonInfo.
function RigResolver.Resolve(Model: Model): RigBinding
	local Joints: Array<JointInfo> = {}
	local JointMap: JointMap = {}

	for _, Descendant in Model:GetDescendants() do
		if not Descendant:IsA("Motor6D") then
			continue
		end

		local Motor = Descendant :: Motor6D
		local Part1 = Motor.Part1
		if not Part1 then
			continue
		end

		local TrackName = Part1.Name
		local Info: JointInfo = {
			Name = TrackName,
			Motor = Motor,
			Part0Name = if Motor.Part0 then Motor.Part0.Name else "",
			Part1Name = TrackName,
			DefaultTransform = Motor.Transform,
		}

		table.insert(Joints, Info)
		JointMap[TrackName] = Motor
	end

	local Skeleton = __GetOrCreateSkeleton(Joints)
	local RootPart = __FindRootPart(Model)

	-- Build Motors array aligned to Skeleton.BoneNames order
	local Motors: Array<Motor6D> = table.create(#Skeleton.BoneNames)
	for Index, BoneName in Skeleton.BoneNames do
		Motors[Index] = JointMap[BoneName]
	end

	Logger.Info(
		`Resolved {#Joints} joints for rig "{Model.Name}" (skeleton {string.sub(Skeleton.Fingerprint, 1, 32)}...)`
	)

	return {
		Skeleton = Skeleton,
		Motors = Motors,
		RootPart = RootPart,
		Model = Model,
	}
end

--- Decrement RefCount for the binding's skeleton. Evicts from cache when zero.
function RigResolver.ReleaseBinding(Binding: RigBinding)
	local Skeleton = Binding.Skeleton
	Skeleton.RefCount -= 1
	if Skeleton.RefCount <= 0 then
		__SkeletonCache[Skeleton.Fingerprint] = nil
		Logger.Debug(`Evicted skeleton cache for fingerprint {string.sub(Skeleton.Fingerprint, 1, 32)}...`)
	end
end

--- Hot-swap a single Motor6D reference (e.g. after part reparent).
--- Asserts the motor's Part1.Name matches the expected bone at that index.
function RigResolver.RebindMotor(Binding: RigBinding, BoneName: string, NewMotor: Motor6D)
	local Skeleton = Binding.Skeleton
	local Index = Skeleton.NameToIndex[BoneName]
	assert(Index, `RebindMotor: bone "{BoneName}" not found in skeleton`)
	assert(
		NewMotor.Part1 and NewMotor.Part1.Name == BoneName,
		`RebindMotor: Motor Part1 name "{if NewMotor.Part1 then NewMotor.Part1.Name else "nil"}" does not match bone "{BoneName}"`
	)
	Binding.Motors[Index] = NewMotor
end

--- Create a new RigBinding that extends a base skeleton with additional bones.
--- Base bone indices are preserved; new bones are appended.
function RigResolver.ExtendBinding(BaseBinding: RigBinding, ExtraJoints: Array<JointInfo>): RigBinding
	-- Build JointInfo array from existing skeleton + motors, then append extras
	local BaseSkeleton = BaseBinding.Skeleton
	local BaseCount = #BaseSkeleton.BoneNames
	local AllJoints: Array<JointInfo> = table.create(BaseCount + #ExtraJoints)

	-- Reconstruct JointInfo from skeleton data + motor refs
	for Index = 1, BaseCount do
		local BoneName = BaseSkeleton.BoneNames[Index]
		local Motor = BaseBinding.Motors[Index]
		AllJoints[Index] = {
			Name = BoneName,
			Motor = Motor,
			Part0Name = BaseSkeleton.ParentMap[BoneName] or "",
			Part1Name = BoneName,
			DefaultTransform = if Motor then Motor.Transform else CFrame.identity,
		}
	end

	for _, Joint in ExtraJoints do
		table.insert(AllJoints, Joint)
	end

	-- Create new skeleton (different fingerprint due to extra bones)
	local Skeleton = __GetOrCreateSkeleton(AllJoints)
	local Motors: Array<Motor6D> = table.create(#Skeleton.BoneNames)
	local MotorLookup: StringIndexable<Motor6D> = {}
	for _, Joint in AllJoints do
		MotorLookup[Joint.Name] = Joint.Motor
	end
	for Index, BoneName in Skeleton.BoneNames do
		Motors[Index] = MotorLookup[BoneName]
	end

	return {
		Skeleton = Skeleton,
		Motors = Motors,
		RootPart = BaseBinding.RootPart,
		Model = BaseBinding.Model,
	}
end

--- Read rest pose from skeleton buffers and return a CFrame dictionary.
function RigResolver.GetDefaultPose(Binding: RigBinding): StringIndexable<CFrame>
	local Skeleton = Binding.Skeleton
	local Pose: StringIndexable<CFrame> = {}

	for Index, BoneName in Skeleton.BoneNames do
		local PosOffset = (Index - 1) * Constants.POS_STRIDE
		local RotOffset = (Index - 1) * Constants.ROTATION_BUFFER_STRIDE

		local Position = Vector3.new(
			buffer.readf32(Skeleton.RestPositions, PosOffset),
			buffer.readf32(Skeleton.RestPositions, PosOffset + 4),
			buffer.readf32(Skeleton.RestPositions, PosOffset + 8)
		)

		local Q: Quat = {
			X = buffer.readf32(Skeleton.RestRotations, RotOffset),
			Y = buffer.readf32(Skeleton.RestRotations, RotOffset + 4),
			Z = buffer.readf32(Skeleton.RestRotations, RotOffset + 8),
			W = buffer.readf32(Skeleton.RestRotations, RotOffset + 12),
		}

		Pose[BoneName] = Quaternion.ToCFrame(Q, Position)
	end

	return Pose
end

--- Write rest pose from skeleton buffers directly to Motor6D.Transform.
function RigResolver.RestoreDefaultPose(Binding: RigBinding)
	local Skeleton = Binding.Skeleton

	for Index = 1, #Skeleton.BoneNames do
		local Motor = Binding.Motors[Index]
		if not Motor then
			continue
		end

		local PosOffset = (Index - 1) * Constants.POS_STRIDE
		local RotOffset = (Index - 1) * Constants.ROTATION_BUFFER_STRIDE

		local Position = Vector3.new(
			buffer.readf32(Skeleton.RestPositions, PosOffset),
			buffer.readf32(Skeleton.RestPositions, PosOffset + 4),
			buffer.readf32(Skeleton.RestPositions, PosOffset + 8)
		)

		local Q: Quat = {
			X = buffer.readf32(Skeleton.RestRotations, RotOffset),
			Y = buffer.readf32(Skeleton.RestRotations, RotOffset + 4),
			Z = buffer.readf32(Skeleton.RestRotations, RotOffset + 8),
			W = buffer.readf32(Skeleton.RestRotations, RotOffset + 12),
		}

		Motor.Transform = Quaternion.ToCFrame(Q, Position)
	end
end

--- Return a snapshot of the skeleton cache for diagnostics.
function RigResolver.GetCacheStats(): { UniqueFingerprints: number, Entries: { { Fingerprint: string, BoneCount: number, RefCount: number } } }
	local Entries = {}
	local Count = 0
	for Fingerprint, Skeleton in __SkeletonCache do
		Count += 1
		Entries[Count] = {
			Fingerprint = string.sub(Fingerprint, 1, 20),
			BoneCount = #Skeleton.BoneNames,
			RefCount = Skeleton.RefCount,
		}
	end
	return {
		UniqueFingerprints = Count,
		Entries = Entries,
	}
end

--- Clear the skeleton cache. Intended for testing only.
function RigResolver.ClearCache()
	table.clear(__SkeletonCache)
end

--- Retrieve a cached skeleton by fingerprint. Intended for testing/inspection.
function RigResolver.GetCachedSkeleton(Fingerprint: string): SkeletonInfo?
	return __SkeletonCache[Fingerprint]
end

export type RigResolver = typeof(RigResolver)

return RigResolver
