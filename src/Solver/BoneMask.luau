--!strict
--!optimize 2
--!native
--[[
	BoneMask — per-bone float weights for partial animation blending.

	Each bone gets a weight from 0.0 (excluded) to 1.0 (fully included).
	Used by AnimationSolver to skip evaluation and blending for masked-out bones.

	Weights stored in a flat buffer (BoneCount × 4 bytes, f32 per bone).
	BoneMask is static (created once, cached). For animated per-bone weights
	that transition smoothly at runtime, see LiveBoneWeights in AnimationSolver.
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)

type Array<V> = CoreTypes.Array<V>

local BoneMask = {}

export type self = {
	Weights: buffer,
	BoneCount: number,
}

export type BoneMask = self

function BoneMask.FullBody(BoneCount: number): BoneMask
	local Weights = buffer.create(BoneCount * 4)
	for Index = 0, BoneCount - 1 do
		buffer.writef32(Weights, Index * 4, 1.0)
	end
	return {
		Weights = Weights,
		BoneCount = BoneCount,
	}
end

function BoneMask.Empty(BoneCount: number): BoneMask
	-- buffer.create already zeroes memory
	return {
		Weights = buffer.create(BoneCount * 4),
		BoneCount = BoneCount,
	}
end

function BoneMask.FromBone(
	BoneCount: number,
	RootBoneName: string,
	ChildrenMap: CoreTypes.StringIndexable<Array<string>>,
	NameToIndex: CoreTypes.StringIndexable<number>
): BoneMask
	local Mask = BoneMask.Empty(BoneCount)

	-- Recursive flood-fill from root bone
	local function MarkDescendants(BoneName: string)
		local Index = NameToIndex[BoneName]
		if Index then
			buffer.writef32(Mask.Weights, (Index - 1) * 4, 1.0)
		end

		local Children = ChildrenMap[BoneName]
		if Children then
			for _, ChildName in Children do
				MarkDescendants(ChildName)
			end
		end
	end

	MarkDescendants(RootBoneName)

	return Mask
end

function BoneMask.Invert(Mask: BoneMask): BoneMask
	local Count = Mask.BoneCount
	local Weights = buffer.create(Count * 4)
	for Index = 0, Count - 1 do
		local Offset = Index * 4
		buffer.writef32(Weights, Offset, 1.0 - buffer.readf32(Mask.Weights, Offset))
	end
	return {
		Weights = Weights,
		BoneCount = Count,
	}
end

function BoneMask.Combine(A: BoneMask, B: BoneMask): BoneMask
	local Count = A.BoneCount
	local Weights = buffer.create(Count * 4)
	for Index = 0, Count - 1 do
		local Offset = Index * 4
		buffer.writef32(Weights, Offset, math.max(buffer.readf32(A.Weights, Offset), buffer.readf32(B.Weights, Offset)))
	end
	return {
		Weights = Weights,
		BoneCount = Count,
	}
end

function BoneMask.MaxWeight(Mask: BoneMask): number
	local Max = 0
	for Index = 0, Mask.BoneCount - 1 do
		local Value = buffer.readf32(Mask.Weights, Index * 4)
		if Value > Max then
			Max = Value
		end
	end
	return Max
end

export type BoneMaskModule = typeof(BoneMask)

return BoneMask
