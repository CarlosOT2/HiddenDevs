-- Discord: miranha0 | Roblox: HOMEMARANHA06

-- Services
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
-- Modules
local SessionData = require(ServerScriptService.Data.SessionData)
local INFO = require(ServerScriptService.Systems.Modules.INFO)
local EntityDataTypes = require(ServerStorage.Types.EntityData)
local ODMMovement = require(ServerScriptService.Systems.Modules.ODM.Movement)


local function IsCollidableResult(result: RaycastResult?): boolean
	return result ~= nil and result.Instance:IsA("BasePart") and result.Instance.CanCollide
end

local function GetHookTargetPosition(entitydata: EntityDataTypes.Data): Vector3?
	local leftHook = entitydata.temp.ODM.hooks.Left
	local rightHook = entitydata.temp.ODM.hooks.Right

	if leftHook.active and rightHook.active then
		-- With two hooks, uses the midpoint between them.
		return (leftHook.position + rightHook.position) / 2
	end

	if leftHook.active then return leftHook.position end
	if rightHook.active then return rightHook.position end

	return nil
end

RunService.PreSimulation:Connect(function(deltaTime)
	for _, entitydata in pairs(SessionData.Entity.GetAll()) do
		if entitydata.type ~= "player" then continue end

		local odm = entitydata.temp.ODM
		local leftActive = odm.hooks.Left.active
		local rightActive = odm.hooks.Right.active

		-- Continues updating without hooks while decelerating.
		if not leftActive and not rightActive and not odm.decelerating then continue end

		local char = entitydata.references.char
		local player = entitydata.references.player

		local root = char:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		local linearVelocity = odm.LinearVelocityReference
		local alignOrientation = odm.AlignOrientationReference

		if not root or not humanoid or not linearVelocity or not alignOrientation then continue end

		local hasActiveHook = odm.hooks.Left.active or odm.hooks.Right.active
		if not hasActiveHook and not odm.decelerating then
			ODMMovement.Decelerate(player)
			continue
		end
		
		-- Updates the speed.
		if odm.decelerating then
			odm.speed = math.max(
                odm.speed - INFO.ODM.Deceleration * deltaTime, 
                0
            )
		else
			odm.speed = INFO.ODM.Speed
		end

		local direction: Vector3

		if odm.decelerating then
			-- Maintains the direction the player had when releasing the last hook.
			direction =
				odm.lastDirectionDecelerating
				or odm.smoothedDirection
				or root.CFrame.LookVector

			direction = if direction.Magnitude > 0.001
				then direction.Unit
				else Vector3.new(0, 0, -1)
		else
			local hookTargetPosition = GetHookTargetPosition(entitydata)

			if not hookTargetPosition then
				ODMMovement.Decelerate(player)
				continue
			end

			local difference = hookTargetPosition - root.Position

			direction = if difference.Magnitude <= 0.001
				then odm.smoothedDirection or root.CFrame.LookVector
				else difference.Unit
		end

		-- Smooths sudden changes in direction.
		local previousSmoothed = odm.smoothedDirection or direction
		local smoothAlpha = math.clamp(12 * deltaTime, 0, 1)
		local smoothedDirection = previousSmoothed:Lerp(direction, smoothAlpha)

		smoothedDirection = if smoothedDirection.Magnitude > 0.001 then smoothedDirection.Unit else direction
		odm.smoothedDirection = smoothedDirection

		-- Falling does not affect rotation, keeping the body more upright.
		local orientationDirection = smoothedDirection
		if orientationDirection.Magnitude <= 0.001 then 
            orientationDirection = root.CFrame.LookVector 
        end
		orientationDirection = orientationDirection.Unit

		alignOrientation.Enabled = true
		alignOrientation.RigidityEnabled = odm.decelerating
		alignOrientation.CFrame = CFrame.lookAt(Vector3.zero, orientationDirection, Vector3.yAxis)

		-- Calculates the velocity that pulls the character toward the hook.
		local targetVelocity 
		if odm.gasBoosting then 
			targetVelocity = direction * (odm.speed * INFO.ODM.GasBoostMultiplier)
		else 
			targetVelocity = direction * odm.speed
		end

		
		-- Applies lateral movement to the left or right while using the ODM gear.
		if not odm.decelerating and odm.sideMovement ~= nil then
			local sideDirection = root.CFrame.RightVector
			local directionMultiplier = if odm.sideMovement == "Left" then -1 elseif odm.sideMovement == "Right" then 1 else nil
			targetVelocity += sideDirection * INFO.ODM.SideSpeed * directionMultiplier
		end
		
		if odm.decelerating then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { char }
			params.IgnoreWater = true
			
			local currentFallSpeed = math.abs(linearVelocity.VectorVelocity.Y)
			local groundCheckDistance = 3.5 + currentFallSpeed * deltaTime
			local groundResult = workspace:Raycast(
                root.Position, 
                Vector3.new(0, -groundCheckDistance, 0), params
            )
			
			local touchingGround = IsCollidableResult(groundResult)
		
			if touchingGround then
				odm.touchingGroundTime += deltaTime
			else
				odm.touchingGroundTime = 0
			end

			odm.touchingGround = touchingGround
			if touchingGround then
				-- On the ground, removes only the vertical velocity.
				local horizontalDirection = Vector3.new(direction.X, 0, direction.Z)
				targetVelocity = if horizontalDirection.Magnitude > 0.001
					then horizontalDirection.Unit * odm.speed
					else Vector3.zero
				humanoid.PlatformStand = false
			else
				-- Falling increases as the ODM speed decreases.
				local speedPercent = math.clamp(odm.speed / INFO.ODM.Speed, 0, 1)
				local fallSpeed = INFO.ODM.FallSpeed * (1 - speedPercent) * INFO.ODM.FallMultiplier
				targetVelocity += Vector3.new(0, -fallSpeed, 0)
			end
		else
			alignOrientation.RigidityEnabled = false
		end

		--[[
		
		local obstacleResult = workspace:Raycast(
			root.Position,
			orientationDirection * 2,
			params
		)

		if IsCollidableResult(obstacleResult) and not odm.colliding then
			local collisionDirection = Vector3.new(
				obstacleResult.Normal.X,
				1,
				obstacleResult.Normal.Z
			)

			odm.collisionDirection = if collisionDirection.Magnitude > 0.001
				then collisionDirection.Unit
				else Vector3.yAxis

			odm.colliding = true
		end
		]]

		linearVelocity.VectorVelocity = linearVelocity.VectorVelocity:Lerp(
            targetVelocity, 
            math.clamp(15 * deltaTime, 0, 1)
        )
		if odm.speed <= 0 and odm.touchingGround then 
            ODMMovement.Stop(player) 
        end
	end
end)