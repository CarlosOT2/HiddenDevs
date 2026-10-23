-- Discord: miranha0 | Roblox: HOMEMARANHA06

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
-- Events
local ODMEvent = ReplicatedStorage.RE:WaitForChild("ODM")
-- Modules
local ODMTypes = require(ServerStorage.Types.ODM)
local SessionData = require(ServerScriptService.Data.SessionData)
local INFO = require(ServerScriptService.Systems.Modules.INFO)

local Movement = {}

local function HasActiveHook(player: Player): boolean
	local data = SessionData.Entity.Get(player)
	if not data then return false end

	return data.temp.ODM.hooks.Left.active or data.temp.ODM.hooks.Right.active
end

local function ResetHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]

	hook.active = false
	hook.part = nil
	hook.position = nil
end

local function Reset(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local char = data.references.char
	local humanoid = char:FindFirstChildOfClass("Humanoid")
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
	local root = char:FindFirstChild("HumanoidRootPart")
	local humanoid = char:FindFirstChildOfClass("Humanoid")

	if not root or not humanoid then return nil end

	local odm = data.temp.ODM

	humanoid.AutoRotate = false
	humanoid.PlatformStand = false
	humanoid.JumpHeight = 0

    -- Prevents the Humanoid from trying to get up on its own while using the ODM gear.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)

	local attachment = Instance.new("Attachment")
	attachment.Name = "ODMAttachment"
	attachment.Parent = root

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

function Movement.Start(player: Player, hookSide: ODMTypes.hookSide, hookPart: BasePart, hookPosition: Vector3)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM
	local hook = odm.hooks[hookSide]

	-- Reuses existing components during deceleration.
	if not odm.LinearVelocityReference or not odm.AlignOrientationReference or not odm.AttachmentReference then
		local created = CreateMovementComponents(player)
		if not created then ResetHook(player, hookSide) return end
	end

	hook.active = true
	hook.part = hookPart
	hook.position = hookPosition

	odm.speed = INFO.ODM.Speed
	odm.decelerating = false
	odm.touchingGround = false
	odm.touchingGroundTime = 0

	-- Clears the previous direction to turn toward the new hook.
	odm.smoothedDirection = nil
	odm.lastDirectionDecelerating = nil

	ODMEvent:FireClient(player, "Start", data.references.char, { hookSide = hookSide, hookPosition = hookPosition, hookPart = hookPart })
end

function Movement.StartBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end
	if not HasActiveHook(player) and not data.temp.ODM.decelerating then return end
	
	data.temp.ODM.gasBoosting = true
	ODMEvent:FireClient(player, "StartBoost", data.references.char)
end
function Movement.SideMovement(player: Player, sideMovementDirection: ODMTypes.sideMovementDirection)
	local data = SessionData.Entity.Get(player)
	if not data then return end
	
	if sideMovementDirection == "Stop" then
		
		data.temp.ODM.sideMovement = nil
	else
		data.temp.ODM.sideMovement = sideMovementDirection
	end
end

function Movement.Decelerate(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local odm = data.temp.ODM

	if HasActiveHook(player) then return end
	if odm.decelerating then return end

	local root = data.references.char:FindFirstChild("HumanoidRootPart")

	-- Saves the actual movement direction when releasing the last hook.
	if root then
		local velocity = root.AssemblyLinearVelocity
		if velocity.Magnitude > 0.001 then
			odm.lastDirectionDecelerating = velocity.Unit
		else
			local look = root.CFrame.LookVector
			odm.lastDirectionDecelerating = if look.Magnitude > 0.001 then look.Unit else Vector3.new(0, 0, -1)
		end
	end

	odm.decelerating = true

	ODMEvent:FireClient(player, "Decelerate", data.references.char)
end

function Movement.StopHook(player: Player, hookSide: ODMTypes.hookSide)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	local hook = data.temp.ODM.hooks[hookSide]
	if not hook.active then return end

	ResetHook(player, hookSide)
	ODMEvent:FireClient(player, "StopHook", data.references.char, { hookSide = hookSide })

	-- Continues movement if the other hook is still active.
	if HasActiveHook(player) then return end

	Movement.Decelerate(player)
end

function Movement.StopBoost(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end
	
	data.temp.ODM.gasBoosting = false
	ODMEvent:FireClient(player, "StopBoost", data.references.char)
end

function Movement.Stop(player: Player)
	local data = SessionData.Entity.Get(player)
	if not data then return end

	Reset(player)

	ODMEvent:FireClient(player, "Stop", data.references.char)
end

return Movement