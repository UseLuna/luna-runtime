--!strict
local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local ImportTypes = require(Luna.Types.ImportTypes)
local AnimationData = require(Luna.Core.AnimationData)
local Logger = require(Luna.Shared.Logger)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type ImportAdapter = ImportTypes.ImportAdapter
type EditAnimation = AnimationData.EditAnimation

local Importer = {}

local __Adapters: StringIndexable<ImportAdapter> = {}

-- Register a new import adapter. Adapters can be built-in or user-provided.
function Importer.RegisterAdapter(Adapter: ImportAdapter)
	if __Adapters[Adapter.Name] then
		Logger.Warn(`Import adapter "{Adapter.Name}" is being overwritten`)
	end
	__Adapters[Adapter.Name] = Adapter
	Logger.Info(`Registered import adapter: "{Adapter.Name}"`)
end

-- Import from a source using a named adapter.
function Importer.Import(AdapterName: string, Source: any): EditAnimation?
	local Adapter = __Adapters[AdapterName]
	if not Adapter then
		Logger.Error(`No import adapter registered with name "{AdapterName}"`)
		return nil :: any -- dead code: Logger.Error throws, but Luau needs a return path
	end
	return Adapter.Import(Source) :: EditAnimation
end

-- Get all registered adapter names.
function Importer.GetAdapterNames(): Array<string>
	local Names: Array<string> = {}
	for Name, _ in __Adapters do
		table.insert(Names, Name)
	end
	return Names
end

-- Clear all registered adapters. Call on plugin unload to prevent stale state across reloads.
function Importer.Reset()
	table.clear(__Adapters)
end

-- Auto-register built-in adapters
local KeyframeSequenceCodec = require(script.Parent.Adapters.KeyframeSequenceCodec)
Importer.RegisterAdapter(KeyframeSequenceCodec.ImportAdapter)

local LunaFileCodec = require(script.Parent.Adapters.LunaFileCodec)
Importer.RegisterAdapter(LunaFileCodec.ImportAdapter)

export type Importer = typeof(Importer)

return Importer
