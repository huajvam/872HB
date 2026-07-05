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
		local function runMoneyFarmSequence(isCancelled)
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
			clickGuiElement(phoneContainer)

			local jobsButton = waitForGuiElement(JOBS_BUTTON_PATH, 5, isCancelled)
			if not jobsButton then
				return false, "Jobs button not found (is the phone open?)"
			end

			task.wait(0.3)
			if isCancelled() then
				return false, "cancelled"
			end
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
			clickGuiElement(acceptButton)

			return true
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

				local ok, message = runMoneyFarmSequence(isCancelled)
				if ok then
					Library:Notify("Money Farm: job accepted", 3)
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
