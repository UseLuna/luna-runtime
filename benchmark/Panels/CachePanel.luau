--!strict

--[[
	CachePanel — Displays RigResolver skeleton cache diagnostics.

	Shows unique fingerprint count, per-fingerprint breakdown, ref counts,
	bone counts, and an estimate of memory saved by sharing skeleton data.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local Benchmark = ReplicatedStorage:WaitForChild("Benchmark")

local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local RigResolver = require(LunaRuntime.Solver.RigResolver)

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local BYTES_PER_BONE = 200

-- ============================================================================
-- [[ PANEL ]]
-- ============================================================================

local CachePanel = {}

CachePanel.Name = "Cache"

function CachePanel.Render(Iris: any, _State: any)
	local Stats = RigResolver.GetCacheStats()
	local Entries = Stats.Entries
	local UniqueCount = Stats.UniqueFingerprints

	-- ── Summary ─────────────────────────────────────────────────────────────

	Iris.Text({ `Unique Fingerprints: {UniqueCount}` })

	if UniqueCount == 0 then
		Iris.Text({ "No skeletons cached", false, BenchmarkConstants.COLOR_GRAY })
		return
	end

	-- ── Memory savings estimate ──────────────────────────────────────────────

	-- Total bytes if every ref stored its own copy vs sharing
	local TotalRefs = 0
	local TotalBytesUnshared = 0
	local TotalBytesShared = 0

	for _, Entry in Entries do
		local BoneBytes = Entry.BoneCount * BYTES_PER_BONE
		TotalRefs += Entry.RefCount
		TotalBytesUnshared += BoneBytes * Entry.RefCount
		TotalBytesShared += BoneBytes
	end

	local SavingsBytes = TotalBytesUnshared - TotalBytesShared
	local SavingsKb = SavingsBytes / 1024

	Iris.Text({ `Total Refs: {TotalRefs}` })
	Iris.Text({ `Est. Memory Saved: {string.format("%.1f", SavingsKb)} KB`, false, BenchmarkConstants.COLOR_GREEN })

	-- ── Per-fingerprint breakdown ────────────────────────────────────────────

	local Tree = Iris.Tree({ "Per-Fingerprint Breakdown", false, false, false })
	if Tree.state.isUncollapsed:get() then
		for _, Entry in Entries do
			Iris.SameLine()
			Iris.Text({ Entry.Fingerprint, false, BenchmarkConstants.COLOR_CYAN })
			Iris.Text({ `  Bones: {Entry.BoneCount}` })
			Iris.Text({ `  Refs: {Entry.RefCount}` })
			Iris.End()
		end
	end
	Iris.End()
end

return CachePanel
