-- Discord: miranha0 | Roblox: HOMEMARANHA06


------------------------------------------------------------------------------------------------
-- Services

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

------------------------------------------------------------------------------------------------
-- Events

-- Used to synchronize ODM-related visual effects with the owning client.
local ODMEvent = ReplicatedStorage.RE:WaitForChild("ODM")

------------------------------------------------------------------------------------------------
-- Modules

local ODMTypes = require(ServerStorage.Types.ODM)
local EntityDataTypes = require(ServerStorage.Types.EntityData)
local SessionData = require(ServerScriptService.Data.SessionData)
local INFO = require(ServerScriptService.Systems.Modules.INFO)

------------------------------------------------------------------------------------------------
-- Hook helpers

-- Checks whether at least one hook is currently active.
-- This function centralizes the hook-state check so different parts of the controller
-- don't need to repeat the same Left/Right conditions.
local function hasActiveHook(player: Player): boolean
	local data = SessionData.Entity.Get(player)

	if not data then
		return false
	end

	local hooks = data.temp.ODM.hooks

	return hooks.Left.active or hooks.Right.active
end

-- Resets only the requested hook.
-- Keeping this operation separate prevents releasing one hook from accidentally
-- modifying the state of the opposite hook.
-- The hook's part and position must also be cleared because other functions use
-- these references to calculate the movement target.
local function resetHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local hook = data.temp.ODM.hooks[hookSide]

	hook.active = false
	hook.part = nil
	hook.position = nil
end

-- Returns the world-space position the character should move toward.
-- When both hooks are active, the midpoint is used instead of choosing one hook.
-- This produces a balanced movement direction between both anchors.
-- When only one hook is active, its position becomes the movement target.
-- Returning nil means there is no active target and the character should enter
-- the deceleration flow.
local function getHookTargetPosition(
	entityData: EntityDataTypes.Data
): Vector3?
	local hooks = entityData.temp.ODM.hooks

	local leftHook = hooks.Left
	local rightHook = hooks.Right

	if leftHook.active and rightHook.active then
		-- Averaging both world positions prevents one hook from being favored.
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

------------------------------------------------------------------------------------------------
-- Movement components

-- Completely restores the character after ODM movement ends.
-- This function centralizes cleanup so every way of stopping ODM uses the same
-- procedure instead of independently destroying constraints and restoring
-- Humanoid properties.
-- It is important to clear both the Instance references and the temporary state.
-- Otherwise, a later activation could accidentally reuse destroyed constraints
-- or values from a previous movement session.
local function reset(player: Player)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local character = data.references.char
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local odm = data.temp.ODM

	-- Clear both hooks so no previous anchor can affect a future activation.
	resetHook(player, "Left")
	resetHook(player, "Right")

	-- Reset movement state.
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0
	odm.speed = 0

	-- Direction data belongs to the previous movement session.
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	-- odm.colliding = false
	-- odm.collisionDirection = nil

	-- Destroy LinearVelocity first because it directly controls the assembly's movement.
	if odm.LinearVelocityReference then
		odm.LinearVelocityReference:Destroy()
		odm.LinearVelocityReference = nil
	end

	-- Orientation is controlled separately from movement velocity.
	-- It must be destroyed as well to restore normal character rotation.
	if odm.AlignOrientationReference then
		odm.AlignOrientationReference:Destroy()
		odm.AlignOrientationReference = nil
	end

	-- Both constraints use this attachment, so destroy it after destroying the constraints.
	if odm.AttachmentReference then
		odm.AttachmentReference:Destroy()
		odm.AttachmentReference = nil
	end

	if not humanoid then
		return
	end

	-- Restore the Humanoid properties changed when ODM was activated.
	humanoid.AutoRotate = true
	humanoid.PlatformStand = false
	humanoid.JumpHeight = 7.2
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
end

-- Creates the physics objects required by the ODM movement system.
-- This function is separated from Start() because creating Instances and configuring
-- physics constraints is a distinct responsibility from activating a hook.
-- The three references are stored in the ODM state so they can be reused while
-- the character is moving. This avoids creating duplicate constraints every time
-- another hook is activated.
-- LinearVelocity controls the character's movement.
-- AlignOrientation controls the character's rotation.
-- Attachment connects both constraints to the HumanoidRootPart.
local function createMovementComponents(player: Player): true?
	local data = SessionData.Entity.Get(player)

	if not data then
		return nil
	end

	local character = data.references.char

	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if not root or not humanoid then
		return nil
	end

	local odm = data.temp.ODM

	-- Disable default character rotation because AlignOrientation will control facing.
	humanoid.AutoRotate = false

	-- Keep the Humanoid out of PlatformStand while the constraints handle movement.
	humanoid.PlatformStand = false

	-- ODM controls vertical movement, so normal jumping is temporarily disabled.
	humanoid.JumpHeight = 0

	-- Prevent the Humanoid from automatically getting up while using ODM.
	-- This avoids the default GettingUp transition interfering with the custom movement.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	-- A single attachment is shared by both constraints.
	-- This keeps their reference point consistent on the character's root assembly.
	local attachment = Instance.new("Attachment")
	attachment.Name = "ODMAttachment"
	attachment.Parent = root

	-- LinearVelocity controls the character's target velocity.
	-- The target is calculated by the simulation and updated every physics step.
	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "ODMLinearVelocity"
	linearVelocity.Attachment0 = attachment
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.ForceLimitsEnabled = false

	-- World-relative velocity is important because hook positions are world-space positions.
	-- Using Attachment-relative velocity here would change the movement direction
	-- according to the character's rotation.
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.Parent = root

	-- AlignOrientation controls the character's facing direction independently
	-- from LinearVelocity.
	-- Separating movement and rotation allows the character to face its travel
	-- direction without having to use the same vector for both calculations.
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

	-- Store the created references.
	-- The simulation reads these references directly instead of searching for
	-- the constraints by name on every physics step.
	odm.AttachmentReference = attachment
	odm.LinearVelocityReference = linearVelocity
	odm.AlignOrientationReference = alignOrientation

	return true
end

------------------------------------------------------------------------------------------------
-- Public methods

-- Activates a hook and starts or resumes ODM movement.
-- This function is responsible for preparing the movement state and storing
-- the hook's anchor information.
-- It does not calculate the character's velocity directly.
-- The PreSimulation connection handles that continuously.
-- If the character is already using ODM, existing constraints are reused.
-- This is important when activating the second hook because creating another
-- set of constraints would cause multiple physics controllers to affect the character.
function Start(
	player: Player,
	hookSide: ODMTypes.hookSide,
	hookPart: BasePart,
	hookPosition: Vector3
)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local odm = data.temp.ODM
	local hook = odm.hooks[hookSide]

	-- Check whether any required movement component is missing.
	-- All three references must exist before the simulation can safely update movement.
	local componentsMissing =
		not odm.LinearVelocityReference
		or not odm.AlignOrientationReference
		or not odm.AttachmentReference

	if componentsMissing then
		local created = createMovementComponents(player)

		if not created then
			-- Do not leave the hook marked as active if movement components
			-- could not be created for the current character.
			resetHook(player, hookSide)
			return
		end
	end

	-- Store the new anchor information.
	-- These values are later used by getHookTargetPosition().
	hook.active = true
	hook.part = hookPart
	hook.position = hookPosition

	-- Restore the configured movement speed whenever a hook is activated.
	odm.speed = INFO.ODM.Speed

	-- A new hook cancels the previous deceleration phase.
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0

	-- Clear the previous direction so the character can smoothly turn toward the new hook.
	-- Reusing an old direction could cause the character to initially steer toward
	-- an anchor that is no longer relevant.
	odm.smoothedDirection = nil

	-- The saved release direction must not override the newly activated hook.
	odm.lastDirectionDecelerating = nil

	-- The server owns movement state; this event only tells the owning client
	-- to update hook-related visual effects.
	ODMEvent:FireClient(player, "Start", data.references.char, {
		hookSide = hookSide,
		hookPosition = hookPosition,
		hookPart = hookPart,
	})
end

-- Enables the gas boost.
-- Boost is handled as a movement modifier rather than a separate movement system.
-- The PreSimulation loop reads gasBoosting and applies the configured multiplier
-- when calculating the target velocity.
-- It is rejected while idle because there is no active ODM movement to boost.
function StartBoost(player: Player)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local odm = data.temp.ODM

	-- Allow boosting while a hook is active or while the character is still decelerating.
	if not hasActiveHook(player) and not odm.decelerating then
		return
	end

	-- The server-side flag is authoritative.
	odm.gasBoosting = true

	-- Notify the client so it can start boost-related visual effects.
	ODMEvent:FireClient(player, "StartBoost", data.references.char)
end

-- Stores the player's lateral movement input.
-- This function does not apply velocity directly.
-- It only updates the requested direction, which is consumed by
-- getTargetVelocity() during the next physics update.
-- Keeping input state separate from physics calculations prevents input events
-- from having to manage the movement constraints themselves.
function SideMovement(
	player: Player,
	sideMovementDirection: ODMTypes.sideMovementDirection
)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	-- nil represents no lateral input.
	-- This makes it easy for getTargetVelocity() to check whether side movement
	-- should be applied.
	if sideMovementDirection == "Stop" then
		data.temp.ODM.sideMovement = nil
		return
	end

	data.temp.ODM.sideMovement = sideMovementDirection
end

-- Starts the deceleration phase after the final hook is released.
-- The current movement direction is captured before deceleration begins.
-- This is important because the hook target is no longer available after release.
-- Without saving the direction, the character could lose its movement direction
-- or suddenly rotate toward an unrelated fallback direction.
function Decelerate(player: Player)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local odm = data.temp.ODM

	-- Do not decelerate while another hook is still pulling the character.
	if hasActiveHook(player) then
		return
	end

	-- Prevent multiple calls from restarting the same deceleration transition.
	if odm.decelerating then
		return
	end

	local character = data.references.char
	local root = character and character:FindFirstChild("HumanoidRootPart")

	if root then
		-- AssemblyLinearVelocity represents the actual movement of the character,
		-- including the influence of physics.
		local velocity = root.AssemblyLinearVelocity

		if velocity.Magnitude > 0.001 then
			-- Preserve the current momentum direction.
			-- Unit converts the velocity into a direction without its original magnitude.
			odm.lastDirectionDecelerating = velocity.Unit
		else
			-- If the character has almost no velocity, use its facing direction.
			-- This prevents attempting to normalize a nearly zero velocity vector.
			local lookDirection = root.CFrame.LookVector

			odm.lastDirectionDecelerating =
				if lookDirection.Magnitude > 0.001
				then lookDirection.Unit
				else Vector3.new(0, 0, -1)
		end
	end

	-- The simulation now knows that it must gradually reduce movement speed.
	odm.decelerating = true

	-- Notify the client that the final hook has been released.
	-- The server continues handling the actual movement and deceleration.
	ODMEvent:FireClient(player, "Decelerate", data.references.char)
end

-- Releases one hook without necessarily stopping ODM movement.
-- The other hook must remain active if it is still attached.
-- Deceleration should only begin after both hooks have been released.
function StopHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	local hook = data.temp.ODM.hooks[hookSide]

	-- Ignore duplicate release requests.
	if not hook.active then
		return
	end

	-- Clear the selected hook before checking the state of the other one.
	resetHook(player, hookSide)

	-- Tell the client which hook should have its visual effects removed.
	ODMEvent:FireClient(player, "StopHook", data.references.char, {
		hookSide = hookSide,
	})

	-- If the opposite hook is still active, movement must continue.
	if hasActiveHook(player) then
		return
	end

	-- No hooks remain, so preserve current momentum and begin deceleration.
	Decelerate(player)
end

-- Stops the gas boost without releasing any active hook.
-- Boost and hook state are independent.
-- Releasing boost should only remove the speed multiplier, not interrupt movement.
function StopBoost(player: Player)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	data.temp.ODM.gasBoosting = false

	-- Notify the client to stop boost-related visual effects.
	ODMEvent:FireClient(player, "StopBoost", data.references.char)
end

-- Completely stops ODM movement.
-- Unlike StopHook(), this function does not preserve momentum or enter deceleration.
-- It immediately restores normal character control and destroys the physics constraints.
-- Use this for situations where ODM must be forcibly terminated.
function Stop(player: Player)
	local data = SessionData.Entity.Get(player)

	if not data then
		return
	end

	-- Centralized cleanup avoids duplicating constraint destruction and state restoration.
	reset(player)

	-- Notify the client after the server has restored the character.
	ODMEvent:FireClient(player, "Stop", data.references.char)
end

------------------------------------------------------------------------------------------------
-- Simulation helpers

-- Determines whether a raycast result represents a valid ground surface.
-- A raycast hitting something does not automatically mean the character is grounded.
-- The hit must be a collidable BasePart to count as supporting ground.
-- This function keeps that rule consistent wherever ground detection is needed.
local function isCollidableResult(result: RaycastResult?): boolean
	return result ~= nil
		and result.Instance:IsA("BasePart")
		and result.Instance.CanCollide
end

-- Determines the direction in which the character should move.
--
-- There are two movement phases:
--
-- 1. Hook movement:
--    The character moves toward the active hook or the midpoint between both hooks.
--
-- 2. Deceleration:
--    Since the hooks have been released, the saved movement direction is used
--    to preserve the character's momentum.
--
-- Returning nil indicates that no valid movement direction is available.
local function getMovementDirection(
	entityData: EntityDataTypes.Data,
	root: BasePart
): Vector3?
	local odm = entityData.temp.ODM

	if odm.decelerating then
		-- During deceleration, the hook positions are no longer valid movement targets.
		-- Prefer the direction captured when the final hook was released.
		local direction =
			odm.lastDirectionDecelerating
			or odm.smoothedDirection
			or root.CFrame.LookVector

		-- Always return a normalized direction so the configured speed
		-- can be applied independently from the vector's original magnitude.
		return if direction.Magnitude > 0.001
			then direction.Unit
			else Vector3.new(0, 0, -1)
	end

	-- During normal ODM movement, the active hook determines the direction.
	local hookTargetPosition = getHookTargetPosition(entityData)

	if not hookTargetPosition then
		return nil
	end

	-- Subtract the character's position from the target position.
	-- The resulting vector points from the character toward the hook.
	local difference = hookTargetPosition - root.Position

	-- If the character is already almost at the target, normalizing the difference
	-- could produce an unstable direction.
	-- Reuse the previous direction as a fallback to prevent sudden direction changes.
	return if difference.Magnitude <= 0.001
		then odm.smoothedDirection or root.CFrame.LookVector
		else difference.Unit
end

-- Updates the character's facing direction.
-- This function is intentionally separate from velocity calculation.
-- The character's facing direction and movement velocity are related, but they
-- do not need to use exactly the same vector.
-- For example, additional falling velocity should not make the character rotate
-- toward the ground.
-- Direction smoothing also prevents abrupt rotation when the active hook changes.
local function updateOrientation(
	entityData: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3,
	deltaTime: number
)
	local odm = entityData.temp.ODM
	local alignOrientation = odm.AlignOrientationReference

	-- Use the previous smoothed direction as the starting point.
	-- On the first update, use the current direction directly.
	local previousSmoothed = odm.smoothedDirection or direction

	-- Scale interpolation by deltaTime so the smoothing is not tied to a specific frame rate.
	local smoothAlpha = math.clamp(12 * deltaTime, 0, 1)

	-- Blend the previous direction toward the new target direction.
	local smoothedDirection = previousSmoothed:Lerp(direction, smoothAlpha)

	-- Normalize the result because interpolation can produce a vector
	-- whose magnitude is not exactly one.
	smoothedDirection = if smoothedDirection.Magnitude > 0.001
		then smoothedDirection.Unit
		else direction

	-- Save the result for the next physics update.
	odm.smoothedDirection = smoothedDirection

	-- Keep orientation based on the actual movement direction.
	-- Do not include extra falling velocity in this calculation.
	local orientationDirection = smoothedDirection

	if orientationDirection.Magnitude <= 0.001 then
		orientationDirection = root.CFrame.LookVector
	end

	orientationDirection = orientationDirection.Unit

	-- Enable and update the orientation constraint.
	-- CFrame.lookAt creates the desired facing rotation.
	-- The constraint's Attachment0 determines where that rotation is applied.
	alignOrientation.Enabled = true
	alignOrientation.RigidityEnabled = odm.decelerating
	alignOrientation.CFrame = CFrame.lookAt(
		Vector3.zero,
		orientationDirection,
		Vector3.yAxis
	)
end

-- Calculates the target velocity before deceleration-specific adjustments.
--
-- The final velocity is composed of:
-- - Forward movement toward the hook.
-- - Optional gas boost.
-- - Optional lateral movement.
--
-- This function only calculates the desired velocity.
-- LinearVelocity is updated later in the main simulation loop.
local function getTargetVelocity(
	entityData: EntityDataTypes.Data,
	root: BasePart,
	direction: Vector3
): Vector3
	local odm = entityData.temp.ODM

	-- Calculate forward movement.
	-- Boost increases the magnitude without changing the movement direction.
	local targetVelocity = if odm.gasBoosting
		then direction * (odm.speed * INFO.ODM.GasBoostMultiplier)
		else direction * odm.speed

	-- Lateral movement is disabled during deceleration.
	-- Otherwise, an old side input could redirect the character after the hooks
	-- have already been released.
	if odm.decelerating or odm.sideMovement == nil then
		return targetVelocity
	end

	-- RightVector represents the character's local right direction.
	-- This makes lateral movement relative to the character's orientation.
	local sideDirection = root.CFrame.RightVector

	-- Convert the requested side into a signed multiplier.
	-- Left is negative because it points opposite to RightVector.
	local directionMultiplier =
		if odm.sideMovement == "Left" then -1
		elseif odm.sideMovement == "Right" then 1
		else 0

	-- Add lateral velocity instead of replacing forward movement.
	-- This allows the character to move toward the hook while steering sideways.
	targetVelocity += sideDirection
		* INFO.ODM.SideSpeed
		* directionMultiplier

	return targetVelocity
end

-- Applies deceleration-specific movement adjustments.
--
-- This function handles two important situations:
--
-- 1. Grounded:
--    Remove vertical movement and preserve horizontal movement.
--
-- 2. Airborne:
--    Add a controlled downward velocity that increases as ODM speed decreases.
--
-- Ground detection is performed here because it is only required during
-- the deceleration phase.
local function applyDeceleration(
	entityData: EntityDataTypes.Data,
	root: BasePart,
	humanoid: Humanoid,
	direction: Vector3,
	targetVelocity: Vector3,
	deltaTime: number
): Vector3
	local odm = entityData.temp.ODM
	local linearVelocity = odm.LinearVelocityReference

	-- Configure the ground raycast.
	-- The character must be excluded so its own body parts cannot be detected as ground.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { entityData.references.char }
	params.IgnoreWater = true

	-- Extend the ground check based on the current downward velocity and simulation step.
	-- At higher falling speeds, the character can travel farther between physics updates.
	-- Increasing the ray length helps prevent missed ground detection.
	local currentFallSpeed = math.abs(linearVelocity.VectorVelocity.Y)
	local groundCheckDistance = 3.5 + currentFallSpeed * deltaTime

	-- Cast straight down from the root.
	-- The ray direction is independent of character orientation.
	local groundResult = workspace:Raycast(
		root.Position,
		Vector3.new(0, -groundCheckDistance, 0),
		params
	)

	local touchingGround = isCollidableResult(groundResult)

	-- Track how long the character has continuously been touching the ground.
	-- DeltaTime makes this timer independent of the frame rate.
	if touchingGround then
		odm.touchingGroundTime += deltaTime
	else
		-- Reset the timer immediately when ground contact is lost.
		odm.touchingGroundTime = 0
	end

	-- Store the latest ground state so the main simulation can decide when to stop ODM.
	odm.touchingGround = touchingGround

	if touchingGround then
		-- When grounded, remove the vertical component from the movement direction.
		-- This prevents the controller from continuing to request downward movement.
		local horizontalDirection = Vector3.new(
			direction.X,
			0,
			direction.Z
		)

		-- Preserve horizontal movement at the current deceleration speed.
		-- If the direction has no horizontal component, use zero velocity instead.
		targetVelocity = if horizontalDirection.Magnitude > 0.001
			then horizontalDirection.Unit * odm.speed
			else Vector3.zero

		humanoid.PlatformStand = false
	else
		-- Calculate how much of the original ODM speed remains.
		-- Clamping prevents values outside the expected 0-1 range.
		local speedPercent = math.clamp(
			odm.speed / INFO.ODM.Speed,
			0,
			1
		)

		-- As ODM speed decreases, the additional falling speed increases.
		-- This helps the character descend naturally after releasing the hooks.
		local fallSpeed = INFO.ODM.FallSpeed
			* (1 - speedPercent)
			* INFO.ODM.FallMultiplier

		-- Add downward velocity to the movement target.
		-- Orientation is calculated separately, so this does not rotate
		-- the character toward the ground.
		targetVelocity += Vector3.new(0, -fallSpeed, 0)
	end

	return targetVelocity
end

------------------------------------------------------------------------------------------------
-- Simulation connection

-- PreSimulation runs immediately before the physics simulation.
-- This is important because LinearVelocity and AlignOrientation need updated
-- targets before Roblox calculates the next physics step.
--
-- The main loop coordinates the smaller helper functions:
-- 1. Validate the entity and its movement components.
-- 2. Update the current ODM speed.
-- 3. Determine the movement direction.
-- 4. Update character orientation.
-- 5. Calculate target velocity.
-- 6. Apply deceleration adjustments when necessary.
-- 7. Smooth and apply the final velocity.
-- 8. Stop ODM when deceleration is complete and the character is grounded.
RunService.PreSimulation:Connect(function(deltaTime)
	for _, entityData in pairs(SessionData.Entity.GetAll()) do
		-- This controller only handles players.
		-- Other entity types may have their own movement systems.
		if entityData.type ~= "player" then
			continue
		end

		local odm = entityData.temp.ODM

		-- Entities without ODM state do not need to be processed.
		if not odm then
			continue
		end

		local leftActive = odm.hooks.Left.active
		local rightActive = odm.hooks.Right.active

		-- Skip idle entities.
		-- The exception is deceleration: even after both hooks are released,
		-- movement must continue until the character has safely stopped.
		if not leftActive and not rightActive and not odm.decelerating then
			continue
		end

		-- Resolve the current character and player references.
		-- These references come from SessionData rather than being cached globally.
		local character = entityData.references.char
		local player = entityData.references.player

		-- Ignore missing characters and players that have already left the server.
		if not character or not player or player.Parent ~= Players then
			continue
		end

		-- Resolve the instances required by the physics calculations.
		local root = character:FindFirstChild("HumanoidRootPart")
		local humanoid = character:FindFirstChildOfClass("Humanoid")

		-- Reuse the references created by createMovementComponents().
		local linearVelocity = odm.LinearVelocityReference
		local alignOrientation = odm.AlignOrientationReference

		-- Validate the character assembly before performing physics calculations.
		if not root or not root:IsA("BasePart") or not humanoid then
			continue
		end

		-- Both constraints are required.
		-- Updating movement without orientation, or orientation without movement,
		-- would leave the controller in an inconsistent state.
		if not linearVelocity or not alignOrientation then
			continue
		end

		-- Update the current movement speed.
		if odm.decelerating then
			-- Reduce speed according to the configured deceleration rate.
			-- Multiplying by deltaTime makes the reduction independent of frame rate.
			--
			-- math.max prevents speed from becoming negative.
			odm.speed = math.max(
				odm.speed - INFO.ODM.Deceleration * deltaTime,
				0
			)
		else
			-- While at least one hook is active, maintain the configured ODM speed.
			odm.speed = INFO.ODM.Speed
		end

		-- Determine whether movement should follow a hook or preserve release momentum.
		local direction = getMovementDirection(entityData, root)

		if not direction then
			-- No valid movement direction remains.
			-- Use the regular deceleration flow instead of abruptly stopping the character.
			Decelerate(player)
			continue
		end

		-- Update orientation before calculating lateral movement.
		-- getTargetVelocity() uses root.CFrame.RightVector, so it should use
		-- the latest character orientation.
		updateOrientation(entityData, root, direction, deltaTime)

		-- Calculate forward movement, boost and lateral movement.
		local targetVelocity = getTargetVelocity(
			entityData,
			root,
			direction
		)

		-- Apply ground detection and falling behavior only during deceleration.
		if odm.decelerating then
			targetVelocity = applyDeceleration(
				entityData,
				root,
				humanoid,
				direction,
				targetVelocity,
				deltaTime
			)
		end

		-- Smooth the final velocity after all movement modifiers have been applied.
		--
		-- This prevents abrupt changes when:
		-- - Boost starts or ends.
		-- - Lateral movement changes.
		-- - The hook target changes.
		-- - Additional falling velocity is applied.
		--
		-- The interpolation factor is scaled by deltaTime and clamped to prevent
		-- overshooting the target during unusually large physics steps.
		linearVelocity.VectorVelocity =
			linearVelocity.VectorVelocity:Lerp(
				targetVelocity,
				math.clamp(15 * deltaTime, 0, 1)
			)

		-- Only stop when both conditions are satisfied:
		-- 1. ODM speed has reached zero.
		-- 2. The ground raycast confirms that the character is touching ground.
		--
		-- This prevents the character from being stopped in mid-air just because
		-- its horizontal movement speed has reached zero.
		if odm.speed <= 0 and odm.touchingGround then
			Stop(player)
		end
	end
end)
