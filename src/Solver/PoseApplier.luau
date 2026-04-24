--!strict
--!optimize 2
--!native
--[[
	PoseApplier — applies a composed Pose (CFrame dictionary) to a rig's Motor6Ds.
	The ONLY module that touches Roblox Instances in the solve pipeline.
	Abstracts the apply strategy so it can be swapped (Motor6D.Transform is the only
	strategy for now, but BulkMoveTo or buffer batch could be tested later).
]]

local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local Constants = require(Luna.Core.Constants)
local Quaternion = require(Luna.Core.Quaternion)
local RigResolver = require(script.Parent.RigResolver)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type Quat = Quaternion.Quat
type RigInfo = RigResolver.RigInfo

local POS_STRIDE = Constants.POS_STRIDE
local ROT_STRIDE = Constants.ROTATION_BUFFER_STRIDE

local PoseApplier = {}

-- Apply a name→CFrame dictionary to the rig's Motor6D.Transform properties.
-- This is the final step in the solve pipeline — everything upstream is pure math.
function PoseApplier.Apply(RigInfo: RigInfo, CFrames: StringIndexable<CFrame>)
	local Skeleton = RigInfo.Skeleton
	local Motors = RigInfo.Motors
	for TrackName, Value in CFrames do
		local Index = Skeleton.NameToIndex[TrackName]
		if Index then
			local Motor = Motors[Index]
			if Motor then
				Motor.Transform = Value
			end
		end
	end
end

-- ZERO ALLOCATION: Apply directly from buffer-backed Pose (Position + Rotation buffers).
-- Inline ToCFrame math to avoid Quat table allocation per bone.
-- Motors array is 1-based, aligned to skeleton bone order.
function PoseApplier.ApplyPoseBuf(Motors: Array<Motor6D?>, PosBuf: buffer, RotBuf: buffer, BoneCount: number)
	for BoneIdx = 0, BoneCount - 1 do
		local Motor = Motors[BoneIdx + 1]
		if not Motor then
			continue
		end

		local PosOff = BoneIdx * POS_STRIDE
		local RotOff = BoneIdx * ROT_STRIDE

		local PX = buffer.readf32(PosBuf, PosOff)
		local PY = buffer.readf32(PosBuf, PosOff + 4)
		local PZ = buffer.readf32(PosBuf, PosOff + 8)

		local QX = buffer.readf32(RotBuf, RotOff)
		local QY = buffer.readf32(RotBuf, RotOff + 4)
		local QZ = buffer.readf32(RotBuf, RotOff + 8)
		local QW = buffer.readf32(RotBuf, RotOff + 12)

		-- Inline quaternion → rotation matrix (avoids Quat table alloc)
		local X2 = QX + QX
		local Y2 = QY + QY
		local Z2 = QZ + QZ
		local XX = QX * X2
		local XY = QX * Y2
		local XZ = QX * Z2
		local YY = QY * Y2
		local YZ = QY * Z2
		local ZZ = QZ * Z2
		local WX = QW * X2
		local WY = QW * Y2
		local WZ = QW * Z2

		Motor.Transform = CFrame.new(
			PX,
			PY,
			PZ,
			1 - (YY + ZZ),
			XY - WZ,
			XZ + WY,
			XY + WZ,
			1 - (XX + ZZ),
			YZ - WX,
			XZ - WY,
			YZ + WX,
			1 - (XX + YY)
		)
	end
end

-- Restore all joints to their default transforms (captured at resolve time).
function PoseApplier.RestoreDefault(RigInfo: RigInfo)
	RigResolver.RestoreDefaultPose(RigInfo)
end

export type PoseApplier = typeof(PoseApplier)

return PoseApplier
