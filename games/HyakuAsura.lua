local HyakuAsura = {}
local GAME_KEY = "hyaku_asura"

local Services = sharedRequire("@utils/Services.lua")
local Maid = sharedRequire("@utils/Maid.lua")
local CharacterUtils = sharedRequire("@utils/CharacterUtils.lua")
local EntityESP = sharedRequire("classes/EntityESP.lua")

local Players, MarketplaceService, RunService, VirtualInputManager = Services:Get(
	"Players",
	"MarketplaceService",
	"RunService",
	"VirtualInputManager"
)

local Library = sharedRequire("ui/Linoria/Library.lua")
local ThemeManager = sharedRequire("ui/Linoria/addons/ThemeManager.lua")
local SaveManager = sharedRequire("ui/Linoria/addons/SaveManager.lua")

local GLOBAL_ENV = getgenv and getgenv() or _G
local HUAJ_HUB_HYAKU_INIT_KEY = "__huaj_hub_hyaku_initialized_v1"
local HUAJ_HUB_HYAKU_LIBRARY_KEY = "__huaj_hub_hyaku_library_v1"
local HUAJ_HUB_HYAKU_ESP_DRAWINGS_KEY = "__huaj_hub_hyaku_esp_drawings_v1"
local HUAJ_HUB_HYAKU_REMOTE_BLOCK_HOOK_KEY = "__huaj_hub_hyaku_remote_block_hook_v1"
local HUAJ_HUB_HYAKU_REMOTE_BLOCK_CALLBACK_KEY = "__huaj_hub_hyaku_remote_block_callback_v1"
local HYAKU_RHYTHM_REMOTE_INTERVAL = 0.03
local HYAKU_PROMPT_SCAN_INTERVAL = 0.12

local LocalPlayer = Players.LocalPlayer
local maid = Maid.new()
local unloadCallbacks = {}

local getCharacterRoot = CharacterUtils.getRoot
local getCharacterHumanoid = CharacterUtils.getHumanoid
local getEspLiveFolder = CharacterUtils.getLiveFolder

local function registerLibraryUnloadCallback(callback)
	table.insert(unloadCallbacks, callback)
end

local function sanitizeTabLabel(name)
	if type(name) ~= "string" then
		return "Hyaku Asura"
	end

	name = name:gsub("[%z\1-\31]", "")
	name = name:match("^%s*(.-)%s*$") or name
	return name ~= "" and name or "Hyaku Asura"
end

local function getGameTabName()
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(game.PlaceId)
	end)

	if ok and type(info) == "table" and type(info.Name) == "string" then
		return sanitizeTabLabel(info.Name)
	end

	return "Hyaku Asura"
end

local function isLocalCharacter(model)
	return model ~= nil and LocalPlayer and LocalPlayer.Character == model
end

local function getEspTargetType(model)
	if not model or not model:IsA("Model") or isLocalCharacter(model) then
		return nil
	end

	local ownerPlayer = Players:GetPlayerFromCharacter(model)
	if ownerPlayer then
		return ownerPlayer ~= LocalPlayer and "player" or nil
	end

	local humanoid = getCharacterHumanoid(model)
	local root = getCharacterRoot(model)
	local hasAnimator = model:FindFirstChildWhichIsA("Animator", true) ~= nil
	local hasAnimationController = model:FindFirstChildWhichIsA("AnimationController", true) ~= nil

	if humanoid and root then
		return "mob"
	end

	if root and (hasAnimator or hasAnimationController) then
		return "mob"
	end

	return nil
end

local function getEspDistance(model)
	local localCharacter = LocalPlayer and LocalPlayer.Character
	local localRoot = getCharacterRoot(localCharacter)
	local targetRoot = getCharacterRoot(model)
	if not localRoot or not targetRoot then
		return math.huge
	end

	return (targetRoot.Position - localRoot.Position).Magnitude
end

local function getEspDisplayName(model, targetType)
	if targetType == "player" then
		local player = Players:GetPlayerFromCharacter(model)
		if player then
			return player.DisplayName ~= "" and player.DisplayName or player.Name
		end
	end

	return model.Name
end

local function clearGlobalEspDrawings(globalEspDrawings)
	for index = #globalEspDrawings, 1, -1 do
		local object = globalEspDrawings[index]
		if object then
			pcall(function()
				object.Visible = false
			end)
			pcall(function()
				if type(object.Remove) == "function" then
					object:Remove()
				elseif type(object.Destroy) == "function" then
					object:Destroy()
				end
			end)
		end
		globalEspDrawings[index] = nil
	end
end

local function iterEspCandidateModels()
	local models = {}
	local seen = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and not seen[character] then
			seen[character] = true
			table.insert(models, character)
		end
	end

	local liveFolder = getEspLiveFolder()
	if liveFolder then
		for _, child in ipairs(liveFolder:GetChildren()) do
			if child:IsA("Model") and not seen[child] then
				seen[child] = true
				table.insert(models, child)
			end
		end
	end

	return models
end

local function getToggleValue(key, default)
	local toggle = Toggles and Toggles[key]
	if toggle and toggle.Value ~= nil then
		return toggle.Value
	end
	return default
end

local function getOptionValue(key, default)
	local option = Options and Options[key]
	if option and option.Value ~= nil then
		return option.Value
	end
	return default
end

local function getLocalEntityModel()
	local entitiesFolder = workspace:FindFirstChild("Entities")
	if not entitiesFolder or not LocalPlayer then
		return nil
	end

	return entitiesFolder:FindFirstChild(LocalPlayer.Name)
end

local function getLocalEntityMainScript()
	local entityModel = getLocalEntityModel()
	if not entityModel then
		return nil
	end

	return entityModel:FindFirstChild("MainScript")
end

local function getLocalEntityStatsFolder()
	local mainScript = getLocalEntityMainScript()
	if not mainScript then
		return nil
	end

	return mainScript:FindFirstChild("Stats")
end

local function getLocalEntityAttributesFolder()
	local mainScript = getLocalEntityMainScript()
	if not mainScript then
		return nil
	end

	return mainScript:FindFirstChild("Attributes")
end

local function installRemoteBlockHook()
	if GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_HOOK_KEY] then
		return true
	end

	if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
		return false
	end

	local hookWrapper = newcclosure or function(callback)
		return callback
	end

	local originalNamecall
	originalNamecall = hookmetamethod(game, "__namecall", hookWrapper(function(self, ...)
		local args = table.pack(...)
		local callback = GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_CALLBACK_KEY]
		local isCallerCheckAvailable = type(checkcaller) == "function"

		if (not isCallerCheckAvailable or not checkcaller())
			and getnamecallmethod() == "FireServer"
		then
			if type(callback) == "function" then
				local ok, shouldBlock = pcall(callback, self, args)
				if ok and shouldBlock == true then
					return nil
				end
			end
		end

		return originalNamecall(self, ...)
	end))

	GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_HOOK_KEY] = true
	return true
end

function HyakuAsura.init(_context)
	if GLOBAL_ENV[HUAJ_HUB_HYAKU_INIT_KEY] then
		local existingLibrary = GLOBAL_ENV[HUAJ_HUB_HYAKU_LIBRARY_KEY]
		if type(existingLibrary) == "table" and type(existingLibrary.Unload) == "function" then
			pcall(function()
				existingLibrary:Unload()
			end)
		end

		GLOBAL_ENV[HUAJ_HUB_HYAKU_INIT_KEY] = nil
		GLOBAL_ENV[HUAJ_HUB_HYAKU_LIBRARY_KEY] = nil
	end

	GLOBAL_ENV[HUAJ_HUB_HYAKU_INIT_KEY] = true
	GLOBAL_ENV[HUAJ_HUB_HYAKU_LIBRARY_KEY] = Library
	GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_CALLBACK_KEY] = nil

	installRemoteBlockHook()

	GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_CALLBACK_KEY] = function(remote, packedArgs)
		if not remote or not packedArgs or remote.Name ~= "Toggle?" then
			return false
		end

		local remoteParent = remote.Parent
		if not remoteParent or remoteParent.Name ~= "MainScript" then
			return false
		end

		local payload = packedArgs[1]
		if type(payload) ~= "table" then
			return false
		end

		return payload.Action == "Run"
	end

	local gameTabName = getGameTabName()

	Library:OnUnload(function()
		GLOBAL_ENV[HUAJ_HUB_HYAKU_REMOTE_BLOCK_CALLBACK_KEY] = nil
		for _, callback in ipairs(unloadCallbacks) do
			pcall(callback)
		end
	end)

	local Window = Library:CreateWindow({
		Title = "Huaj Hub",
		Center = true,
		AutoShow = true,
		Size = UDim2.fromOffset(550, 600),
		TabPadding = 0,
		MenuFadeTime = 0.2,
	})

	local Tabs = {
		Main = Window:AddTab(gameTabName),
		ESP = Window:AddTab("ESP"),
		Stats = Window:AddTab("Stats"),
		Settings = Window:AddTab("Settings"),
	}

	do
		local localCheatsGroup = Tabs.Main:AddLeftGroupbox("Local Cheats")
		local autoTrainGroup = Tabs.Main:AddRightGroupbox("Auto Train")
		local infiniteRhythmLoopToken = 0
		local autoBenchToken = 0
		local autoPullUpToken = 0
		local cachedBenchPromptFrame = nil
		local cachedBenchPromptLabel = nil
		local lastBenchVisibleKey = nil
		local lastBenchPromptScanAt = 0
		local rhythmChargeConnection
		local staminaConnection

		local function getRhythmInputRemote()
			local character = LocalPlayer and LocalPlayer.Character
			if not character then
				return nil
			end

			local mainScript = character:FindFirstChild("MainScript")
			if not mainScript then
				return nil
			end

			local inputRemote = mainScript:FindFirstChild("Input")
			if inputRemote and inputRemote:IsA("RemoteEvent") then
				return inputRemote
			end

			return nil
		end

		local function getRhythmChargeValue()
			local statsFolder = getLocalEntityStatsFolder()
			local rhythmCharge = statsFolder and statsFolder:FindFirstChild("RhythmCharge")
			if rhythmCharge and rhythmCharge:IsA("NumberValue") then
				return rhythmCharge
			end

			return nil
		end

		local function getStaminaValue()
			local statsFolder = getLocalEntityStatsFolder()
			local stamina = statsFolder and statsFolder:FindFirstChild("Stamina")
			if stamina and stamina:IsA("NumberValue") then
				return stamina
			end

			return nil
		end

		local function getSpeedBoostValue()
			local attributesFolder = getLocalEntityAttributesFolder()
			local speedBoost = attributesFolder and attributesFolder:FindFirstChild("SpeedIII")
			if speedBoost and speedBoost:IsA("BoolValue") then
				return speedBoost
			end

			return nil
		end

		local function applyInfiniteRhythmCharge()
			local rhythmCharge = getRhythmChargeValue()
			if not rhythmCharge then
				return false
			end

			pcall(function()
				rhythmCharge.Value = 100
			end)
			return true
		end

		local function stopInfiniteRhythmChargeHook()
			if rhythmChargeConnection then
				pcall(function()
					rhythmChargeConnection:Disconnect()
				end)
				rhythmChargeConnection = nil
			end
		end

		local function applyInfiniteStamina()
			local stamina = getStaminaValue()
			if not stamina then
				return false
			end

			pcall(function()
				stamina.Value = 100
			end)
			return true
		end

		local function stopInfiniteStaminaHook()
			if staminaConnection then
				pcall(function()
					staminaConnection:Disconnect()
				end)
				staminaConnection = nil
			end
		end

		local function startInfiniteStaminaHook()
			stopInfiniteStaminaHook()
			local stamina = getStaminaValue()
			if not stamina then
				return
			end

			applyInfiniteStamina()
			staminaConnection = stamina:GetPropertyChangedSignal("Value"):Connect(function()
				if Toggles and Toggles.InfiniteStaminaEnabled and Toggles.InfiniteStaminaEnabled.Value then
					applyInfiniteStamina()
				end
			end)
		end

		local function setSpeedBoostEnabled(enabled)
			local speedBoost = getSpeedBoostValue()
			if not speedBoost then
				return false
			end

			pcall(function()
				speedBoost.Value = enabled == true
			end)
			return true
		end

		local function startInfiniteRhythmChargeHook()
			stopInfiniteRhythmChargeHook()
			local rhythmCharge = getRhythmChargeValue()
			if not rhythmCharge then
				return
			end

			applyInfiniteRhythmCharge()
			rhythmChargeConnection = rhythmCharge:GetPropertyChangedSignal("Value"):Connect(function()
				if Toggles and Toggles.InfiniteRhythmEnabled and Toggles.InfiniteRhythmEnabled.Value then
					applyInfiniteRhythmCharge()
				end
			end)
		end

		local function fireInfiniteRhythmRemote(isDown)
			local inputRemote = getRhythmInputRemote()
			if not inputRemote then
				return false
			end

			local payload = {
				{
					KeyInfo = {
						Direction = "None",
						Name = "R",
						Airborne = false,
					},
					IsDown = isDown == nil and true or isDown,
				},
			}

			pcall(function()
				inputRemote:FireServer(unpack(payload))
			end)

			return true
		end

		local function startInfiniteRhythmLoop()
			infiniteRhythmLoopToken += 1
			local currentToken = infiniteRhythmLoopToken
			startInfiniteRhythmChargeHook()
			task.spawn(function()
				fireInfiniteRhythmRemote(true)
				while currentToken == infiniteRhythmLoopToken and Toggles.InfiniteRhythmEnabled and Toggles.InfiniteRhythmEnabled.Value do
					fireInfiniteRhythmRemote(true)
					applyInfiniteRhythmCharge()
					task.wait(HYAKU_RHYTHM_REMOTE_INTERVAL)
				end
			end)
		end

		local function stopInfiniteRhythmLoop()
			infiniteRhythmLoopToken += 1
			stopInfiniteRhythmChargeHook()
			fireInfiniteRhythmRemote(false)
		end

		-- Auto Train Automation Module
		local function getClosestTrainingSpot(spotName)
			if type(spotName) ~= "string" or spotName == "" then
				return nil
			end

			local trainingSpots = workspace:FindFirstChild("TrainingSpots")
			if not trainingSpots then
				return nil
			end

			local closest, dist = nil, math.huge
			local root = getCharacterRoot(LocalPlayer and LocalPlayer.Character)
			if not root then
				return nil
			end

			for _, folder in ipairs(trainingSpots:GetChildren()) do
				if folder.Name == spotName then
					local model = folder:FindFirstChildOfClass("Model") or folder:FindFirstChildWhichIsA("Model", true)
					local part = model and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true))
					if part then
						local d = (root.Position - part.Position).Magnitude
						if d < dist then
							dist = d
							closest = folder
						end
					end
				end
			end

			return closest
		end

		local function getTrainingSpotTeleportModel(spotFolder)
			if not spotFolder then
				return nil
			end

			if spotFolder:IsA("Model") then
				return spotFolder
			end

			local directModel = spotFolder:FindFirstChildOfClass("Model")
			if directModel then
				return directModel
			end

			local nestedModel = spotFolder:FindFirstChildWhichIsA("Model", true)
			if nestedModel then
				return nestedModel
			end

			local anyPart = spotFolder:FindFirstChildWhichIsA("BasePart", true)
			if anyPart then
				return anyPart.Parent
			end

			return nil
		end

		local function getTrainingSpotRemote(spotFolder)
			local directRadio = spotFolder and spotFolder:FindFirstChild("Radio")
			local directRemote = directRadio and directRadio:FindFirstChild("Remote")
			if directRemote and directRemote:IsA("RemoteEvent") then
				return directRemote
			end

			return nil
		end

		local function teleportCharacterToTrainingSpot(character, spotModel)
			if not character or not spotModel then
				return false
			end

			local targetCFrame = spotModel:GetPivot() * CFrame.new(0, 2, 0)
			local root = getCharacterRoot(character)

			if root then
				pcall(function()
					root.AssemblyLinearVelocity = Vector3.zero
				end)
				pcall(function()
					root.CFrame = targetCFrame
				end)
				return true
			end

			local ok = pcall(function()
				character:PivotTo(targetCFrame)
			end)
			return ok
		end

		local function normalizeBenchPromptText(text)
			if type(text) ~= "string" then
				return nil
			end

			text = text:upper():match("^%s*(.-)%s*$") or ""
			if text == "W" or text == "A" or text == "S" or text == "D" then
				return text
			end

			return nil
		end

		local function getPromptLabelKey(instance)
			if not instance then
				return nil
			end

			local okClassName, className = pcall(function()
				return instance.ClassName
			end)
			if not okClassName or className ~= "TextLabel" then
				return nil
			end

			local okText, text = pcall(function()
				return instance.Text
			end)
			if not okText then
				return nil
			end

			return normalizeBenchPromptText(text)
		end

		local function findNilInstanceByNameAndClass(name, className)
			if type(getnilinstances) ~= "function" then
				return nil
			end

			local ok, instances = pcall(function()
				return getnilinstances()
			end)
			if not ok or type(instances) ~= "table" then
				return nil
			end

			for _, instance in next, instances do
				if instance and instance.Name == name and instance.ClassName == className then
					return instance
				end
			end

			return nil
		end

		local function getBenchPromptFrame()
			if cachedBenchPromptFrame then
				local okParent = pcall(function()
					return cachedBenchPromptFrame.Parent
				end)
				if okParent then
					return cachedBenchPromptFrame
				end
				cachedBenchPromptFrame = nil
			end

			local now = os.clock()
			if (now - lastBenchPromptScanAt) < HYAKU_PROMPT_SCAN_INTERVAL then
				return nil
			end
			lastBenchPromptScanAt = now

			local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
			local trainingGui = playerGui and playerGui:FindFirstChild("Training")
			if trainingGui then
				local directFrame = trainingGui:FindFirstChild("KeyMiniGame")
					or trainingGui:FindFirstChild("KeyMinigame")
					or trainingGui:FindFirstChild("KeyMiniGame", true)
					or trainingGui:FindFirstChild("KeyMinigame", true)
				if directFrame then
					cachedBenchPromptFrame = directFrame
					return cachedBenchPromptFrame
				end
			end

			cachedBenchPromptFrame = findNilInstanceByNameAndClass("KeyMinigame", "Frame")
				or findNilInstanceByNameAndClass("KeyMiniGame", "Frame")
				or findNilInstanceByNameAndClass("KeyMinigame", "CanvasGroup")
				or findNilInstanceByNameAndClass("KeyMiniGame", "CanvasGroup")
			return cachedBenchPromptFrame
		end

		local function getBenchPromptLabel()
			local promptFrame = getBenchPromptFrame()
			if not promptFrame then
				cachedBenchPromptLabel = nil
				return nil
			end

			if cachedBenchPromptLabel then
				local okClassName, className = pcall(function()
					return cachedBenchPromptLabel.ClassName
				end)
				if okClassName and className == "TextLabel" then
					return cachedBenchPromptLabel
				end
				cachedBenchPromptLabel = nil
			end

			local okDescendants, descendants = pcall(function()
				return promptFrame:GetDescendants()
			end)
			if okDescendants and type(descendants) == "table" then
				for _, instance in ipairs(descendants) do
					if instance and instance.Name == "TextLabel" then
						local okClassName, className = pcall(function()
							return instance.ClassName
						end)
						if okClassName and className == "TextLabel" then
							cachedBenchPromptLabel = instance
							return cachedBenchPromptLabel
						end
					end
				end

				for _, instance in ipairs(descendants) do
					local okClassName, className = pcall(function()
						return instance.ClassName
					end)
					if okClassName and className == "TextLabel" then
						cachedBenchPromptLabel = instance
						return cachedBenchPromptLabel
					end
				end
			end

			cachedBenchPromptLabel = findNilInstanceByNameAndClass("TextLabel", "TextLabel")
			if cachedBenchPromptLabel then
				return cachedBenchPromptLabel
			end

			return nil
		end

		local function getBenchPromptKey()
			local promptLabel = getBenchPromptLabel()
			if not promptLabel then
				return nil
			end

			return getPromptLabelKey(promptLabel)
		end

		local function pressBenchPromptKey(key)
			local keyCode = Enum.KeyCode[key]
			if not VirtualInputManager or not keyCode then
				return false
			end

			pcall(function()
				VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
			end)
			task.wait(0.08)
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
			end)
			return true
		end

		local function holdInteractionKey(duration)
			if not VirtualInputManager then
				return
			end

			pcall(function()
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
			end)
			task.wait(duration or 0.3)
			pcall(function()
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
			end)
		end

		local function getAutoTrainToken(toggleKey)
			if toggleKey == "AutoBenchEnabled" then
				return autoBenchToken
			end

			if toggleKey == "AutoPullUpEnabled" then
				return autoPullUpToken
			end

			return -1
		end

		local function startTrainingSpotAutomation(toggleKey, spotName, options)
			local currentToken = getAutoTrainToken(toggleKey)
			options = options or {}
			
			task.spawn(function()
				while currentToken == getAutoTrainToken(toggleKey) and Toggles[toggleKey] and Toggles[toggleKey].Value do
					local spotFolder = getClosestTrainingSpot(spotName)
					local character = LocalPlayer and LocalPlayer.Character
					
					if spotFolder and character then
						local spotModel = getTrainingSpotTeleportModel(spotFolder)
						local spotRemote = getTrainingSpotRemote(spotFolder)
						
						if spotModel and spotRemote then
							-- Stealth Teleport with micro-wait to settle physics
							teleportCharacterToTrainingSpot(character, spotModel)
							task.wait(0.35)

							if options.HoldEBeforeStart then
								holdInteractionKey(options.HoldEDuration or 0.3)
								task.wait(0.1)
							end
							
							-- Start Training Remote
							local startArgs = {
								"Start",
								{
									Macro = false,
								},
							}

							pcall(function()
								spotRemote:FireServer(unpack(startArgs))
							end)
							task.wait(0.6)
							
							-- Prompt-driven WASD loop
							lastBenchVisibleKey = nil
							local trainingEndAt = os.clock() + (options.Duration or 60)
							while currentToken == getAutoTrainToken(toggleKey)
								and Toggles[toggleKey].Value
								and os.clock() < trainingEndAt
							do
								local promptedKey = getBenchPromptKey()
								if promptedKey then
									if promptedKey ~= lastBenchVisibleKey then
										lastBenchVisibleKey = promptedKey
										pressBenchPromptKey(promptedKey)
										task.wait(0.04)
									else
										task.wait(0.02)
									end
								else
									lastBenchVisibleKey = nil
									task.wait(0.05)
								end
							end
						end
					end
					task.wait(1)
				end
			end)
		end

		local function startAutoBench()
			autoBenchToken += 1
			startTrainingSpotAutomation("AutoBenchEnabled", "Bench", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoPullUp()
			autoPullUpToken += 1
			startTrainingSpotAutomation("AutoPullUpEnabled", "PullUp", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		localCheatsGroup:AddToggle("InfiniteRhythmEnabled", {
			Text = "Infinite Rhythm",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startInfiniteRhythmLoop()
			else
				stopInfiniteRhythmLoop()
			end
		end)

		localCheatsGroup:AddToggle("InfiniteStaminaEnabled", {
			Text = "Infinite Stamina",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startInfiniteStaminaHook()
				applyInfiniteStamina()
			else
				stopInfiniteStaminaHook()
			end
		end)

		localCheatsGroup:AddToggle("SpeedBoostEnabled", {
			Text = "Speed Boost",
			Default = false,
		}):OnChanged(function(enabled)
			setSpeedBoostEnabled(enabled)
		end)

		autoTrainGroup:AddToggle("AutoBenchEnabled", {
			Text = "Auto Bench",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				if Toggles and Toggles.AutoPullUpEnabled and Toggles.AutoPullUpEnabled.Value then
					pcall(function() Toggles.AutoPullUpEnabled:SetValue(false) end)
				end
				startAutoBench()
			else
				autoBenchToken += 1
			end
		end)

		autoTrainGroup:AddToggle("AutoPullUpEnabled", {
			Text = "Auto PullUp",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				if Toggles and Toggles.AutoBenchEnabled and Toggles.AutoBenchEnabled.Value then
					pcall(function() Toggles.AutoBenchEnabled:SetValue(false) end)
				end
				startAutoPullUp()
			else
				autoPullUpToken += 1
			end
		end)

		registerLibraryUnloadCallback(function()
			stopInfiniteRhythmLoop()
			stopInfiniteStaminaHook()
			setSpeedBoostEnabled(false)
			autoBenchToken += 1
			autoPullUpToken += 1
			if Toggles and Toggles.InfiniteRhythmEnabled then
				pcall(function() Toggles.InfiniteRhythmEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.InfiniteStaminaEnabled then
				pcall(function() Toggles.InfiniteStaminaEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.SpeedBoostEnabled then
				pcall(function() Toggles.SpeedBoostEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoBenchEnabled then
				pcall(function() Toggles.AutoBenchEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoPullUpEnabled then
				pcall(function() Toggles.AutoPullUpEnabled:SetValue(false) end)
			end
		end)
	end

	do
		local statsGroup = Tabs.Stats:AddLeftGroupbox("Stats")
		local statsRefreshToken = 0
		local trackedStats = {
			"AttackSpeed",
			"Agility",
			"Fat",
			"LowerMuscle",
			"UpperMuscle",
			"Strength",
			"StaminaInStat",
			"TotalPower",
		}
		local statsLabels = {}

		local function formatStatNumber(value)
			local numericValue = tonumber(value)
			if not numericValue then
				return "N/A"
			end

			if math.abs(numericValue - math.floor(numericValue + 0.5)) < 0.001 then
				return tostring(math.floor(numericValue + 0.5))
			end

			local formatted = string.format("%.2f", numericValue)
			formatted = formatted:gsub("(%..-)0+$", "%1")
			formatted = formatted:gsub("%.$", "")
			return formatted
		end

		local function refreshStatsTab()
			local statsFolder = getLocalEntityStatsFolder()

			if not statsFolder then
				for _, statName in ipairs(trackedStats) do
					local label = statsLabels[statName]
					if label then
						label:SetText(string.format("%s: N/A", statName))
					end
				end
				return
			end

			for _, statName in ipairs(trackedStats) do
				local statValue = statsFolder:FindFirstChild(statName)
				local displayValue = "N/A"
				if statValue and statValue:IsA("NumberValue") then
					displayValue = formatStatNumber(statValue.Value)
				end

				local label = statsLabels[statName]
				if label then
					label:SetText(string.format("%s: %s", statName, displayValue))
				end
			end
		end

		for _, statName in ipairs(trackedStats) do
			statsLabels[statName] = statsGroup:AddLabel(string.format("%s: N/A", statName))
		end

		local function startStatsRefreshLoop()
			statsRefreshToken += 1
			local currentToken = statsRefreshToken
			task.spawn(function()
				while currentToken == statsRefreshToken do
					refreshStatsTab()
					task.wait(0.2)
				end
			end)
		end

		startStatsRefreshLoop()

		registerLibraryUnloadCallback(function()
			statsRefreshToken += 1
		end)
	end

	do
		local espGroup = Tabs.ESP:AddLeftGroupbox("ESP")
		local espVisualGroup = Tabs.ESP:AddRightGroupbox("ESP Visuals")
		local playerEspEntries = {}
		local mobEspEntries = {}
		local globalEspDrawings = GLOBAL_ENV[HUAJ_HUB_HYAKU_ESP_DRAWINGS_KEY] or {}
		local drawingAvailable = type(Drawing) == "table" and type(Drawing.new) == "function"
		local espDrawUnavailableNotified = false
		local espShuttingDown = false

		GLOBAL_ENV[HUAJ_HUB_HYAKU_ESP_DRAWINGS_KEY] = globalEspDrawings

		local function clearEspCache(cache)
			for model, entry in pairs(cache) do
				cache[model] = nil
				if entry and type(entry.Destroy) == "function" then
					entry:Destroy()
				end
			end
		end

		local function forceClearEsp()
			clearEspCache(playerEspEntries)
			clearEspCache(mobEspEntries)
			clearGlobalEspDrawings(globalEspDrawings)
		end

		local function ensureEspEntry(cache, model, accentColor)
			if espShuttingDown or not drawingAvailable or not model or not model.Parent then
				return nil
			end

			local entry = cache[model]
			if not entry then
				entry = EntityESP.new(globalEspDrawings, accentColor, function()
					return espShuttingDown
				end)
				entry.model = model
				cache[model] = entry
			end

			entry:setAccentColor(accentColor)
			return entry
		end

		local function getEspBoundingBox(model)
			local camera = workspace.CurrentCamera
			if not camera or not model then
				return nil
			end

			local cf, size = model:GetBoundingBox()
			local corners = {}
			for x = -1, 1, 2 do
				for y = -1, 1, 2 do
					for z = -1, 1, 2 do
						table.insert(corners, cf * Vector3.new(size.X * 0.5 * x, size.Y * 0.5 * y, size.Z * 0.5 * z))
					end
				end
			end

			local minX, minY = math.huge, math.huge
			local maxX, maxY = -math.huge, -math.huge
			local onScreenCorner = false

			for _, worldPoint in ipairs(corners) do
				local viewportPoint, onScreen = camera:WorldToViewportPoint(worldPoint)
				if viewportPoint.Z > 0 then
					minX = math.min(minX, viewportPoint.X)
					minY = math.min(minY, viewportPoint.Y)
					maxX = math.max(maxX, viewportPoint.X)
					maxY = math.max(maxY, viewportPoint.Y)
					onScreenCorner = onScreenCorner or onScreen
				end
			end

			if minX == math.huge or minY == math.huge or maxX == -math.huge or maxY == -math.huge then
				return nil
			end

			return {
				left = minX,
				top = minY,
				right = maxX,
				bottom = maxY,
				width = maxX - minX,
				height = maxY - minY,
				onScreen = onScreenCorner,
			}
		end

		local function getEspRigPoints(model)
			local camera = workspace.CurrentCamera
			if not camera then
				return {}
			end

			local projectedPoints = {}
			local pointNames = {
				"Head", "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "LeftHand",
				"RightUpperArm", "RightLowerArm", "RightHand", "LeftUpperLeg", "LeftLowerLeg",
				"LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot", "Torso", "Left Arm",
				"Right Arm", "Left Leg", "Right Leg",
			}

			for _, partName in ipairs(pointNames) do
				local part = model:FindFirstChild(partName, true)
				if part and part:IsA("BasePart") then
					local viewportPoint, onScreen = camera:WorldToViewportPoint(part.Position)
					if onScreen and viewportPoint.Z > 0 then
						projectedPoints[partName] = Vector2.new(viewportPoint.X, viewportPoint.Y)
					end
				end
			end

			return projectedPoints
		end

		local function updateEspSkeleton(entry, model, accentColor)
			local projectedPoints = getEspRigPoints(model)
			local lineIndex = 1
			local skeletonPairs = {
				{"Head", "UpperTorso"}, {"UpperTorso", "LowerTorso"}, {"UpperTorso", "LeftUpperArm"},
				{"LeftUpperArm", "LeftLowerArm"}, {"LeftLowerArm", "LeftHand"}, {"UpperTorso", "RightUpperArm"},
				{"RightUpperArm", "RightLowerArm"}, {"RightLowerArm", "RightHand"}, {"LowerTorso", "LeftUpperLeg"},
				{"LeftUpperLeg", "LeftLowerLeg"}, {"LeftLowerLeg", "LeftFoot"}, {"LowerTorso", "RightUpperLeg"},
				{"RightUpperLeg", "RightLowerLeg"}, {"RightUpperLeg", "RightFoot"}, {"Head", "Torso"},
				{"Torso", "Left Arm"}, {"Torso", "Right Arm"}, {"Torso", "Left Leg"}, {"Torso", "Right Leg"},
			}

			for _, pair in ipairs(skeletonPairs) do
				local point0 = projectedPoints[pair[1]]
				local point1 = projectedPoints[pair[2]]
				local line = entry.skeletonLines[lineIndex]
				if line then
					if point0 and point1 then
						line.From = point0
						line.To = point1
						line.Color = accentColor
						line.Visible = true
					else
						line.Visible = false
					end
					lineIndex = lineIndex + 1
				end
			end

			entry:hideSkeletonFrom(lineIndex)
		end

		local function updateEspEntry(entry, model, targetType, accentColor)
			local humanoid = getCharacterHumanoid(model)
			local distance = getEspDistance(model)
			local box = getEspBoundingBox(model)
			if not box or box.width < 2 or box.height < 2 or not box.onScreen then
				entry:hide()
				return
			end

			local topLeft = Vector2.new(box.left, box.top)
			local topRight = Vector2.new(box.right, box.top)
			local bottomLeft = Vector2.new(box.left, box.bottom)
			local bottomRight = Vector2.new(box.right, box.bottom)
			local camera = workspace.CurrentCamera
			local viewportSize = camera and camera.ViewportSize or Vector2.new(1920, 1080)
			local tracerStart = Vector2.new(viewportSize.X * 0.5, viewportSize.Y - 2)
			local tracerEnd = Vector2.new(box.left + (box.width * 0.5), box.bottom)

			entry:setBox({
				{topLeft, topRight},
				{topRight, bottomRight},
				{bottomRight, bottomLeft},
				{bottomLeft, topLeft},
			}, accentColor, getToggleValue("EspShowBox", true))

			local health = humanoid and math.max(humanoid.Health, 0) or 0
			local maxHealth = humanoid and math.max(humanoid.MaxHealth, 1) or 100
			local healthRatio = math.clamp(health / maxHealth, 0, 1)
			local barHeight = math.max(box.height, 4)
			local barWidth = 4
			local barX = box.left - 7

			entry:setHealthBar(
				Vector2.new(barX, box.top),
				Vector2.new(barWidth, barHeight),
				Vector2.new(barX + 1, box.bottom - ((barHeight - 2) * healthRatio) - 1),
				Vector2.new(barWidth - 2, math.max((barHeight - 2) * healthRatio, 1)),
				Color3.fromRGB(math.floor(255 * (1 - healthRatio)), math.floor(255 * healthRatio), 90),
				getToggleValue("EspShowHealthBar", true) and humanoid ~= nil
			)

			entry:setText(
				entry.nameText,
				getEspDisplayName(model, targetType),
				Vector2.new(box.left + (box.width * 0.5), box.top - 14),
				getToggleValue("EspShowNames", true)
			)

			entry:setText(
				entry.distanceText,
				string.format("%.0f studs", distance),
				Vector2.new(box.left + (box.width * 0.5), box.bottom + 1),
				getToggleValue("EspShowDistance", true)
			)

			entry:setText(
				entry.healthText,
				string.format("%d / %d HP", math.floor(health + 0.5), math.floor(maxHealth + 0.5)),
				Vector2.new(box.left + (box.width * 0.5), box.top - 27),
				getToggleValue("EspShowHealthText", false) and humanoid ~= nil
			)

			entry:setTracer(tracerStart, tracerEnd, accentColor, getToggleValue("EspShowTracers", false))

			if getToggleValue("EspShowSkeleton", false) then
				updateEspSkeleton(entry, model, accentColor)
			else
				entry:hideSkeletonFrom(1)
			end
		end

		local function updateTypedEsp(cache, targetType, accentColor)
			local enabledToggle = targetType == "player" and Toggles.PlayerEspEnabled or Toggles.MobEspEnabled
			if not drawingAvailable then
				clearEspCache(cache)
				return
			end

			if not (enabledToggle and enabledToggle.Value) then
				clearEspCache(cache)
				return
			end

			local validModels = {}
			for _, model in ipairs(iterEspCandidateModels()) do
				if getEspTargetType(model) == targetType then
					local humanoid = getCharacterHumanoid(model)
					local aliveEnough = humanoid == nil or humanoid.Health > 0
					local maxDistance = getOptionValue("EspRenderDistance", 500)

					if aliveEnough and getEspDistance(model) <= maxDistance then
						validModels[model] = true
						local entry = ensureEspEntry(cache, model, accentColor)
						if entry then
							updateEspEntry(entry, model, targetType, accentColor)
						end
					end
				end
			end

			for model, entry in pairs(cache) do
				if not validModels[model] then
					cache[model] = nil
					if entry and type(entry.Destroy) == "function" then
						entry:Destroy()
					end
				end
			end
		end

		local function refreshEsp()
			if espShuttingDown then
				forceClearEsp()
				return
			end

			if not drawingAvailable and not espDrawUnavailableNotified then
				espDrawUnavailableNotified = true
				Library:Notify("Drawing API unavailable.", 3)
				return
			end

			updateTypedEsp(playerEspEntries, "player", Color3.fromRGB(40, 170, 255))
			updateTypedEsp(mobEspEntries, "mob", Color3.fromRGB(80, 255, 140))
		end

		local function scheduleEspRefresh()
			task.defer(refreshEsp)
		end

		espGroup:AddToggle("PlayerEspEnabled", { Text = "Player ESP", Default = false })
		espGroup:AddToggle("MobEspEnabled", { Text = "Mob ESP", Default = false })
		espVisualGroup:AddToggle("EspShowNames", { Text = "Show Names", Default = true })
		espVisualGroup:AddToggle("EspShowDistance", { Text = "Show Distance", Default = true })
		espVisualGroup:AddToggle("EspShowHealthText", { Text = "Show Health Text", Default = false })
		espVisualGroup:AddToggle("EspShowHealthBar", { Text = "Show Health Bar", Default = true })
		espVisualGroup:AddToggle("EspShowBox", { Text = "Box ESP", Default = true })
		espVisualGroup:AddToggle("EspShowSkeleton", { Text = "Skeleton ESP", Default = false })
		espVisualGroup:AddToggle("EspShowTracers", { Text = "Tracer Lines", Default = true })
		espVisualGroup:AddSlider("EspRenderDistance", {
			Text = "Render Distance", Default = 500, Min = 10, Max = 2000, Rounding = 0, Suffix = " studs"
		})

		Toggles.PlayerEspEnabled:OnChanged(refreshEsp)
		Toggles.MobEspEnabled:OnChanged(refreshEsp)
		Toggles.EspShowNames:OnChanged(refreshEsp)
		Toggles.EspShowDistance:OnChanged(refreshEsp)
		Toggles.EspShowHealthText:OnChanged(refreshEsp)
		Toggles.EspShowHealthBar:OnChanged(refreshEsp)
		Toggles.EspShowBox:OnChanged(refreshEsp)
		Toggles.EspShowTracers:OnChanged(refreshEsp)
		Options.EspRenderDistance:OnChanged(refreshEsp)
		Toggles.EspShowSkeleton:OnChanged(function()
			clearEspCache(playerEspEntries)
			clearEspCache(mobEspEntries)
			refreshEsp()
		end)

		maid:GiveTask(Players.PlayerAdded:Connect(function(player)
			maid:GiveTask(player.CharacterAdded:Connect(scheduleEspRefresh))
			scheduleEspRefresh()
		end))
		maid:GiveTask(Players.PlayerRemoving:Connect(scheduleEspRefresh))

		for _, player in ipairs(Players:GetPlayers()) do
			maid:GiveTask(player.CharacterAdded:Connect(scheduleEspRefresh))
		end

		local liveFolder = getEspLiveFolder()
		if liveFolder then
			maid:GiveTask(liveFolder.ChildAdded:Connect(scheduleEspRefresh))
			maid:GiveTask(liveFolder.ChildRemoved:Connect(scheduleEspRefresh))
		end

		maid:GiveTask(RunService.Heartbeat:Connect(function()
			if getToggleValue("PlayerEspEnabled", false) or getToggleValue("MobEspEnabled", false) then
				refreshEsp()
			end
		end))

		registerLibraryUnloadCallback(function()
			espShuttingDown = true
			forceClearEsp()
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

		local menuGroup = Tabs.Settings:AddLeftGroupbox("Menu")
		menuGroup:AddButton("Unload", function() Library:Unload() end)
	end

	registerLibraryUnloadCallback(function()
		maid:DoCleaning()
		GLOBAL_ENV[HUAJ_HUB_HYAKU_INIT_KEY] = nil
		GLOBAL_ENV[HUAJ_HUB_HYAKU_LIBRARY_KEY] = nil
	end)
end

return HyakuAsura
