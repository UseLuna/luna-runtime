--!strict
--!optimize 2
--!native
--[[
	Binary search utilities for sorted keyframe arrays.

	Two variants:
	  FindLastAtOrBefore — returns index of last element where .Time <= Target
	  FindInsertIndex    — returns index where a new element with .Time should be inserted

	Used by Evaluator, Sampler, ExportPipeline, and AnimationData.
]]

local SearchUtils = {}

-- Find the index of the last element in a sorted array whose .Time <= TargetTime.
-- If all elements are after TargetTime, returns 1.
-- The array must have a .Time field on each element and be sorted ascending by .Time.
function SearchUtils.FindLastAtOrBefore(Array: { { Time: number } }, TargetTime: number): number
	local Low = 1
	local High = #Array
	local Result = 1

	while Low <= High do
		local Mid = (Low + High) // 2
		if Array[Mid].Time <= TargetTime then
			Result = Mid
			Low = Mid + 1
		else
			High = Mid - 1
		end
	end

	return Result
end

-- Find the insertion index for a new element with the given Time.
-- Returns the index of the first element where .Time >= Time (lower bound).
-- If all elements are before Time, returns #Array + 1.
function SearchUtils.FindInsertIndex(Array: { { Time: number } }, Time: number): number
	local Low = 1
	local High = #Array
	local Result = High + 1

	while Low <= High do
		local Mid = (Low + High) // 2
		if Array[Mid].Time < Time then
			Low = Mid + 1
		else
			Result = Mid
			High = Mid - 1
		end
	end

	return Result
end

export type SearchUtils = typeof(SearchUtils)

return SearchUtils
