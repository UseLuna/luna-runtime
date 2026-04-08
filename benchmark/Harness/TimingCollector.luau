--!strict

--[[
	TimingCollector — Core measurement engine for the Luna benchmark harness.

	Maintains a ring buffer of FrameSample records. All samples are pre-allocated
	at construction so there are zero table allocations during hot measurement.

	Time window:
	  Frames older than WindowSeconds are excluded from snapshot calculations.
	  "Older" is determined by comparing each sample's FrameStart wall-clock time
	  against the newest sample's FrameStart, not against os.clock() at read time,
	  so the window is stable across a single GetSnapshot call.

	Warmup detection:
	  Coefficient of variation (StdDev / Mean) of total-frame-time over the last
	  WARMUP_WINDOW_FRAMES frames must stay below WARMUP_CV_THRESHOLD for at least
	  WARMUP_MIN_FRAMES samples to have been collected.
]]

local Benchmark = script.Parent.Parent
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)

-- ── Types ────────────────────────────────────────────────────────────────────

type TimingSnapshot = BenchmarkTypes.TimingSnapshot

-- Internal per-frame sample stored in the ring buffer.
type FrameSample = {
	FrameStart: number,  -- os.clock() at BeginFrame
	EvalEnd: number,     -- os.clock() at MarkEvalEnd
	FrameEnd: number,    -- os.clock() at EndFrame
	HeapKb: number,      -- gcinfo() at EndFrame (already in KB)
	IsValid: boolean,    -- true once all three marks have been recorded
}

export type TimingCollector = {
	-- Public config
	_IsEnabled: boolean,
	_WindowSeconds: number,
	_NpcCount: number,
	_TrackCount: number,
	_BoneCount: number,

	-- Ring buffer state
	_Buffer: { FrameSample },
	_WriteIndex: number,   -- next slot to write (1-based, wraps via modulo)
	_TotalFrames: number,  -- monotonically increasing; used for min-frame guard

	-- In-flight frame state (only valid between BeginFrame and EndFrame)
	_FrameStart: number,
	_EvalEnd: number,
	_IsFrameOpen: boolean,
}

-- ── Module ───────────────────────────────────────────────────────────────────

local TimingCollectorModule = {}
TimingCollectorModule.__index = TimingCollectorModule

local MAX_SIZE = BenchmarkConstants.MAX_RING_BUFFER_SIZE
local DEFAULT_WINDOW = BenchmarkConstants.DEFAULT_WINDOW_SECONDS
local CV_THRESHOLD = BenchmarkConstants.WARMUP_CV_THRESHOLD
local WARMUP_WINDOW = BenchmarkConstants.WARMUP_WINDOW_FRAMES
local WARMUP_MIN = BenchmarkConstants.WARMUP_MIN_FRAMES

-- Pre-allocate all FrameSample tables once.
local function BuildRingBuffer(): { FrameSample }
	local Buffer: { FrameSample } = table.create(MAX_SIZE)
	for Index = 1, MAX_SIZE do
		Buffer[Index] = {
			FrameStart = 0,
			EvalEnd = 0,
			FrameEnd = 0,
			HeapKb = 0,
			IsValid = false,
		}
	end
	return Buffer
end

-- ── Constructor ──────────────────────────────────────────────────────────────

function TimingCollectorModule.new(): TimingCollector
	local Self: TimingCollector = setmetatable({
		_IsEnabled = true,
		_WindowSeconds = DEFAULT_WINDOW,
		_NpcCount = 0,
		_TrackCount = 0,
		_BoneCount = 0,

		_Buffer = BuildRingBuffer(),
		_WriteIndex = 1,
		_TotalFrames = 0,

		_FrameStart = 0,
		_EvalEnd = 0,
		_IsFrameOpen = false,
	}, TimingCollectorModule) :: any

	return Self
end

-- ── Configuration ────────────────────────────────────────────────────────────

function TimingCollectorModule.SetEnabled(Self: TimingCollector, Enabled: boolean)
	Self._IsEnabled = Enabled
end

function TimingCollectorModule.SetWindow(Self: TimingCollector, Seconds: number)
	Self._WindowSeconds = Seconds
end

function TimingCollectorModule.SetCounts(Self: TimingCollector, NpcCount: number, TrackCount: number, BoneCount: number)
	Self._NpcCount = NpcCount
	Self._TrackCount = TrackCount
	Self._BoneCount = BoneCount
end

-- ── Frame Marks ──────────────────────────────────────────────────────────────

function TimingCollectorModule.BeginFrame(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end
	Self._FrameStart = os.clock()
	Self._EvalEnd = 0
	Self._IsFrameOpen = true
end

function TimingCollectorModule.MarkEvalEnd(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end
	Self._EvalEnd = os.clock()
end

function TimingCollectorModule.EndFrame(Self: TimingCollector)
	if not Self._IsEnabled then
		return
	end
	if not Self._IsFrameOpen then
		return
	end
	Self._IsFrameOpen = false

	-- Write into the current ring buffer slot (pre-allocated, no allocation here).
	local Slot = Self._Buffer[Self._WriteIndex]
	Slot.FrameStart = Self._FrameStart
	Slot.EvalEnd = Self._EvalEnd
	Slot.FrameEnd = os.clock()
	Slot.HeapKb = gcinfo()
	Slot.IsValid = true

	-- Advance write pointer (1-based wraparound).
	Self._WriteIndex = (Self._WriteIndex % MAX_SIZE) + 1
	Self._TotalFrames += 1
end

-- ── Reset ────────────────────────────────────────────────────────────────────

function TimingCollectorModule.Reset(Self: TimingCollector)
	-- Invalidate all slots without reallocating.
	local Buffer = Self._Buffer
	for Index = 1, MAX_SIZE do
		Buffer[Index].IsValid = false
	end
	Self._WriteIndex = 1
	Self._TotalFrames = 0
	Self._IsFrameOpen = false
	Self._FrameStart = 0
	Self._EvalEnd = 0
end

-- ── Snapshot ─────────────────────────────────────────────────────────────────

--[[
	Walk backwards from the most-recently-written slot to collect the active
	window. The newest slot is always at WriteIndex - 1 (with wraparound).

	We stop when we either:
	  (a) hit a sample whose FrameStart is older than WindowSeconds ago, or
	  (b) have walked all MAX_SIZE slots.

	All arithmetic is done in seconds; final values are converted to ms/us
	only when building the snapshot table.
]]
function TimingCollectorModule.GetSnapshot(Self: TimingCollector): TimingSnapshot
	local Buffer = Self._Buffer
	local WindowSeconds = Self._WindowSeconds

	-- The slot just before WriteIndex is the most recent write.
	-- If nothing has been written yet, WriteIndex == 1, so NewestSlot == MAX_SIZE (not yet valid).
	local NewestSlotIndex = ((Self._WriteIndex - 2) % MAX_SIZE) + 1
	local NewestSlot = Buffer[NewestSlotIndex]

	-- Bail early with a zeroed snapshot if no valid data yet.
	if not NewestSlot.IsValid then
		return {
			AvgEvalMs = 0, AvgApplyMs = 0, AvgTotalMs = 0,
			PeakEvalMs = 0, PeakApplyMs = 0, PeakTotalMs = 0,
			PerTrackUs = 0, PerMotorUs = 0, PerNpcUs = 0,
			EvalPercent = 0, ApplyPercent = 0,
			CurrentFps = 0, FrameCount = 0, HeapKb = 0,
		}
	end

	local WindowCutoff = NewestSlot.FrameStart - WindowSeconds

	-- Accumulators
	local SumEval = 0
	local SumApply = 0
	local SumTotal = 0
	local PeakEval = 0
	local PeakApply = 0
	local PeakTotal = 0
	local LatestHeapKb = 0
	local ActiveCount = 0

	-- Walk backwards through the ring buffer.
	for Step = 0, MAX_SIZE - 1 do
		local SlotIndex = ((NewestSlotIndex - 1 - Step) % MAX_SIZE) + 1
		local Sample = Buffer[SlotIndex]

		if not Sample.IsValid then
			break
		end
		if Sample.FrameStart < WindowCutoff then
			break
		end

		local EvalTime = Sample.EvalEnd - Sample.FrameStart
		local ApplyTime = Sample.FrameEnd - Sample.EvalEnd
		local TotalTime = Sample.FrameEnd - Sample.FrameStart

		-- EvalEnd == 0 means MarkEvalEnd was never called this frame; treat as no eval phase.
		if Sample.EvalEnd == 0 then
			EvalTime = 0
			ApplyTime = TotalTime
		end

		SumEval += EvalTime
		SumApply += ApplyTime
		SumTotal += TotalTime

		if EvalTime > PeakEval then PeakEval = EvalTime end
		if ApplyTime > PeakApply then PeakApply = ApplyTime end
		if TotalTime > PeakTotal then PeakTotal = TotalTime end

		ActiveCount += 1

		-- Grab heap from the newest sample only (most current reading).
		if Step == 0 then
			LatestHeapKb = Sample.HeapKb
		end
	end

	if ActiveCount == 0 then
		return {
			AvgEvalMs = 0, AvgApplyMs = 0, AvgTotalMs = 0,
			PeakEvalMs = 0, PeakApplyMs = 0, PeakTotalMs = 0,
			PerTrackUs = 0, PerMotorUs = 0, PerNpcUs = 0,
			EvalPercent = 0, ApplyPercent = 0,
			CurrentFps = 0, FrameCount = 0, HeapKb = 0,
		}
	end

	-- Derive window duration from oldest to newest FrameStart within the window.
	-- Find oldest sample FrameStart in our walked range.
	local OldestSlotIndex = ((NewestSlotIndex - ActiveCount) % MAX_SIZE) + 1
	local OldestSample = Buffer[OldestSlotIndex]
	local ActualWindowDuration = NewestSlot.FrameStart - OldestSample.FrameStart

	-- FPS: frames in window / elapsed time. Guard against zero-duration window.
	local CurrentFps = if ActualWindowDuration > 0 then ActiveCount / ActualWindowDuration else 0

	-- Averages (seconds → ms)
	local MS = 1000
	local US = 1_000_000
	local InvCount = 1 / ActiveCount
	local AvgEvalMs = SumEval * InvCount * MS
	local AvgApplyMs = SumApply * InvCount * MS
	local AvgTotalMs = SumTotal * InvCount * MS

	-- Per-unit costs (seconds → µs)
	local NpcCount = Self._NpcCount
	local TrackCount = Self._TrackCount
	local BoneCount = Self._BoneCount  -- treated as "motors"

	local AvgTotalSec = SumTotal * InvCount
	local PerNpcUs = if NpcCount > 0 then AvgTotalSec / NpcCount * US else 0
	local PerTrackUs = if TrackCount > 0 then AvgTotalSec / TrackCount * US else 0
	local PerMotorUs = if BoneCount > 0 then AvgTotalSec / BoneCount * US else 0

	-- Phase percentages
	local EvalPercent = if SumTotal > 0 then SumEval / SumTotal * 100 else 0
	local ApplyPercent = if SumTotal > 0 then SumApply / SumTotal * 100 else 0

	return {
		AvgEvalMs = AvgEvalMs,
		AvgApplyMs = AvgApplyMs,
		AvgTotalMs = AvgTotalMs,
		PeakEvalMs = PeakEval * MS,
		PeakApplyMs = PeakApply * MS,
		PeakTotalMs = PeakTotal * MS,
		PerTrackUs = PerTrackUs,
		PerMotorUs = PerMotorUs,
		PerNpcUs = PerNpcUs,
		EvalPercent = EvalPercent,
		ApplyPercent = ApplyPercent,
		CurrentFps = CurrentFps,
		FrameCount = ActiveCount,
		HeapKb = LatestHeapKb,
	}
end

-- ── Warmup Detection ─────────────────────────────────────────────────────────

--[[
	Walk backwards through up to WARMUP_WINDOW_FRAMES valid samples and compute
	coefficient of variation (CV = StdDev / Mean) of total frame time.

	Returns true when:
	  1. At least WARMUP_MIN_FRAMES total frames have been recorded.
	  2. There are WARMUP_WINDOW_FRAMES consecutive valid samples to inspect.
	  3. CV of those samples is below WARMUP_CV_THRESHOLD.
]]
function TimingCollectorModule.IsWarmupComplete(Self: TimingCollector): boolean
	if Self._TotalFrames < WARMUP_MIN then
		return false
	end

	local Buffer = Self._Buffer
	local NewestSlotIndex = ((Self._WriteIndex - 2) % MAX_SIZE) + 1

	-- Collect the last WARMUP_WINDOW total-frame-time values.
	local Samples: { number } = table.create(WARMUP_WINDOW)
	local Count = 0

	for Step = 0, WARMUP_WINDOW - 1 do
		local SlotIndex = ((NewestSlotIndex - Step) % MAX_SIZE) + 1
		local Sample = Buffer[SlotIndex]
		if not Sample.IsValid then
			return false  -- Not enough consecutive samples yet.
		end
		Count += 1
		Samples[Count] = Sample.FrameEnd - Sample.FrameStart
	end

	if Count < WARMUP_WINDOW then
		return false
	end

	-- Compute mean.
	local Sum = 0
	for Index = 1, Count do
		Sum += Samples[Index]
	end
	local Mean = Sum / Count

	if Mean <= 0 then
		return false
	end

	-- Compute population standard deviation.
	local SumSqDiff = 0
	for Index = 1, Count do
		local Diff = Samples[Index] - Mean
		SumSqDiff += Diff * Diff
	end
	local StdDev = math.sqrt(SumSqDiff / Count)
	local Cv = StdDev / Mean

	return Cv < CV_THRESHOLD
end

-- ── Export ───────────────────────────────────────────────────────────────────

return TimingCollectorModule
