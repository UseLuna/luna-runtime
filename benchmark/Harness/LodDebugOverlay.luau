--!strict

--[[
	LodDebugOverlay — Billboard and frustum wireframe visualization for LOD debugging.

	Billboards: Per-NPC BillboardGui showing current LOD tier, color-coded by tier.
	Frustum: 12 neon Part edges drawing the camera frustum used for LOD culling.
]]

local Workspace = game:GetService("Workspace")

local Benchmark = script.Parent.Parent
local BenchmarkConstants = require(Benchmark.BenchmarkConstants)

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local TIER_COLORS = BenchmarkConstants.TIER_COLORS
local COLOR_CYAN = BenchmarkConstants.COLOR_CYAN

local TIER_LABELS: { string } = {
	"T0 Frozen",
	"T1 Full",
	"T2 Reduced",
	"T3 Low",
	"T4 Minimal",
}

local BILLBOARD_SIZE = UDim2.fromScale(2, 1)
local BILLBOARD_STUDS_OFFSET = Vector3.new(0, 3, 0)
local EDGE_THICKNESS = 0.05
local NEAR_DISTANCE = 1
local FRUSTUM_FOLDER_NAME = "LodFrustumDebug"

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

local LodDebugOverlay = {}

type BillboardEntry = {
	Billboard: BillboardGui,
	Label: TextLabel,
	Solver: any,
}

local __BillboardEntries: { BillboardEntry } = {}
local __IsBillboardsEnabled = false

local __FrustumEdges: { Part } = {}
local __FrustumFolder: Folder? = nil
local __IsFrustumEnabled = false

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

--- Create a single neon edge Part for the frustum wireframe.
local function __CreateEdgePart(): Part
	local Edge = Instance.new("Part")
	Edge.Anchored = true
	Edge.CanCollide = false
	Edge.CanTouch = false
	Edge.CanQuery = false
	Edge.Material = Enum.Material.Neon
	Edge.Color = COLOR_CYAN
	Edge.CastShadow = false
	Edge.Size = Vector3.new(EDGE_THICKNESS, EDGE_THICKNESS, 1)
	return Edge
end

--- Position and size a Part as an edge between two world-space points.
local function __PositionEdge(Edge: Part, StartPoint: Vector3, EndPoint: Vector3)
	local MidPoint = (StartPoint + EndPoint) * 0.5
	local Length = (EndPoint - StartPoint).Magnitude
	if Length < 0.001 then
		Edge.Size = Vector3.new(EDGE_THICKNESS, EDGE_THICKNESS, EDGE_THICKNESS)
		Edge.CFrame = CFrame.new(MidPoint)
		return
	end
	Edge.Size = Vector3.new(EDGE_THICKNESS, EDGE_THICKNESS, Length)
	Edge.CFrame = CFrame.lookAt(MidPoint, EndPoint)
end

--- Compute the 4 corners of a frustum rectangle at a given distance from the camera.
--- Returns corners in order: TopLeft, TopRight, BottomRight, BottomLeft (world space).
local function __FrustumCornersAtDistance(
	CameraCFrame: CFrame,
	FieldOfView: number,
	ViewportPadding: number,
	AspectRatio: number,
	Distance: number
): (Vector3, Vector3, Vector3, Vector3)
	local HalfHeight = Distance * math.tan(math.rad(FieldOfView / 2)) * (1 + ViewportPadding)
	local HalfWidth = HalfHeight * AspectRatio

	-- Local-space corners (camera looks down -Z in Roblox)
	local Center = CameraCFrame.Position + CameraCFrame.LookVector * Distance

	local Right = CameraCFrame.RightVector * HalfWidth
	local Up = CameraCFrame.UpVector * HalfHeight

	local TopLeft = Center - Right + Up
	local TopRight = Center + Right + Up
	local BottomRight = Center + Right - Up
	local BottomLeft = Center - Right - Up

	return TopLeft, TopRight, BottomRight, BottomLeft
end

--- Write the 12 frustum edges from near and far corners.
--- Near corners: indices 1-4 (TopLeft, TopRight, BottomRight, BottomLeft)
--- Far  corners: indices 5-8
--- Edges 1-4: near rectangle, 5-8: far rectangle, 9-12: connecting lines.
local function __UpdateEdgePositions(
	Edges: { Part },
	NearTL: Vector3, NearTR: Vector3, NearBR: Vector3, NearBL: Vector3,
	FarTL: Vector3,  FarTR: Vector3,  FarBR: Vector3,  FarBL: Vector3
)
	-- Near rectangle (4 edges)
	__PositionEdge(Edges[1], NearTL, NearTR)
	__PositionEdge(Edges[2], NearTR, NearBR)
	__PositionEdge(Edges[3], NearBR, NearBL)
	__PositionEdge(Edges[4], NearBL, NearTL)

	-- Far rectangle (4 edges)
	__PositionEdge(Edges[5], FarTL, FarTR)
	__PositionEdge(Edges[6], FarTR, FarBR)
	__PositionEdge(Edges[7], FarBR, FarBL)
	__PositionEdge(Edges[8], FarBL, FarTL)

	-- Connecting lines near→far (4 edges)
	__PositionEdge(Edges[9],  NearTL, FarTL)
	__PositionEdge(Edges[10], NearTR, FarTR)
	__PositionEdge(Edges[11], NearBR, FarBR)
	__PositionEdge(Edges[12], NearBL, FarBL)
end

-- ============================================================================
-- [[ PUBLIC API — BILLBOARDS ]]
-- ============================================================================

--- Create billboard GUIs for each NPC entry.
--- NpcData: array of { Model: Model, Solver: any }
function LodDebugOverlay.EnableBillboards(NpcData: { { Model: Model, Solver: any } })
	LodDebugOverlay.DisableBillboards()

	for _, Entry in NpcData do
		local NpcModel = Entry.Model
		local Solver = Entry.Solver

		local Adornee: BasePart? = NpcModel.PrimaryPart
			or NpcModel:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not Adornee then
			continue
		end

		local Billboard = Instance.new("BillboardGui")
		Billboard.Size = BILLBOARD_SIZE
		Billboard.StudsOffset = BILLBOARD_STUDS_OFFSET
		Billboard.AlwaysOnTop = true
		Billboard.Adornee = Adornee
		Billboard.Parent = Adornee

		local Label = Instance.new("TextLabel")
		Label.Size = UDim2.fromScale(1, 1)
		Label.TextScaled = true
		Label.BackgroundTransparency = 0.3
		Label.FontFace = Font.fromName("GothamBold")
		Label.Text = "T?"
		Label.TextColor3 = Color3.fromRGB(255, 255, 255)
		Label.Parent = Billboard

		local Corner = Instance.new("UICorner")
		Corner.CornerRadius = UDim.new(0.2, 0)
		Corner.Parent = Label

		local BillboardEntry: BillboardEntry = {
			Billboard = Billboard,
			Label = Label,
			Solver = Solver,
		}

		table.insert(__BillboardEntries, BillboardEntry)
	end

	__IsBillboardsEnabled = true
end

--- Update all billboard labels based on current LOD tiers from LodManager.
function LodDebugOverlay.UpdateBillboards(LodManager: any)
	if not __IsBillboardsEnabled then
		return
	end

	for _, Entry in __BillboardEntries do
		local Tier: number = LodManager.GetTier(LodManager, Entry.Solver)
		-- Tier is 0-based (0=Frozen/culled ... 4=Minimal); TIER_COLORS is 1-based.
		local ColorIndex = math.clamp(Tier + 1, 1, #TIER_COLORS)
		local LabelText = TIER_LABELS[ColorIndex] or `T{Tier}`

		Entry.Label.BackgroundColor3 = TIER_COLORS[ColorIndex]
		Entry.Label.Text = LabelText
	end
end

--- Destroy all billboard GUIs and clear state.
function LodDebugOverlay.DisableBillboards()
	for _, Entry in __BillboardEntries do
		Entry.Billboard:Destroy()
	end
	table.clear(__BillboardEntries)
	__IsBillboardsEnabled = false
end

--- Returns true if billboard overlays are currently active.
function LodDebugOverlay.IsBillboardsEnabled(): boolean
	return __IsBillboardsEnabled
end

-- ============================================================================
-- [[ PUBLIC API — FRUSTUM ]]
-- ============================================================================

--- Create 12 neon edge parts and position them to represent the camera frustum.
function LodDebugOverlay.EnableFrustum(
	CameraCFrame: CFrame,
	FieldOfView: number,
	ViewportPadding: number,
	AspectRatio: number,
	FarDistance: number
)
	LodDebugOverlay.DisableFrustum()

	local Folder = Instance.new("Folder")
	Folder.Name = FRUSTUM_FOLDER_NAME
	Folder.Parent = Workspace
	__FrustumFolder = Folder

	local Edges: { Part } = table.create(12)
	for Index = 1, 12 do
		local Edge = __CreateEdgePart()
		Edge.Parent = Folder
		Edges[Index] = Edge
	end
	__FrustumEdges = Edges

	local NearTL, NearTR, NearBR, NearBL = __FrustumCornersAtDistance(
		CameraCFrame, FieldOfView, ViewportPadding, AspectRatio, NEAR_DISTANCE
	)
	local FarTL, FarTR, FarBR, FarBL = __FrustumCornersAtDistance(
		CameraCFrame, FieldOfView, ViewportPadding, AspectRatio, FarDistance
	)

	__UpdateEdgePositions(Edges, NearTL, NearTR, NearBR, NearBL, FarTL, FarTR, FarBR, FarBL)

	__IsFrustumEnabled = true
end

--- Reposition the 12 edge parts to match the updated camera frustum.
function LodDebugOverlay.UpdateFrustum(
	CameraCFrame: CFrame,
	FieldOfView: number,
	ViewportPadding: number,
	AspectRatio: number,
	FarDistance: number
)
	if not __IsFrustumEnabled then
		return
	end

	local NearTL, NearTR, NearBR, NearBL = __FrustumCornersAtDistance(
		CameraCFrame, FieldOfView, ViewportPadding, AspectRatio, NEAR_DISTANCE
	)
	local FarTL, FarTR, FarBR, FarBL = __FrustumCornersAtDistance(
		CameraCFrame, FieldOfView, ViewportPadding, AspectRatio, FarDistance
	)

	__UpdateEdgePositions(__FrustumEdges, NearTL, NearTR, NearBR, NearBL, FarTL, FarTR, FarBR, FarBL)
end

--- Destroy all frustum edge parts and clear state.
function LodDebugOverlay.DisableFrustum()
	if __FrustumFolder then
		__FrustumFolder:Destroy()
		__FrustumFolder = nil
	end
	table.clear(__FrustumEdges)
	__IsFrustumEnabled = false
end

--- Returns true if the frustum wireframe is currently active.
function LodDebugOverlay.IsFrustumEnabled(): boolean
	return __IsFrustumEnabled
end

-- ============================================================================

return LodDebugOverlay
