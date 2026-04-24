--!strict
local CoreTypes = require(script.Parent.CoreTypes)

type StringIndexable<V> = CoreTypes.StringIndexable<V>

local ModifierTypes = {}

-- Per-track modifier (Noise, Spring, Jitter — travels with the animation)
export type ModifierEntry = {
	Type: string,
	Order: number,
	Weight: number,
	IsEnabled: boolean,
	Config: StringIndexable<any>,
}

-- Per-rig constraint (AimAt, LockPosition — bound to rig, not animation)
export type ConstraintEntry = {
	Type: string,
	BoneName: string,
	Weight: number,
	IsEnabled: boolean,
	Config: StringIndexable<any>,
}

-- Factory for creating modifier instances at runtime
export type ModifierFactory = {
	Create: (Config: StringIndexable<any>) -> ModifierInstance,
}

-- Runtime modifier instance (Phase 4 implements Apply)
export type ModifierInstance = {
	Type: string,
	Order: number,
	Weight: number,
	IsEnabled: boolean,
	Config: StringIndexable<any>,
	State: StringIndexable<any>?,
}

return ModifierTypes
