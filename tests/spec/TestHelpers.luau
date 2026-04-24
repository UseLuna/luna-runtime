--!strict
local EPSILON = 1e-5

local TestHelpers = {}

function TestHelpers.CFrameComponentsClose(A: CFrame, B: CFrame, Tolerance: number?): boolean
	local Eps = Tolerance or EPSILON
	local AComps = { A:GetComponents() }
	local BComps = { B:GetComponents() }
	for I = 1, 12 do
		if math.abs(AComps[I] - BComps[I]) > Eps then
			return false
		end
	end
	return true
end

function TestHelpers.QuatClose(
	A: { X: number, Y: number, Z: number, W: number },
	B: { X: number, Y: number, Z: number, W: number },
	Tolerance: number?
): boolean
	local Eps = Tolerance or EPSILON
	return math.abs(A.X - B.X) < Eps
		and math.abs(A.Y - B.Y) < Eps
		and math.abs(A.Z - B.Z) < Eps
		and math.abs(A.W - B.W) < Eps
end

return TestHelpers
