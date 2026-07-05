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

			-- Walks a trail's dots starting from the one closest to the player,
			-- heading toward whichever end of the trail is farther away (the
			-- objective end).
			local function followCompassDots(trailFolder)
				local dots = getCompassDots(trailFolder)
				if #dots == 0 then
					return false, "trail " .. trailFolder.Name .. " has no dots"
				end

				local root = getCharacterRoot()
				if not root then
					return false, "no character root"
				end

				local closestIndex = 1
				local closestDistance = math.huge
				for i, dot in ipairs(dots) do
					local distance = (dot.position - root.Position).Magnitude
					if distance < closestDistance then
						closestIndex = i
						closestDistance = distance
					end
				end

				local distanceToFirst = (dots[1].position - root.Position).Magnitude
				local distanceToLast = (dots[#dots].position - root.Position).Magnitude

				local lastIndex, step
				if distanceToLast >= distanceToFirst then
					lastIndex, step = #dots, 1
				else
					lastIndex, step = 1, -1
				end

				logFarm(("following %d compass dots (from dot %d toward dot %d)"):format(
					math.abs(lastIndex - closestIndex) + 1, dots[closestIndex].index, dots[lastIndex].index))

				for i = closestIndex, lastIndex, step do
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
				-- stands still for the click. The destination dot marks where
				-- the game says this trail's objective is.
				setWKeyHeld(false)
				setWalkTarget(nil)
				return true, nil, dots[lastIndex].position
			end

			-- Parts already fired this job. Firing a spot twice is an invalid
			-- click server-side, so each part is clicked at most once per job.
			local firedParts = {}

			-- The clickable job part closest to the trail's destination dot —
			-- the objective the compass was pointing at. Measuring from the
			-- player instead can grab a neighboring shelf spot, which the
			-- server rejects as an invalid click.
			local function nearestClickTarget(fromPosition)
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
				logFarm("click candidates (dist from trail end): " .. table.concat(summary, ", "))

				return candidates[1].part, candidates[1].distance
			end

			-- Dot instances recorded just before each fire; a trail containing
			-- any dot the snapshot has never seen is the one the game just
			-- drew, i.e. the objective it wants next. Instances, not counts:
			-- the game can redraw a trail by swapping its dots for new ones
			-- with the same count. This is the ONLY navigation signal used -
			-- guessing trails is what caused invalid clicks.
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

			local function getQuestProgress()
				local label = findRestockQuestLabel()
				local done = label and label.Text:match("(%d+)%s*/")
				return tonumber(done)
			end

			-- Counted restocks since the last Stock click. Every logged kick
			-- happened on the 4th spot fire in a row: the Stock click hands
			-- the player 3 items, so after 3 restocks it's back to the box.
			local ITEMS_PER_STOCK_VISIT = 3
			local spotsSinceStock = 0

			-- Walks up to the target if needed and fires its ClickDetector,
			-- guarded by the range gates. Only returns false on cancellation;
			-- a skipped click is not fatal.
			local function approachAndFire(target)
				local root = getCharacterRoot()
				local clickDistance = root and (target.Position - root.Position).Magnitude or math.huge
				if clickDistance > 5 then
					walkTo(target.Position, isCancelled)
					setWKeyHeld(false)
					setWalkTarget(nil)
					root = getCharacterRoot()
					clickDistance = root and (target.Position - root.Position).Magnitude or math.huge
				end

				if isCancelled() then
					return false, "cancelled"
				end

				if clickDistance > 5.5 then
					-- Never fire from outside the 6 stud range.
					logFarm(("still %.1f studs from %s; skipping this click"):format(clickDistance, target.Name))
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
				snapshotTrailDots()
				-- Spots are one-shot, but the Stock box is revisited over and
				-- over, so it stays fireable.
				if target.Name ~= "Stock" then
					firedParts[target] = true
				end
				fireclickdetector(target:FindFirstChildOfClass("ClickDetector"))

				if target.Name == "Stock" then
					spotsSinceStock = 0
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
						spotsSinceStock += 1
						logFarm(("server counted the restock (%s/12, %d since last stock visit)"):format(
							tostring(getQuestProgress()), spotsSinceStock))
					else
						logFarm("quest counter did NOT increase after that fire - the server rejected it")
					end
				end

				return true
			end

			-- Stock visit + up to 3 spots, repeated, with headroom for retries.
			local MAX_CYCLES = 30

			for cycle = 1, MAX_CYCLES do
				if isCancelled() then
					return false, "cancelled"
				end

				-- Once the tracker stops showing the restock text the job is done.
				if cycle > 1 and not findRestockQuestLabel() then
					logFarm("quest tracker no longer shows the restock text; route done")
					break
				end

				if spotsSinceStock >= ITEMS_PER_STOCK_VISIT then
					-- Items used up: back to the Stock box before touching any
					-- more spots. Follow the game's trail there if it draws
					-- one quickly, otherwise walk straight to the box.
					logFarm(("%d restocks since the last stock visit; returning to the Stock box"):format(spotsSinceStock))

					local stockTrail = nil
					local stockTrailDeadline = os.clock() + 3
					while os.clock() < stockTrailDeadline do
						if isCancelled() then
							return false, "cancelled"
						end

						stockTrail = findFreshTrail()
						if stockTrail then
							break
						end

						task.wait(0.15)
					end

					if stockTrail then
						logFarm("following the game's trail: " .. stockTrail.Name)
						local moved, moveError = followCompassDots(stockTrail)
						if not moved then
							return false, moveError
						end
					end

					local stockPart = findWorkspaceChild({ "Jobs", "Restock", "JLF", "Stock" })
					if not (stockPart and stockPart:FindFirstChildOfClass("ClickDetector")) then
						return false, "Stock part not found for the refill"
					end

					local fired, fireError = approachAndFire(stockPart)
					if not fired then
						return false, fireError
					end
				else
					-- Follow ONLY the trail the game draws (its dots appeared
					-- since the last fire) - never guess ahead of it.
					local trailFolder = nil
					local trailDeadline = os.clock() + 12
					while os.clock() < trailDeadline do
						if isCancelled() then
							return false, "cancelled"
						end

						trailFolder = findFreshTrail()
						if trailFolder then
							logFarm("following the game's trail: " .. trailFolder.Name)
							break
						end

						task.wait(0.15)
					end

					if not trailFolder then
						local compass = workspace:FindFirstChild(COMPASS_FOLDER_NAME)
						if compass then
							local contents = {}
							for _, child in ipairs(compass:GetChildren()) do
								table.insert(contents, ("%s(%d)"):format(child.Name, #child:GetChildren()))
							end
							logFarm("CompassPaths contents at timeout: " .. table.concat(contents, ", "))
						end

						logFarm("no new compass trail appeared within 12s; route done")
						break
					end

					local moved, moveError, trailEndPosition = followCompassDots(trailFolder)
					if not moved then
						return false, moveError
					end

					local target, targetDistance = nearestClickTarget(trailEndPosition)
					if not target then
						return false, "no clickable job part near the end of the path"
					end

					if targetDistance > 3.5 then
						-- The nearest part is too far from the trail end to be
						-- this trail's objective. Firing anything else is an
						-- invalid click, so fire nothing.
						logFarm(("%s is %.1f studs from the trail end - not the objective; skipping the fire"):format(target.Name, targetDistance))
					else
						local fired, fireError = approachAndFire(target)
						if not fired then
							return false, fireError
						end
					end
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
