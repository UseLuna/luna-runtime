--!strict

--[[
	BaselineStore — Serialize/deserialize baseline snapshots to a Configuration
	instance in ReplicatedStorage.

	Storage layout:
	  ReplicatedStorage
	    └─ BenchmarkBaseline  (Configuration)
	         └─ Data          (StringValue, JSON-encoded BaselineSnapshot)

	API:
	  BaselineStore.Save(Results, Note)   — write a new baseline
	  BaselineStore.Load()                — read and decode the stored baseline
	  BaselineStore.Clear()               — destroy the Configuration instance
	  BaselineStore.Export()              — return the raw JSON string
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

local LunaRuntime = ReplicatedStorage:WaitForChild("LunaRuntime")
local Logger = require(LunaRuntime.Shared.Logger)

-- ── Types ────────────────────────────────────────────────────────────────────

type SuiteResult = BenchmarkTypes.SuiteResult
type BaselineSnapshot = BenchmarkTypes.BaselineSnapshot

-- ── Constants ────────────────────────────────────────────────────────────────

local CONTAINER_NAME = "BenchmarkBaseline"
local DATA_VALUE_NAME = "Data"

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function GetContainer(): Configuration?
	return ReplicatedStorage:FindFirstChild(CONTAINER_NAME) :: Configuration?
end

local function GetOrCreateContainer(): Configuration
	local Existing = GetContainer()
	if Existing then
		return Existing
	end

	local Container = Instance.new("Configuration")
	Container.Name = CONTAINER_NAME
	Container.Parent = ReplicatedStorage
	return Container
end

local function GetDataValue(Container: Configuration): StringValue?
	return Container:FindFirstChild(DATA_VALUE_NAME) :: StringValue?
end

local function GetOrCreateDataValue(Container: Configuration): StringValue
	local Existing = GetDataValue(Container)
	if Existing then
		return Existing
	end

	local DataValue = Instance.new("StringValue")
	DataValue.Name = DATA_VALUE_NAME
	DataValue.Parent = Container
	return DataValue
end

-- ── Module ───────────────────────────────────────────────────────────────────

local BaselineStore = {}

--[[
	Save — serialize {Results, Note, Timestamp} to JSON and store in the
	Configuration. Creates or replaces the existing container.
]]
function BaselineStore.Save(Results: { SuiteResult }, Note: string)
	local Snapshot: BaselineSnapshot = {
		Results = Results,
		Note = Note,
		Timestamp = os.date("%Y-%m-%d %H:%M:%S") :: string,
	}

	local IsOk, EncodedOrErr = pcall(function()
		return HttpService:JSONEncode(Snapshot)
	end)

	if not IsOk then
		Logger.Error(`BaselineStore.Save: JSON encode failed — {tostring(EncodedOrErr)}`)
		return
	end

	local Encoded = EncodedOrErr :: string

	local Container = GetOrCreateContainer()

	-- Clear any existing Data value before writing so we start fresh.
	local OldData = GetDataValue(Container)
	if OldData then
		OldData:Destroy()
	end

	local DataValue = GetOrCreateDataValue(Container)
	DataValue.Value = Encoded

	Logger.Info(`BaselineStore.Save: baseline saved ({#Results} suite result(s), timestamp {Snapshot.Timestamp})`)
end

--[[
	Load — find the Configuration, decode JSON, and return (BaselineSnapshot?, errorMessage?).
	Returns nil + error string on failure.
]]
function BaselineStore.Load(): (BaselineSnapshot?, string?)
	local Container = GetContainer()
	if not Container then
		return nil, "No baseline found (BenchmarkBaseline does not exist in ReplicatedStorage)"
	end

	local DataValue = GetDataValue(Container)
	if not DataValue then
		return nil, `No Data StringValue inside {CONTAINER_NAME}`
	end

	local Raw = DataValue.Value
	if Raw == "" then
		return nil, "Baseline Data value is empty"
	end

	local IsOk, DecodedOrErr = pcall(function()
		return HttpService:JSONDecode(Raw)
	end)

	if not IsOk then
		local ErrMsg = `BaselineStore.Load: JSON decode failed — {tostring(DecodedOrErr)}`
		Logger.Warn(ErrMsg)
		return nil, ErrMsg
	end

	local Snapshot = DecodedOrErr :: BaselineSnapshot

	Logger.Info(`BaselineStore.Load: baseline loaded (timestamp {Snapshot.Timestamp}, note: "{Snapshot.Note}")`)
	return Snapshot, nil
end

--[[
	Clear — destroy the BenchmarkBaseline Configuration instance entirely.
]]
function BaselineStore.Clear()
	local Container = GetContainer()
	if not Container then
		Logger.Info("BaselineStore.Clear: nothing to clear (BenchmarkBaseline not found)")
		return
	end

	Container:Destroy()
	Logger.Info("BaselineStore.Clear: BenchmarkBaseline removed")
end

--[[
	Export — return the raw JSON string from the Data StringValue.
	Returns an empty string if no baseline is stored.
]]
function BaselineStore.Export(): string
	local Container = GetContainer()
	if not Container then
		Logger.Warn("BaselineStore.Export: no BenchmarkBaseline found")
		return ""
	end

	local DataValue = GetDataValue(Container)
	if not DataValue then
		Logger.Warn(`BaselineStore.Export: no Data StringValue inside {CONTAINER_NAME}`)
		return ""
	end

	return DataValue.Value
end

-- ── Export ───────────────────────────────────────────────────────────────────

return BaselineStore
