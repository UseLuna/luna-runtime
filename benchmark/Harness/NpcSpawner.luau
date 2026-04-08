--!strict

local Benchmark = script.Parent.Parent
local BenchmarkTypes = require(Benchmark.BenchmarkTypes)
local LunaRuntime = game:GetService("ReplicatedStorage"):WaitForChild("LunaRuntime")
local RigResolver = require(LunaRuntime.Solver.RigResolver)
local Logger = require(LunaRuntime.Shared.Logger)

type SpawnConfig = BenchmarkTypes.SpawnConfig
type SpawnResult = BenchmarkTypes.SpawnResult
type RigVariantConfig = BenchmarkTypes.RigVariantConfig

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local R6_LIMB_NAMES: { string } = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local R15_LIMB_NAMES: { string } = {
	"Head",
	"UpperTorso",
	"LowerTorso",
	"LeftUpperArm",
	"LeftLowerArm",
	"LeftHand",
	"RightUpperArm",
	"RightLowerArm",
	"RightHand",
	"LeftUpperLeg",
	"LeftLowerLeg",
	"LeftFoot",
	"RightUpperLeg",
	"RightLowerLeg",
	"RightFoot",
}

local SPAWN_Y = 5
local FOLDER_NAME = "BenchmarkNpcs"

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

local NpcSpawner = {}

local __SpawnedModels: { Model } = {}
local __SpawnedFolder: Folder? = nil

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

--- Find a Motor6D in a model whose Part1 has the given name.
local function __FindMotorByPart1Name(Model: Model, TargetName: string): Motor6D?
	for _, Descendant in Model:GetDescendants() do
		if Descendant:IsA("Motor6D") then
			local Motor = Descendant :: Motor6D
			if Motor.Part1 and Motor.Part1.Name == TargetName then
				return Motor
			end
		end
	end
	return nil
end

--- Destroy a random limb Motor6D from the model based on rig type.
local function __ApplyMissingLimb(Clone: Model, RigType: string)
	local LimbNames = if RigType == "R6" then R6_LIMB_NAMES else R15_LIMB_NAMES
	local RandomIndex = math.random(1, #LimbNames)
	local TargetName = LimbNames[RandomIndex]
	local Motor = __FindMotorByPart1Name(Clone, TargetName)
	if Motor then
		Motor:Destroy()
	else
		Logger.Warn(`NpcSpawner: Could not find Motor6D for limb "{TargetName}" on "{Clone.Name}"`)
	end
end

--- Add a Tool with a Handle Part and RightGrip Motor6D attached to the right hand.
local function __ApplyToolEquipped(Clone: Model)
	local RightHand = Clone:FindFirstChild("RightHand") :: BasePart?
		or Clone:FindFirstChild("Right Arm") :: BasePart?
	if not RightHand then
		Logger.Warn(`NpcSpawner: Could not find right hand part on "{Clone.Name}" for ToolEquipped variant`)
		return
	end

	local Tool = Instance.new("Tool")
	Tool.Name = "BenchmarkTool"
	Tool.RequiresHandle = true

	local Handle = Instance.new("Part")
	Handle.Name = "Handle"
	Handle.Size = Vector3.new(1, 1, 3)
	Handle.CanCollide = false
	Handle.Massless = true
	Handle.Parent = Tool

	local RightGrip = Instance.new("Motor6D")
	RightGrip.Name = "RightGrip"
	RightGrip.Part0 = RightHand
	RightGrip.Part1 = Handle
	RightGrip.C0 = CFrame.new(0, 0, -1.5)
	RightGrip.Parent = RightHand

	Tool.Parent = Clone
end

--- Set Transparency=1 on all BaseParts except HumanoidRootPart.
local function __ApplyNoRender(Clone: Model)
	for _, Descendant in Clone:GetDescendants() do
		if Descendant:IsA("BasePart") and Descendant.Name ~= "HumanoidRootPart" then
			(Descendant :: BasePart).Transparency = 1
		end
	end
end

--- Compute grid position for a given NPC index (0-based) and column count.
local function __GridPosition(Index: number, Columns: number, Spacing: number): Vector3
	local Col = Index % Columns
	local Row = Index // Columns
	return Vector3.new(Col * Spacing, SPAWN_Y, Row * Spacing)
end

--- Determine the variant assignment boundaries from percent config.
--- Returns (MissingLimbEnd, ToolEquippedEnd) — both exclusive upper bounds.
local function __ComputeVariantBoundaries(
	Count: number,
	Variants: RigVariantConfig
): (number, number, number)
	local MissingLimbCount = math.floor(Count * Variants.MissingLimbPercent / 100)
	local ToolEquippedCount = math.floor(Count * Variants.ToolEquippedPercent / 100)
	-- Clamp so we never exceed Count
	if MissingLimbCount + ToolEquippedCount > Count then
		ToolEquippedCount = Count - MissingLimbCount
	end
	local PristineCount = Count - MissingLimbCount - ToolEquippedCount
	return MissingLimbCount, ToolEquippedCount, PristineCount
end

-- ============================================================================
-- [[ PUBLIC API ]]
-- ============================================================================

--- Spawn NPCs according to SpawnConfig. Returns models, rig bindings, and variant counts.
function NpcSpawner.Spawn(Config: SpawnConfig): SpawnResult
	NpcSpawner.Cleanup()

	-- Locate template
	local Templates = workspace:FindFirstChild("Templates")
	if not Templates then
		Logger.Error("NpcSpawner: Workspace.Templates not found — pre-place R6/R15 template models in Studio")
	end

	local TemplateName = Config.RigType
	local Template = (Templates :: Folder):FindFirstChild(TemplateName) :: Model?
	if not Template then
		Logger.Error(`NpcSpawner: Template "{TemplateName}" not found in Workspace.Templates`)
	end

	-- Create folder to hold spawned NPCs
	local Folder = Instance.new("Folder")
	Folder.Name = FOLDER_NAME
	Folder.Parent = workspace
	__SpawnedFolder = Folder

	local Count = Config.Count
	local Columns = math.ceil(math.sqrt(Count))
	local Spacing = Config.Density

	local MissingLimbCount, ToolEquippedCount, PristineCount = __ComputeVariantBoundaries(Count, Config.Variants)

	local Models: { Model } = table.create(Count)
	local RigBindings: { any } = table.create(Count)

	for Index = 0, Count - 1 do
		local Clone = (Template :: Model):Clone()
		Clone.Name = `NPC_{Index + 1}`

		-- Position HumanoidRootPart and anchor it
		local RootPart = Clone:FindFirstChild("HumanoidRootPart") :: BasePart?
		if RootPart then
			RootPart.Anchored = true
			RootPart.CFrame = CFrame.new(__GridPosition(Index, Columns, Spacing))
		else
			Logger.Warn(`NpcSpawner: No HumanoidRootPart on clone "{Clone.Name}"`)
		end

		Clone.Parent = Folder

		-- Apply variant (1-based: indices 1..MissingLimbCount, then ToolEquipped, then Pristine)
		local OneBasedIndex = Index + 1
		if OneBasedIndex <= MissingLimbCount then
			__ApplyMissingLimb(Clone, Config.RigType)
		elseif OneBasedIndex <= MissingLimbCount + ToolEquippedCount then
			__ApplyToolEquipped(Clone)
		end
		-- else: Pristine — no modification needed

		-- Isolation: No Render — hide meshes, keep Motor6D writes
		if Config.IsolationMode == "No Render" then
			__ApplyNoRender(Clone)
		end

		-- Isolation: No Eval — skip RigResolver entirely
		local Binding: any = nil
		if Config.IsolationMode ~= "No Eval" then
			local Success, Result = pcall(RigResolver.Resolve, Clone)
			if Success then
				Binding = Result
			else
				Logger.Warn(`NpcSpawner: RigResolver.Resolve failed for "{Clone.Name}": {tostring(Result)}`)
			end
		end

		Models[OneBasedIndex] = Clone
		RigBindings[OneBasedIndex] = Binding
	end

	__SpawnedModels = Models

	Logger.Info(
		`NpcSpawner: Spawned {Count} NPCs ({Config.RigType}) — `
			.. `MissingLimb={MissingLimbCount}, ToolEquipped={ToolEquippedCount}, Pristine={PristineCount}`
	)

	return {
		Models = Models,
		RigBindings = RigBindings,
		VariantCounts = {
			Pristine = PristineCount,
			MissingLimb = MissingLimbCount,
			ToolEquipped = ToolEquippedCount,
		},
	}
end

--- Destroy all spawned NPCs and clear state.
function NpcSpawner.Cleanup()
	if __SpawnedFolder then
		__SpawnedFolder:Destroy()
		__SpawnedFolder = nil
	end
	table.clear(__SpawnedModels)
end

--- Return the current array of spawned models.
function NpcSpawner.GetSpawnedModels(): { Model }
	return __SpawnedModels
end

--- Return the number of currently spawned models.
function NpcSpawner.GetSpawnedCount(): number
	return #__SpawnedModels
end

return NpcSpawner
