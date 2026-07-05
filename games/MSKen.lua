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

local function logFarm(message)
	warn("[HuajHub][MoneyFarm] " .. tostring(message))
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

-- The default camera scripts overwrite CFrame writes every frame, so steering
-- only sticks while the camera is Scriptable; saved type is restored after.
-- While active, a RenderStepped loop eases the camera toward a chase view of
-- the current steer target every rendered frame, which keeps both the view
-- and the W-direction smooth.
local savedCameraType = nil
local steerTargetPosition = nil
local steerConnection = nil

local function updateFarmCamera(deltaTime)
	local camera = workspace.CurrentCamera
	local root = getCharacterRoot()
	if not camera or not root or not steerTargetPosition then
		return
	end

	local look = steerTargetPosition - root.Position
	look = Vector3.new(look.X, 0, look.Z)
	if look.Magnitude <= 0.001 then
		return
	end

	look = look.Unit

	-- Third-person chase view: behind and above the player, facing the target,
	-- so held W (camera-relative) runs straight at it.
	local desired = CFrame.lookAt(root.Position - look * 10 + Vector3.new(0, 6, 0), root.Position + look * 5)
	local alpha = math.clamp((deltaTime or 0.016) * 8, 0, 1)
	camera.CFrame = camera.CFrame:Lerp(desired, alpha)
end

local function setFarmCameraActive(active)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	if active then
		if savedCameraType == nil then
			savedCameraType = camera.CameraType
		end
		camera.CameraType = Enum.CameraType.Scriptable

		if not steerConnection then
			steerConnection = RunService.RenderStepped:Connect(updateFarmCamera)
		end
	else
		if steerConnection then
			steerConnection:Disconnect()
			steerConnection = nil
		end
		steerTargetPosition = nil

		if savedCameraType ~= nil then
			camera.CameraType = savedCameraType
			savedCameraType = nil
		end
	end
end

local function steerCameraToward(position)
	steerTargetPosition = position
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

		-- Flag it if W is held but the character isn't actually moving; that
		-- means the key input isn't reaching the game.
		if lastPosition == nil or (root.Position - lastPosition).Magnitude > 0.5 then
			lastPosition = root.Position
			lastProgressAt = os.clock()
		elseif wKeyHeld and not stallReported and os.clock() - lastProgressAt > 2 then
			stallReported = true
			logFarm("W is held but the character is not moving - key input may not be reaching the game")
		end

		steerCameraToward(position)
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

	Library:OnUnload(function()
		runtimeState.moneyFarmToken += 1
		setWKeyHeld(false)
		setFarmCameraActive(false)
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
			setFarmCameraActive(true)

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

				-- Arrived; let go of W and freeze the camera so the character
				-- stops for the click.
				setWKeyHeld(false)
				steerCameraToward(nil)
				return true
			end

			-- The nearest clickable job part (a Stock box or restock spot from
			-- any store); after walking the path this is what the trail was
			-- leading to.
			local function nearestClickTarget()
				local root = getCharacterRoot()
				if not root then
					return nil
				end

				local jobsFolder = findWorkspaceChild({ "Jobs" })
				if not jobsFolder then
					return nil
				end

				local best, bestDistance = nil, math.huge

				for _, descendant in ipairs(jobsFolder:GetDescendants()) do
					if descendant:IsA("ClickDetector") then
						local part = descendant.Parent
						if part and part:IsA("BasePart") then
							local distance = (part.Position - root.Position).Magnitude
							if distance < bestDistance then
								best, bestDistance = part, distance
							end
						end
					end
				end

				return best, bestDistance
			end

			-- Each trail is followed once, in numeric order: Path_Stocker (the
			-- Stock box) first, then Path_Stocker_1 through Path_Stocker_12.
			local visitedTrails = {}

			local function trailOrder(folder)
				local suffix = folder.Name:match("_(%d+)$")
				return suffix and tonumber(suffix) or 0
			end

			local function pickNextTrail()
				local best, bestOrder = nil, math.huge

				for _, folder in ipairs(getTrailFolders()) do
					if not visitedTrails[folder.Name] and #getCompassDots(folder) > 0 then
						local order = trailOrder(folder)
						if order < bestOrder then
							best, bestOrder = folder, order
						end
					end
				end

				return best
			end

			-- Stock pickup + 12 spots, with headroom for retries.
			local MAX_CYCLES = 20

			for cycle = 1, MAX_CYCLES do
				if isCancelled() then
					return false, "cancelled"
				end

				-- Once the tracker stops showing the restock text the job is done.
				if cycle > 1 and not findRestockQuestLabel() then
					logFarm("quest tracker no longer shows the restock text; route done")
					break
				end

				-- Trails for the spots spawn shortly after the Stock click (and
				-- their dots can stream in late), so poll instead of giving up
				-- on the first empty look.
				local trailFolder = nil
				local trailDeadline = os.clock() + 10
				while os.clock() < trailDeadline do
					if isCancelled() then
						return false, "cancelled"
					end

					trailFolder = pickNextTrail()
					if trailFolder then
						break
					end

					task.wait(0.2)
				end

				if not trailFolder then
					logFarm("no unvisited compass trail appeared within 10s; route done")
					break
				end

				logFarm("following trail: " .. trailFolder.Name)
				local moved, moveError = followCompassDots(trailFolder)
				if not moved then
					return false, moveError
				end

				visitedTrails[trailFolder.Name] = true

				local target, targetDistance = nearestClickTarget()
				if not target then
					return false, "no clickable job part near the end of the path"
				end

				-- Get within the detector's activation range first.
				if targetDistance > 5 then
					walkTo(target.Position, isCancelled)
					setWKeyHeld(false)
				end

				-- Stand at the part for a moment before firing, like a player
				-- lining up the click. Randomized: metronome-perfect intervals
				-- are what interaction anti-cheats look for.
				if not sleepUnlessCancelled(randomRange(1.6, 3.4), isCancelled) then
					return false, "cancelled"
				end

				logFarm(("firing ClickDetector on %s (%.1f studs away)"):format(target:GetFullName(), targetDistance))
				fireclickdetector(target:FindFirstChildOfClass("ClickDetector"))

				-- Brief settle for the click to register; the next cycle already
				-- polls for the next trail, so no long wait is needed here.
				if not sleepUnlessCancelled(randomRange(0.8, 1.9), isCancelled) then
					return false, "cancelled"
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
					setFarmCameraActive(false)

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
