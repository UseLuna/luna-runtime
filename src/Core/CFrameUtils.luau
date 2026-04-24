--!strict
--!optimize 2
--!native
local Quaternion = require(script.Parent.Quaternion)

type Quat = Quaternion.Quat

local CFrameUtils = {}

export type DecomposedCFrame = {
	Position: Vector3,
	Rotation: Quat,
}

function CFrameUtils.Decompose(CF: CFrame): DecomposedCFrame
	return {
		Position = CF.Position,
		Rotation = Quaternion.FromCFrame(CF),
	}
end

function CFrameUtils.Compose(Decomposed: DecomposedCFrame): CFrame
	return Quaternion.ToCFrame(Decomposed.Rotation, Decomposed.Position)
end

function CFrameUtils.Lerp(A: DecomposedCFrame, B: DecomposedCFrame, Alpha: number): DecomposedCFrame
	return {
		Position = A.Position:Lerp(B.Position, Alpha),
		Rotation = Quaternion.Slerp(A.Rotation, B.Rotation, Alpha),
	}
end

function CFrameUtils.Identity(): DecomposedCFrame
	return {
		Position = Vector3.zero,
		Rotation = Quaternion.Identity(),
	}
end

export type CFrameUtils = typeof(CFrameUtils)

return CFrameUtils
