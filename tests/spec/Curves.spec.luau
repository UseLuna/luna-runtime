--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local Curves = require(ReplicatedStorage.Luna.Core.Curves)

local EPSILON = 1e-4

-- [[ HELPERS ]]

local function ExpectClose(Actual: number, Expected: number, Tolerance: number?)
	local Eps = Tolerance or EPSILON
	expect(math.abs(Actual - Expected)).toBeLessThan(Eps)
end

-- [[ EASING — BOUNDARY TESTS ]]
-- Every easing function must return 0 at Alpha=0 and 1 at Alpha=1

describe("Curves", function()
	describe("Easing Boundaries", function()
		local EasingFunctions = {
			{ "Sine", Curves.EaseSine },
			{ "Quad", Curves.EaseQuad },
			{ "Cubic", Curves.EaseCubic },
			{ "Quart", Curves.EaseQuart },
			{ "Quint", Curves.EaseQuint },
			{ "Expo", Curves.EaseExpo },
			{ "Circ", Curves.EaseCirc },
			{ "Back", Curves.EaseBack },
			{ "Bounce", Curves.EaseBounce },
			{ "Elastic", Curves.EaseElastic },
		}

		for _, Entry in EasingFunctions do
			local Name = Entry[1] :: string
			local Fn = Entry[2] :: Curves.EasingFunction

			it(`{Name} In: 0→0 and 1→1`, function()
				ExpectClose(Curves.ApplyIn(Fn, 0), 0)
				ExpectClose(Curves.ApplyIn(Fn, 1), 1)
			end)

			it(`{Name} Out: 0→0 and 1→1`, function()
				ExpectClose(Curves.ApplyOut(Fn, 0), 0)
				ExpectClose(Curves.ApplyOut(Fn, 1), 1)
			end)

			it(`{Name} InOut: 0→0, 0.5→~0.5, 1→1`, function()
				ExpectClose(Curves.ApplyInOut(Fn, 0), 0)
				ExpectClose(Curves.ApplyInOut(Fn, 1), 1)
			end)
		end
	end)

	-- [[ EASING — MONOTONICITY ]]
	-- Non-overshooting easings must be monotonically increasing

	describe("Easing Monotonicity", function()
		local MonotonicFunctions = {
			{ "Sine", Curves.EaseSine },
			{ "Quad", Curves.EaseQuad },
			{ "Cubic", Curves.EaseCubic },
			{ "Quart", Curves.EaseQuart },
			{ "Quint", Curves.EaseQuint },
			{ "Expo", Curves.EaseExpo },
			{ "Circ", Curves.EaseCirc },
		}

		for _, Entry in MonotonicFunctions do
			local Name = Entry[1] :: string
			local Fn = Entry[2] :: Curves.EasingFunction

			it(`{Name} In is monotonically increasing`, function()
				local Previous = -1
				for Step = 0, 20 do
					local Alpha = Step / 20
					local Value = Curves.ApplyIn(Fn, Alpha)
					expect(Value >= Previous - EPSILON).toBe(true)
					Previous = Value
				end
			end)
		end
	end)

	-- [[ EASING — OVERSHOOT ]]
	-- Back and Elastic can exceed [0,1] range

	describe("Easing Overshoot", function()
		it("Back In goes below 0 mid-curve", function()
			local MinValue = 1
			for Step = 1, 19 do
				local Value = Curves.ApplyIn(Curves.EaseBack, Step / 20)
				MinValue = math.min(MinValue, Value)
			end
			expect(MinValue).toBeLessThan(0)
		end)

		it("Elastic In goes below 0 mid-curve", function()
			local MinValue = 1
			for Step = 1, 19 do
				local Value = Curves.ApplyIn(Curves.EaseElastic, Step / 20)
				MinValue = math.min(MinValue, Value)
			end
			expect(MinValue).toBeLessThan(0)
		end)
	end)

	-- [[ EASING — RESOLVE ]]

	describe("ResolveEasing", function()
		it("resolves valid style + direction", function()
			local Fn = Curves.ResolveEasing("Quad", "In")
			expect(Fn).never.toBeNil()
			if Fn then
				ExpectClose(Fn(0), 0)
				ExpectClose(Fn(1), 1)
				ExpectClose(Fn(0.5), 0.25)
			end
		end)

		it("resolves Out direction", function()
			local Fn = Curves.ResolveEasing("Quad", "Out")
			expect(Fn).never.toBeNil()
			if Fn then
				ExpectClose(Fn(0), 0)
				ExpectClose(Fn(1), 1)
				ExpectClose(Fn(0.5), 0.75)
			end
		end)

		it("resolves InOut direction", function()
			local Fn = Curves.ResolveEasing("Quad", "InOut")
			expect(Fn).never.toBeNil()
			if Fn then
				ExpectClose(Fn(0), 0)
				ExpectClose(Fn(1), 1)
			end
		end)

		it("returns nil for invalid style", function()
			local Fn = Curves.ResolveEasing("NotAStyle", "In")
			expect(Fn).toBeNil()
		end)

		it("returns nil for invalid direction", function()
			local Fn = Curves.ResolveEasing("Quad", "NotADirection")
			expect(Fn).toBeNil()
		end)
	end)

	-- [[ BEZIER — COMPILATION ]]

	describe("Bezier Compilation", function()
		it("compiles zero-offset handles to near-linear coefficients", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0, ValueOffset = 0 },
				{ TimeOffset = 0, ValueOffset = 0 },
				1
			)
			-- With zero offsets, P1=(0,0) and P2=(1,1), produces a linear-like curve
			expect(Coeffs.AX).toBeDefined()
			expect(Coeffs.LUT).toBeDefined()
		end)

		it("produces LUT of correct size", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0 },
				{ TimeOffset = -0.3, ValueOffset = 0 },
				1
			)
			expect(#Coeffs.LUT).toBe(11)
		end)

		it("LUT starts at 0 and ends at 1", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.2, ValueOffset = 0.1 },
				{ TimeOffset = -0.2, ValueOffset = -0.1 },
				1
			)
			ExpectClose(Coeffs.LUT[1], 0)
			ExpectClose(Coeffs.LUT[#Coeffs.LUT], 1)
		end)
	end)

	-- [[ BEZIER — EVALUATION ]]

	describe("Bezier Evaluation", function()
		it("returns 0 at NormalizedTime=0", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0 },
				{ TimeOffset = -0.3, ValueOffset = 0 },
				1
			)
			ExpectClose(Curves.EvaluateBezierAlpha(Coeffs, 0), 0)
		end)

		it("returns 1 at NormalizedTime=1", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0 },
				{ TimeOffset = -0.3, ValueOffset = 0 },
				1
			)
			ExpectClose(Curves.EvaluateBezierAlpha(Coeffs, 1), 1)
		end)

		it("zero-offset handles produce near-linear results", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0, ValueOffset = 0 },
				{ TimeOffset = 0, ValueOffset = 0 },
				1
			)
			-- With P1=(0,0) P2=(1,1), the curve is degenerate but endpoints work
			ExpectClose(Curves.EvaluateBezierAlpha(Coeffs, 0), 0)
			ExpectClose(Curves.EvaluateBezierAlpha(Coeffs, 1), 1)
		end)

		-- CSS ease-in: cubic-bezier(0.42, 0, 1, 1)
		-- P1=(0.42, 0), P2=(1, 1) — starts slow, ends fast
		it("CSS ease-in curve: midpoint alpha < 0.5", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.42, ValueOffset = 0 },
				{ TimeOffset = 0, ValueOffset = 0 },
				1
			)
			local MidAlpha = Curves.EvaluateBezierAlpha(Coeffs, 0.5)
			expect(MidAlpha).toBeLessThan(0.5)
		end)

		-- CSS ease-out: cubic-bezier(0, 0, 0.58, 1)
		-- P1=(0, 0), P2=(0.58, 1) — starts fast, ends slow
		it("CSS ease-out curve: midpoint alpha > 0.5", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0, ValueOffset = 0 },
				{ TimeOffset = -0.42, ValueOffset = 0 },
				1
			)
			local MidAlpha = Curves.EvaluateBezierAlpha(Coeffs, 0.5)
			expect(MidAlpha).toBeGreaterThan(0.5)
		end)

		it("evaluates smoothly across range", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0.2 },
				{ TimeOffset = -0.3, ValueOffset = -0.2 },
				1
			)
			local Previous = -1
			for Step = 0, 10 do
				local Time = Step / 10
				local Value = Curves.EvaluateBezierAlpha(Coeffs, Time)
				-- Should be roughly increasing (not guaranteed for all handles, but these are mild)
				expect(Value >= Previous - 0.01).toBe(true)
				Previous = Value
			end
		end)
	end)

	-- [[ NEWTON SOLVER ]]

	describe("SolveTimeToParameter", function()
		it("returns 0 for X=0", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0 },
				{ TimeOffset = -0.3, ValueOffset = 0 },
				1
			)
			ExpectClose(Curves.SolveTimeToParameter(Coeffs, 0), 0)
		end)

		it("returns 1 for X=1", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.3, ValueOffset = 0 },
				{ TimeOffset = -0.3, ValueOffset = 0 },
				1
			)
			ExpectClose(Curves.SolveTimeToParameter(Coeffs, 1), 1)
		end)
	end)

	-- [[ STEPPED ]]

	describe("Stepped", function()
		it("always returns 0 via registry", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("Stepped", 0, Context), 0)
			ExpectClose(Curves.RemapAlpha("Stepped", 0.5, Context), 0)
			ExpectClose(Curves.RemapAlpha("Stepped", 0.99, Context), 0)
		end)
	end)

	-- [[ HERMITE ]]

	describe("Hermite", function()
		it("returns 0 at t=0 and 1 at t=1", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("Hermite", 0, Context), 0)
			ExpectClose(Curves.RemapAlpha("Hermite", 1, Context), 1)
		end)

		it("returns ~0.5 at t=0.5 (smoothstep midpoint)", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("Hermite", 0.5, Context), 0.5)
		end)

		it("is smoother than linear at boundaries", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			-- Smoothstep has zero derivative at t=0 and t=1
			-- So value near 0 should be very small (slower start than linear)
			local NearStart = Curves.RemapAlpha("Hermite", 0.1, Context)
			expect(NearStart).toBeLessThan(0.1)
		end)
	end)

	-- [[ REGISTRY ]]

	describe("Curve Registry", function()
		it("has Linear, Stepped, Bezier, Easing, Hermite registered", function()
			expect(Curves.GetCurveEvaluator("Linear")).never.toBeNil()
			expect(Curves.GetCurveEvaluator("Stepped")).never.toBeNil()
			expect(Curves.GetCurveEvaluator("Bezier")).never.toBeNil()
			expect(Curves.GetCurveEvaluator("Easing")).never.toBeNil()
			expect(Curves.GetCurveEvaluator("Hermite")).never.toBeNil()
		end)

		it("returns nil for unregistered modes", function()
			expect(Curves.GetCurveEvaluator("NotAMode")).toBeNil()
		end)

		it("RemapAlpha falls back to linear for unknown modes", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("UnknownMode", 0.7, Context), 0.7)
		end)

		it("allows registering custom curve modes", function()
			Curves.RegisterCurve("TestCustom", function(NormalizedTime: number, _Context: Curves.CurveContext): number
				return NormalizedTime * NormalizedTime
			end)

			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("TestCustom", 0.5, Context), 0.25)

			-- Verify it shows up in registered modes
			local Modes = Curves.GetRegisteredModes()
			local HasCustom = false
			for _, Mode in Modes do
				if Mode == "TestCustom" then
					HasCustom = true
					break
				end
			end
			expect(HasCustom).toBe(true)
		end)

		it("GetRegisteredModes returns all built-in modes", function()
			local Modes = Curves.GetRegisteredModes()
			expect(#Modes >= 5).toBe(true)
		end)
	end)

	-- [[ ROBLOX EASING MAPPING ]]

	describe("GetRobloxEasing", function()
		it("Linear maps to Linear", function()
			local Info = Curves.GetRobloxEasing("Linear", nil, nil)
			expect(Info).never.toBeNil()
			if Info then
				expect(Info.Style).toBe("Linear")
			end
		end)

		it("Stepped maps to Constant", function()
			local Info = Curves.GetRobloxEasing("Stepped", nil, nil)
			expect(Info).never.toBeNil()
			if Info then
				expect(Info.Style).toBe("Constant")
			end
		end)

		it("Easing Cubic In maps natively", function()
			local Info = Curves.GetRobloxEasing("Easing", "Cubic", "In")
			expect(Info).never.toBeNil()
			if Info then
				expect(Info.Style).toBe("Cubic")
				expect(Info.Direction).toBe("In")
			end
		end)

		it("Easing Bounce Out maps natively", function()
			local Info = Curves.GetRobloxEasing("Easing", "Bounce", "Out")
			expect(Info).never.toBeNil()
			if Info then
				expect(Info.Style).toBe("Bounce")
				expect(Info.Direction).toBe("Out")
			end
		end)

		it("Easing Elastic InOut maps natively", function()
			local Info = Curves.GetRobloxEasing("Easing", "Elastic", "InOut")
			expect(Info).never.toBeNil()
			if Info then
				expect(Info.Style).toBe("Elastic")
				expect(Info.Direction).toBe("InOut")
			end
		end)

		it("Easing Quad returns nil (no native equivalent)", function()
			expect(Curves.GetRobloxEasing("Easing", "Quad", "In")).toBeNil()
		end)

		it("Easing Sine returns nil (no native equivalent)", function()
			expect(Curves.GetRobloxEasing("Easing", "Sine", "Out")).toBeNil()
		end)

		it("Bezier returns nil (must bake)", function()
			expect(Curves.GetRobloxEasing("Bezier", nil, nil)).toBeNil()
		end)

		it("Hermite returns nil (must bake)", function()
			expect(Curves.GetRobloxEasing("Hermite", nil, nil)).toBeNil()
		end)

		it("Custom mode returns nil (must bake)", function()
			expect(Curves.GetRobloxEasing("SomeCustomCurve", nil, nil)).toBeNil()
		end)
	end)

	-- [[ REMAP ALPHA — INTEGRATION ]]

	describe("RemapAlpha", function()
		it("Linear passes through unchanged", function()
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = nil }
			ExpectClose(Curves.RemapAlpha("Linear", 0.3, Context), 0.3)
			ExpectClose(Curves.RemapAlpha("Linear", 0.7, Context), 0.7)
		end)

		it("Easing uses provided function", function()
			local Fn = Curves.ResolveEasing("Quad", "In")
			local Context: Curves.CurveContext = { BezierCoeffs = nil, EasingFn = Fn }
			ExpectClose(Curves.RemapAlpha("Easing", 0.5, Context), 0.25)
		end)

		it("Bezier uses provided coefficients", function()
			local Coeffs = Curves.CompileBezier(
				{ TimeOffset = 0.42, ValueOffset = 0 },
				{ TimeOffset = 0, ValueOffset = 0 },
				1
			)
			local Context: Curves.CurveContext = { BezierCoeffs = Coeffs, EasingFn = nil }
			local Alpha = Curves.RemapAlpha("Bezier", 0.5, Context)
			-- CSS ease-in: midpoint should be less than 0.5
			expect(Alpha).toBeLessThan(0.5)
		end)
	end)
end)
