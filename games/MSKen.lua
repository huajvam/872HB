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
local ACCEPT_BUTTON_PATH = { "Phone", "Container", "PhoneFrame", "Container", "PhoneLabel", "JobsScreen", "img", "jobs", "scroll", "1", "img", "accept" }
-- Any label under PlayerGui.Quests containing this text marks the restock job
-- as active. Matched by scanning descendants because quest rows are cloned
-- from a template at runtime, so their exact paths aren't stable.
local RESTOCK_QUEST_TEXT = "You still need to restock"

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

-- Finds the live quest entry (a visible clone of the template row) by
-- scanning every label under PlayerGui.Quests for the restock text.
local function findRestockQuestLabel()
	local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local questsGui = playerGui and playerGui:FindFirstChild("Quests")
	if not questsGui then
		return nil
	end

	for _, descendant in ipairs(questsGui:GetDescendants()) do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton"))
			and descendant.Text:find(RESTOCK_QUEST_TEXT, 1, true) then
			return descendant
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

local function walkTo(position, isCancelled)
	local deadline = os.clock() + 10
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
			if type(fireclickdetector) ~= "function" then
				return false, "this executor does not support fireclickdetector"
			end

			logFarm("restock route started; following the compass path")
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

			local function getQuestProgress()
				local label = findRestockQuestLabel()
				local done = label and label.Text:match("(%d+)%s*/")
				return tonumber(done)
			end

			-- Only a part the player is basically standing on gets fired.
			local SUPER_CLOSE_RANGE = 4

			-- Fires the target's ClickDetector if the player is close enough.
			-- Only returns false on cancellation; a skipped click is not fatal.
			local function approachAndFire(target)
				local root = getCharacterRoot()
				local clickDistance = root and (target.Position - root.Position).Magnitude or math.huge

				if clickDistance > SUPER_CLOSE_RANGE then
					walkTo(target.Position, isCancelled)
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

				-- Short human-like pause to line up the click.
				if not sleepUnlessCancelled(randomRange(1.2, 2.4), isCancelled) then
					return false, "cancelled"
				end

				local questLabel = findRestockQuestLabel()
				logFarm(("quest before fire: %s"):format(questLabel and questLabel.Text or "<no label>"))
				logFarm(("firing ClickDetector on %s (%.1f studs away)"):format(target:GetFullName(), clickDistance))

				local progressBefore = getQuestProgress()
				firedParts[target] = true
				fireclickdetector(target:FindFirstChildOfClass("ClickDetector"))

				if target.Name == "Stock" then
					return true
				end

				-- For spot clicks, wait until the server actually counts the
				-- restock, then move on immediately.
				if progressBefore ~= nil then
					local counted = false
					local countDeadline = os.clock() + 6
					while os.clock() < countDeadline do
						if isCancelled() then
							return false, "cancelled"
						end

						local progressNow = getQuestProgress()
						if progressNow and progressNow > progressBefore then
							counted = true
							break
						end

						task.wait(0.15)
					end

					if counted then
						logFarm(("server counted the restock (%s/12)"):format(tostring(getQuestProgress())))
					else
						logFarm("quest counter did NOT increase after that fire - the server rejected it")
					end
				end

				return true
			end

			local function getTrailByIndex(index)
				local compass = workspace:FindFirstChild(COMPASS_FOLDER_NAME)
				return compass and compass:FindFirstChild(("%s_%d"):format(TRAIL_NAME_PREFIX, index)) or nil
			end

			local function getSpotByIndex(index)
				local spotsFolder = findWorkspaceChild({ "Jobs", "Restock", "JLF", "Spots" })
				local children = spotsFolder and spotsFolder:GetChildren()
				return children and children[index] or nil
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

				return approachAndFire(stockPart)
			end

			-- The job: click the Stock box ONCE, then click all 12 spots in
			-- order. There is no returning to the Stock box.
			local stockClicked, stockError = clickStockOnce()
			if not stockClicked then
				return false, stockError
			end

			for spotIndex = 1, 12 do
				if isCancelled() then
					return false, "cancelled"
				end

				-- Once the tracker stops showing the restock text the job is done.
				if spotIndex > 1 and not findRestockQuestLabel() then
					logFarm("quest tracker no longer shows the restock text; route done")
					break
				end

				-- Follow this spot's own trail if it has dots (waiting briefly
				-- for them to stream in), otherwise walk directly to the spot.
				local trailFolder = getTrailByIndex(spotIndex)
				local dotsDeadline = os.clock() + 5
				while os.clock() < dotsDeadline do
					if isCancelled() then
						return false, "cancelled"
					end

					trailFolder = getTrailByIndex(spotIndex)
					if trailFolder and #getCompassDots(trailFolder) > 0 then
						break
					end

					task.wait(0.15)
				end

				-- Pick WHICH shelf to fire from the game's own signals: the
				-- trail's final dot when there is one, or the indexed spot
				-- part when there isn't. Never from player proximity.
				local target = nil

				if trailFolder and #getCompassDots(trailFolder) > 0 then
					local moved, moveError, trailEndPosition = followCompassDots(trailFolder)
					if not moved then
						return false, moveError
					end

					local candidate, candidateDistance = nearestUnfiredPartTo(trailEndPosition)
					if candidate and candidateDistance <= 3.5 then
						target = candidate
					elseif candidate then
						logFarm(("%s is %.1f studs from the trail's last dot - not the objective; not firing"):format(
							candidate.Name, candidateDistance))
					end
				else
					local spotPart = getSpotByIndex(spotIndex)
					if not spotPart or not spotPart:IsA("BasePart") or not spotPart:FindFirstChildOfClass("ClickDetector") then
						logFarm(("no trail and no usable spot part for #%d; skipping it"):format(spotIndex))
					elseif firedParts[spotPart] then
						logFarm(("spot #%d was already fired; skipping it"):format(spotIndex))
					else
						logFarm(("no dots for %s_%d; walking straight to spot #%d"):format(TRAIL_NAME_PREFIX, spotIndex, spotIndex))
						walkTo(spotPart.Position, isCancelled)
						setWKeyHeld(false)
						setWalkTarget(nil)

						if isCancelled() then
							return false, "cancelled"
						end

						target = spotPart
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
			for sweep = 1, 6 do
				if isCancelled() then
					return false, "cancelled"
				end

				if not findRestockQuestLabel() then
					break
				end

				logFarm(("sweep %d: quest still active, hunting leftover spots"):format(sweep))

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
					walkTo(best.Position, isCancelled)
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

			return true
		end

		local function runMoneyFarmSequence(isCancelled)
			logFarm("sequence started")

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
			logFarm("clicking the job frame for 3 seconds")
			-- Click the job frame repeatedly for 3 seconds to make sure it registers,
			-- then move on to the accept button.
			local clickDeadline = os.clock() + 3
			while os.clock() < clickDeadline do
				if isCancelled() then
					return false, "cancelled"
				end
				clickGuiElement(jobsButton, 0.75, 0.5)
				task.wait(0.15)
			end

			local acceptButton = waitForGuiElement(ACCEPT_BUTTON_PATH, 5, isCancelled)
			if not acceptButton then
				return false, "Accept button not found on the jobs screen"
			end

			task.wait(0.3)
			if isCancelled() then
				return false, "cancelled"
			end
			logFarm("clicking the accept button")
			clickGuiElement(acceptButton)

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

		moneyFarmGroup:AddToggle("MoneyFarmEnabled", {
			Text = "Farm",
			Default = false,
		})

		Toggles.MoneyFarmEnabled:OnChanged(function(enabled)
			runtimeState.moneyFarmToken += 1
			local token = runtimeState.moneyFarmToken

			if not enabled then
				return
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
