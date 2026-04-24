--!strict
--!optimize 2
--!native
--[[
	Pose — flat buffer-backed storage for decomposed bone transforms.
	Used by AnimationSolver for zero-allocation blending.

	Positions: buffer of BoneCount × 12 bytes (3 × f32, POS_STRIDE)
	Rotations: buffer of BoneCount × 16 bytes (4 × f32, ROT_STRIDE)

	CFrame composition only happens once at apply time via ComposeToCFrames.
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local Constants = require(Luna.Core.Constants)
local Quaternion = require(Luna.Core.Quaternion)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>

local POS_STRIDE = Constants.POS_STRIDE
local ROT_STRIDE = Constants.ROTATION_BUFFER_STRIDE

local Pose = {}

export type self = {
	Positions: buffer,
	Rotations: buffer,
	BoneCount: number,
}

export type Pose = self

-- Create a new Pose with pre-allocated buffers sized to BoneCount.
-- Positions zeroed, rotations set to identity (W=1).
function Pose.Create(BoneCount: number): Pose
	local Positions = buffer.create(BoneCount * POS_STRIDE)
	local Rotations = buffer.create(BoneCount * ROT_STRIDE)

	-- Positions default to 0 from buffer.create
	-- Write identity quaternions (0, 0, 0, 1)
	for Index = 0, BoneCount - 1 do
		buffer.writef32(Rotations, Index * ROT_STRIDE + 12, 1)
	end

	return {
		Positions = Positions,
		Rotations = Rotations,
		BoneCount = BoneCount,
	}
end

-- Reset all positions to zero and rotations to identity.
function Pose.Reset(self: Pose)
	buffer.fill(self.Positions, 0, 0)
	buffer.fill(self.Rotations, 0, 0)
	for Index = 0, self.BoneCount - 1 do
		buffer.writef32(self.Rotations, Index * ROT_STRIDE + 12, 1)
	end
end

-- Read a position from a position buffer at a 1-based BoneIndex.
function Pose.ReadPosition(PosBuf: buffer, BoneIndex: number): Vector3
	local Offset = (BoneIndex - 1) * POS_STRIDE
	return Vector3.new(
		buffer.readf32(PosBuf, Offset),
		buffer.readf32(PosBuf, Offset + 4),
		buffer.readf32(PosBuf, Offset + 8)
	)
end

-- Write a position to a position buffer at a 1-based BoneIndex.
function Pose.WritePosition(PosBuf: buffer, BoneIndex: number, Pos: Vector3)
	local Offset = (BoneIndex - 1) * POS_STRIDE
	buffer.writef32(PosBuf, Offset, Pos.X)
	buffer.writef32(PosBuf, Offset + 4, Pos.Y)
	buffer.writef32(PosBuf, Offset + 8, Pos.Z)
end

-- Compose all positions + quaternions into a name→CFrame dictionary.
-- This is the ONLY place CFrames are created from buffer data.
function Pose.ComposeToCFrames(self: Pose, BoneNames: Array<string>): StringIndexable<CFrame>
	local Result: StringIndexable<CFrame> = {}
	local PosBuf = self.Positions
	local RotBuf = self.Rotations

	for Index = 1, self.BoneCount do
		local PosOff = (Index - 1) * POS_STRIDE
		local RotOff = (Index - 1) * ROT_STRIDE

		local Position = Vector3.new(
			buffer.readf32(PosBuf, PosOff),
			buffer.readf32(PosBuf, PosOff + 4),
			buffer.readf32(PosBuf, PosOff + 8)
		)

		local Q: Quaternion.Quat = {
			X = buffer.readf32(RotBuf, RotOff),
			Y = buffer.readf32(RotBuf, RotOff + 4),
			Z = buffer.readf32(RotBuf, RotOff + 8),
			W = buffer.readf32(RotBuf, RotOff + 12),
		}

		Result[BoneNames[Index]] = Quaternion.ToCFrame(Q, Position)
	end

	return Result
end

-- Copy all data from Source into Dest (same BoneCount required).
function Pose.CopyInto(Source: Pose, Dest: Pose)
	buffer.copy(Dest.Positions, 0, Source.Positions, 0, Source.BoneCount * POS_STRIDE)
	buffer.copy(Dest.Rotations, 0, Source.Rotations, 0, Source.BoneCount * ROT_STRIDE)
end

export type PoseModule = typeof(Pose)

return Pose
