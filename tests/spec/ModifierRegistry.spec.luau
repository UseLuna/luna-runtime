--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.Luna.Packages.jest_globals)
local describe = JestGlobals.describe
local it = JestGlobals.it
local expect = JestGlobals.expect

local ModifierRegistry = require(ReplicatedStorage.Luna.Core.ModifierRegistry)

describe("ModifierRegistry", function()
	it("registers and creates a modifier", function()
		ModifierRegistry.Register("TestNoise", {
			Create = function(Config)
				return {
					Type = "TestNoise",
					Order = 0,
					Weight = 1,
					IsEnabled = true,
					Config = Config,
					State = nil,
				}
			end,
		})

		local Instance = ModifierRegistry.Create("TestNoise", { Amplitude = 5 })
		expect(Instance).never.toBeNil()
		if Instance then
			expect(Instance.Type).toBe("TestNoise")
			expect(Instance.Config.Amplitude).toBe(5)
		end
	end)

	it("returns nil for unregistered type", function()
		local Instance = ModifierRegistry.Create("NonExistent", {})
		expect(Instance).toBeNil()
	end)

	it("GetFactory returns factory for registered type", function()
		ModifierRegistry.Register("TestSpring", {
			Create = function(Config)
				return {
					Type = "TestSpring",
					Order = 0,
					Weight = 1,
					IsEnabled = true,
					Config = Config,
					State = { Velocity = 0 },
				}
			end,
		})

		expect(ModifierRegistry.GetFactory("TestSpring")).never.toBeNil()
		expect(ModifierRegistry.GetFactory("NonExistent")).toBeNil()
	end)

	it("GetRegisteredTypes lists registered types", function()
		local Types = ModifierRegistry.GetRegisteredTypes()
		expect(#Types >= 2).toBe(true)
	end)

	it("stateful modifier has non-nil State", function()
		local Instance = ModifierRegistry.Create("TestSpring", { Stiffness = 100 })
		expect(Instance).never.toBeNil()
		if Instance then
			expect(Instance.State).never.toBeNil()
		end
	end)
end)
