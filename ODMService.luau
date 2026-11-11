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

-- Constants
local MIN_DIRECTION_MAGNITUDE = 0.001
local DEFAULT_LOOK_DIRECTION = Vector3.new(0, 0, -1)
local ORIENTATION_SMOOTHNESS = 12
local VELOCITY_SMOOTHNESS = 15
local GROUND_CHECK_DISTANCE = 3.5

-- Hook helpers

-- Both hooks are stored in the same entity state, allowing the controller
-- to determine whether movement should continue without checking each side separately.
local function HasActiveHook(player: Player): boolean
	local data = SessionData.Entity.Get(player)
	if not data then return false end

	local hooks = data.temp.ODM.hooks

	return hooks.Left.active or hooks.Right.active
end

-- Each hook owns its own anchor information.
-- Clearing only the selected hook prevents releasing one side from affecting the other.
local function ResetHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]

	hook.active = false
	hook.part = nil
	hook.position = nil
end

-- The target changes depending on how many hooks are currently active.
-- When both hooks are active, their midpoint creates a balanced movement direction.
local function GetHookTargetPosition(
	entitydata: EntityDataTypes.Data
): Vector3?
	local hooks = entitydata.temp.ODM.hooks
	local leftHook = hooks.Left
	local rightHook = hooks.Right

	if leftHook.active and rightHook.active then
		return (leftHook.position + rightHook.position) / 2
	end

	if leftHook.active then
		return leftHook.position
	end

	if rightHook.active then
		return rightHook.position
	end

	return nil
end

-- Movement components

-- Restore all temporary movement changes.
-- Keeping cleanup centralized prevents different stop conditions from leaving
-- constraints or Humanoid settings in an inconsistent state.
local function Reset(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local char = data.references.char
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local odm = data.temp.ODM

	ResetHook(player, "Left")
	ResetHook(player, "Right")

	-- Reset the simulation state so a future activation starts independently
	-- from the previous movement session.
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0
	odm.speed = 0
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	-- odm.colliding = false
	-- odm.collisionDirection = nil

	-- Destroy the constraints before their shared attachment.
	-- This avoids keeping physics objects connected to an attachment that no longer exists.
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

	if not humanoid then return end

	-- Restore the default character behavior after removing custom movement control.
	humanoid.AutoRotate = true
	humanoid.PlatformStand = false
	humanoid.JumpHeight = 7.2
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
end

-- Create the physics objects required by the ODM controller.
-- The attachment is shared by both constraints so their reference frame remains consistent.
local function CreateMovementComponents(player: Player): true?
	local data = SessionData.Entity.Get(player)
	if not data then return nil end

	local char = data.references.char
	if not char then return nil end

	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")

	if not root or not humanoid then return nil end

	local odm = data.temp.ODM

	-- The controller handles character rotation and movement directly.
	-- Disabling these Humanoid features prevents Roblox's default behavior
	-- from competing with the custom physics constraints.
	humanoid.AutoRotate = false
	humanoid.PlatformStand = false
	humanoid.JumpHeight = 0
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	local attachment = Instance.new("Attachment")
	attachment.Name = "ODMAttachment"
	attachment.Parent = root

	-- LinearVelocity controls the character's translational movement.
	-- World-relative velocity is used because hook positions are also world-space values.
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "ODMLinearVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.ForceLimitsEnabled = false
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Parent = root

	-- AlignOrientation handles rotation independently from movement.
	-- OneAttachment mode allows the target CFrame to define the desired world direction.
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

	-- Store the references in the entity state.
	-- The simulation reuses these instances instead of searching for them every frame.
	odm.AttachmentReference = attachment
	odm.LinearVelocityReference = linearVelocity
	odm.AlignOrientationReference = alignOrientation

	return true
end

-- Methods

-- Activate a hook and initialize the movement session.
-- Existing components are reused when another hook is activated during deceleration.
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

	-- A complete set of references is required for the simulation to work.
	-- If any component is missing, recreate the movement components.
	local hasComponents = odm.LinearVelocityReference
		and odm.AlignOrientationReference
		and odm.AttachmentReference

	if not hasComponents then
		local created = CreateMovementComponents(player)

		if not created then
			ResetHook(player, hookSide)
			return
		end
	end

	hook.active = true
	hook.part = hookPart
	hook.position = hookPosition

	-- Every new hook activation restores the base movement speed.
	-- It also cancels the previous release phase, allowing movement to resume immediately.
	odm.speed = INFO.ODM.Speed
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0

	-- Discard the previous direction because the new hook may be located
	-- somewhere completely different from the previous movement target.
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	-- The server remains responsible for movement state.
	-- This event only synchronizes the corresponding visual effects with the client.
	ODMEvent:FireClient(player, "Start", data.references.char, {
		hookSide = hookSide,
		hookPosition = hookPosition,
		hookPart = hookPart,
	})
end

-- Enable the gas multiplier while the player is moving or decelerating.
-- Boosting while idle is rejected because there is no active movement to modify.
function StartBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	if not HasActiveHook(player) and not odm.decelerating then
		return
	end

	odm.gasBoosting = true

	ODMEvent:FireClient(player, "StartBoost", data.references.char)
end

-- Store the current lateral input.
-- The simulation reads this value when calculating the final movement velocity.
function SideMovement(
	player: Player,
	sideMovementDirection: ODMTypes.sideMovementDirection
)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	-- Nil represents the absence of lateral input.
	-- This keeps the simulation from applying side movement after the input is released.
	odm.sideMovement = if sideMovementDirection == "Stop"
		then nil
		else sideMovementDirection
end

-- Capture the current movement direction before entering the release phase.
-- This allows the character to preserve its momentum even after the hook target disappears.
local function GetDecelerationDirection(
	root: BasePart
): Vector3
	local velocity = root.AssemblyLinearVelocity

	if velocity.Magnitude > MIN_DIRECTION_MAGNITUDE then
		return velocity.Unit
	end

	-- If the character has almost no velocity, use its facing direction instead.
	-- This prevents normalization of a near-zero velocity vector.
	local lookDirection = root.CFrame.LookVector

	return if lookDirection.Magnitude > MIN_DIRECTION_MAGNITUDE
		then lookDirection.Unit
		else DEFAULT_LOOK_DIRECTION
end

-- Start the release phase after the final hook has been removed.
-- The direction is captured only once so the character does not begin steering
-- toward a hook that is no longer active.
function Decelerate(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	-- Another active hook still provides a valid movement target.
	if HasActiveHook(player) then return end

	-- Prevent repeated calls from restarting the same deceleration phase.
	if odm.decelerating then return end

	local char = data.references.char
	local root = char and char:FindFirstChild("HumanoidRootPart")

	if root then
		odm.lastDirectionDecelerating = GetDecelerationDirection(root)
	end

	odm.decelerating = true

	ODMEvent:FireClient(player, "Decelerate", data.references.char)
end

-- Release one hook without affecting the opposite side.
-- Deceleration only starts when there are no remaining active hooks.
function StopHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]
	if not hook.active then return end

	ResetHook(player, hookSide)

	ODMEvent:FireClient(player, "StopHook", data.references.char, {
		hookSide = hookSide,
	})

	-- The other hook can continue controlling movement independently.
	if HasActiveHook(player) then return end

	Decelerate(player)
end

-- Stop the gas multiplier without releasing either hook.
function StopBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	data.temp.ODM.gasBoosting = false

	ODMEvent:FireClient(player, "StopBoost", data.references.char)
end

-- Fully terminate the movement session and restore normal character control.
-- All cleanup is delegated to Reset so every termination path uses the same logic.
function Stop(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	Reset(player)

	ODMEvent:FireClient(player, "Stop", data.references.char)
end

-- Simulation helpers

-- Only collidable BaseParts should count as valid ground.
-- This prevents non-solid raycast results from stopping the deceleration process.
local function IsCollidableResult(result: RaycastResult?): boolean
	if not result then return false end
	if not result.Instance:IsA("BasePart") then return false end

	return result.Instance.CanCollide
end

-- Resolve the direction used by the movement simulation.
-- During normal movement, the direction points toward the active hook.
-- During deceleration, the previously captured direction is preserved instead.
local function GetMovementDirection(
	entitydata: EntityDataTypes.Data,
	root: BasePart
): Vector3?
	local odm = entitydata.temp.ODM

	if odm.decelerating then
		local direction = odm.lastDirectionDecelerating
			or odm.smoothedDirection
			or root.CFrame.LookVector

		return if direction.Magnitude > MIN_DIRECTION_MAGNITUDE
			then direction.Unit
			else DEFAULT_LOOK_DIRECTION
	end

	local hookTargetPosition = GetHookTargetPosition(entitydata)
	if not hookTargetPosition then return nil end

	local difference = hookTargetPosition - root.Position

	-- When the character is already very close to the target,
	-- reuse its previous direction instead of normalizing a nearly zero vector.
	return if difference.Magnitude <= MIN_DIRECTION_MAGNITUDE
		then odm.smoothedDirection or root.CFrame.LookVector
		else difference.Unit
end

-- Smooth the character's rotation toward the current movement direction.
-- Without interpolation, small changes in the hook target could cause abrupt rotations.
local function UpdateOrientation(
	entitydata: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3,
	deltaTime: number
)
	local odm = entitydata.temp.ODM
	local alignOrientation = odm.AlignOrientationReference

	local previousSmoothed = odm.smoothedDirection or direction
	local smoothAlpha = math.clamp(ORIENTATION_SMOOTHNESS * deltaTime, 0, 1)

	local smoothedDirection = previousSmoothed:Lerp(direction, smoothAlpha)

	smoothedDirection = if smoothedDirection.Magnitude > MIN_DIRECTION_MAGNITUDE
		then smoothedDirection.Unit
		else direction

	odm.smoothedDirection = smoothedDirection

	-- The falling velocity should not affect the character's facing direction.
	-- Orientation is based on the movement direction rather than the final velocity vector.
	local orientationDirection = smoothedDirection

	if orientationDirection.Magnitude <= MIN_DIRECTION_MAGNITUDE then
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

-- Calculate the velocity produced by the active movement modifiers.
-- Boost changes the pull speed, while lateral movement adds velocity perpendicular
-- to the character's facing direction.
local function GetTargetVelocity(
	entitydata: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3
): Vector3
	local odm = entitydata.temp.ODM

	local speedMultiplier = if odm.gasBoosting
		then INFO.ODM.GasBoostMultiplier
		else 1

	local targetVelocity = direction * odm.speed * speedMultiplier

	-- Lateral movement is disabled during deceleration because the character
	-- should preserve its release trajectory instead of accepting new steering input.
	if odm.decelerating or not odm.sideMovement then
		return targetVelocity
	end

	local directionMultiplier = if odm.sideMovement == "Left"
		then -1
		elseif odm.sideMovement == "Right"
		then 1
		else 0

	local sideDirection = root.CFrame.RightVector

	targetVelocity += sideDirection
		* INFO.ODM.SideSpeed
		* directionMultiplier

	return targetVelocity
end

-- Create the raycast configuration used to detect ground contact.
-- Excluding the character prevents its own body parts from being detected as ground.
local function GetGroundRaycastParams(
	char: Model
): RaycastParams
	local params = RaycastParams.new()

	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	params.IgnoreWater = true

	return params
end

-- Calculate how far below the character the ground check should extend.
-- A faster downward movement requires a longer ray so the ground can still be detected
-- between physics updates.
local function GetGroundCheckDistance(
	linearVelocity: LinearVelocity,
	deltaTime: number
): number
	local currentFallSpeed = math.abs(linearVelocity.VectorVelocity.Y)

	return GROUND_CHECK_DISTANCE + currentFallSpeed * deltaTime
end

-- Update the time spent touching the ground.
-- Resetting the timer when contact is lost prevents separate ground contacts
-- from being treated as one continuous landing.
local function UpdateGroundContact(
	odm: EntityDataTypes.Data["temp"]["ODM"],
	touchingGround: boolean,
	deltaTime: number
)
	if not touchingGround then
		odm.touchingGroundTime = 0
	else
		odm.touchingGroundTime += deltaTime
	end

	odm.touchingGround = touchingGround
end

-- Remove the vertical component of the target velocity while grounded.
-- When airborne, gradually increase the falling component as ODM speed decreases.
local function GetDecelerationVelocity(
	odm: EntityDataTypes.Data["temp"]["ODM"],
	direction: Vector3,
	targetVelocity: Vector3,
	touchingGround: boolean
): Vector3
	if touchingGround then
		local horizontalDirection = Vector3.new(direction.X, 0, direction.Z)

		return if horizontalDirection.Magnitude > MIN_DIRECTION_MAGNITUDE
			then horizontalDirection.Unit * odm.speed
			else Vector3.zero
	end

	local speedPercent = math.clamp(odm.speed / INFO.ODM.Speed, 0, 1)

	local fallSpeed = INFO.ODM.FallSpeed
		* (1 - speedPercent)
		* INFO.ODM.FallMultiplier

	return targetVelocity + Vector3.new(0, -fallSpeed, 0)
end

-- Apply the release-specific movement adjustments.
-- Ground detection and velocity composition are kept separate so each calculation
-- can be understood and modified independently.
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
	local char = entitydata.references.char

	local params = GetGroundRaycastParams(char)
	local groundCheckDistance = GetGroundCheckDistance(linearVelocity, deltaTime)

	local groundResult = workspace:Raycast(
		root.Position,
		Vector3.new(0, -groundCheckDistance, 0),
		params
	)

	local touchingGround = IsCollidableResult(groundResult)

	UpdateGroundContact(odm, touchingGround, deltaTime)

	if touchingGround then
		humanoid.PlatformStand = false
	end

	return GetDecelerationVelocity(
		odm,
		direction,
		targetVelocity,
		touchingGround
	)
end

-- Simulation helpers

-- Update the movement speed according to the current movement phase.
-- DeltaTime makes deceleration independent of the server's physics update frequency.
local function UpdateSpeed(
	odm: EntityDataTypes.Data["temp"]["ODM"],
	deltaTime: number
)
	if not odm.decelerating then
		odm.speed = INFO.ODM.Speed
		return
	end

	odm.speed = math.max(
		odm.speed - INFO.ODM.Deceleration * deltaTime,
		0
	)
end

-- Interpolate the actuator's velocity toward the newly calculated target.
-- This prevents abrupt changes when boost, lateral movement, or falling modifiers change.
local function UpdateVelocity(
	linearVelocity: LinearVelocity,
	targetVelocity: Vector3,
	deltaTime: number
)
	local smoothAlpha = math.clamp(VELOCITY_SMOOTHNESS * deltaTime, 0, 1)

	linearVelocity.VectorVelocity = linearVelocity.VectorVelocity:Lerp(
		targetVelocity,
		smoothAlpha
	)
end

-- Validate the entity before allowing it to enter the simulation.
-- The entity can remain in session data briefly after its Player or character is removed.
local function GetSimulationReferences(
	entitydata: EntityDataTypes.Data
): (Player?, BasePart?, Humanoid?, LinearVelocity?, AlignOrientation?)
	local char = entitydata.references.char
	local player = entitydata.references.player

	if not char or not player then
		return nil
	end

	if player.Parent ~= Players then
		return nil
	end

	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")

	if not root or not root:IsA("BasePart") or not humanoid then
		return nil
	end

	local odm = entitydata.temp.ODM
	local linearVelocity = odm.LinearVelocityReference
	local alignOrientation = odm.AlignOrientationReference

	if not linearVelocity or not alignOrientation then
		return nil
	end

	return player, root, humanoid, linearVelocity, alignOrientation
end

-- Process one entity for the current physics step.
-- Separating this from the entity loop keeps the main simulation focused on iteration,
-- while this function handles the complete movement lifecycle of a single player.
local function UpdateEntity(
	entitydata: EntityDataTypes.Data,
	deltaTime: number
)
	if entitydata.type ~= "player" then return end

	local odm = entitydata.temp.ODM
	if not odm then return end

	local hasActiveHook = odm.hooks.Left.active or odm.hooks.Right.active

	-- Idle entities do not need physics calculations.
	-- Decelerating entities remain active even after both hooks have been released.
	if not hasActiveHook and not odm.decelerating then
		return
	end

	local player, root, humanoid, linearVelocity =
		GetSimulationReferences(entitydata)

	if not player or not root or not humanoid or not linearVelocity then
		return
	end

	UpdateSpeed(odm, deltaTime)

	local direction = GetMovementDirection(entitydata, root)

	-- A missing target means normal hook movement can no longer continue.
	-- Decelerate uses the same release process as a manually released final hook.
	if not direction then
		Decelerate(player)
		return
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

	UpdateVelocity(linearVelocity, targetVelocity, deltaTime)

	-- Cleanup is only allowed after the player has stopped and ground contact
	-- has been confirmed. This prevents an airborne player from losing movement control
	-- before the release sequence has finished.
	if odm.speed <= 0 and odm.touchingGround then
		Stop(player)
	end
end

-- Simulation connection

-- PreSimulation runs before physics is calculated.
-- Updating every active entity here keeps velocity and orientation changes synchronized
-- with the physics step instead of relying on a separate frame-based update.
RunService.PreSimulation:Connect(function(deltaTime)
	for _, entitydata in pairs(SessionData.Entity.GetAll()) do
		UpdateEntity(entitydata, deltaTime)
	end
end)
