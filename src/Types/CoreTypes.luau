--!strict
export type Indexable<K, V> = { [K]: V }
export type StringIndexable<V> = Indexable<string, V>
export type Array<V> = Indexable<number, V>

export type MinMax = { Min: number, Max: number }

-- Minimal joint description shared across Core and Solver.
-- Solver's JointInfo extends this with Motor6D-specific fields.
export type JointInput = {
	Name: string,
	Part0Name: string,
	Part1Name: string,
}

return {}
