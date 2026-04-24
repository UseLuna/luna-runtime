--!strict
--!optimize 2
--!native
--[[
	High-performance signal (pub/sub) utility.
	Doubly-linked list for O(1) connect/disconnect.
	Thread reuse to avoid allocations on Fire.
	Based on a proven production signal implementation.

	Lives in Shared/ so both Runtime (Solver) and Editor can use it
	without upward dependency violations.
]]

local FreeThread: thread? = nil

local function __DeletedSignalError()
	error("Cannot use a destroyed signal", 2)
end

local __ErrorTable = {
	__index = function()
		return __DeletedSignalError()
	end,
	__newindex = function()
		return __DeletedSignalError()
	end,
}

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: any) -> (),

	_Callback: (...any) -> (),
	_Next: any,
	_Prev: any,
	_Signal: any,
}

export type self = {
	_Head: Connection?,
	_Tail: Connection?,
}

export type Signal<T...> = typeof(setmetatable({} :: self, Signal))

-- Thread reuse optimization (supports up to 8 parameters without allocating memory)
local function __YieldLoop()
	while true do
		local CurrentConnection: Connection?, A, B, C, D, E, F, G, H = coroutine.yield()
		local RestoredThread = FreeThread
		FreeThread = nil

		while CurrentConnection do
			-- Capture next node BEFORE executing callback, in case the callback disconnects this node
			local NextConnection = CurrentConnection._Next

			if CurrentConnection.Connected then
				CurrentConnection._Callback(A, B, C, D, E, F, G, H)
			end

			CurrentConnection = NextConnection
		end

		FreeThread = RestoredThread
	end
end

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({
		_Head = nil,
		_Tail = nil,
	}, Signal)

	return (self :: any) :: Signal<T...>
end

function Signal.Connect<T...>(self: Signal<T...>, Callback: (T...) -> ()): Connection
	local ConnectionObject = {} :: Connection
	ConnectionObject.Connected = true
	ConnectionObject._Callback = Callback :: any
	ConnectionObject._Next = nil
	ConnectionObject._Prev = self._Tail
	ConnectionObject._Signal = self :: any

	if self._Tail then
		self._Tail._Next = ConnectionObject
	else
		self._Head = ConnectionObject
	end
	self._Tail = ConnectionObject

	function ConnectionObject.Disconnect(SelfConnection: Connection)
		if not SelfConnection.Connected then
			return
		end
		SelfConnection.Connected = false

		-- Drop callback reference immediately so captured memory can be GC'd
		SelfConnection._Callback = nil :: any

		local ParentSignal = SelfConnection._Signal
		if not ParentSignal then
			return
		end

		-- O(1) extraction from doubly-linked list
		if SelfConnection._Next then
			SelfConnection._Next._Prev = SelfConnection._Prev
		else
			ParentSignal._Tail = SelfConnection._Prev
		end

		if SelfConnection._Prev then
			SelfConnection._Prev._Next = SelfConnection._Next
		else
			ParentSignal._Head = SelfConnection._Next
		end

		-- Leave _Next intact so any active firing loop can continue down the chain
		SelfConnection._Prev = nil
		SelfConnection._Signal = nil
	end

	return ConnectionObject
end

function Signal.Once<T...>(self: Signal<T...>, Callback: (T...) -> ()): Connection
	local ConnectionObject: Connection

	ConnectionObject = Signal.Connect(self, function(...)
		if ConnectionObject then
			ConnectionObject.Disconnect(ConnectionObject)
		end
		Callback(...)
	end)

	return ConnectionObject
end

function Signal.Fire<T...>(self: Signal<T...>, ...: T...)
	local Head = self._Head
	if not Head then
		return
	end

	-- Guard against stale thread from module cache surviving plugin reload
	if FreeThread and coroutine.status(FreeThread) == "dead" then
		FreeThread = nil
	end
	if not FreeThread then
		FreeThread = task.spawn(__YieldLoop)
	end

	task.spawn(FreeThread :: thread, Head, ...)
end

function Signal.Wait<T...>(self: Signal<T...>): T...
	local Thread = coroutine.running()

	Signal.Once(self, function(...)
		assert(
			coroutine.status(Thread) == "suspended",
			":Wait() called, then another thread resumed the waiting thread"
		)
		task.spawn(Thread, ...)
	end)

	return coroutine.yield()
end

function Signal.DisconnectAll<T...>(self: Signal<T...>)
	local Current = self._Head

	while Current do
		Current.Connected = false
		Current._Callback = nil :: any
		Current._Signal = nil
		Current._Prev = nil
		Current = Current._Next
	end

	self._Head = nil
	self._Tail = nil
end

function Signal.Destroy<T...>(self: Signal<T...>)
	Signal.DisconnectAll(self)
	setmetatable(self :: any, __ErrorTable)
end

return Signal
