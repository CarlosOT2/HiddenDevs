-- Discord: miranha0 | Roblox: HOMEMARANHA06

-- Services
local Players = game:GetService("Players") -- Used to validate whether a player is still connected before updating their character.
local RunService = game:GetService("RunService") -- PreSimulation updates movement immediately before the physics engine simulates the next frame.
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Contains the RemoteEvent used to notify clients about ODM visual effects.
local ServerScriptService = game:GetService("ServerScriptService") -- Stores authoritative session data and server-side systems.
local ServerStorage = game:GetService("ServerStorage") -- Holds server-only modules, including type definitions that should not replicate to clients.

-- Event
local ODMEvent = ReplicatedStorage.RE:WaitForChild("ODM") -- Wait until the RemoteEvent is available before initializing the controller.

-- Modules
local ODMTypes = require(ServerStorage.Types.ODM) -- Defines the valid hook-side and lateral-movement types used by this controller.
local EntityDataTypes = require(ServerStorage.Types.EntityData) -- Defines the entity-data structure consumed by the ODM helpers and simulation.
local SessionData = require(ServerScriptService.Data.SessionData) -- Provides the authoritative character references and temporary ODM state for each entity.
local INFO = require(ServerScriptService.Systems.Modules.INFO) -- Centralizes movement configuration so gameplay values can be adjusted independently of the simulation.

------------------------------------------------------------------------------------------------
-- Hook helpers

local function HasActiveHook(player: Player): boolean -- Checks whether either hook is active, keeping hook-state validation consistent across the controller.
	local data = SessionData.Entity.Get(player) -- Retrieve the current entity record instead of relying on a potentially outdated reference.
	if not data then return false end

	local hooks = data.temp.ODM.hooks -- Hook activation state is stored in temporary session data rather than persistent player data.
	return hooks.Left.active or hooks.Right.active
end

local function ResetHook(player: Player, hookSide: ODMTypes.hookSide) -- Clears one hook without affecting the state of the opposite hook.
	local data = SessionData.Entity.Get(player) -- Resolve the current entity record because the character or session may have changed.
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide] -- Use the hook-side type to access either hook through the same cleanup logic.

	hook.active = false -- Mark the hook as inactive so it is no longer considered by movement calculations.
	hook.part = nil -- Remove the anchored part reference to prevent stale references from being reused.
	hook.position = nil -- Clear the world-space anchor position along with its associated part.
end

local function GetHookTargetPosition( -- Returns the movement target based on the active hooks, or nil when no hook is attached.
	entitydata: EntityDataTypes.Data
): Vector3?
	local leftHook = entitydata.temp.ODM.hooks.Left -- Keep both hook records available to determine whether movement should use one anchor or their midpoint.
	local rightHook = entitydata.temp.ODM.hooks.Right

	if leftHook.active and rightHook.active then -- When both hooks are active, use their midpoint to calculate a balanced movement direction.
		return (leftHook.position + rightHook.position) / 2 -- Averaging both world-space positions prevents either anchor from being favored.
	end

	if leftHook.active then return leftHook.position end -- With only the left hook active, its anchor becomes the movement target.
	if rightHook.active then return rightHook.position end -- With only the right hook active, use its anchor instead.

	return nil -- A nil target indicates that no active hook can provide a movement direction.
end

------------------------------------------------------------------------------------------------
-- Movement components

local function Reset(player: Player) -- Clears the ODM state, destroys its physics constraints, and restores the character's default movement settings.
	local data = SessionData.Entity.Get(player) -- Cleanup must tolerate missing session data because it may run during player or character removal.
	if not data then return end

	local char = data.references.char -- Retrieve the character from the entity's stored references.
	local humanoid = char and char:FindFirstChildOfClass("Humanoid") -- Restore Humanoid properties only when the current character still has a Humanoid.
	local odm = data.temp.ODM -- Keep all movement-related state under the entity's ODM data.

	ResetHook(player, "Left") -- Clear the left hook and its associated anchor information.
	ResetHook(player, "Right") -- Clear the right hook to ensure neither anchor survives the reset.

	odm.decelerating = false -- End the release phase so the next activation starts with a clean movement state.
	odm.touchingGround = false -- Clear the previous ground-contact result.
	odm.touchingGroundTime = 0 -- Reset the duration of continuous ground contact.
	odm.speed = 0 -- Remove any remaining movement speed from the previous activation.
	odm.smoothedDirection = nil -- Discard the previous steering direction so it cannot influence a future activation.
	odm.lastDirectionDecelerating = nil -- Clear the saved momentum direction because it is only valid during the current release phase.

	-- odm.colliding = false
	-- odm.collisionDirection = nil

	if odm.LinearVelocityReference then -- Destroy the velocity actuator before clearing its reference.
		odm.LinearVelocityReference:Destroy()
		odm.LinearVelocityReference = nil
	end

	if odm.AlignOrientationReference then -- Destroy the orientation actuator independently from the velocity actuator.
		odm.AlignOrientationReference:Destroy()
		odm.AlignOrientationReference = nil
	end

	if odm.AttachmentReference then -- Destroy the shared attachment after both constraints have been removed.
		odm.AttachmentReference:Destroy()
		odm.AttachmentReference = nil
	end

	if humanoid then -- Restore character settings only when the Humanoid is still available.
		humanoid.AutoRotate = true -- Return rotation control to the default Humanoid controller.
		humanoid.PlatformStand = false -- Restore normal Humanoid movement behavior.
		humanoid.JumpHeight = 7.2 -- Restore the default jump height after ODM disables jumping.
		humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true) -- Allow the character to recover normally after ODM movement ends.
	end
end

local function CreateMovementComponents(player: Player): true? -- Creates the physics constraints required by ODM and stores their references for reuse.
	local data = SessionData.Entity.Get(player) -- Resolve the current entity so the constraints are created for its active character.
	if not data then return nil end

	local char = data.references.char -- A valid character is required before creating any movement components.
	if not char then return nil end

	local root = char:FindFirstChild("HumanoidRootPart") -- Both constraints operate on the character's root assembly.
	local humanoid = char:FindFirstChildOfClass("Humanoid")

	if not root or not humanoid then return nil end -- Validate all required character components before changing settings or creating instances.

	local odm = data.temp.ODM -- Store the created instances in the same state table consumed by the simulation.

	humanoid.AutoRotate = false -- Disable automatic rotation because AlignOrientation controls the character's facing direction.
	humanoid.PlatformStand = false -- Keep the Humanoid out of PlatformStand while physics constraints control movement.
	humanoid.JumpHeight = 0 -- Disable normal jumping because ODM controls vertical movement while active.

	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false) -- Prevent the default getting-up transition from interfering with ODM movement.

	local attachment = Instance.new("Attachment") -- Both constraints share one attachment on the root assembly.
	attachment.Name = "ODMAttachment"
	attachment.Parent = root

	local linearVelocity = Instance.new("LinearVelocity") -- Controls the character's translational velocity independently of its orientation.
	linearVelocity.Name = "ODMLinearVelocity"
	linearVelocity.Attachment0 = attachment -- Apply the constraint through the root attachment rather than using a world-relative attachment.
	linearVelocity.VectorVelocity = Vector3.zero -- Initialize the target velocity at zero to avoid inheriting an unintended movement target.
	linearVelocity.ForceLimitsEnabled = false -- Remove the configured force limit so the constraint can reach its requested velocity.
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World -- Use world-space velocity because hook positions and movement directions are also calculated in world space.
	linearVelocity.Parent = root

	local alignOrientation = Instance.new("AlignOrientation") -- Controls character rotation separately from its movement velocity.
	alignOrientation.Name = "ODMAlignOrientation"
	alignOrientation.Attachment0 = attachment -- Use the same attachment as LinearVelocity so both constraints act on the same assembly.
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment -- OneAttachment mode allows the target orientation to be specified directly through CFrame.
	alignOrientation.Enabled = true
	alignOrientation.RigidityEnabled = false -- Allow the physics solver to rotate the character smoothly instead of forcing an immediate alignment.
	alignOrientation.Responsiveness = 80 -- Determines how quickly the character follows the target orientation.
	alignOrientation.MaxTorque = math.huge -- Remove the practical torque limit so the constraint can maintain the requested orientation.
	alignOrientation.MaxAngularVelocity = math.huge -- Remove the angular velocity limit to avoid restricting rapid changes in facing direction.
	alignOrientation.Parent = root

	odm.AttachmentReference = attachment -- Retain the shared attachment so Reset() can destroy it after removing both constraints.
	odm.LinearVelocityReference = linearVelocity -- The simulation updates this actuator to control the character's movement.
	odm.AlignOrientationReference = alignOrientation -- The simulation updates this actuator to control the character's facing direction.

	return true
end

------------------------------------------------------------------------------------------------
-- Methods

function Start( -- Activates a hook and initializes the movement state without affecting the opposite hook.
	player: Player,
	hookSide: ODMTypes.hookSide,
	hookPart: BasePart,
	hookPosition: Vector3
)
	local data = SessionData.Entity.Get(player) -- Retrieve the authoritative entity record used by the movement simulation.
	if not data then return end

	local odm = data.temp.ODM -- Keep a local reference to the current ODM state.
	local hook = odm.hooks[hookSide] -- Resolve the selected hook using its typed side.

	if not odm.LinearVelocityReference -- Reuse existing components during an active session; create them only when the required references are missing.
		or not odm.AlignOrientationReference
		or not odm.AttachmentReference then
		local created = CreateMovementComponents(player) -- Create the attachment and constraints when this activation requires them.

		if not created then -- Abort activation if the character does not have the components required for ODM movement.
			ResetHook(player, hookSide)
			return
		end
	end

	hook.active = true -- Activate the hook after the movement components have been successfully created.
	hook.part = hookPart -- Store the part hit by the hook.
	hook.position = hookPosition -- Store the exact world-space anchor position used to calculate the movement direction.

	odm.speed = INFO.ODM.Speed -- Restore the configured base speed whenever a hook is activated.
	odm.decelerating = false -- Cancel any previous release phase because an active hook now provides a movement target.
	odm.touchingGround = false -- Reset ground contact for the new hook movement phase.
	odm.touchingGroundTime = 0 -- Reset the continuous ground-contact timer.

	odm.smoothedDirection = nil -- Discard the previous steering direction so the new hook can establish its own direction.
	odm.lastDirectionDecelerating = nil -- Clear the previous release direction because the character is no longer decelerating.

	ODMEvent:FireClient(player, "Start", data.references.char, { -- Notify the owning client about the hook activation; this event is for visual presentation only, while the server controls movement and physics.
		hookSide = hookSide, -- Identifies which hook the client should display.
		hookPosition = hookPosition, -- Provides the anchor position needed to align the client's visual effects.
		hookPart = hookPart, -- Provides the hit part for visual effects that reference the anchored instance.
	})
end

function StartBoost(player: Player) -- Activates the server-side boost state while ODM movement is active.
	local data = SessionData.Entity.Get(player)
	if not data then return end

	if not HasActiveHook(player) and not data.temp.ODM.decelerating then -- Reject boost requests when there is no active hook or ongoing release movement.
		return
	end

	data.temp.ODM.gasBoosting = true -- Store boost state on the server because GetTargetVelocity() uses it to calculate the actual movement speed.
	ODMEvent:FireClient(player, "StartBoost", data.references.char) -- Notify the client to display boost effects; the server remains responsible for the movement speed.
end

function SideMovement( -- Updates the player's lateral movement input, which is consumed by the simulation.
	player: Player,
	sideMovementDirection: ODMTypes.sideMovementDirection
)
	local data = SessionData.Entity.Get(player) -- Resolve the current entity before modifying its movement state.
	if not data then return end

	if sideMovementDirection == "Stop" then -- Represent stopped lateral input as nil so the simulation can distinguish it from either direction.
		data.temp.ODM.sideMovement = nil
	else
		data.temp.ODM.sideMovement = sideMovementDirection -- Store the latest lateral input until it is replaced by another update.
	end
end

function Decelerate(player: Player) -- Starts the release phase after the character no longer has an active hook.
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	if HasActiveHook(player) then return end -- Do not begin deceleration while the opposite hook is still active.
	if odm.decelerating then return end -- Prevent multiple calls from restarting or overwriting an existing release phase.

	local char = data.references.char -- Read the character's current assembly velocity to preserve its actual movement direction.
	local root = char and char:FindFirstChild("HumanoidRootPart")

	if root then -- Capture the current movement direction before the final hook is released from the simulation.
		local velocity = root.AssemblyLinearVelocity

		if velocity.Magnitude > 0.001 then -- Use the assembly velocity when it is large enough to provide a reliable direction.
			odm.lastDirectionDecelerating = velocity.Unit -- Preserve the current momentum direction for the release phase.
		else
			local look = root.CFrame.LookVector -- Use the character's facing direction when its current velocity is nearly zero.

			odm.lastDirectionDecelerating = -- Provide a valid fallback direction so subsequent movement calculations never receive a zero vector.
				if look.Magnitude > 0.001
				then look.Unit
			else Vector3.new(0, 0, -1) -- Use a fixed world direction as a final fallback.
			end
		end

		odm.decelerating = true -- Switch the simulation to the release phase, where speed is gradually reduced.

		ODMEvent:FireClient(player, "Decelerate", data.references.char) -- Notify the client to update hook-related effects; server-side physics continues independently.
	end

	function StopHook(player: Player, hookSide: ODMTypes.hookSide) -- Releases the selected hook and starts deceleration only when no other hook remains active.
		local data = SessionData.Entity.Get(player)
		if not data then return end

		local hook = data.temp.ODM.hooks[hookSide] -- Resolve the requested hook without modifying the opposite side.
		if not hook.active then return end -- Ignore duplicate release requests when the selected hook is already inactive.

		ResetHook(player, hookSide) -- Clear the server-side hook state before checking whether another hook is still active.

		ODMEvent:FireClient(player, "StopHook", data.references.char, { -- Notify the client so it can remove the visual associated with the released hook.
			hookSide = hookSide, -- Identify the hook whose visual representation should be removed.
		})

		if HasActiveHook(player) then return end -- Keep movement active while the opposite hook continues providing a target.

		Decelerate(player) -- Enter the release phase only after both hooks have been released.
	end

	function StopBoost(player: Player) -- Disables boost without changing the current hook or deceleration state.
		local data = SessionData.Entity.Get(player)
		if not data then return end

		data.temp.ODM.gasBoosting = false -- Clear the authoritative boost flag before notifying the client.
		ODMEvent:FireClient(player, "StopBoost", data.references.char) -- Notify the client to stop boost effects; the server immediately uses normal movement speed.
	end

	function Stop(player: Player) -- Ends the ODM session and restores the character to its normal movement state.
		local data = SessionData.Entity.Get(player)
		if not data then return end

		Reset(player) -- Centralize state cleanup, constraint destruction, and Humanoid restoration in one function.

		ODMEvent:FireClient(player, "Stop", data.references.char) -- Notify the client after server cleanup so visual state follows the authoritative movement state.
	end

	------------------------------------------------------------------------------------------------
	-- Simulation helpers

	local function IsCollidableResult(result: RaycastResult?): boolean -- Determines whether a raycast hit qualifies as ground for the release simulation.
		return result ~= nil -- A missing result means the ray did not hit a surface.
			and result.Instance:IsA("BasePart") -- Only BasePart instances are accepted by this ground-contact check.
			and result.Instance.CanCollide -- Non-collidable parts must not be treated as surfaces that can support the character.
	end

	local function GetMovementDirection( -- Returns the active hook direction or the saved momentum direction during deceleration.
		entitydata: EntityDataTypes.Data,
		root: BasePart
	): Vector3?
		local odm = entitydata.temp.ODM

		if odm.decelerating then -- During release, movement must preserve momentum instead of following an anchor that is no longer active.
			local direction = -- Prefer the direction captured when the last hook was released, with smoothed and facing directions as fallbacks.
				odm.lastDirectionDecelerating
				or odm.smoothedDirection
				or root.CFrame.LookVector

			return if direction.Magnitude > 0.001 -- Ensure the returned direction is normalized before applying movement speed.
				then direction.Unit
				else Vector3.new(0, 0, -1) -- Prevent a zero-length direction from reaching the movement and orientation calculations.
		end

		local hookTargetPosition = GetHookTargetPosition(entitydata) -- Retrieve the active hook position or the midpoint between both active hooks.
		if not hookTargetPosition then return nil end -- No active target means there is no valid hook-based movement direction.

		local difference = hookTargetPosition - root.Position -- Calculate the direction from the character's root toward the hook target.

		return if difference.Magnitude <= 0.001 -- Avoid normalizing an almost-zero vector when the character is already at the target position.
			then odm.smoothedDirection or root.CFrame.LookVector -- Preserve the previous direction to prevent sudden changes when both positions nearly overlap.
			else difference.Unit -- Return a normalized direction so the configured speed controls the final velocity magnitude.
	end

	local function UpdateOrientation( -- Smoothly aligns the character with its movement direction without coupling rotation to vertical falling velocity.
		entitydata: EntityDataTypes.Data,
		root: BasePart,
		direction: Vector3,
		deltaTime: number
	)
		local odm = entitydata.temp.ODM -- Store the smoothed direction in ODM state so it can be reused by subsequent simulation steps.
		local alignOrientation = odm.AlignOrientationReference -- Use the orientation constraint created for the character's root assembly.

		local previousSmoothed = odm.smoothedDirection or direction -- Use the current direction on the first update; otherwise continue from the previous smoothed direction.
		local smoothAlpha = math.clamp(12 * deltaTime, 0, 1) -- Scale interpolation by deltaTime to keep the smoothing behavior consistent across frame rates.
		local smoothedDirection = previousSmoothed:Lerp(direction, smoothAlpha) -- Gradually blend toward the new direction to avoid abrupt character rotation.

		smoothedDirection = if smoothedDirection.Magnitude > 0.001 -- Normalize the interpolated direction before using it as the orientation target.
			then smoothedDirection.Unit
			else direction

		odm.smoothedDirection = smoothedDirection -- Preserve the result so the next update continues from the current orientation direction.

		local orientationDirection = smoothedDirection -- Keep facing direction independent from the additional downward velocity used during falling.

		if orientationDirection.Magnitude <= 0.001 then -- Protect CFrame.lookAt from receiving an invalid zero-length direction.
			orientationDirection = root.CFrame.LookVector -- Fall back to the character's current facing direction.
		end

		orientationDirection = orientationDirection.Unit -- Normalize the final direction before constructing the target orientation.

		alignOrientation.Enabled = true -- Ensure the orientation constraint is active during the movement update.
		alignOrientation.RigidityEnabled = odm.decelerating -- Use rigid alignment during release to maintain the saved momentum-facing direction.
		alignOrientation.CFrame = CFrame.lookAt( -- Construct the target rotation using the movement direction and world up vector.
			Vector3.zero, -- The constraint uses the attachment position, so only the target rotation is relevant here.
			orientationDirection, -- The character faces along its current smoothed movement direction.
			Vector3.yAxis -- Keep the world Y axis as the up direction.
		)
	end

	local function GetTargetVelocity( -- Builds the target velocity by combining hook movement with boost and optional lateral movement.
		entitydata: EntityDataTypes.Data,
		root: BasePart,
		direction: Vector3
	): Vector3
		local odm = entitydata.temp.ODM -- Read the movement modifiers from the entity's authoritative ODM state.

		local targetVelocity -- Build the base movement velocity first, then apply the relevant movement modifiers.

		if odm.gasBoosting then -- Apply the boost multiplier only when the server-side boost state is active.
			targetVelocity = direction * (odm.speed * INFO.ODM.GasBoostMultiplier) -- Increase velocity magnitude without changing the movement direction.
		else
			targetVelocity = direction * odm.speed -- Use the current ODM speed when boost is inactive.
		end

		if not odm.decelerating and odm.sideMovement ~= nil then -- Allow lateral movement while attached, but prevent it from redirecting momentum during release.
			local sideDirection = root.CFrame.RightVector -- Use the character's current right vector to calculate movement relative to its orientation.
			local directionMultiplier = -- Convert the requested side into a signed multiplier for the lateral velocity.
				if odm.sideMovement == "Left" then -1 -- Negative RightVector produces movement toward the character's left.
			elseif odm.sideMovement == "Right" then 1 -- Positive RightVector produces movement toward the character's right.
			else 0 -- Apply no lateral velocity for any other value.

				targetVelocity += sideDirection -- Add lateral movement to the hook-directed velocity instead of replacing it.
					* INFO.ODM.SideSpeed
					* directionMultiplier
			end

			return targetVelocity
		end

		local function ApplyDeceleration( -- Adjusts release velocity according to ground contact and the character's current movement speed.
			entitydata: EntityDataTypes.Data,
			root: BasePart,
			humanoid: Humanoid,
			direction: Vector3,
			targetVelocity: Vector3,
			deltaTime: number
		): Vector3
			local odm = entitydata.temp.ODM -- Access the current release state and the velocity actuator used by the main simulation.
			local linearVelocity = odm.LinearVelocityReference

			local params = RaycastParams.new() -- Configure a ground query that ignores the character's own assembly.
			params.FilterType = Enum.RaycastFilterType.Exclude -- Exclude the character so its body parts cannot be detected as ground.
			params.FilterDescendantsInstances = { entitydata.references.char } -- Only the current character is excluded from the raycast.
			params.IgnoreWater = true -- Do not consider water a supporting surface for this ground check.

			local currentFallSpeed = math.abs(linearVelocity.VectorVelocity.Y) -- Read the current vertical velocity to estimate the character's downward movement.
			local groundCheckDistance = 3.5 + currentFallSpeed * deltaTime -- Extend the ray according to the expected vertical movement during this simulation step.

			local groundResult = workspace:Raycast( -- Cast downward from the root to check for a collidable surface beneath the character.
				root.Position, -- Use the root position as the origin of the ground check.
				Vector3.new(0, -groundCheckDistance, 0), -- Cast along the negative world Y axis.
				params -- Apply the character exclusion and water settings.
			)

			local touchingGround = IsCollidableResult(groundResult) -- Apply the controller's ground-contact rules to the raycast result.

			if touchingGround then -- Accumulate contact time while the character continuously detects a supporting surface.
				odm.touchingGroundTime += deltaTime -- Use deltaTime so the timer measures elapsed time rather than frame count.
			else
				odm.touchingGroundTime = 0 -- Reset the timer when contact is interrupted.
			end

			odm.touchingGround = touchingGround -- Store the latest ground-contact state for the simulation's stop condition.

			if touchingGround then -- Remove vertical movement while the character is touching the ground.
				local horizontalDirection = Vector3.new(direction.X, 0, direction.Z) -- Preserve only the horizontal components of the movement direction.

				targetVelocity = if horizontalDirection.Magnitude > 0.001 -- Rebuild the target velocity using the horizontal direction and current deceleration speed.
					then horizontalDirection.Unit * odm.speed
					else Vector3.zero -- Avoid producing an invalid direction when the movement is almost entirely vertical.

				humanoid.PlatformStand = false -- Keep the Humanoid out of PlatformStand while grounded movement is handled by the constraints.
			else
				local speedPercent = math.clamp(odm.speed / INFO.ODM.Speed, 0, 1) -- Normalize current speed against the configured base speed and constrain the result to a valid ratio.
				local fallSpeed = INFO.ODM.FallSpeed -- Start with the configured falling-speed value.
					* (1 - speedPercent) -- Increase the falling contribution as ODM speed decreases.
					* INFO.ODM.FallMultiplier -- Apply the configurable multiplier to tune the falling behavior independently.

				targetVelocity += Vector3.new(0, -fallSpeed, 0) -- Add downward velocity without changing the direction used by the orientation controller.
			end

			return targetVelocity -- Return the adjusted velocity so the main simulation can apply its final interpolation.
		end

		------------------------------------------------------------------------------------------------
		-- Simulation connection

		RunService.PreSimulation:Connect(function(deltaTime) -- Update the ODM actuators before each physics step so the engine simulates using the latest target velocity.
			for _, entitydata in pairs(SessionData.Entity.GetAll()) do -- Iterate through session entities because this controller operates on the entity-data structure.
				if entitydata.type ~= "player" then continue end -- Skip non-player entities because they may use a different movement controller.

				local odm = entitydata.temp.ODM -- Retrieve the entity's temporary ODM state.
				if not odm then continue end -- Ignore entities that do not have ODM state initialized.

				local leftActive = odm.hooks.Left.active -- Cache both hook states to determine whether this entity requires an ODM simulation update.
				local rightActive = odm.hooks.Right.active

				if not leftActive and not rightActive and not odm.decelerating then continue end -- Skip idle entities; continue updating after hook release only while deceleration is active.

				local char = entitydata.references.char -- Retrieve the current character from the entity's stored references.
				local player = entitydata.references.player -- Retrieve the player associated with this entity.

				if not char or not player or player.Parent ~= Players then continue end -- Skip entities whose character is missing or whose player has left the server.

				local root = char:FindFirstChild("HumanoidRootPart") -- Resolve the root each step to avoid using a stale reference after character replacement.
				local humanoid = char:FindFirstChildOfClass("Humanoid") -- The Humanoid is required for grounded movement adjustments.
				local linearVelocity = odm.LinearVelocityReference -- Reuse the velocity actuator stored during component creation.
				local alignOrientation = odm.AlignOrientationReference -- Reuse the orientation actuator stored during component creation.

				if not root or not root:IsA("BasePart") or not humanoid then continue end -- Validate the character components before running the movement calculations.
				if not linearVelocity or not alignOrientation then continue end -- Both actuators are required to keep movement and orientation synchronized.

				if odm.decelerating then -- Reduce speed over elapsed time while the character is in the release phase.
					odm.speed = math.max( -- Prevent the calculated speed from becoming negative.
						odm.speed - INFO.ODM.Deceleration * deltaTime, -- Apply the configured deceleration rate independently of the frame rate.
						0 -- Zero is the minimum allowed movement speed.
					)
				else
					odm.speed = INFO.ODM.Speed -- Maintain the configured base speed while at least one hook is active.
				end

				local direction = GetMovementDirection(entitydata, root) -- Resolve the movement direction from the active hooks or saved release momentum.

				if not direction then -- A missing direction indicates that no valid movement target is available.
					Decelerate(player) -- Reuse the normal release transition so the current momentum can be preserved.
					continue
				end

				UpdateOrientation(entitydata, root, direction, deltaTime) -- Update facing before calculating lateral movement because it depends on the root's current RightVector.

				local targetVelocity = GetTargetVelocity(entitydata, root, direction) -- Combine the primary movement direction with the active movement modifiers.

				if odm.decelerating then -- Apply ground detection and falling behavior only during the release phase.
					targetVelocity = ApplyDeceleration( -- Adjust the target velocity before sending it to the LinearVelocity actuator.
						entitydata, -- Provides access to the character references and temporary ODM state.
						root, -- Supplies the root position used by the ground raycast.
						humanoid, -- Allows grounded movement to update the Humanoid's physical state.
						direction, -- Supplies the current movement direction for horizontal velocity calculations.
						targetVelocity, -- Passes the composed velocity so the helper can apply release-specific adjustments.
						deltaTime -- Scales ground detection and contact timing to the current simulation step.
					)
				end

				linearVelocity.VectorVelocity = linearVelocity.VectorVelocity:Lerp( -- Smooth the final target velocity after all movement modifiers have been applied.
					targetVelocity, -- The fully composed velocity that the actuator should approach.
					math.clamp(15 * deltaTime, 0, 1) -- Clamp interpolation to prevent overshooting during unusually large simulation steps.
				)

				if odm.speed <= 0 and odm.touchingGround then -- End the session only when deceleration is complete and ground contact has been confirmed.
					Stop(player) -- Restore Humanoid settings, clear ODM state, and destroy the movement constraints.
				end
			end
end)
