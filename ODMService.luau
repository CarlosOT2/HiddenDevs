-- Discord: miranha0 | Roblox: HOMEMARANHA06

-- Services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
-- Event
local ODMEvent = ReplicatedStorage.RE:WaitForChild("ODM")
-- Modules
local ODMTypes = require(ServerStorage.Types.ODM)
local EntityDataTypes = require(ServerStorage.Types.EntityData)
local SessionData = require(ServerScriptService.Data.SessionData)
local INFO = require(ServerScriptService.Systems.Modules.INFO)

------------------------------------------------------------------------------------------------
-- Hook helpers

local function HasActiveHook(player: Player): boolean
	local data = SessionData.Entity.Get(player)
	if not data then return false end

	local hooks = data.temp.ODM.hooks
	return hooks.Left.active or hooks.Right.active
end

local function ResetHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]

	hook.active = false
	hook.part = nil
	hook.position = nil
end

local function GetHookTargetPosition(
	entitydata: EntityDataTypes.Data
): Vector3?
	local leftHook = entitydata.temp.ODM.hooks.Left
	local rightHook = entitydata.temp.ODM.hooks.Right

	if leftHook.active and rightHook.active then
		-- Use the midpoint when both hooks are active.
		return (leftHook.position + rightHook.position) / 2
	end

	if leftHook.active then return leftHook.position end
	if rightHook.active then return rightHook.position end

	return nil
end

------------------------------------------------------------------------------------------------
-- Movement components

local function Reset(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local char = data.references.char
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local odm = data.temp.ODM

	ResetHook(player, "Left")
	ResetHook(player, "Right")

	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0
	odm.speed = 0
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	-- odm.colliding = false
	-- odm.collisionDirection = nil

	if odm.LinearVelocityReference then
		odm.LinearVelocityReference:Destroy()
		odm.LinearVelocityReference = nil
	end

	if odm.AlignOrientationReference then
		odm.AlignOrientationReference:Destroy()
		odm.AlignOrientationReference = nil
	end

	if odm.AttachmentReference then
		odm.AttachmentReference:Destroy()
		odm.AttachmentReference = nil
	end

	if humanoid then
		humanoid.AutoRotate = true
		humanoid.PlatformStand = false
		humanoid.JumpHeight = 7.2
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
	end
end

local function CreateMovementComponents(player: Player): true?
	local data = SessionData.Entity.Get(player)
	if not data then return nil end

	local char = data.references.char
	if not char then return nil end

	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")

	if not root or not humanoid then return nil end

	local odm = data.temp.ODM

	humanoid.AutoRotate = false
	humanoid.PlatformStand = false
	humanoid.JumpHeight = 0

	-- Prevent the Humanoid from automatically getting up while using ODM.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	local attachment = Instance.new("Attachment")
	attachment.Name = "ODMAttachment"
	attachment.Parent = root

	-- Velocity controls movement; orientation controls the body's rotation.
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "ODMLinearVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.ForceLimitsEnabled = false
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "ODMAlignOrientation"
	alignOrientation.Attachment0 = attachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Enabled = true
	alignOrientation.RigidityEnabled = false
	alignOrientation.Responsiveness = 80
	alignOrientation.MaxTorque = math.huge
	alignOrientation.MaxAngularVelocity = math.huge
	alignOrientation.Parent = root

	odm.AttachmentReference = attachment
	odm.LinearVelocityReference = linearVelocity
	odm.AlignOrientationReference = alignOrientation

	return true
end

------------------------------------------------------------------------------------------------
-- Public methods

function Start(
	player: Player,
	hookSide: ODMTypes.hookSide,
	hookPart: BasePart,
	hookPosition: Vector3
)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM
	local hook = odm.hooks[hookSide]

	-- Reuse existing components while decelerating.
	if not odm.LinearVelocityReference
		or not odm.AlignOrientationReference
		or not odm.AttachmentReference then
		local created = CreateMovementComponents(player)

		if not created then
			ResetHook(player, hookSide)
			return
		end
	end

	hook.active = true
	hook.part = hookPart
	hook.position = hookPosition

	odm.speed = INFO.ODM.Speed
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0

	-- Clear the previous direction to turn toward the new hook.
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	ODMEvent:FireClient(player, "Start", data.references.char, {
		hookSide = hookSide,
		hookPosition = hookPosition,
		hookPart = hookPart,
	})
end

function StartBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	if not HasActiveHook(player) and not data.temp.ODM.decelerating then
		return
	end

	data.temp.ODM.gasBoosting = true
	ODMEvent:FireClient(player, "StartBoost", data.references.char)
end

function SideMovement(
	player: Player,
	sideMovementDirection: ODMTypes.sideMovementDirection
)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	if sideMovementDirection == "Stop" then
		data.temp.ODM.sideMovement = nil
	else
		data.temp.ODM.sideMovement = sideMovementDirection
	end
end

function Decelerate(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	if HasActiveHook(player) then return end
	if odm.decelerating then return end

	local char = data.references.char
	local root = char and char:FindFirstChild("HumanoidRootPart")

	-- Store the actual movement direction when releasing the last hook.
	if root then
		local velocity = root.AssemblyLinearVelocity

		if velocity.Magnitude > 0.001 then
			odm.lastDirectionDecelerating = velocity.Unit
		else
			local look = root.CFrame.LookVector

			odm.lastDirectionDecelerating =
				if look.Magnitude > 0.001
				then look.Unit
				else Vector3.new(0, 0, -1)
		end
	end

	odm.decelerating = true

	ODMEvent:FireClient(player, "Decelerate", data.references.char)
end

function StopHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]
	if not hook.active then return end

	ResetHook(player, hookSide)

	ODMEvent:FireClient(player, "StopHook", data.references.char, {
		hookSide = hookSide,
	})

	-- Continue moving if the other hook is still active.
	if HasActiveHook(player) then return end

	Decelerate(player)
end

function StopBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	data.temp.ODM.gasBoosting = false
	ODMEvent:FireClient(player, "StopBoost", data.references.char)
end

function Stop(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	Reset(player)

	ODMEvent:FireClient(player, "Stop", data.references.char)
end

------------------------------------------------------------------------------------------------
-- Simulation helpers

local function IsCollidableResult(result: RaycastResult?): boolean
	return result ~= nil
		and result.Instance:IsA("BasePart")
		and result.Instance.CanCollide
end

local function GetMovementDirection(
	entitydata: EntityDataTypes.Data,
	root: BasePart
): Vector3?
	local odm = entitydata.temp.ODM

	if odm.decelerating then
		-- Maintain the movement direction from when the last hook was released.
		local direction =
			odm.lastDirectionDecelerating
			or odm.smoothedDirection
			or root.CFrame.LookVector

		return if direction.Magnitude > 0.001
			then direction.Unit
			else Vector3.new(0, 0, -1)
	end

	local hookTargetPosition = GetHookTargetPosition(entitydata)
	if not hookTargetPosition then return nil end

	local difference = hookTargetPosition - root.Position

	return if difference.Magnitude <= 0.001
		then odm.smoothedDirection or root.CFrame.LookVector
		else difference.Unit
end

local function UpdateOrientation(
	entitydata: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3,
	deltaTime: number
)
	local odm = entitydata.temp.ODM
	local alignOrientation = odm.AlignOrientationReference

	-- Smooth sudden changes in direction.
	local previousSmoothed = odm.smoothedDirection or direction
	local smoothAlpha = math.clamp(12 * deltaTime, 0, 1)
	local smoothedDirection = previousSmoothed:Lerp(direction, smoothAlpha)

	smoothedDirection = if smoothedDirection.Magnitude > 0.001
		then smoothedDirection.Unit
		else direction

	odm.smoothedDirection = smoothedDirection

	-- Keep the added falling velocity from affecting the body's orientation.
	local orientationDirection = smoothedDirection

	if orientationDirection.Magnitude <= 0.001 then
		orientationDirection = root.CFrame.LookVector
	end

	orientationDirection = orientationDirection.Unit

	alignOrientation.Enabled = true
	alignOrientation.RigidityEnabled = odm.decelerating
	alignOrientation.CFrame = CFrame.lookAt(
		Vector3.zero,
		orientationDirection,
		Vector3.yAxis
	)
end

local function GetTargetVelocity(
	entitydata: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3
): Vector3
	local odm = entitydata.temp.ODM

	-- Calculate the velocity that pulls the character toward the hook.
	local targetVelocity

	if odm.gasBoosting then
		targetVelocity = direction * (odm.speed * INFO.ODM.GasBoostMultiplier)
	else
		targetVelocity = direction * odm.speed
	end

	-- Apply left or right lateral movement while using ODM.
	if not odm.decelerating and odm.sideMovement ~= nil then
		local sideDirection = root.CFrame.RightVector
		local directionMultiplier =
			if odm.sideMovement == "Left" then -1
			elseif odm.sideMovement == "Right" then 1
			else 0

		targetVelocity += sideDirection
			* INFO.ODM.SideSpeed
			* directionMultiplier
	end

	return targetVelocity
end

local function ApplyDeceleration(
	entitydata: EntityDataTypes.Data,
	root: BasePart,
	humanoid: Humanoid,
	direction: Vector3,
	targetVelocity: Vector3,
	deltaTime: number
): Vector3
	local odm = entitydata.temp.ODM
	local linearVelocity = odm.LinearVelocityReference

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { entitydata.references.char }
	params.IgnoreWater = true

	-- Extend the ground check using the vertical velocity and simulation step.
	local currentFallSpeed = math.abs(linearVelocity.VectorVelocity.Y)
	local groundCheckDistance = 3.5 + currentFallSpeed * deltaTime

	local groundResult = workspace:Raycast(
		root.Position,
		Vector3.new(0, -groundCheckDistance, 0),
		params
	)

	local touchingGround = IsCollidableResult(groundResult)

	if touchingGround then
		odm.touchingGroundTime += deltaTime
	else
		odm.touchingGroundTime = 0
	end

	odm.touchingGround = touchingGround

	if touchingGround then
		-- Remove vertical velocity when grounded.
		local horizontalDirection = Vector3.new(direction.X, 0, direction.Z)

		targetVelocity = if horizontalDirection.Magnitude > 0.001
			then horizontalDirection.Unit * odm.speed
			else Vector3.zero

		humanoid.PlatformStand = false
	else
		-- Increase falling speed as ODM speed decreases.
		local speedPercent = math.clamp(odm.speed / INFO.ODM.Speed, 0, 1)
		local fallSpeed = INFO.ODM.FallSpeed
			* (1 - speedPercent)
			* INFO.ODM.FallMultiplier

		targetVelocity += Vector3.new(0, -fallSpeed, 0)
	end

	return targetVelocity
end

------------------------------------------------------------------------------------------------
-- Simulation connection

RunService.PreSimulation:Connect(function(deltaTime)
	for _, entitydata in pairs(SessionData.Entity.GetAll()) do
		if entitydata.type ~= "player" then continue end

		local odm = entitydata.temp.ODM
		if not odm then continue end

		local leftActive = odm.hooks.Left.active
		local rightActive = odm.hooks.Right.active

		-- Continue updating without active hooks while decelerating.
		if not leftActive and not rightActive and not odm.decelerating then continue end

		local char = entitydata.references.char
		local player = entitydata.references.player

		if not char or not player or player.Parent ~= Players then continue end

		local root = char:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		local linearVelocity = odm.LinearVelocityReference
		local alignOrientation = odm.AlignOrientationReference

		if not root or not root:IsA("BasePart") or not humanoid then continue end
		if not linearVelocity or not alignOrientation then continue end

		-- Update movement speed.
		if odm.decelerating then
			odm.speed = math.max(
				odm.speed - INFO.ODM.Deceleration * deltaTime,
				0
			)
		else
			odm.speed = INFO.ODM.Speed
		end

		local direction = GetMovementDirection(entitydata, root)

		if not direction then
			Decelerate(player)
			continue
		end

		UpdateOrientation(entitydata, root, direction, deltaTime)

		local targetVelocity = GetTargetVelocity(entitydata, root, direction)

		if odm.decelerating then
			targetVelocity = ApplyDeceleration(
				entitydata,
				root,
				humanoid,
				direction,
				targetVelocity,
				deltaTime
			)
		end

		-- Smooth the final velocity after boost, lateral movement and falling.
		linearVelocity.VectorVelocity = linearVelocity.VectorVelocity:Lerp(
			targetVelocity,
			math.clamp(15 * deltaTime, 0, 1)
		)

		if odm.speed <= 0 and odm.touchingGround then
			Stop(player)
		end
	end
end)

