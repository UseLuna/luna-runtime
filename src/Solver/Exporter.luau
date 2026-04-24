--!strict
local Luna = script.Parent.Parent

local CoreTypes = require(Luna.Types.CoreTypes)
local ExportTypes = require(Luna.Types.ExportTypes)
local ExportPipeline = require(Luna.Core.ExportPipeline)
local AnimationData = require(Luna.Core.AnimationData)
local Logger = require(Luna.Shared.Logger)

type Array<V> = CoreTypes.Array<V>
type StringIndexable<V> = CoreTypes.StringIndexable<V>
type JointInput = CoreTypes.JointInput
type ExportAdapter = ExportTypes.ExportAdapter
type ExportSnapshot = ExportTypes.ExportSnapshot
type EditAnimation = AnimationData.EditAnimation

local Exporter = {}

local __Adapters: StringIndexable<ExportAdapter> = {}

-- Register a new export adapter. Adapters can be built-in or user-provided.
function Exporter.RegisterAdapter(Adapter: ExportAdapter)
	if __Adapters[Adapter.Name] then
		Logger.Warn(`Export adapter "{Adapter.Name}" is being overwritten`)
	end
	__Adapters[Adapter.Name] = Adapter
	Logger.Info(`Registered export adapter: "{Adapter.Name}"`)
end

-- Export a pre-built snapshot using a named adapter.
function Exporter.Export(AdapterName: string, Snapshot: ExportSnapshot): any
	local Adapter = __Adapters[AdapterName]
	if not Adapter then
		Logger.Error(`No export adapter registered with name "{AdapterName}"`)
		return nil
	end
	return Adapter.Export(Snapshot)
end

-- Get all registered adapter names.
function Exporter.GetAdapterNames(): Array<string>
	local Names: Array<string> = {}
	for Name, _ in __Adapters do
		table.insert(Names, Name)
	end
	return Names
end

-- Convenience: run the full pipeline (snapshot creation + export) in one call.
-- Uses the original non-baked pipeline (samples only at keyframe times, no easing metadata).
function Exporter.ExportAnimation(AdapterName: string, Animation: EditAnimation, Joints: Array<JointInput>): any
	local Snapshot = ExportPipeline.CreateSnapshot(Animation, Joints)
	return Exporter.Export(AdapterName, Snapshot)
end

-- Convenience: run the baked pipeline (curve-aware sampling + easing metadata) in one call.
-- Non-native curves are baked at TargetFPS (defaults to Animation.FrameRate).
-- Use this for KeyframeSequence export to preserve curve fidelity.
function Exporter.ExportAnimationBaked(
	AdapterName: string,
	Animation: EditAnimation,
	Joints: Array<JointInput>,
	TargetFPS: number?
): any
	local Snapshot = ExportPipeline.CreateBakedSnapshot(Animation, Joints, TargetFPS)
	return Exporter.Export(AdapterName, Snapshot)
end

-- Clear all registered adapters. Call on plugin unload to prevent stale state across reloads.
function Exporter.Reset()
	table.clear(__Adapters)
end

-- Auto-register built-in adapters
local KeyframeSequenceCodec = require(script.Parent.Adapters.KeyframeSequenceCodec)
Exporter.RegisterAdapter(KeyframeSequenceCodec.ExportAdapter)

export type Exporter = typeof(Exporter)

return Exporter
