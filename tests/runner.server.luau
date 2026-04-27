--!strict
--[[
	Jest test runner for luna-runtime. Mirrors the luna-animator pattern.

	Build + run:
		rojo build test.project.json -o test.rbxl
		run-in-roblox --place test.rbxl --script tests/runner.server.luau
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Luna = ReplicatedStorage:WaitForChild("Luna", 10)
local Tests = ReplicatedStorage:WaitForChild("Tests", 10)
if not Luna or not Tests then
	-- selene: allow(global_usage)
	warn("Luna or Tests not found in ReplicatedStorage after 10s")
	return
end

local Jest = require(Luna.Packages.jest)
local RunCLI = Jest.runCLI

local IsProcessServiceAvailable, ProcessService = pcall(function()
	return game:GetService("ProcessService")
end)

local Status, Result = RunCLI(Tests, {
	verbose = false,
	ci = false,
}, { Tests }):awaitStatus()

if Status == "Rejected" then
	-- selene: allow(global_usage)
	print(Result)
end

local Passed = Status == "Resolved"
	and Result.results.numFailedTestSuites == 0
	and Result.results.numFailedTests == 0

if IsProcessServiceAvailable then
	(ProcessService :: any):ExitAsync(if Passed then 0 else 1)
end

return nil
