--!strict
--!optimize 2
--!native
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local ExportTypes = require(script.Parent.Parent.Types.ExportTypes)
local Constants = require(script.Parent.Constants)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type PoseEasingInfo = ExportTypes.PoseEasingInfo

local Curves = {}

-- [[ TYPES ]]

export type BezierCoefficients = {
	AX: number,
	BX: number,
	CX: number,
	AY: number,
	BY: number,
	CY: number,
	LUT: Array<number>,
}

export type BezierHandle = {
	TimeOffset: number,
	ValueOffset: number,
}

export type EasingFunction = (Alpha: number) -> number

-- Context passed to curve evaluators — contains all data a curve mode might need
export type CurveContext = {
	BezierCoeffs: BezierCoefficients?,
	EasingFn: EasingFunction?,
}

-- A CurveEvaluator remaps a normalized time (0-1) to an alpha (0-1).
-- Third parties register these to add custom curve modes.
export type CurveEvaluator = (NormalizedTime: number, Context: CurveContext) -> number

-- [[ CURVE REGISTRY ]]
-- Modular system: built-in modes are registered below, third parties can add more.

local __Registry: StringIndexable<CurveEvaluator> = {}

function Curves.RegisterCurve(Mode: string, Evaluator: CurveEvaluator)
	__Registry[Mode] = Evaluator
end

function Curves.GetCurveEvaluator(Mode: string): CurveEvaluator?
	return __Registry[Mode]
end

function Curves.GetRegisteredModes(): Array<string>
	local Modes: Array<string> = {}
	for Mode in __Registry do
		table.insert(Modes, Mode)
	end
	return Modes
end

-- Master dispatch — called by the Evaluator for every non-constant keyframe pair.
-- Falls back to linear (passthrough) for unregistered modes.
function Curves.RemapAlpha(Mode: string, NormalizedTime: number, Context: CurveContext): number
	local CurveEval = __Registry[Mode]
	if CurveEval then
		return CurveEval(NormalizedTime, Context)
	end
	return NormalizedTime
end

-- [[ BEZIER — BLENDER-STYLE CUBIC BEZIER ]]
-- Matches Blender's FCurve evaluation: cubic bezier between two keyframes,
-- handles stored as offsets, Newton's method for time-to-parameter solving.

-- Compile two BezierHandles into polynomial coefficients.
-- RightHandle is from the left keyframe, LeftHandle is from the right keyframe.
-- Produces coefficients for B(t) = A*t³ + B*t² + C*t (D=0 for normalized curves).
function Curves.CompileBezier(
	RightHandle: BezierHandle,
	LeftHandle: BezierHandle,
	SegmentDuration: number
): BezierCoefficients
	-- Normalize handle offsets to [0,1] space
	-- P0 = (0, 0), P3 = (1, 1)
	local P1X = math.clamp(RightHandle.TimeOffset / SegmentDuration, 0, 1)
	local P1Y = RightHandle.ValueOffset
	local P2X = math.clamp(1 + LeftHandle.TimeOffset / SegmentDuration, 0, 1)
	local P2Y = 1 + LeftHandle.ValueOffset

	-- Standard cubic bezier coefficient derivation
	-- C = 3(P1 - P0) = 3*P1
	-- B = 3(P2 - P1) - C
	-- A = P3 - P0 - C - B = 1 - C - B
	local CX = 3 * P1X
	local BX = 3 * (P2X - P1X) - CX
	local AX = 1 - CX - BX

	local CY = 3 * P1Y
	local BY = 3 * (P2Y - P1Y) - CY
	local AY = 1 - CY - BY

	-- Pre-compute LUT for Newton's method initial guess
	local LutSize = Constants.BEZIER_LUT_SIZE
	local LUT: Array<number> = table.create(LutSize)
	for Index = 0, LutSize - 1 do
		local T = Index / (LutSize - 1)
		LUT[Index + 1] = ((AX * T + BX) * T + CX) * T
	end

	return {
		AX = AX,
		BX = BX,
		CX = CX,
		AY = AY,
		BY = BY,
		CY = CY,
		LUT = LUT,
	}
end

-- Evaluate cubic polynomial at parameter T
function Curves.EvaluateCubic(A: number, B: number, C: number, T: number): number
	return ((A * T + B) * T + C) * T
end

-- Derivative of cubic polynomial
local function __EvaluateCubicDerivative(A: number, B: number, C: number, T: number): number
	return (3 * A * T + 2 * B) * T + C
end

-- Find initial guess from LUT via linear search
local function __GetInitialGuess(Coeffs: BezierCoefficients, X: number): number
	local LUT = Coeffs.LUT
	local LutSize = #LUT
	local Interval = 1 / (LutSize - 1)

	for Index = 1, LutSize - 1 do
		if LUT[Index + 1] >= X then
			local Start = LUT[Index]
			local Span = LUT[Index + 1] - Start
			if Span == 0 then
				return (Index - 1) * Interval
			end
			return ((Index - 1) + (X - Start) / Span) * Interval
		end
	end

	return 1
end

-- Newton's method to solve BezierX(T) = X for T.
-- Falls back to bisection if Newton fails to converge.
function Curves.SolveTimeToParameter(Coeffs: BezierCoefficients, X: number): number
	if X <= 0 then
		return 0
	end
	if X >= 1 then
		return 1
	end

	local T = __GetInitialGuess(Coeffs, X)

	-- 1. Newton's method (fast convergence for well-behaved curves)
	local MaxIterations = Constants.NEWTON_MAX_ITERATIONS
	local MinSlope = Constants.NEWTON_MIN_SLOPE

	for _ = 1, MaxIterations do
		local CurrentX = Curves.EvaluateCubic(Coeffs.AX, Coeffs.BX, Coeffs.CX, T) - X
		local Derivative = __EvaluateCubicDerivative(Coeffs.AX, Coeffs.BX, Coeffs.CX, T)

		if math.abs(Derivative) < MinSlope then
			break
		end

		T = T - CurrentX / Derivative

		if math.abs(CurrentX) < Constants.BEZIER_SUBDIVISION_PRECISION then
			return T
		end
	end

	-- 2. Bisection fallback (guaranteed convergence)
	local Low = 0
	local High = 1
	T = X

	for _ = 1, Constants.BEZIER_SUBDIVISION_MAX_ITERATIONS do
		local CurrentX = Curves.EvaluateCubic(Coeffs.AX, Coeffs.BX, Coeffs.CX, T) - X
		if math.abs(CurrentX) < Constants.BEZIER_SUBDIVISION_PRECISION then
			return T
		end
		if CurrentX > 0 then
			High = T
		else
			Low = T
		end
		T = (Low + High) / 2
	end

	return T
end

-- Full bezier alpha evaluation: time → parameter (Newton) → value
function Curves.EvaluateBezierAlpha(Coeffs: BezierCoefficients, NormalizedTime: number): number
	if NormalizedTime <= 0 then
		return 0
	end
	if NormalizedTime >= 1 then
		return 1
	end

	local Parameter = Curves.SolveTimeToParameter(Coeffs, NormalizedTime)
	return Curves.EvaluateCubic(Coeffs.AY, Coeffs.BY, Coeffs.CY, Parameter)
end

-- [[ EASING LIBRARY ]]
-- 10 base functions (In direction). Out and InOut derived via wrappers.
-- Formulas match Blender's easing presets and standard Robert Penner equations.

function Curves.EaseSine(Alpha: number): number
	return 1 - math.cos(Alpha * math.pi / 2)
end

function Curves.EaseQuad(Alpha: number): number
	return Alpha * Alpha
end

function Curves.EaseCubic(Alpha: number): number
	return Alpha * Alpha * Alpha
end

function Curves.EaseQuart(Alpha: number): number
	local A2 = Alpha * Alpha
	return A2 * A2
end

function Curves.EaseQuint(Alpha: number): number
	local A2 = Alpha * Alpha
	return A2 * A2 * Alpha
end

function Curves.EaseExpo(Alpha: number): number
	if Alpha <= 0 then
		return 0
	end
	return math.pow(2, 10 * (Alpha - 1))
end

function Curves.EaseCirc(Alpha: number): number
	return 1 - math.sqrt(1 - Alpha * Alpha)
end

function Curves.EaseBack(Alpha: number): number
	local Overshoot = Constants.EASE_BACK_OVERSHOOT
	return Alpha * Alpha * ((Overshoot + 1) * Alpha - Overshoot)
end

function Curves.EaseBounce(Alpha: number): number
	-- Bounce is naturally an Out function, so the base is Out
	-- and we invert for In usage in the direction wrappers
	local N1 = 7.5625
	local D1 = 2.75
	local A = 1 - Alpha

	if A < 1 / D1 then
		return 1 - N1 * A * A
	elseif A < 2 / D1 then
		A = A - 1.5 / D1
		return 1 - (N1 * A * A + 0.75)
	elseif A < 2.5 / D1 then
		A = A - 2.25 / D1
		return 1 - (N1 * A * A + 0.9375)
	else
		A = A - 2.625 / D1
		return 1 - (N1 * A * A + 0.984375)
	end
end

function Curves.EaseElastic(Alpha: number): number
	if Alpha <= 0 then
		return 0
	end
	if Alpha >= 1 then
		return 1
	end
	return -math.pow(2, 10 * Alpha - 10) * math.sin((Alpha * 10 - 10.75) * (2 * math.pi) / 3)
end

-- [[ DIRECTION WRAPPERS ]]

function Curves.ApplyIn(Fn: EasingFunction, Alpha: number): number
	return Fn(Alpha)
end

function Curves.ApplyOut(Fn: EasingFunction, Alpha: number): number
	return 1 - Fn(1 - Alpha)
end

function Curves.ApplyInOut(Fn: EasingFunction, Alpha: number): number
	if Alpha < 0.5 then
		return Fn(Alpha * 2) / 2
	end
	return 1 - Fn((1 - Alpha) * 2) / 2
end

-- [[ EASING RESOLUTION ]]

-- Lookup table: EasingStyle → base function
local __EASING_FUNCTIONS: StringIndexable<EasingFunction> = {
	Sine = Curves.EaseSine,
	Quad = Curves.EaseQuad,
	Cubic = Curves.EaseCubic,
	Quart = Curves.EaseQuart,
	Quint = Curves.EaseQuint,
	Expo = Curves.EaseExpo,
	Circ = Curves.EaseCirc,
	Back = Curves.EaseBack,
	Bounce = Curves.EaseBounce,
	Elastic = Curves.EaseElastic,
}

-- Pre-built lookup table of all Style × Direction combinations.
-- Avoids allocating a new closure on every ResolveEasing call.
local __RESOLVED_EASINGS: StringIndexable<StringIndexable<EasingFunction>> = {}

do
	local Directions: StringIndexable<(EasingFunction, number) -> number> = {
		["In"] = Curves.ApplyIn,
		Out = Curves.ApplyOut,
		InOut = Curves.ApplyInOut,
	}

	for StyleName, BaseFn in __EASING_FUNCTIONS do
		__RESOLVED_EASINGS[StyleName] = {}
		for DirName, DirFn in Directions do
			__RESOLVED_EASINGS[StyleName][DirName] = function(Alpha: number): number
				return DirFn(BaseFn, Alpha)
			end
		end
	end
end

-- Resolve an EasingStyle + EasingDirection to a single callable function.
-- Returns nil for unrecognized combinations (caller falls back to linear).
function Curves.ResolveEasing(Style: string, Direction: string): EasingFunction?
	local StyleTable = __RESOLVED_EASINGS[Style]
	if not StyleTable then
		return nil
	end
	return StyleTable[Direction]
end

-- [[ ROBLOX EASING MAPPING ]]
-- Roblox Pose only supports 5 easing styles: Linear, Constant, Cubic, Elastic, Bounce.
-- Returns a table with Style/Direction strings matching Enum.PoseEasingStyle/Direction,
-- or nil if the curve mode has no native Roblox equivalent (must be baked).

-- Easing styles that have a 1:1 Roblox PoseEasingStyle equivalent
local __ROBLOX_NATIVE_EASINGS: StringIndexable<boolean> = {
	Cubic = true,
	Bounce = true,
	Elastic = true,
}

function Curves.GetRobloxEasing(CurveMode: string, EasingStyle: string?, EasingDirection: string?): PoseEasingInfo?
	if CurveMode == "Linear" then
		return { Style = "Linear", Direction = "In" }
	end

	if CurveMode == "Stepped" then
		return { Style = "Constant", Direction = "In" }
	end

	if CurveMode == "Easing" and EasingStyle and EasingDirection then
		if __ROBLOX_NATIVE_EASINGS[EasingStyle] then
			return { Style = EasingStyle, Direction = EasingDirection }
		end
	end

	-- Bezier, Hermite, Sine, Quad, Quart, Quint, Expo, Circ, Back, custom → must bake
	return nil
end

-- [[ REGISTER BUILT-IN CURVE MODES ]]

Curves.RegisterCurve("Linear", function(NormalizedTime: number, _Context: CurveContext): number
	return NormalizedTime
end)

Curves.RegisterCurve("Stepped", function(_NormalizedTime: number, _Context: CurveContext): number
	return 0
end)

Curves.RegisterCurve("Bezier", function(NormalizedTime: number, Context: CurveContext): number
	if Context.BezierCoeffs then
		return Curves.EvaluateBezierAlpha(Context.BezierCoeffs, NormalizedTime)
	end
	return NormalizedTime
end)

Curves.RegisterCurve("Easing", function(NormalizedTime: number, Context: CurveContext): number
	if Context.EasingFn then
		return Context.EasingFn(NormalizedTime)
	end
	return NormalizedTime
end)

Curves.RegisterCurve("Hermite", function(NormalizedTime: number, _Context: CurveContext): number
	-- Smoothstep: 3t² - 2t³ (simple hermite without neighbor context)
	local T = NormalizedTime
	return T * T * (3 - 2 * T)
end)

export type Curves = typeof(Curves)

return Curves
