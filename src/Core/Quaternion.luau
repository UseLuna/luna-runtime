--!strict
--!optimize 2
--!native
local Constants = require(script.Parent.Constants)

local Quaternion = {}

export type Quat = {
	X: number,
	Y: number,
	Z: number,
	W: number,
}

function Quaternion.Identity(): Quat
	return { X = 0, Y = 0, Z = 0, W = 1 }
end

function Quaternion.FromCFrame(CF: CFrame): Quat
	-- Extract rotation components from CFrame's rotation matrix
	local _, _, _, R00, R01, R02, R10, R11, R12, R20, R21, R22 = CF:GetComponents()

	-- Shepperd's method for robust quaternion extraction
	local Trace = R00 + R11 + R22
	if Trace > 0 then
		local S = math.sqrt(Trace + 1) * 2
		return {
			X = (R21 - R12) / S,
			Y = (R02 - R20) / S,
			Z = (R10 - R01) / S,
			W = 0.25 * S,
		}
	elseif R00 > R11 and R00 > R22 then
		local S = math.sqrt(1 + R00 - R11 - R22) * 2
		return {
			X = 0.25 * S,
			Y = (R01 + R10) / S,
			Z = (R02 + R20) / S,
			W = (R21 - R12) / S,
		}
	elseif R11 > R22 then
		local S = math.sqrt(1 + R11 - R00 - R22) * 2
		return {
			X = (R01 + R10) / S,
			Y = 0.25 * S,
			Z = (R12 + R21) / S,
			W = (R02 - R20) / S,
		}
	else
		local S = math.sqrt(1 + R22 - R00 - R11) * 2
		return {
			X = (R02 + R20) / S,
			Y = (R12 + R21) / S,
			Z = 0.25 * S,
			W = (R10 - R01) / S,
		}
	end
end

function Quaternion.ToCFrame(Q: Quat, Position: Vector3): CFrame
	local X, Y, Z, W = Q.X, Q.Y, Q.Z, Q.W

	-- Pre-compute repeated products
	local X2 = X + X
	local Y2 = Y + Y
	local Z2 = Z + Z
	local XX = X * X2
	local XY = X * Y2
	local XZ = X * Z2
	local YY = Y * Y2
	local YZ = Y * Z2
	local ZZ = Z * Z2
	local WX = W * X2
	local WY = W * Y2
	local WZ = W * Z2

	return CFrame.new(
		Position.X,
		Position.Y,
		Position.Z,
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

function Quaternion.Multiply(A: Quat, B: Quat): Quat
	return {
		X = A.W * B.X + A.X * B.W + A.Y * B.Z - A.Z * B.Y,
		Y = A.W * B.Y - A.X * B.Z + A.Y * B.W + A.Z * B.X,
		Z = A.W * B.Z + A.X * B.Y - A.Y * B.X + A.Z * B.W,
		W = A.W * B.W - A.X * B.X - A.Y * B.Y - A.Z * B.Z,
	}
end

function Quaternion.Conjugate(Q: Quat): Quat
	return { X = -Q.X, Y = -Q.Y, Z = -Q.Z, W = Q.W }
end

function Quaternion.Dot(A: Quat, B: Quat): number
	return A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W
end

function Quaternion.Length(Q: Quat): number
	return math.sqrt(Q.X * Q.X + Q.Y * Q.Y + Q.Z * Q.Z + Q.W * Q.W)
end

function Quaternion.Normalize(Q: Quat): Quat
	local Len = Quaternion.Length(Q)
	if Len < Constants.EPSILON then
		return Quaternion.Identity()
	end
	local InvLen = 1 / Len
	return {
		X = Q.X * InvLen,
		Y = Q.Y * InvLen,
		Z = Q.Z * InvLen,
		W = Q.W * InvLen,
	}
end

-- Negate B if dot product is negative to ensure shortest-path interpolation.
-- Without this, a 350-degree rotation would take the long arc instead of the short 10-degree path.
local function __EnsureShortestPath(B: Quat, DotProduct: number): Quat
	if DotProduct < 0 then
		return { X = -B.X, Y = -B.Y, Z = -B.Z, W = -B.W }
	end
	return B
end

function Quaternion.Nlerp(A: Quat, B: Quat, Alpha: number): Quat
	local D = Quaternion.Dot(A, B)
	local AdjustedB = __EnsureShortestPath(B, D)

	return Quaternion.Normalize({
		X = A.X + (AdjustedB.X - A.X) * Alpha,
		Y = A.Y + (AdjustedB.Y - A.Y) * Alpha,
		Z = A.Z + (AdjustedB.Z - A.Z) * Alpha,
		W = A.W + (AdjustedB.W - A.W) * Alpha,
	})
end

function Quaternion.Slerp(A: Quat, B: Quat, Alpha: number): Quat
	local D = Quaternion.Dot(A, B)
	local AdjustedB = __EnsureShortestPath(B, D)
	local AbsDot = math.abs(D)

	-- When quaternions are nearly parallel, slerp is numerically unstable.
	-- Fall back to nlerp which is cheaper and nearly identical in this case.
	if AbsDot > Constants.SLERP_THRESHOLD then
		return Quaternion.Nlerp(A, AdjustedB, Alpha)
	end

	local Theta = math.acos(AbsDot)
	local SinTheta = math.sin(Theta)
	local WeightA = math.sin((1 - Alpha) * Theta) / SinTheta
	local WeightB = math.sin(Alpha * Theta) / SinTheta

	return {
		X = A.X * WeightA + AdjustedB.X * WeightB,
		Y = A.Y * WeightA + AdjustedB.Y * WeightB,
		Z = A.Z * WeightA + AdjustedB.Z * WeightB,
		W = A.W * WeightA + AdjustedB.W * WeightB,
	}
end

-- ============================================================================
-- [[ INTO VARIANTS (zero allocation — mutate existing Quat tables) ]]
-- ============================================================================

-- Write identity values into an existing Quat table.
function Quaternion.IdentityInto(Out: Quat)
	Out.X = 0
	Out.Y = 0
	Out.Z = 0
	Out.W = 1
end

-- Write conjugate of Q into Out. Out may alias Q safely.
function Quaternion.ConjugateInto(Q: Quat, Out: Quat)
	Out.X = -Q.X
	Out.Y = -Q.Y
	Out.Z = -Q.Z
	Out.W = Q.W
end

-- Normalize Q and write result into Out. Out may alias Q safely.
function Quaternion.NormalizeInto(Q: Quat, Out: Quat)
	local Len = math.sqrt(Q.X * Q.X + Q.Y * Q.Y + Q.Z * Q.Z + Q.W * Q.W)
	if Len < Constants.EPSILON then
		Out.X = 0
		Out.Y = 0
		Out.Z = 0
		Out.W = 1
		return
	end
	local InvLen = 1 / Len
	Out.X = Q.X * InvLen
	Out.Y = Q.Y * InvLen
	Out.Z = Q.Z * InvLen
	Out.W = Q.W * InvLen
end

-- Nlerp between A and B at Alpha, write into Out. Handles shortest-path sign flip.
-- Out must NOT alias A or B (reads from both during write).
function Quaternion.NlerpInto(A: Quat, B: Quat, Alpha: number, Out: Quat)
	local D = A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W
	local Sign = if D < 0 then -1 else 1

	local BX = B.X * Sign
	local BY = B.Y * Sign
	local BZ = B.Z * Sign
	local BW = B.W * Sign

	local RX = A.X + (BX - A.X) * Alpha
	local RY = A.Y + (BY - A.Y) * Alpha
	local RZ = A.Z + (BZ - A.Z) * Alpha
	local RW = A.W + (BW - A.W) * Alpha

	local Len = math.sqrt(RX * RX + RY * RY + RZ * RZ + RW * RW)
	if Len < Constants.EPSILON then
		Out.X = 0
		Out.Y = 0
		Out.Z = 0
		Out.W = 1
		return
	end
	local InvLen = 1 / Len
	Out.X = RX * InvLen
	Out.Y = RY * InvLen
	Out.Z = RZ * InvLen
	Out.W = RW * InvLen
end

-- Slerp between A and B at Alpha, write into Out. Handles shortest-path.
-- Falls back to NlerpInto when quaternions are nearly parallel (same as Slerp).
-- Out must NOT alias A or B.
function Quaternion.SlerpInto(A: Quat, B: Quat, Alpha: number, Out: Quat)
	local D = A.X * B.X + A.Y * B.Y + A.Z * B.Z + A.W * B.W
	local Sign = if D < 0 then -1 else 1
	local AbsDot = math.abs(D)

	local BX = B.X * Sign
	local BY = B.Y * Sign
	local BZ = B.Z * Sign
	local BW = B.W * Sign

	if AbsDot > Constants.SLERP_THRESHOLD then
		-- Nearly parallel: fall back to nlerp (cheaper, numerically stable)
		local RX = A.X + (BX - A.X) * Alpha
		local RY = A.Y + (BY - A.Y) * Alpha
		local RZ = A.Z + (BZ - A.Z) * Alpha
		local RW = A.W + (BW - A.W) * Alpha

		local Len = math.sqrt(RX * RX + RY * RY + RZ * RZ + RW * RW)
		if Len < Constants.EPSILON then
			Out.X = 0
			Out.Y = 0
			Out.Z = 0
			Out.W = 1
			return
		end
		local InvLen = 1 / Len
		Out.X = RX * InvLen
		Out.Y = RY * InvLen
		Out.Z = RZ * InvLen
		Out.W = RW * InvLen
		return
	end

	local Theta = math.acos(AbsDot)
	local SinTheta = math.sin(Theta)
	local WeightA = math.sin((1 - Alpha) * Theta) / SinTheta
	local WeightB = math.sin(Alpha * Theta) / SinTheta

	Out.X = A.X * WeightA + BX * WeightB
	Out.Y = A.Y * WeightA + BY * WeightB
	Out.Z = A.Z * WeightA + BZ * WeightB
	Out.W = A.W * WeightA + BW * WeightB
end

-- Multiply A * B, write result into Out. Out must NOT alias A or B.
function Quaternion.MultiplyInto(A: Quat, B: Quat, Out: Quat)
	Out.X = A.W * B.X + A.X * B.W + A.Y * B.Z - A.Z * B.Y
	Out.Y = A.W * B.Y - A.X * B.Z + A.Y * B.W + A.Z * B.X
	Out.Z = A.W * B.Z + A.X * B.Y - A.Y * B.X + A.Z * B.W
	Out.W = A.W * B.W - A.X * B.X - A.Y * B.Y - A.Z * B.Z
end

export type Quaternion = typeof(Quaternion)

return Quaternion
