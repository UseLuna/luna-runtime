--!strict

local Workspace = game:GetService("Workspace")
local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local Logger = require(LunaRuntime.Shared.Logger)

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local SPAWN_Y = 5
local FOLDER_NAME = "BenchmarkNativeNpcs"

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

local NativeAnimatorRunner = {}

local __Folder: Folder? = nil
local __Models: { Model } = {}
local __Animators: { Animator } = {}
local __Tracks: { AnimationTrack } = {}
local __Count: number = 0

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

--- Compute grid position for a given NPC index (0-based), column count, and spacing.
--- OffsetX shifts the entire grid to the side so it does not overlap NpcSpawner's grid.
local function __GridPosition(Index: number, Columns: number, Spacing: number, OffsetX: number): Vector3
	local Col = Index % Columns
	local Row = Index // Columns
	return Vector3.new(OffsetX + Col * Spacing, SPAWN_Y, Row * Spacing)
end

--- Find an existing Animator inside Humanoid, or create and parent one.
local function __GetOrCreateAnimator(Humanoid: Humanoid): Animator
	local Existing = Humanoid:FindFirstChildOfClass("Animator")
	if Existing then
		return Existing :: Animator
	end
	local NewAnimator = Instance.new("Animator")
	NewAnimator.Parent = Humanoid
	return NewAnimator
end

-- ============================================================================
-- [[ PUBLIC API ]]
-- ============================================================================

--- Spawn `Count` clones of `Template` in a grid offset to the side of the Luna grid.
--- `Source` must be an Animation instance with AnimationId set.
--- KeyframeSequence is not supported — a warning is logged if detected.
function NativeAnimatorRunner.Spawn(Template: Model, Count: number, Density: number, Source: Instance)
	NativeAnimatorRunner.Cleanup()

	-- Validate source type
	if Source:IsA("KeyframeSequence") then
		Logger.Warn(
			"NativeAnimatorRunner.Spawn: Source is a KeyframeSequence — native Animator requires an Animation "
				.. "instance with an AnimationId asset string. Proceeding will likely fail or produce no playback."
		)
	end

	if not Source:IsA("Animation") then
		Logger.Error(
			`NativeAnimatorRunner.Spawn: Source must be an Animation instance, got "{Source.ClassName}"`
		)
		return
	end

	local AnimSource = Source :: Animation

	-- Create folder
	local Folder = Instance.new("Folder")
	Folder.Name = FOLDER_NAME
	Folder.Parent = Workspace
	__Folder = Folder

	local Columns = math.ceil(math.sqrt(Count))
	-- Offset far enough that no column of the native grid overlaps Luna's grid.
	-- Luna uses [0 .. Columns-1] * Density in X; we start just past that plus 2 extra cells.
	local OffsetX = (Columns + 2) * Density

	local Models: { Model } = table.create(Count)
	local Animators: { Animator } = table.create(Count)
	local Tracks: { AnimationTrack } = table.create(Count)

	for Index = 0, Count - 1 do
		local Clone = Template:Clone()
		Clone.Name = `NativeNPC_{Index + 1}`

		-- Anchor and position HumanoidRootPart
		local RootPart = Clone:FindFirstChild("HumanoidRootPart") :: BasePart?
		if RootPart then
			RootPart.Anchored = true
			RootPart.CFrame = CFrame.new(__GridPosition(Index, Columns, Density, OffsetX))
		else
			Logger.Warn(`NativeAnimatorRunner.Spawn: No HumanoidRootPart on clone "{Clone.Name}"`)
		end

		Clone.Parent = Folder

		-- Locate Humanoid and get/create Animator
		local Humanoid = Clone:FindFirstChildOfClass("Humanoid") :: Humanoid?
		if not Humanoid then
			Logger.Warn(`NativeAnimatorRunner.Spawn: No Humanoid on clone "{Clone.Name}" — skipping track load`)
			local OneBasedIndex = Index + 1
			Models[OneBasedIndex] = Clone
			Animators[OneBasedIndex] = nil :: any
			Tracks[OneBasedIndex] = nil :: any
			continue
		end

		local Animator = __GetOrCreateAnimator(Humanoid)

		-- Load animation track — this does not start playback
		local Track = Animator:LoadAnimation(AnimSource)

		local OneBasedIndex = Index + 1
		Models[OneBasedIndex] = Clone
		Animators[OneBasedIndex] = Animator
		Tracks[OneBasedIndex] = Track
	end

	__Models = Models
	__Animators = Animators
	__Tracks = Tracks
	__Count = Count

	Logger.Info(`NativeAnimatorRunner.Spawn: Spawned {Count} native NPC(s) with grid offset X={OffsetX}`)
end

--- Start looped playback on all loaded tracks.
function NativeAnimatorRunner.PlayAll()
	for _, Track in __Tracks do
		if Track then
			Track.Looped = true
			Track:Play()
		end
	end
	Logger.Info(`NativeAnimatorRunner.PlayAll: Started {__Count} track(s)`)
end

--- Stop all tracks instantly (FadeTime=0). Rigs and Animators remain in the scene.
function NativeAnimatorRunner.StopAll()
	for _, Track in __Tracks do
		if Track then
			Track:Stop(0)
		end
	end
	Logger.Info(`NativeAnimatorRunner.StopAll: Stopped {__Count} track(s)`)
end

--- Stop all tracks, destroy track objects, then destroy the folder and clear all state.
function NativeAnimatorRunner.Cleanup()
	-- Stop and destroy tracks first
	for _, Track in __Tracks do
		if Track then
			Track:Stop(0)
			Track:Destroy()
		end
	end

	-- Destroy the scene folder (takes models + animators with it)
	if __Folder then
		__Folder:Destroy()
		__Folder = nil
	end

	-- Clear module-level state
	table.clear(__Models)
	table.clear(__Animators)
	table.clear(__Tracks)
	__Count = 0
end

--- Return the number of native NPCs currently spawned.
function NativeAnimatorRunner.GetCount(): number
	return __Count
end

return NativeAnimatorRunner
