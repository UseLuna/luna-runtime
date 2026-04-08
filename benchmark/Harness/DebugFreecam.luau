--!strict

--[[
	DebugFreecam — Free camera for LOD inspection.

	Freezes the current camera position as the LOD reference point while allowing
	the developer to freely fly around the scene. The frozen CFrame/FOV is exposed
	so the benchmark LOD system continues to evaluate NPCs from the original viewpoint.

	Controls:
	  RMB held   → mouse-look (yaw / pitch)
	  W/S        → forward / back
	  A/D        → strafe left / right
	  Q/E        → move down / up
	  LeftShift  → 3× speed boost
]]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

-- ============================================================================
-- [[ CONSTANTS ]]
-- ============================================================================

local MOUSE_SENSITIVITY = 0.003
local BASE_SPEED = 50
local SPRINT_MULTIPLIER = 3
local PITCH_CLAMP = math.rad(89)

-- ============================================================================
-- [[ MODULE STATE ]]
-- ============================================================================

local DebugFreecam = {}

local __IsEnabled = false

-- Frozen LOD reference
local __FrozenCFrame = CFrame.identity
local __FrozenFov = 70

-- Camera navigation state
local __Yaw = 0
local __Pitch = 0
local __Position = Vector3.zero

-- Saved original camera state
local __SavedCameraType = Enum.CameraType.Custom
local __SavedCameraSubject: Instance? = nil
local __SavedCameraCFrame = CFrame.identity

-- Saved humanoid root anchor state
local __SavedRootAnchored = false

-- ============================================================================
-- [[ PRIVATE HELPERS ]]
-- ============================================================================

--- Get the local player's HumanoidRootPart, or nil if unavailable.
local function __GetRootPart(): BasePart?
	local LocalPlayer = Players.LocalPlayer
	if not LocalPlayer then
		return nil
	end
	local Character = LocalPlayer.Character
	if not Character then
		return nil
	end
	return Character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--- Decompose a CFrame into yaw and pitch angles matching the freecam convention.
--- Yaw: rotation around world Y. Pitch: rotation around local X.
local function __DecomposeAngles(CF: CFrame): (number, number)
	local LookVector = CF.LookVector
	local Yaw = math.atan2(-LookVector.X, -LookVector.Z)
	local Pitch = math.asin(math.clamp(LookVector.Y, -1, 1))
	return Yaw, Pitch
end

--- Return true if the given KeyCode is currently held down.
local function __IsKeyDown(KeyCode: Enum.KeyCode): boolean
	return UserInputService:IsKeyDown(KeyCode)
end

-- ============================================================================
-- [[ PUBLIC API ]]
-- ============================================================================

--- Enable the freecam. Freezes the current camera CFrame as the LOD reference.
function DebugFreecam.Enable()
	if __IsEnabled then
		return
	end

	local Camera = Workspace.CurrentCamera
	if not Camera then
		return
	end

	-- Save original camera state
	__SavedCameraType = Camera.CameraType
	__SavedCameraSubject = Camera.CameraSubject
	__SavedCameraCFrame = Camera.CFrame

	-- Freeze current camera CFrame/FOV as the LOD reference
	__FrozenCFrame = Camera.CFrame
	__FrozenFov = Camera.FieldOfView

	-- Decompose current look direction into yaw/pitch for navigation
	__Yaw, __Pitch = __DecomposeAngles(Camera.CFrame)
	__Position = Camera.CFrame.Position

	-- Hand camera control to script
	Camera.CameraType = Enum.CameraType.Scriptable

	-- Anchor HumanoidRootPart so the character doesn't fall
	local RootPart = __GetRootPart()
	if RootPart then
		__SavedRootAnchored = RootPart.Anchored
		RootPart.Anchored = true
	else
		__SavedRootAnchored = false
	end

	__IsEnabled = true
end

--- Disable the freecam and restore the original camera state.
function DebugFreecam.Disable()
	if not __IsEnabled then
		return
	end

	local Camera = Workspace.CurrentCamera
	if Camera then
		Camera.CameraType = __SavedCameraType
		Camera.CameraSubject = __SavedCameraSubject
		Camera.CFrame = __SavedCameraCFrame
	end

	-- Restore HumanoidRootPart anchor state
	local RootPart = __GetRootPart()
	if RootPart then
		RootPart.Anchored = __SavedRootAnchored
	end

	-- Release mouse lock
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default

	__IsEnabled = false
end

--- Per-frame update — call from RenderStepped with the frame DeltaTime.
function DebugFreecam.Update(DeltaTime: number)
	if not __IsEnabled then
		return
	end

	local Camera = Workspace.CurrentCamera
	if not Camera then
		return
	end

	-- ── Mouse Look ──────────────────────────────────────────────────────────

	local IsRmbHeld = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)

	if IsRmbHeld then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition

		local MouseDelta = UserInputService:GetMouseDelta()
		__Yaw -= MouseDelta.X * MOUSE_SENSITIVITY
		__Pitch -= MouseDelta.Y * MOUSE_SENSITIVITY
		__Pitch = math.clamp(__Pitch, -PITCH_CLAMP, PITCH_CLAMP)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end

	-- ── Build Rotation ──────────────────────────────────────────────────────

	local Rotation = CFrame.fromEulerAnglesYXZ(__Pitch, __Yaw, 0)

	-- ── Movement ────────────────────────────────────────────────────────────

	local MoveLocal = Vector3.zero

	-- Z axis: W = forward (-Z), S = back (+Z)
	if __IsKeyDown(Enum.KeyCode.W) then
		MoveLocal -= Vector3.zAxis
	end
	if __IsKeyDown(Enum.KeyCode.S) then
		MoveLocal += Vector3.zAxis
	end

	-- X axis: D = right (+X), A = left (-X)
	if __IsKeyDown(Enum.KeyCode.D) then
		MoveLocal += Vector3.xAxis
	end
	if __IsKeyDown(Enum.KeyCode.A) then
		MoveLocal -= Vector3.xAxis
	end

	-- Y axis: E = up (+Y), Q = down (-Y)
	if __IsKeyDown(Enum.KeyCode.E) then
		MoveLocal += Vector3.yAxis
	end
	if __IsKeyDown(Enum.KeyCode.Q) then
		MoveLocal -= Vector3.yAxis
	end

	-- Normalize movement direction and transform to world space
	local MagnitudeSq = MoveLocal.X * MoveLocal.X + MoveLocal.Y * MoveLocal.Y + MoveLocal.Z * MoveLocal.Z
	if MagnitudeSq > 0 then
		local Speed = BASE_SPEED
		if __IsKeyDown(Enum.KeyCode.LeftShift) then
			Speed *= SPRINT_MULTIPLIER
		end

		local WorldMovement = Rotation:VectorToWorldSpace(MoveLocal.Unit) * Speed * DeltaTime
		__Position += WorldMovement
	end

	-- ── Apply Camera ────────────────────────────────────────────────────────

	Camera.CFrame = CFrame.new(__Position) * Rotation
end

--- Returns true if the freecam is currently active.
function DebugFreecam.IsEnabled(): boolean
	return __IsEnabled
end

--- Returns the frozen camera CFrame used as the LOD reference point.
function DebugFreecam.GetFrozenCFrame(): CFrame
	return __FrozenCFrame
end

--- Returns the frozen field of view used as the LOD reference.
function DebugFreecam.GetFrozenFov(): number
	return __FrozenFov
end

-- ============================================================================

return DebugFreecam
