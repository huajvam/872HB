local MSKen = {}
local GAME_KEY = "ms_ken"

local Library = sharedRequire("ui/Linoria/Library.lua")
local ThemeManager = sharedRequire("ui/Linoria/addons/ThemeManager.lua")
local SaveManager = sharedRequire("ui/Linoria/addons/SaveManager.lua")

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

local GLOBAL_ENV = getgenv and getgenv() or _G
local HUAJ_HUB_MSKEN_INIT_KEY = "__huaj_hub_msken_initialized_v1"
local HUAJ_HUB_MSKEN_LIBRARY_KEY = "__huaj_hub_msken_library_v1"

local PHONE_CONTAINER_PATH = { "Phone", "Container", "PhoneFrame", "Container" }
local JOBS_BUTTON_PATH = { "Phone", "Container", "PhoneFrame", "Container", "PhoneLabel", "HomeScreen", "img", "HomeFrame", "Jobs", "img" }
-- Jobs are listed in numbered slots on the phone's jobs screen: slot 1 is the
-- restock job, slot 3 is the delivery job.
local function getAcceptButtonPath(slot)
	return { "Phone", "Container", "PhoneFrame", "Container", "PhoneLabel", "JobsScreen", "img", "jobs", "scroll", tostring(slot), "img", "accept" }
end

local RESTOCK_JOB_SLOT = 1
local DELIVERY_JOB_SLOT = 3
local ACCEPT_BUTTON_PATH = getAcceptButtonPath(RESTOCK_JOB_SLOT)
-- Any label under PlayerGui.Quests containing this text marks the restock job
-- as active. Matched by scanning descendants because quest rows are cloned
-- from a template at runtime, so their exact paths aren't stable.
local RESTOCK_QUEST_TEXT = "You still need to restock"

-- Delivery route waypoints, teleported through in order: the shop, each drop
-- off, and finally back to the shop before the next job is taken.
local DELIVERY_ROUTE = {
	CFrame.new(140.826431, 4.04428768, 77.9906464, -0.999805689, 5.95979444e-09, -0.019713087, 6.71388101e-09, 1, -3.81869043e-08, 0.019713087, -3.83118319e-08, -0.999805689),
	CFrame.new(158.564713, 1.50003231, 89.5151978, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-719.91272, 1.49971616, -179.245575, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-41.7301788, 1.49793923, -235.875366, -0.699219465, 0.0016660376, -0.714905262, -7.47049926e-05, 0.999997079, 0.00240349071, 0.714907169, 0.0017339742, -0.699217319),
	CFrame.new(-438.138367, 1.39754319, -772.952698, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(-139.964081, 1.50791931, -325.238983, 1, -0, 0, 0, 0.999998629, 0.00164011808, -0, -0.00164011808, 0.999998629),
	CFrame.new(158.564713, 1.50003231, 89.5151978, 1, 0, 0, 0, 1, 0, 0, 0, 1),
	CFrame.new(140.826431, 4.04428768, 77.9906464, -0.999805689, 5.95979444e-09, -0.019713087, 6.71388101e-09, 1, -3.81869043e-08, 0.019713087, -3.83118319e-08, -0.999805689),
}

-- How long to stand at each waypoint before moving to the next.
local DELIVERY_WAYPOINT_DWELL = 2

-- The game draws trails of numbered dots (Dot_1, Dot_2, ...) guiding the
-- player to each job objective: Path_Stocker leads to the Stock box, then
-- Path_Stocker_1 .. Path_Stocker_12 lead to the individual restock spots.
local COMPASS_FOLDER_NAME = "CompassPaths"
local TRAIL_NAME_PREFIX = "Path_Stocker"

-- Every log line also goes into a rolling history that gets dumped to a file
-- when a kick/disconnect is detected, since the console dies with the kick.
local FARM_LOG_FILE = "HuajHub_MSKen_log.txt"
local farmLogHistory = {}

local function logFarm(message)
	local line = ("[%s] %s"):format(os.date("%H:%M:%S"), tostring(message))
	warn("[HuajHub][MoneyFarm] " .. line)

	table.insert(farmLogHistory, line)
	if #farmLogHistory > 100 then
		table.remove(farmLogHistory, 1)
	end
end

local function dumpFarmLog(reason)
	if type(writefile) ~= "function" then
		return
	end

	pcall(function()
		writefile(FARM_LOG_FILE, ("DUMP REASON: %s\n\n%s\n"):format(tostring(reason), table.concat(farmLogHistory, "\n")))
	end)
end

local function findGuiElement(pathParts)
	local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local current = playerGui

	for _, childName in ipairs(pathParts) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(childName)
	end

	return current
end

-- A GuiObject only renders when it and every ancestor are visible and its
-- ScreenGui is enabled; hidden rows stay in the tree.
local function isGuiElementVisible(element)
	local current = element

	while current and not current:IsA("ScreenGui") do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end

	return current ~= nil and current.Enabled == true
end

-- Reads the restock counter off the quest tracker. Several rows can carry
-- restock text at once - the live one plus stale leftovers from earlier jobs
-- that still say "0 / 12" - so prefer rows actually on screen, and take the
-- highest count among them rather than whichever comes first in the tree.
local function getRestockProgress()
	local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local questsGui = playerGui and playerGui:FindFirstChild("Quests")
	if not questsGui then
		return nil
	end

	local visibleBest, anyBest = nil, nil

	for _, descendant in ipairs(questsGui:GetDescendants()) do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			local text = descendant.Text
			if text:find(RESTOCK_QUEST_TEXT, 1, true) or text:lower():find("restock", 1, true) then
				local count = tonumber(text:match("(%d+)%s*/"))
				if count then
					if isGuiElementVisible(descendant) and (not visibleBest or count > visibleBest) then
						visibleBest = count
					end
					if not anyBest or count > anyBest then
						anyBest = count
					end
				end
			end
		end
	end

	return visibleBest or anyBest
end

-- Finds a quest row showing the restock text. Quest rows are clones of a
-- template row and keep that name, so they cannot be told apart by name -
-- only by whether they are actually rendered. requireVisible = true asks
-- "is the job on screen right now", false just reads whatever text exists.
local function findRestockQuestLabel(requireVisible)
	local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local questsGui = playerGui and playerGui:FindFirstChild("Quests")
	if not questsGui then
		return nil
	end

	-- The tracker scrambles its text while animating a counter change, so
	-- match loosely: the "restock" word survives most frames, and the
	-- "N / 12" counter form is a fallback when it doesn't.
	for _, descendant in ipairs(questsGui:GetDescendants()) do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
			and (not requireVisible or isGuiElementVisible(descendant)) then
			local text = descendant.Text
			if text:find(RESTOCK_QUEST_TEXT, 1, true)
				or text:lower():find("restock", 1, true)
				or text:match("%d+%s*/%s*12") then
				return descendant
			end
		end
	end

	return nil
end

local function waitForGuiElement(pathParts, timeout, shouldCancel)
	local deadline = os.clock() + timeout

	while os.clock() < deadline do
		if shouldCancel and shouldCancel() then
			return nil
		end

		local element = findGuiElement(pathParts)
		if element then
			return element
		end

		task.wait(0.1)
	end

	return nil
end

local PHONE_TOOL_NAME = "Phone"

-- The phone tool lives in the character model while equipped
-- (e.g. workspace.<PlayerName>.Phone) and in the Backpack otherwise.
local function isPhoneEquipped()
	local character = LocalPlayer and LocalPlayer.Character
	local tool = character and character:FindFirstChild(PHONE_TOOL_NAME)
	return tool ~= nil and tool:IsA("Tool")
end

-- Puts the phone (or anything else) away, the way a player does before
-- getting to work. Returns what was unequipped, for logging.
local function unequipAllTools()
	local character = LocalPlayer and LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid then
		return nil
	end

	local held = character:FindFirstChildOfClass("Tool")
	if not held then
		return nil
	end

	local heldName = held.Name
	humanoid:UnequipTools()
	return heldName
end

local function getEquippedToolName()
	local character = LocalPlayer and LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	return tool and tool.Name or "none"
end

local function equipPhoneFromBackpack()
	local character = LocalPlayer and LocalPlayer.Character
	local backpack = LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local phoneTool = backpack and backpack:FindFirstChild(PHONE_TOOL_NAME)

	if not humanoid or not phoneTool or not phoneTool:IsA("Tool") then
		return false
	end

	humanoid:EquipTool(phoneTool)
	return true
end

local function findWorkspaceChild(pathParts)
	local current = workspace

	for _, childName in ipairs(pathParts) do
		if not current then
			return nil
		end
		current = current:FindFirstChild(childName)
	end

	return current
end

local function getCharacterRoot()
	local character = LocalPlayer and LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") or nil
end

local function teleportTo(targetCFrame)
	local root = getCharacterRoot()
	if not root then
		return false
	end

	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = targetCFrame
	return true
end

local function getDotPosition(instance)
	if instance:IsA("BasePart") then
		return instance.Position
	end
	if instance:IsA("Model") then
		return instance:GetPivot().Position
	end
	if instance:IsA("Attachment") then
		return instance.WorldPosition
	end
	return nil
end

-- Every Path_Stocker* folder currently in the compass folder.
local function getTrailFolders()
	local compass = workspace:FindFirstChild(COMPASS_FOLDER_NAME)
	if not compass then
		return {}
	end

	local folders = {}
	for _, child in ipairs(compass:GetChildren()) do
		if child.Name:sub(1, #TRAIL_NAME_PREFIX) == TRAIL_NAME_PREFIX then
			table.insert(folders, child)
		end
	end

	return folders
end

-- Returns a trail's compass dots sorted by their number (Dot_1, Dot_2, ...).
local function getCompassDots(folder)
	if not folder then
		return {}
	end

	local children = folder:GetChildren()
	local dots = {}
	for _, child in ipairs(children) do
		-- Any trailing number in the name counts as the dot index.
		local index = tonumber(child.Name:match("(%d+)%s*$"))
		local position = getDotPosition(child)
		if index and position then
			table.insert(dots, { index = index, position = position })
		end
	end

	if #dots == 0 and #children > 0 then
		local names = {}
		for i = 1, math.min(#children, 8) do
			names[i] = children[i].Name .. " (" .. children[i].ClassName .. ")"
		end
		logFarm(("%s has %d children but none look like dots: %s"):format(folder.Name, #children, table.concat(names, ", ")))
	end

	table.sort(dots, function(a, b)
		return a.index < b.index
	end)

	return dots
end

local function anyTrailHasDots()
	for _, folder in ipairs(getTrailFolders()) do
		if #getCompassDots(folder) > 0 then
			return true
		end
	end

	return false
end

-- Movement works like a real player: the W key is held down through
-- VirtualInputManager and the camera is steered at the target each tick, so
-- the character runs wherever the camera faces (default Roblox controls).
local wKeyHeld = false

local function setWKeyHeld(held)
	if wKeyHeld == held then
		return
	end

	wKeyHeld = held
	pcall(function()
		if held then
			-- Double-tap W: the game starts running on the second press, so
			-- tap once, release, then press again and keep it held.
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
			task.wait(0.05)
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
			task.wait(0.05)
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
		else
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
		end
	end)
end

-- Movement direction is fed straight into the Humanoid every frame, bound
-- AFTER the default control scripts so it overrides the camera-relative W
-- direction. W stays held for the game's double-tap run mechanic, but the
-- camera is left completely alone - the player can look around freely.
local WALK_BIND_NAME = "HuajHubMSKenMove"
local walkTargetPosition = nil
local walkBindActive = false

local function setWalkTarget(position)
	walkTargetPosition = position
end

local function setMovementOverrideActive(active)
	if active == walkBindActive then
		return
	end

	walkBindActive = active

	if active then
		RunService:BindToRenderStep(WALK_BIND_NAME, Enum.RenderPriority.Input.Value + 1, function()
			if not walkTargetPosition then
				return
			end

			local character = LocalPlayer and LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local root = getCharacterRoot()
			if not humanoid or not root then
				return
			end

			local offset = walkTargetPosition - root.Position
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude < 0.1 then
				humanoid:Move(Vector3.zero, false)
				return
			end

			humanoid:Move(flat.Unit, false)
		end)
	else
		walkTargetPosition = nil
		pcall(function()
			RunService:UnbindFromRenderStep(WALK_BIND_NAME)
		end)
	end
end

local function walkTo(position, isCancelled, timeout)
	local deadline = os.clock() + (timeout or 10)
	local lastPosition = nil
	local lastProgressAt = os.clock()
	local stallReported = false

	while os.clock() < deadline do
		if isCancelled and isCancelled() then
			setWKeyHeld(false)
			return false, "cancelled"
		end

		local root = getCharacterRoot()
		if not root then
			setWKeyHeld(false)
			return false, "no character"
		end

		local offset = position - root.Position
		local flatDistance = Vector3.new(offset.X, 0, offset.Z).Magnitude
		if flatDistance <= 3 then
			-- W stays held between dots so the run is one smooth motion.
			return true
		end

		-- If W is held but the character stops making progress, it's snagged
		-- on something - hop over it like a player would.
		if lastPosition == nil or (root.Position - lastPosition).Magnitude > 0.5 then
			lastPosition = root.Position
			lastProgressAt = os.clock()
		elseif wKeyHeld and os.clock() - lastProgressAt > 1.5 then
			if not stallReported then
				stallReported = true
				logFarm("movement stalled; jumping to get unstuck")
			end

			local character = LocalPlayer and LocalPlayer.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Jump = true
			end

			-- Give the jump a moment to carry before judging progress again.
			lastProgressAt = os.clock()
		end

		setWalkTarget(position)
		setWKeyHeld(true)
		task.wait(0.05)
	end

	setWKeyHeld(false)
	return false, "timeout"
end

local function randomRange(minimum, maximum)
	return minimum + math.random() * (maximum - minimum)
end

local function sleepUnlessCancelled(duration, isCancelled)
	local deadline = os.clock() + duration

	while os.clock() < deadline do
		if isCancelled() then
			return false
		end
		task.wait(0.1)
	end

	return true
end

-- relativeX/relativeY pick the click point inside the element (0 = left/top edge,
-- 0.5 = center, 1 = right/bottom edge); default is the center.
local function clickGuiElement(element, relativeX, relativeY)
	relativeX = relativeX or 0.5
	relativeY = relativeY or 0.5

	local inset = GuiService:GetGuiInset()
	local x = element.AbsolutePosition.X + element.AbsoluteSize.X * relativeX + inset.X
	local y = element.AbsolutePosition.Y + element.AbsoluteSize.Y * relativeY + inset.Y

	VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
	task.wait(0.05)
	VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
end

-- Clears a finished restock task off the tracker by pressing its Exit (X)
-- button, so the leftover row cannot be mistaken for an active job on the
-- next lap. The row index is not stable, so the restock row is found by its
-- text rather than by position.
local QUESTS_LIST_PATH = { "Quests", "Frame", "quests" }

-- A live Exit button carries an _ExitAnimPivot child; rows without it are
-- not actually pressable, so that marker is what makes it safe to click.
local function findPressableExitButton(row)
	for _, descendant in ipairs(row:GetDescendants()) do
		if descendant.Name == "Exit"
			and descendant:IsA("GuiObject")
			and descendant:FindFirstChild("_ExitAnimPivot") then
			return descendant
		end
	end

	return nil
end

local function rowMentionsRestock(row)
	for _, descendant in ipairs(row:GetDescendants()) do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
			and descendant.Text:lower():find("restock", 1, true) then
			return true
		end
	end

	return false
end

local function moveMouseToGuiElement(element)
	local inset = GuiService:GetGuiInset()
	local x = element.AbsolutePosition.X + element.AbsoluteSize.X * 0.5 + inset.X
	local y = element.AbsolutePosition.Y + element.AbsoluteSize.Y * 0.5 + inset.Y
	VirtualInputManager:SendMouseMoveEvent(x, y, game)
end

local function dismissRestockQuest()
	-- Retry a few times: the row animates out, and a click during the
	-- animation can be swallowed.
	for attempt = 1, 4 do
		local questsList = findGuiElement(QUESTS_LIST_PATH)
		if not questsList then
			logFarm("quest list not found; cannot clear the task")
			return false
		end

		local exitButton, questRow = nil, nil
		for _, row in ipairs(questsList:GetChildren()) do
			if rowMentionsRestock(row) then
				exitButton = findPressableExitButton(row)
				if exitButton then
					questRow = row
					break
				end
			end
		end

		if not exitButton then
			if attempt > 1 then
				logFarm("restock task cleared off the tracker")
				return true
			end

			logFarm("no restock row with a pressable Exit found")
			return false
		end

		-- The X is typically revealed on hover, so hover the row and then the
		-- button before pressing, and click whether or not it reports visible.
		logFarm(("pressing Exit on %s (visible=%s)"):format(
			exitButton:GetFullName(), tostring(isGuiElementVisible(exitButton))))

		moveMouseToGuiElement(questRow)
		task.wait(0.2)
		moveMouseToGuiElement(exitButton)
		task.wait(0.2)
		clickGuiElement(exitButton)

		task.wait(0.5)
	end

	return false
end

-- Reports the character's motion state at click time. No waiting: clicks fire
-- the moment the shelf is in range, even while the player is still moving.
local function describeCharacterState()
	local character = LocalPlayer and LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = getCharacterRoot()
	if not humanoid or not root then
		return "no character"
	end

	return ("velocity=%.1f state=%s moveDir=%.1f"):format(
		root.AssemblyLinearVelocity.Magnitude,
		tostring(humanoid:GetState()),
		humanoid.MoveDirection.Magnitude)
end

function MSKen.init(_context)
	if GLOBAL_ENV[HUAJ_HUB_MSKEN_INIT_KEY] then
		local existingLibrary = GLOBAL_ENV[HUAJ_HUB_MSKEN_LIBRARY_KEY]
		if type(existingLibrary) == "table" and type(existingLibrary.Unload) == "function" then
			pcall(function()
				existingLibrary:Unload()
			end)
		end

		GLOBAL_ENV[HUAJ_HUB_MSKEN_INIT_KEY] = nil
		GLOBAL_ENV[HUAJ_HUB_MSKEN_LIBRARY_KEY] = nil
	end

	GLOBAL_ENV[HUAJ_HUB_MSKEN_INIT_KEY] = true
	GLOBAL_ENV[HUAJ_HUB_MSKEN_LIBRARY_KEY] = Library

	local runtimeState = {
		moneyFarmToken = 0,
	}

	-- Fires with the disconnect dialog text the moment a kick happens; logs it
	-- and dumps the whole action history to a file so it can be read after
	-- rejoining (the file lands in the executor's workspace folder).
	local kickWatchConnection = GuiService.ErrorMessageChanged:Connect(function(errorMessage)
		if errorMessage and errorMessage ~= "" then
			logFarm("DISCONNECTED: " .. tostring(errorMessage))
			dumpFarmLog("disconnect: " .. tostring(errorMessage))
		end
	end)

	Library:OnUnload(function()
		runtimeState.moneyFarmToken += 1
		setWKeyHeld(false)
		setMovementOverrideActive(false)
		kickWatchConnection:Disconnect()
		GLOBAL_ENV[HUAJ_HUB_MSKEN_INIT_KEY] = nil
		GLOBAL_ENV[HUAJ_HUB_MSKEN_LIBRARY_KEY] = nil
	end)

	local Window = Library:CreateWindow({
		Title = "MS:Ken | Huaj Hub",
		Center = true,
		AutoShow = true,
		Size = UDim2.fromOffset(550, 600),
		TabPadding = 0,
		MenuFadeTime = 0.2,
	})

	local Tabs = {
		Autofarm = Window:AddTab("Autofarm"),
		Settings = Window:AddTab("Settings"),
	}

	local moneyFarmGroup = Tabs.Autofarm:AddLeftGroupbox("Money Farm")

	do
		local function runRestockRoute(isCancelled)
			logFarm("restock route started; following the compass path")

			-- Put the phone away before working the shelves; clicking them
			-- with the phone still in hand is not a state a real player is
			-- ever in when restocking.
			local putAway = unequipAllTools()
			if putAway then
				logFarm("put away the " .. putAway .. " before starting the route")
				task.wait(0.4)
			end

			setMovementOverrideActive(true)

			-- Walks a trail's dots strictly in numeric order: Dot_1, Dot_2, ...
			-- The game draws them from the player toward the objective, and
			-- walkTo returns instantly for dots the player is already at.
			local function followCompassDots(trailFolder)
				local dots = getCompassDots(trailFolder)
				if #dots == 0 then
					return false, "trail " .. trailFolder.Name .. " has no dots"
				end

				logFarm(("following the %d dots of %s in order"):format(#dots, trailFolder.Name))

				for i = 1, #dots do
					if isCancelled() then
						return false, "cancelled"
					end

					local walked, walkError = walkTo(dots[i].position, isCancelled)
					if not walked then
						if walkError == "cancelled" then
							return false, "cancelled"
						end

						-- Stuck on this dot; keep going, the next one may free
						-- the path.
						logFarm(("timed out walking to dot %d; skipping it"):format(dots[i].index))
					end
				end

				-- Arrived; let go of W and stop steering so the character
				-- stands still for the click. The final dot marks WHICH shelf
				-- this trail's objective is.
				setWKeyHeld(false)
				setWalkTarget(nil)
				return true, nil, dots[#dots].position
			end

			-- Parts already fired this job. Firing a spot twice is an invalid
			-- click server-side, so each part is clicked at most once per job.
			local firedParts = {}

			-- The un-fired clickable part closest to fromPosition (the trail's
			-- final dot when available - the game's own pointer at the right
			-- shelf - or the player's position otherwise).
			local function nearestUnfiredPartTo(fromPosition)
				if not fromPosition then
					local root = getCharacterRoot()
					fromPosition = root and root.Position
				end
				if not fromPosition then
					return nil
				end

				local jobsFolder = findWorkspaceChild({ "Jobs", "Restock", "JLF" })
				if not jobsFolder then
					return nil
				end

				local candidates = {}

				for _, descendant in ipairs(jobsFolder:GetDescendants()) do
					if descendant:IsA("ClickDetector") then
						local part = descendant.Parent
						if part and part:IsA("BasePart") and not firedParts[part] then
							table.insert(candidates, {
								part = part,
								distance = (part.Position - fromPosition).Magnitude,
							})
						end
					end
				end

				if #candidates == 0 then
					return nil
				end

				table.sort(candidates, function(a, b)
					return a.distance < b.distance
				end)

				local summary = {}
				for i = 1, math.min(3, #candidates) do
					summary[i] = ("%s=%.1f"):format(candidates[i].part.Name, candidates[i].distance)
				end
				logFarm("click candidates: " .. table.concat(summary, ", "))

				return candidates[1].part, candidates[1].distance, candidates[2] and candidates[2].distance or nil
			end

			local getQuestProgress = getRestockProgress

			-- Highest restock count the server has confirmed this job.
			local bestProgress = 0

			-- Counter value from just before the last click, checked on the
			-- next cycle so the player never stands around waiting for it.
			local pendingProgressCheck = nil
			local lastFiredTarget = nil

			-- Guards against a job that can never finish: the tracker sometimes
			-- keeps a stale "0 / 12" row on screen after a job ends, which
			-- otherwise keeps the route grinding through every retry.
			local routeStartedAt = os.clock()
			local lastProgressAt = os.clock()
			local ROUTE_TIME_LIMIT = 180
			local STALL_LIMIT = 25

			local function noteProgress()
				local progress = getQuestProgress()
				if progress and progress > bestProgress then
					bestProgress = progress
					lastProgressAt = os.clock()
				end
				return bestProgress
			end

			-- True when the route should stop and let a fresh job be accepted.
			local function routeShouldGiveUp()
				if os.clock() - routeStartedAt > ROUTE_TIME_LIMIT then
					logFarm(("route hit its %ds time limit at %d/12; starting over"):format(ROUTE_TIME_LIMIT, bestProgress))
					return true
				end

				if os.clock() - lastProgressAt > STALL_LIMIT and not anyTrailHasDots() then
					logFarm(("no progress for %ds and no trails drawn (%d/12); starting over"):format(STALL_LIMIT, bestProgress))
					return true
				end

				return false
			end

			local function reportProgress()
				if pendingProgressCheck == nil then
					noteProgress()
					return
				end

				local progressNow = getQuestProgress()
				if progressNow and progressNow > pendingProgressCheck then
					logFarm(("server counted the restock (%d/12)"):format(noteProgress()))
				elseif progressNow then
					logFarm(("counter still at %d/12 after the last click - putting that shelf back in the queue"):format(progressNow))
					-- The click did not take, so let the shelf be targeted
					-- again instead of leaving the job one short.
					if lastFiredTarget then
						firedParts[lastFiredTarget] = nil
					end
				end

				pendingProgressCheck = nil
				lastFiredTarget = nil
			end

			-- The job is only finished once 12 restocks are counted, or the
			-- tracker stays gone for several seconds. A single miss means the
			-- label is mid-animation, not that the job ended.
			local function jobIsFinished()
				if bestProgress >= 12 then
					logFarm("all 12 restocks counted; job complete")
					return true
				end

				-- Cheap outs first, so a mid-animation label never costs time:
				-- a tracker row on screen or any drawn trail means work remains.
				if findRestockQuestLabel(true) or anyTrailHasDots() then
					return false
				end

				local deadline = os.clock() + 4
				while os.clock() < deadline do
					if isCancelled() then
						return false
					end

					if findRestockQuestLabel(true) then
						return false
					end

					task.wait(0.25)
				end

				logFarm(("quest tracker gone for 4s at %d/12; treating the job as over"):format(bestProgress))
				return true
			end

			-- Dot instances recorded just before each fire; a trail containing
			-- any dot the snapshot has never seen is the one the game drew
			-- after that click - its CURRENT target. The server validates
			-- clicks against this, which is why picking our own order got
			-- tolerated twice and then kicked, every time.
			local trailDotSnapshot = {}

			local function snapshotTrailDots()
				trailDotSnapshot = {}
				for _, folder in ipairs(getTrailFolders()) do
					local seen = {}
					for _, child in ipairs(folder:GetChildren()) do
						seen[child] = true
					end
					trailDotSnapshot[folder.Name] = seen
				end
			end

			local function findFreshTrail()
				for _, folder in ipairs(getTrailFolders()) do
					if #getCompassDots(folder) > 0 then
						local seen = trailDotSnapshot[folder.Name]
						if not seen then
							return folder
						end

						for _, child in ipairs(folder:GetChildren()) do
							if not seen[child] then
								return folder
							end
						end
					end
				end

				return nil
			end

			-- Only a part the player is basically standing on gets fired.
			local SUPER_CLOSE_RANGE = 4

			-- Click pacing. Every kicked run fired 4+ detectors inside ~20s;
			-- the one run that never earned an invalid click had 8-12s between
			-- clicks. The anti-cheat is counting clicks per unit time, not
			-- checking which shelf, so keep the cadence human.
			-- Manual fast clicking never gets kicked, so speed itself is fine;
			-- keep only a token gap between clicks.
			local MIN_SECONDS_BETWEEN_FIRES = 0.3
			local MAX_FIRES_PER_WINDOW = 12
			local FIRE_WINDOW_SECONDS = 30
			local fireTimes = {}

			-- Blocks until firing again is within the pacing limits.
			local function waitForFireSlot()
				while true do
					local now = os.clock()

					-- Drop timestamps that have aged out of the window.
					for i = #fireTimes, 1, -1 do
						if now - fireTimes[i] > FIRE_WINDOW_SECONDS then
							table.remove(fireTimes, i)
						end
					end

					local waitFor = 0

					local lastFire = fireTimes[#fireTimes]
					if lastFire then
						waitFor = math.max(waitFor, MIN_SECONDS_BETWEEN_FIRES - (now - lastFire))
					end

					if #fireTimes >= MAX_FIRES_PER_WINDOW then
						waitFor = math.max(waitFor, FIRE_WINDOW_SECONDS - (now - fireTimes[1]))
					end

					if waitFor <= 0 then
						return true
					end

					logFarm(("pacing: waiting %.1fs before the next click (%d fired in the last %ds)"):format(
						waitFor, #fireTimes, FIRE_WINDOW_SECONDS))

					if not sleepUnlessCancelled(waitFor, isCancelled) then
						return false
					end
				end
			end

			-- Fires the target's ClickDetector if the player is close enough.
			-- Only returns false on cancellation; a skipped click is not fatal.
			-- immediate skips the lead-in pause and pacing wait (used for the
			-- Stock click, which starts the job and has nothing to pace after).
			local function approachAndFire(target, immediate)
				local root = getCharacterRoot()
				local clickDistance = root and (target.Position - root.Position).Magnitude or math.huge

				-- Only ever close a short gap in a straight line. Anything
				-- longer has to come from the compass dots: walking straight at
				-- a shelf from across the aisle just wedges into its wall.
				if clickDistance > SUPER_CLOSE_RANGE then
					if clickDistance > 12 then
						logFarm(("%s is %.1f studs away - too far to walk straight at; waiting for the trail"):format(
							target.Name, clickDistance))
						return true
					end

					walkTo(target.Position, isCancelled, 4)
					setWKeyHeld(false)
					setWalkTarget(nil)
				end

				if isCancelled() then
					return false, "cancelled"
				end

				-- The target's identity is already settled (it came from the
				-- trail's final dot or the spot index); just make sure the
				-- player is inside the detector's range before firing.
				root = getCharacterRoot()
				clickDistance = root and (target.Position - root.Position).Magnitude or math.huge
				if clickDistance > 5.8 then
					logFarm(("still %.1f studs from %s; not close enough, skipping this click"):format(clickDistance, target.Name))
					return true
				end

				if not immediate and not waitForFireSlot() then
					return false, "cancelled"
				end

				-- Release the run key so the character does not keep sprinting
				-- past the shelf, but do not wait for it to come to a stop -
				-- the click goes out immediately.
				setWKeyHeld(false)
				setWalkTarget(nil)
				local characterState = describeCharacterState()

				local questLabel = findRestockQuestLabel()
				logFarm(("quest before fire: %s"):format(questLabel and questLabel.Text or "<no label>"))
				logFarm(("character at click: %s holding=%s"):format(characterState, getEquippedToolName()))
				logFarm(("firing ClickDetector on %s (%.1f studs away)"):format(target:GetFullName(), clickDistance))

				local progressBefore = getQuestProgress()
				snapshotTrailDots()
				table.insert(fireTimes, os.clock())

				firedParts[target] = true
				fireclickdetector(target:FindFirstChildOfClass("ClickDetector"))

				-- Do not wait around for the server to confirm: head for the
				-- next shelf right away. The count is picked up on the next
				-- cycle by reportProgress().
				pendingProgressCheck = progressBefore
				lastFiredTarget = (target.Name ~= "Stock") and target or nil
				return true
			end

			local function clickStockOnce()
				local stockPart = findWorkspaceChild({ "Jobs", "Restock", "JLF", "Stock" })
				if not (stockPart and stockPart:FindFirstChildOfClass("ClickDetector")) then
					return false, "Stock part not found"
				end

				logFarm("heading to the Stock box to start the job")

				-- Follow the stock trail if the game has one drawn, otherwise
				-- walk straight to the box.
				local compass = workspace:FindFirstChild(COMPASS_FOLDER_NAME)
				local stockTrail = compass and compass:FindFirstChild(TRAIL_NAME_PREFIX)
				if stockTrail and #getCompassDots(stockTrail) > 0 then
					local moved, moveError = followCompassDots(stockTrail)
					if not moved then
						return false, moveError
					end
				else
					walkTo(stockPart.Position, isCancelled)
					setWKeyHeld(false)
					setWalkTarget(nil)

					if isCancelled() then
						return false, "cancelled"
					end
				end

				-- No lead-in pause here: the Stock click just starts the job.
				return approachAndFire(stockPart, true)
			end

			-- The job: click the Stock box once, then keep following the trail
			-- the game draws to its current target shelf and click that. The
			-- game picks the order; overriding it is what earned the invalid
			-- click strikes.
			local stockClicked, stockError = clickStockOnce()
			if not stockClicked then
				return false, stockError
			end

			for cycle = 1, 30 do
				if isCancelled() then
					return false, "cancelled"
				end

				reportProgress()

				if jobIsFinished() or routeShouldGiveUp() then
					break
				end

				-- Prefer the trail the game drew after the last click; if the
				-- redraw is missed, fall back to any trail that still has dots
				-- rather than abandoning the job.
				local trailFolder = nil
				local freshDeadline = os.clock() + 1.5
				local trailDeadline = os.clock() + 10
				while os.clock() < trailDeadline do
					if isCancelled() then
						return false, "cancelled"
					end

					trailFolder = findFreshTrail()
					if trailFolder then
						logFarm("following the game's trail: " .. trailFolder.Name)
						break
					end

					if os.clock() > freshDeadline then
						for _, folder in ipairs(getTrailFolders()) do
							if #getCompassDots(folder) > 0 then
								trailFolder = folder
								logFarm("no fresh redraw seen; falling back to " .. folder.Name)
								break
							end
						end

						if trailFolder then
							break
						end
					end

					task.wait(0.15)
				end

				local target, targetDistance

				if trailFolder then
					local moved, moveError, trailEndPosition = followCompassDots(trailFolder)
					if not moved then
						return false, moveError
					end

					target, targetDistance = nearestUnfiredPartTo(trailEndPosition)
					if target and targetDistance > 3.5 then
						logFarm(("%s is %.1f studs from the trail's last dot - not the objective"):format(
							target.Name, targetDistance))
						target = nil
					end
				else
					-- No trail at all: walk to the closest shelf we have not
					-- restocked yet and use that.
					local compass = workspace:FindFirstChild(COMPASS_FOLDER_NAME)
					if compass then
						local contents = {}
						for _, child in ipairs(compass:GetChildren()) do
							table.insert(contents, ("%s(%d)"):format(child.Name, #child:GetChildren()))
						end
						logFarm("CompassPaths at timeout: " .. table.concat(contents, ", "))
					end

					-- With no dots to follow, only attempt a shelf that is close
					-- enough for a straight walk to be safe; a long one just
					-- ends up pinned against shelving.
					local candidate, candidateDistance = nearestUnfiredPartTo(nil)
					if candidate and candidateDistance <= 30 then
						logFarm(("no trail available; walking to the nearest unrestocked shelf %.1f studs away (%d/12 done)"):format(
							candidateDistance, bestProgress))
						walkTo(candidate.Position, isCancelled, 8)
						setWKeyHeld(false)
						setWalkTarget(nil)

						if isCancelled() then
							return false, "cancelled"
						end

						target = candidate
					elseif candidate then
						logFarm(("nearest unrestocked shelf is %.1f studs away with no trail; waiting for one"):format(candidateDistance))
						if not sleepUnlessCancelled(1.5, isCancelled) then
							return false, "cancelled"
						end
					end
				end

				if target then
					local fired, fireError = approachAndFire(target)
					if not fired then
						return false, fireError
					end
				end
			end

			-- Sweep phase: trail numbers and spot order can drift apart, which
			-- can leave a straggler after the ordered pass. While the quest is
			-- still active, follow whatever trail has dots (any number) or walk
			-- to the nearest unfired spot directly, and click it.
			for sweep = 1, 14 do
				if isCancelled() then
					return false, "cancelled"
				end

				reportProgress()

				if jobIsFinished() or routeShouldGiveUp() then
					break
				end

				logFarm(("sweep %d: quest still active at %d/12, hunting leftover spots"):format(sweep, bestProgress))

				local trailFolder = nil
				for _, folder in ipairs(getTrailFolders()) do
					if #getCompassDots(folder) > 0 then
						trailFolder = folder
						break
					end
				end

				local sweepTarget = nil

				if trailFolder then
					logFarm("following leftover trail: " .. trailFolder.Name)
					local moved, moveError, trailEndPosition = followCompassDots(trailFolder)
					if not moved then
						return false, moveError
					end

					local candidate, candidateDistance = nearestUnfiredPartTo(trailEndPosition)
					if candidate and candidateDistance <= 3.5 then
						sweepTarget = candidate
					end
				else
					local spotsFolder = findWorkspaceChild({ "Jobs", "Restock", "JLF", "Spots" })
					local root = getCharacterRoot()
					if not spotsFolder or not root then
						break
					end

					local best, bestDistance = nil, math.huge
					for _, spot in ipairs(spotsFolder:GetChildren()) do
						if spot:IsA("BasePart") and not firedParts[spot] and spot:FindFirstChildOfClass("ClickDetector") then
							local distance = (spot.Position - root.Position).Magnitude
							if distance < bestDistance then
								best, bestDistance = spot, distance
							end
						end
					end

					if not best then
						logFarm("no unfired spots left; sweep done")
						break
					end

					logFarm(("walking straight to a leftover spot %.1f studs away"):format(bestDistance))
					walkTo(best.Position, isCancelled, 8)
					setWKeyHeld(false)
					setWalkTarget(nil)

					if isCancelled() then
						return false, "cancelled"
					end

					sweepTarget = best
				end

				if sweepTarget then
					local fired, fireError = approachAndFire(sweepTarget)
					if not fired then
						return false, fireError
					end
				else
					logFarm("sweep: no safe target this pass; retrying")
				end
			end

			-- Dismiss the finished task so the tracker is clean before the next
			-- job is picked up from the phone.
			dismissRestockQuest()

			-- Only a full 12/12 counts as a completed route; anything less is
			-- reported as the failure it is, with the count it reached.
			if bestProgress >= 12 then
				return true
			end

			return false, ("route ended at %d/12 restocks"):format(bestProgress)
		end

		-- Opens the phone, gets to the jobs screen and accepts the job in the
		-- given slot. Shared by the restock and delivery farms.
		local function acceptJobFromPhone(slot, isCancelled)
			local acceptPath = getAcceptButtonPath(slot)

			-- Equip the phone tool from the backpack if it isn't already in hand.
			if not isPhoneEquipped() then
				if not equipPhoneFromBackpack() then
					return false, "Phone tool not found in backpack"
				end

				local deadline = os.clock() + 5
				repeat
					if isCancelled() then
						return false, "cancelled"
					end

					if isPhoneEquipped() then
						break
					end

					task.wait(0.1)
				until os.clock() > deadline

				if not isPhoneEquipped() then
					return false, "Failed to equip the phone tool"
				end
			end

			local phoneContainer = waitForGuiElement(PHONE_CONTAINER_PATH, 5, isCancelled)
			if not phoneContainer then
				return false, "Phone GUI not found after equipping"
			end

			task.wait(0.3)
			if isCancelled() then
				return false, "cancelled"
			end
			logFarm("phone equipped; clicking phone container")
			clickGuiElement(phoneContainer)

			local jobsButton = waitForGuiElement(JOBS_BUTTON_PATH, 5, isCancelled)
			if not jobsButton then
				return false, "Jobs button not found (is the phone open?)"
			end

			task.wait(0.3)
			if isCancelled() then
				return false, "cancelled"
			end
			-- Click the job frame until the accept button is actually on screen
			-- (up to 4s), rather than spamming a fixed 3 seconds. On later laps
			-- the phone often reopens straight onto the jobs screen, where more
			-- clicks on this spot land on whatever is really there.
			logFarm("opening the jobs screen")
			local clickDeadline = os.clock() + 4
			while os.clock() < clickDeadline do
				if isCancelled() then
					return false, "cancelled"
				end

				local accept = findGuiElement(acceptPath)
				if accept and isGuiElementVisible(accept) then
					break
				end

				clickGuiElement(jobsButton, 0.75, 0.5)
				task.wait(0.25)
			end

			local acceptButton = waitForGuiElement(acceptPath, 5, isCancelled)
			if not acceptButton then
				return false, ("Accept button for job slot %d not found"):format(slot)
			end

			task.wait(0.3)
			if isCancelled() then
				return false, "cancelled"
			end
			logFarm(("clicking accept on job slot %d"):format(slot))
			clickGuiElement(acceptButton)

			return true
		end

		local function runMoneyFarmSequence(isCancelled)
			logFarm("sequence started")

			local accepted, acceptError = acceptJobFromPhone(RESTOCK_JOB_SLOT, isCancelled)
			if not accepted then
				return false, acceptError
			end

			-- Verify the restock job is active: either the quest tracker shows
			-- the restock text, or the game has drawn the stocker compass trail
			-- (which only exists while the job is running).
			local questLabel = nil
			local trailIsUp = false
			local questDeadline = os.clock() + 5
			while os.clock() < questDeadline do
				if isCancelled() then
					return false, "cancelled"
				end

				questLabel = findRestockQuestLabel()
				if questLabel then
					break
				end

				if anyTrailHasDots() then
					trailIsUp = true
					break
				end

				task.wait(0.1)
			end

			if questLabel then
				logFarm(("restock quest confirmed via tracker: %q (label: %s)"):format(questLabel.Text, questLabel:GetFullName()))
			elseif trailIsUp then
				logFarm("restock quest confirmed via the compass trail (no tracker label found)")
			else
				logFarm("no restock tracker text and no compass trail; job does not seem active")
				return false, "accepted job is not the restock quest"
			end

			Library:Notify("Job Found!", 3)

			return runRestockRoute(isCancelled)
		end

		local function runDeliverySequence(isCancelled)
			logFarm("delivery: sequence started")

			local accepted, acceptError = acceptJobFromPhone(DELIVERY_JOB_SLOT, isCancelled)
			if not accepted then
				return false, acceptError
			end

			-- Let the accepted job register before moving. No compass check
			-- here: those trails are restock specific, and waiting on one
			-- stopped the delivery route from ever starting.
			if not sleepUnlessCancelled(1, isCancelled) then
				return false, "cancelled"
			end

			Library:Notify("Delivery job accepted", 3)

			local putAway = unequipAllTools()
			if putAway then
				logFarm("delivery: put away the " .. putAway)
				task.wait(0.4)
			end

			-- Teleport through the delivery route in order; the last waypoint
			-- puts the player back at the shop for the next job.
			for index, waypoint in ipairs(DELIVERY_ROUTE) do
				if isCancelled() then
					return false, "cancelled"
				end

				if not teleportTo(waypoint) then
					return false, "no character to teleport"
				end

				local position = waypoint.Position
				logFarm(("delivery: waypoint %d/%d (%.1f, %.1f, %.1f)"):format(
					index, #DELIVERY_ROUTE, position.X, position.Y, position.Z))

				if not sleepUnlessCancelled(DELIVERY_WAYPOINT_DWELL, isCancelled) then
					return false, "cancelled"
				end
			end

			logFarm("delivery: route finished")
			return true
		end

		moneyFarmGroup:AddToggle("MoneyFarmEnabled", {
			Text = "Restock Farm",
			Default = false,
		})

		moneyFarmGroup:AddToggle("DeliveryFarmEnabled", {
			Text = "Delivery Farm",
			Default = false,
		})

		Toggles.DeliveryFarmEnabled:OnChanged(function(enabled)
			runtimeState.moneyFarmToken += 1
			local token = runtimeState.moneyFarmToken

			if not enabled then
				return
			end

			-- The two farms drive the same character, so only one at a time.
			if Toggles.MoneyFarmEnabled.Value then
				Toggles.MoneyFarmEnabled:SetValue(false)
			end

			task.spawn(function()
				local function isCancelled()
					return token ~= runtimeState.moneyFarmToken or not Toggles.DeliveryFarmEnabled.Value
				end

				while not isCancelled() do
					local ok, message = runDeliverySequence(isCancelled)
					setWKeyHeld(false)
					setMovementOverrideActive(false)

					if ok then
						Library:Notify("Delivery Farm: route complete, taking the next job", 3)
					elseif message ~= "cancelled" then
						logFarm("delivery stopped: " .. tostring(message))
						Library:Notify("Delivery Farm: " .. tostring(message), 5)
					end

					if isCancelled() then
						break
					end

					if not sleepUnlessCancelled(randomRange(3, 6), isCancelled) then
						break
					end
				end
			end)
		end)

		Toggles.MoneyFarmEnabled:OnChanged(function(enabled)
			runtimeState.moneyFarmToken += 1
			local token = runtimeState.moneyFarmToken

			if not enabled then
				return
			end

			-- The two farms drive the same character, so only one at a time.
			if Toggles.DeliveryFarmEnabled.Value then
				Toggles.DeliveryFarmEnabled:SetValue(false)
			end

			task.spawn(function()
				local function isCancelled()
					return token ~= runtimeState.moneyFarmToken or not Toggles.MoneyFarmEnabled.Value
				end

				-- Keep accepting and running jobs until the toggle is turned off.
				while not isCancelled() do
					local ok, message = runMoneyFarmSequence(isCancelled)
					setWKeyHeld(false)
					setMovementOverrideActive(false)

					if ok then
						Library:Notify("Money Farm: restock route complete, grabbing the next job", 3)
					elseif message ~= "cancelled" then
						logFarm("stopped: " .. tostring(message))
						Library:Notify("Money Farm: " .. tostring(message) .. " - retrying", 5)
					end

					if isCancelled() then
						break
					end

					-- Breathe between jobs; a bit longer after a failure so a
					-- broken state doesn't spam retries.
					if not sleepUnlessCancelled(ok and randomRange(2.5, 6) or randomRange(5, 9), isCancelled) then
						break
					end
				end
			end)
		end)
	end

	do
		ThemeManager:SetLibrary(Library)
		SaveManager:SetLibrary(Library)
		SaveManager:IgnoreThemeSettings()
		ThemeManager:SetFolder("HuajHub")
		SaveManager:SetFolder("HuajHub/" .. GAME_KEY)
		SaveManager:BuildConfigSection(Tabs.Settings)
		ThemeManager:ApplyToTab(Tabs.Settings)
		SaveManager:LoadAutoloadConfig()

		local menuGroup = Tabs.Settings:AddLeftGroupbox("Menu")
		menuGroup:AddButton("Unload", function() Library:Unload() end)
	end

	warn("HuajHub loaded: " .. GAME_KEY)
end

return MSKen