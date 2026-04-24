--!strict
local Core = {}

Core.Constants = require(script.Constants)
Core.Quaternion = require(script.Quaternion)
Core.CFrameUtils = require(script.CFrameUtils)
Core.Curves = require(script.Curves)
Core.AnimationData = require(script.AnimationData)
Core.Evaluator = require(script.Evaluator)
Core.ExportPipeline = require(script.ExportPipeline)
Core.ModifierRegistry = require(script.ModifierRegistry)
Core.Sampler = require(script.Sampler)
Core.Serializer = require(script.Serializer)
Core.SearchUtils = require(script.SearchUtils)

return Core
