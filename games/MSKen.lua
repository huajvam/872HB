local MSKen = {}
local GAME_KEY = "ms_ken"

local Library = sharedRequire("ui/Linoria/Library.lua")
local ThemeManager = sharedRequire("ui/Linoria/addons/ThemeManager.lua")
local SaveManager = sharedRequire("ui/Linoria/addons/SaveManager.lua")

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

local GLOBAL_ENV = getgenv and getgenv() or _G
local HUAJ_HUB_MSKEN_INIT_KEY = "__huaj_hub_msken_initialized_v1"
local HUAJ_HUB_MSKEN_LIBRARY_KEY = "__huaj_hub_msken_library_v1"

local PHONE_CONTAINER_PATH = { "Phone", "Container", "PhoneFrame", "Container" }
local JOBS_BUTTON_PATH = { "Phone", "Container", "PhoneFrame", "Container", "PhoneLabel", "HomeScreen", "img", "HomeFrame", "Jobs", "img" }
local ACCEPT_BUTTON_PATH = { "Phone", "Container", "PhoneFrame", "Container", "PhoneLabel", "JobsScreen", "img", "jobs", "scroll", "1", "img", "accept" }
local QUEST_NAME_PATH = { "Quests", "Frame", "quests", "template", "container", "name" }
local TARGET_QUEST_TEXT = "You still need to restock 0 / 12 items!"

local STOCK_PART_PATH = { "Jobs", "Restock", "JLF", "Stock" }
local SPOTS_FOLDER_PATH = { "Jobs", "Restock", "JLF", "Spots" }

-- The Stock/Spots ClickDetectors have a 6 stud activation range, so the player
-- is parked as deep below the target part as that range allows: underground but
-- still close enough to fire the click.
local UNDERGROUND_DEPTH = 5.5

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

-- Steps the HumanoidRootPart toward the target each frame at the speed set by
-- the CFrame Speed slider (studs per second), instead of teleporting.
local function moveRootTo(targetPosition, isCancelled)
	while true do
		if isCancelled and isCancelled() then
			return false
		end

		local root = getCharacterRoot()
		if not root then
			return false
		end

		local speed = 50
		if Options and Options.MoneyFarmSpeed then
			speed = Options.MoneyFarmSpeed.Value
		end

		local deltaTime = task.wait()
		local offset = targetPosition - root.Position
		local distance = offset.Magnitude
		local step = math.max(speed, 1) * deltaTime

		root.AssemblyLinearVelocity = Vector3.zero

		if distance <= step then
			root.CFrame = CFrame.new(targetPosition)
			return true
		end

		root.CFrame = CFrame.new(root.Position + offset.Unit * step)
	end
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

			local stockPart = findWorkspaceChild(STOCK_PART_PATH)
			if not (stockPart and stockPart:IsA("BasePart") and stockPart:FindFirstChildOfClass("ClickDetector")) then
				return false, "Stock part or its ClickDetector not found"
			end

			local spotsFolder = findWorkspaceChild(SPOTS_FOLDER_PATH)
			if not spotsFolder then
				return false, "Spots folder not found"
			end

			logFarm("restock route started; moving under the Stock box")

			local platform = Instance.new("Part")
			platform.Name = "HuajHubFarmPlatform"
			platform.Size = Vector3.new(8, 1, 8)
			platform.Anchored = true
			platform.CanCollide = true
			platform.Transparency = 0.5
			platform.Parent = workspace

			local function finish(ok, message)
				platform:Destroy()
				return ok, message
			end

			-- Sinks the player underground, moves them under the target at the
			-- slider speed, parks them on the platform within click range, and
			-- fires the part's ClickDetector.
			local function moveUnderAndClick(part)
				local detector = part:FindFirstChildOfClass("ClickDetector")
				local root = getCharacterRoot()
				if not detector or not root then
					return false
				end

				local underPosition = part.Position - Vector3.new(0, UNDERGROUND_DEPTH, 0)

				-- Go straight down first, then travel underground to the target.
				local sinkPosition = Vector3.new(root.Position.X, underPosition.Y, root.Position.Z)
				if not moveRootTo(sinkPosition, isCancelled) then
					return false
				end

				platform.Position = underPosition - Vector3.new(0, 3.5, 0)
				if not moveRootTo(underPosition, isCancelled) then
					return false
				end

				task.wait(0.2)
				if isCancelled() then
					return false
				end

				logFarm("firing ClickDetector on " .. part:GetFullName())
				fireclickdetector(detector)
				return true
			end

			if not moveUnderAndClick(stockPart) then
				return finish(false, isCancelled() and "cancelled" or "could not click the Stock box")
			end

			if not sleepUnlessCancelled(5, isCancelled) then
				return finish(false, "cancelled")
			end

			for _, spot in ipairs(spotsFolder:GetChildren()) do
				if isCancelled() then
					return finish(false, "cancelled")
				end

				if spot:IsA("BasePart") and spot:FindFirstChildOfClass("ClickDetector") then
					logFarm("moving under spot: " .. spot.Name)
					if not moveUnderAndClick(spot) and isCancelled() then
						return finish(false, "cancelled")
					end

					if not sleepUnlessCancelled(5, isCancelled) then
						return finish(false, "cancelled")
					end
				end
			end

			return finish(true)
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

			-- Verify the accepted job is the restock quest by checking the quest
			-- tracker text. Matches on the "You still need to restock" prefix so
			-- varying item counts don't break it; the exact-text constant stays as
			-- documentation of the expected label.
			local jobConfirmed = false
			local lastQuestText = nil
			local questDeadline = os.clock() + 5
			while os.clock() < questDeadline do
				if isCancelled() then
					return false, "cancelled"
				end

				local questLabel = findGuiElement(QUEST_NAME_PATH)
				if questLabel then
					lastQuestText = questLabel.Text
					if questLabel.Text == TARGET_QUEST_TEXT
						or questLabel.Text:find("You still need to restock", 1, true) then
						jobConfirmed = true
						break
					end
				end

				task.wait(0.1)
			end

			if not jobConfirmed then
				logFarm("quest text never matched; last seen: " .. tostring(lastQuestText))
				return false, "accepted job is not the restock quest"
			end

			logFarm("restock quest confirmed: " .. tostring(lastQuestText))
			Library:Notify("Job Found!", 3)

			return runRestockRoute(isCancelled)
		end

		moneyFarmGroup:AddToggle("MoneyFarmEnabled", {
			Text = "Farm",
			Default = false,
		})

		moneyFarmGroup:AddSlider("MoneyFarmSpeed", {
			Text = "CFrame Speed",
			Default = 50,
			Min = 1,
			Max = 100,
			Rounding = 0,
			Suffix = " studs/s",
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

				local ok, message = runMoneyFarmSequence(isCancelled)
				if ok then
					Library:Notify("Money Farm: restock route complete", 3)
				elseif message ~= "cancelled" then
					Library:Notify("Money Farm: " .. tostring(message), 5)
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
