--!strict
local CoreTypes = require(script.Parent.Parent.Types.CoreTypes)
local ModifierTypes = require(script.Parent.Parent.Types.ModifierTypes)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type ModifierFactory = ModifierTypes.ModifierFactory
type ModifierInstance = ModifierTypes.ModifierInstance

local ModifierRegistry = {}

local __Registry: StringIndexable<ModifierFactory> = {}

-- Register a modifier factory. Third parties can add custom modifiers.
function ModifierRegistry.Register(Type: string, Factory: ModifierFactory)
	__Registry[Type] = Factory
end

-- Create a modifier instance from a registered type and config.
-- Returns nil if the type is not registered.
function ModifierRegistry.Create(Type: string, Config: StringIndexable<any>): ModifierInstance?
	local Factory = __Registry[Type]
	if not Factory then
		return nil
	end
	return Factory.Create(Config)
end

-- Get the factory for a registered type, or nil.
function ModifierRegistry.GetFactory(Type: string): ModifierFactory?
	return __Registry[Type]
end

-- List all registered modifier type names.
function ModifierRegistry.GetRegisteredTypes(): Array<string>
	local Types: Array<string> = {}
	for Type in __Registry do
		table.insert(Types, Type)
	end
	return Types
end

export type ModifierRegistry = typeof(ModifierRegistry)

return ModifierRegistry
