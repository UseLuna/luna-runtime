--!strict

local Constants = {}

Constants.DEFAULT_FPS = 30
Constants.MAX_TRACKS = 128

-- Binary format — magic number (8 bytes, PNG-style defensive)
-- \x89: high bit set prevents text misidentification
-- LNA: "Luna Animation", readable in hex editors
-- \r\n: detects CR/LF corruption from text-mode transfer
-- \x1A: stops DOS type command
-- \n: detects reverse LF-to-CRLF corruption
Constants.LUNA_MAGIC = "\x89LNA\r\n\x1a\n"
Constants.LUNA_HEADER_SIZE = 12

-- Format types
Constants.FORMAT_TYPE_EDIT = 0
Constants.FORMAT_TYPE_SAMPLED = 1
Constants.FORMAT_TYPE_SAMPLED_WITH_MODIFIERS = 2

-- Per-format version numbers (evolve independently)
Constants.FORMAT_VERSION_EDIT = 2
Constants.FORMAT_VERSION_SAMPLED = 1

-- Critical chunk IDs (bit 15 = 0, decoder MUST understand)
Constants.CHUNK_METADATA = 0x0001
Constants.CHUNK_TRACK_HEADERS = 0x0002
Constants.CHUNK_EDIT_KEYFRAMES = 0x0003
Constants.CHUNK_SAMPLED_DATA = 0x0004

-- Ancillary chunk IDs (bit 15 = 1, decoder MAY skip if unknown)
Constants.CHUNK_MODIFIERS = 0x8005
Constants.CHUNK_CONSTRAINTS = 0x8006
Constants.CHUNK_MARKERS = 0x8007

-- Chunk header: type (u16) + size (u32) = 6 bytes before body
Constants.CHUNK_HEADER_SIZE = 6
-- Chunk envelope: header (6) + CRC16 (u16) = 8 bytes total overhead per chunk
Constants.CHUNK_ENVELOPE_SIZE = 8
Constants.CHUNK_ANCILLARY_BIT = 0x8000

-- Quantization
Constants.QUANTIZE_ROTATION_RANGE = 0.70710678
Constants.QUANTIZE_ROTATION_MAX = 1023
Constants.QUANTIZE_POSITION_MAX = 65535

-- Curve mode binary enum
Constants.CURVE_MODE_LINEAR = 0
Constants.CURVE_MODE_STEPPED = 1
Constants.CURVE_MODE_BEZIER = 2
Constants.CURVE_MODE_EASING = 3
Constants.CURVE_MODE_HERMITE = 4

-- String limits
Constants.MAX_NAME_LENGTH = 256

-- Per-channel animation (6 scalar channels per joint)
Constants.CHANNEL_IDS = { "PositionX", "PositionY", "PositionZ", "RotationX", "RotationY", "RotationZ" }
Constants.POSITION_CHANNELS = { "PositionX", "PositionY", "PositionZ" }
Constants.ROTATION_CHANNELS = { "RotationX", "RotationY", "RotationZ" }
Constants.CHANNEL_COUNT = 6

-- Math constants
Constants.EPSILON = 1e-6
Constants.SLERP_THRESHOLD = 0.9995

-- Bezier solver (Newton's method + bisection fallback, matching Blender's approach)
Constants.NEWTON_MAX_ITERATIONS = 8
Constants.NEWTON_MIN_SLOPE = 0.001
Constants.BEZIER_SUBDIVISION_PRECISION = 1e-7
Constants.BEZIER_SUBDIVISION_MAX_ITERATIONS = 10
Constants.BEZIER_LUT_SIZE = 11

-- Easing magic numbers
Constants.EASE_BACK_OVERSHOOT = 1.70158

-- CRC16-CCITT polynomial
Constants.CRC16_POLYNOMIAL = 0x1021

-- Sampler rotation buffer stride: 4 × f32 = 16 bytes per quaternion
Constants.ROTATION_BUFFER_STRIDE = 16

-- Position buffer stride: 3 × f32 = 12 bytes per position (tight packing, no alignment needed in Luau)
Constants.POS_STRIDE = 12

-- Bone weight transition method encoding (u8 values for buffer storage)
Constants.BONE_WEIGHT_SNAP = 0
Constants.BONE_WEIGHT_LERP = 1
Constants.BONE_WEIGHT_SPRING = 2
Constants.BONE_WEIGHT_TRANSITION_STRIDE = 12 -- 3 × f32 (Target, Speed, Velocity)

-- Solver thresholds
Constants.PERCEPTUAL_CULL_THRESHOLD = 0.01
Constants.DEAD_LAYER_THRESHOLD = 0.001
Constants.CROSSFADE_KILL_THRESHOLD = 0.05

-- Storage pack format version (prepended before compressed data)
Constants.STORAGE_PACK_VERSION = 1
-- DataStore maximum buffer size (bytes)
Constants.DATASTORE_SIZE_LIMIT = 4_000_000
-- Attribute/StringValue maximum string size (bytes)
Constants.ATTRIBUTE_SIZE_LIMIT = 200_000

return Constants
