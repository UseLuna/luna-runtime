--!strict
local RunService = game:GetService("RunService")

-- Types
export type LogLevel = "DEBUG" | "INFO" | "WARN" | "ERROR"

export type LoggerProperties = {
	Enabled: boolean,
}

-- We define the class shape separately to allow strict typing on the metatable
type LoggerClass = {
	__index: LoggerClass,
	new: () -> Logger,
	SetGlobalLogLevel: (level: LogLevel) -> (),
	GetGlobalLogLevel: () -> LogLevel,
	Instance: Logger,

	SetEnabled: (self: Logger, enabled: boolean) -> (),
	IsEnabled: (self: Logger) -> boolean,
	Log: (self: Logger, level: LogLevel, ...any) -> (),

	Debug: (self: any, ...any) -> (),
	Info: (self: any, ...any) -> (),
	Warn: (self: any, ...any) -> (),
	Error: (self: any, ...any) -> (),
}

export type Logger = typeof(setmetatable({} :: LoggerProperties, {} :: LoggerClass))

local LogLevels = {
	DEBUG = 1,
	INFO = 2,
	WARN = 3,
	ERROR = 4,
}

local CurrentLogLevel = LogLevels.DEBUG

-- Helper Functions

local function GetContext(): string
	if RunService:IsServer() then
		return "Server"
	elseif RunService:IsClient() then
		return "Client"
	else
		return "Unknown"
	end
end

local function GetCallerInfo(): (string, number)
	local Trace = debug.traceback()
	local TraceLines = Trace:split("\n")
	local LastTrace = ""

	for i = 1, #TraceLines do
		local CurrentTrace = TraceLines[i]
		-- Filter out internal Logger calls
		if CurrentTrace:match("Logger") or CurrentTrace:match("logger") then
			LastTrace = CurrentTrace
			continue
		end

		-- Find the first frame that isn't the Logger
		if LastTrace:match("Logger") and not CurrentTrace:match("Logger") then
			local Extracted = CurrentTrace:split(" ")
			local SourceAndLine = Extracted[1]
			local FunctionData = Extracted[3]

			local ScriptName = "Unknown"
			local LineNumber = 0

			if SourceAndLine then
				local Extracted2 = SourceAndLine:split(":")
				if #Extracted2 >= 2 then
					local PathFragments = Extracted2[1]:split(".")
					ScriptName = PathFragments[#PathFragments] or "Unknown"
					LineNumber = tonumber(Extracted2[2]) or 0
				end
			end

			if FunctionData and ScriptName ~= "Unknown" then
				ScriptName = `{ScriptName}, function {FunctionData}`
			end

			return ScriptName, LineNumber
		end
	end

	return "Unknown", 0
end

local function FormatMessage(Context: string, FileName: string, LineNumber: number, LogLevel: LogLevel): string
	return string.format("[LUNA] [%s] [%s, line %d] [%s]:", Context, FileName, LineNumber, LogLevel)
end

local function OutputLog(LogLevel: LogLevel, ...)
	-- Convert all arguments to string to prevent table.concat errors
	local Arguments = { ... }
	for i, v in ipairs(Arguments) do
		Arguments[i] = tostring(v)
	end

	if LogLevel == "ERROR" then
		local FormattedMessage = table.concat(Arguments, " ")
		error(FormattedMessage, 0)
	elseif LogLevel == "WARN" then
		warn(table.unpack(Arguments))
	else
		print(table.unpack(Arguments))
	end
end
local function ShouldLog(Level: LogLevel): boolean
	return LogLevels[Level] >= CurrentLogLevel
end

-- Class Definition
local Logger = {} :: LoggerClass
Logger.__index = Logger

-- Create a new logger instance
function Logger.new(): Logger
	local self = {} :: LoggerProperties
	self.Enabled = true

	return setmetatable(self, Logger)
end

-- Set global log level filter
function Logger.SetGlobalLogLevel(level: LogLevel)
	if LogLevels[level] then
		CurrentLogLevel = LogLevels[level]
	else
		warn("Invalid log level: " .. tostring(level))
	end
end

-- Get current log level
function Logger.GetGlobalLogLevel(): LogLevel
	for level, value in pairs(LogLevels) do
		if value == CurrentLogLevel then
			return level :: LogLevel
		end
	end
	return "DEBUG"
end

-- Enable/disable this logger instance
function Logger.SetEnabled(self: Logger, Enabled: boolean)
	self.Enabled = Enabled
end

-- Check if this logger instance is enabled
function Logger.IsEnabled(self: Logger): boolean
	return self.Enabled
end

-- Core logging method
function Logger.Log(self: Logger, Level: LogLevel, ...)
	if not self.Enabled or not ShouldLog(Level) then
		return
	end

	local Context = GetContext()
	local FileName, LineNumber = GetCallerInfo()
	local LogMessage = FormatMessage(Context, FileName, LineNumber, Level)

	OutputLog(Level, LogMessage, ...)
end

-- Internal helper to distinguish between Instance calls (logger:Debug) and Static calls (Logger.Debug)
local function DistributeLogCall(Method: string, SelfOrMessage: any, ...: any)
	-- Check if SelfOrMessage is actually a Logger instance
	local IsInstance = type(SelfOrMessage) == "table" and getmetatable(SelfOrMessage) == Logger

	if IsInstance then
		-- Called as logger:Debug(...)
		local self = SelfOrMessage :: Logger
		self:Log(Method :: LogLevel, ...)
	else
		-- Called as Logger.Debug(...) -> selfOrMsg is the first argument (message)
		-- Use the default static instance
		Logger.Instance:Log(Method :: LogLevel, SelfOrMessage, ...)
	end
end

-- Convenience methods (Hybrid: Static or Instance)

function Logger.Debug(self: any, ...)
	DistributeLogCall("DEBUG", self, ...)
end

function Logger.Info(self: any, ...)
	DistributeLogCall("INFO", self, ...)
end

function Logger.Warn(self: any, ...)
	DistributeLogCall("WARN", self, ...)
end

function Logger.Error(self: any, ...)
	DistributeLogCall("ERROR", self, ...)
end

-- Define the Singleton Instance
Logger.Instance = Logger.new()

return Logger
