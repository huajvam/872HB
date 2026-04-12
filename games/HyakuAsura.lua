local HyakuAsura = {}
local GAME_KEY = "hyaku_asura"

local Services = sharedRequire("@utils/Services.lua")
local Maid = sharedRequire("@utils/Maid.lua")
local CharacterUtils = sharedRequire("@utils/CharacterUtils.lua")
local EntityESP = sharedRequire("classes/EntityESP.lua")

local Players, MarketplaceService, ReplicatedStorage, RunService, UserInputService, VirtualInputManager = Services:Get(
	"Players",
	"MarketplaceService",
	"ReplicatedStorage",
	"RunService",
	"UserInputService",
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
		local autoEatGroup = Tabs.Main:AddRightGroupbox("Auto Eat")
		local infiniteRhythmLoopToken = 0
		local autoBenchToken = 0
		local autoPullUpToken = 0
		local autoSquatMachineToken = 0
		local autoTreadmillToken = 0
		local autoBikeToken = 0
		local autoBagsToken = 0
		local autoSleepToken = 0
		local autoEatToken = 0
		local autoSleepInProgress = false
		local autoEatInProgress = false
		local cachedBenchPromptFrame = nil
		local lastBenchVisibleKey = nil
		local lastBenchPromptScanAt = 0
		local moderatorDetectorConnection = nil
		local moderatorUserIds = {
			[1915395703] = 999,
			[4488906362] = 999,
			[1464780145] = 999,
			[1921021351] = 999,
			[452637989] = 999,
			[9869623665] = 999,
			[8168050148] = 1,
			[1042857413] = 1,
			[5413881219] = 1,
			[203443515] = 1,
			[377144428] = 1,
			[108493198] = 1,
			[527936177] = 1,
			[1149150663] = 1,
			[992099552] = 1,
			[892331036] = 1,
			[4081878593] = 200,
			[1015246692] = 200,
		}
		local trainingUiRemote = ReplicatedStorage
			and ReplicatedStorage:FindFirstChild("Remotes")
			and ReplicatedStorage.Remotes:FindFirstChild("TrainingUi")
		local activeTrainingPromptRemote = nil
		local trainingPromptRemoteConnection = nil
		local trainingUiRemoteConnection = nil
		local trainingPromptQueue = {}
		local trainingPromptSequence = 0
		local lastTrainingPromptKey = nil
		local lastTrainingPromptAt = 0
		local rhythmChargeConnection
		local staminaConnection
		local autoEatFoodNames = {
			"Pizza",
			"Kebab",
			"Hotdog",
			"Taco",
			"Ramen",
			"Onigiri",
			"Fries",
			"Burger",
		}
		local autoEatPurchaseNameMap = {
			["burger"] = "Burger",
			["kebab"] = "Kebab",
			["pizza"] = "Pizza",
			["ramen"] = "Ramen",
			["onigiri"] = "Onigiri",
			["taco"] = "Taco",
			["hotdog"] = "Hotdog",
			["fries"] = "Fries",
		}
		local autoBagModes = {
			"Strength",
			"Attack Speed",
		}
		local autoBagPlacementConfig = {
			Axis = "LookVector",
			DistanceOffset = 0.35,
			VerticalOffset = 0.15,
			UseBagAndPlayerDepth = true,
			ManualDistance = 3.5,
			YawOffsetDegrees = 50,
		}

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

		local function getBodyFatiqueValue()
			local statsFolder = getLocalEntityStatsFolder()
			local bodyFatique = statsFolder and (statsFolder:FindFirstChild("BodyFatique") or statsFolder:FindFirstChild("BodyFatigue"))
			if bodyFatique and bodyFatique:IsA("NumberValue") then
				return bodyFatique
			end

			return nil
		end

		local function getHungerValue()
			local statsFolder = getLocalEntityStatsFolder()
			local hunger = statsFolder and statsFolder:FindFirstChild("Hunger")
			if hunger and hunger:IsA("NumberValue") then
				return hunger
			end

			return nil
		end

		local function getTrainingMachineValue()
			local statsFolder = getLocalEntityStatsFolder()
			local trainingMachine = statsFolder and statsFolder:FindFirstChild("TrainingMachine")
			if trainingMachine and trainingMachine:IsA("ObjectValue") then
				return trainingMachine
			end

			return nil
		end

		local function getCurrentTrainingMachineRemote()
			local trainingMachineValue = getTrainingMachineValue()
			local machine = trainingMachineValue and trainingMachineValue.Value
			local radio = machine and machine:FindFirstChild("Radio")
			local remote = radio and radio:FindFirstChild("Remote")
			if remote and remote:IsA("RemoteEvent") then
				return remote
			end

			return activeTrainingPromptRemote
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

		local function stopModeratorDetector()
			if moderatorDetectorConnection then
				pcall(function()
					moderatorDetectorConnection:Disconnect()
				end)
				moderatorDetectorConnection = nil
			end
		end

		local function kickForModerator()
			if LocalPlayer and type(LocalPlayer.Kick) == "function" then
				pcall(function()
					LocalPlayer:Kick("mod joined")
				end)
			end
		end

		local function isModeratorPlayer(player)
			if not player or player == LocalPlayer then
				return false
			end

			local userId = tonumber(player.UserId)
			return userId ~= nil and moderatorUserIds[userId] ~= nil
		end

		local function checkPlayerForModerator(player)
			if isModeratorPlayer(player) then
				kickForModerator()
				return true
			end

			return false
		end

		local function startModeratorDetector()
			stopModeratorDetector()

			for _, player in ipairs(Players:GetPlayers()) do
				if checkPlayerForModerator(player) then
					return
				end
			end

			moderatorDetectorConnection = Players.PlayerAdded:Connect(function(player)
				checkPlayerForModerator(player)
			end)
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

		local function getTrainingSpotSeat(spotFolder)
			local spotModel = getTrainingSpotTeleportModel(spotFolder)
			if not spotModel then
				return nil
			end

			if spotModel:IsA("Seat") then
				return spotModel
			end

			if spotModel:IsA("Model") then
				return spotModel:FindFirstChild("Seat", true) or spotModel:FindFirstChildWhichIsA("Seat", true)
			end

			return nil
		end

		local function isTrainingSpotOccupied(spotFolder)
			local seat = getTrainingSpotSeat(spotFolder)
			if not seat then
				return false
			end

			return seat:FindFirstChildWhichIsA("Sound") ~= nil
		end

		local function getTrainingSpotDistancePart(spotFolder)
			local seat = getTrainingSpotSeat(spotFolder)
			if seat then
				return seat
			end

			local model = getTrainingSpotTeleportModel(spotFolder)
			if model and model:IsA("Model") then
				return model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
			end

			if model and model:IsA("BasePart") then
				return model
			end

			return nil
		end

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
				if folder.Name == spotName and not isTrainingSpotOccupied(folder) then
					local part = getTrainingSpotDistancePart(folder)
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

		local function getClosestTrainingSpotByNames(spotNames)
			if type(spotNames) ~= "table" then
				return nil
			end

			local trainingSpots = workspace:FindFirstChild("TrainingSpots")
			if not trainingSpots then
				return nil
			end

			local allowedNames = {}
			for _, name in ipairs(spotNames) do
				if type(name) == "string" and name ~= "" then
					allowedNames[name] = true
				end
			end

			local closest, dist = nil, math.huge
			local root = getCharacterRoot(LocalPlayer and LocalPlayer.Character)
			if not root then
				return nil
			end

			for _, folder in ipairs(trainingSpots:GetChildren()) do
				if allowedNames[folder.Name] and not isTrainingSpotOccupied(folder) then
					local part = getTrainingSpotDistancePart(folder)
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

			local anchorPart = nil
			if spotModel:IsA("Model") then
				anchorPart = spotModel:FindFirstChild("Seat", true)
					or spotModel:FindFirstChildWhichIsA("Seat", true)
					or spotModel.PrimaryPart
					or spotModel:FindFirstChildWhichIsA("BasePart", true)
			elseif spotModel:IsA("BasePart") then
				anchorPart = spotModel
			end

			local targetCFrame
			if anchorPart then
				targetCFrame = anchorPart.CFrame * CFrame.new(0, math.max(anchorPart.Size.Y * 0.5, 2), 0)
			else
				local ok, pivot = pcall(function()
					return spotModel:GetPivot()
				end)
				if not ok or not pivot then
					return false
				end
				targetCFrame = pivot * CFrame.new(0, 2, 0)
			end

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

		local function findNilInstances()
			if type(getnilinstances) ~= "function" then
				return nil
			end

			local ok, instances = pcall(function()
				return getnilinstances()
			end)
			if not ok or type(instances) ~= "table" then
				return nil
			end

			return instances
		end

		local function isDescendantOfInstance(instance, ancestor)
			if not instance or not ancestor or instance == ancestor then
				return instance == ancestor
			end

			local current = instance
			for _ = 1, 24 do
				local okParent, parent = pcall(function()
					return current.Parent
				end)
				if not okParent or not parent then
					return false
				end
				if parent == ancestor then
					return true
				end
				current = parent
			end

			return false
		end

		local function scanBenchPromptObjects()
			local instances = findNilInstances()
			if not instances then
				return nil, nil
			end

			local foundFrame = nil
			local foundLabel = nil

			for _, instance in next, instances do
				if instance then
					local okName, name = pcall(function()
						return instance.Name
					end)
					local okClass, className = pcall(function()
						return instance.ClassName
					end)
					if okName and okClass then
						if not foundFrame
							and (name == "KeyMinigame" or name == "KeyMiniGame")
							and (className == "Frame" or className == "CanvasGroup")
						then
							foundFrame = instance
						elseif name == "TextLabel" and className == "TextLabel" then
							foundLabel = foundLabel or instance
						end
					end
				end
			end

			if foundFrame then
				for _, instance in next, instances do
					if instance and instance ~= foundFrame then
						local okName, name = pcall(function()
							return instance.Name
						end)
						local okClass, className = pcall(function()
							return instance.ClassName
						end)
						if okName and okClass and name == "TextLabel" and className == "TextLabel" then
							if isDescendantOfInstance(instance, foundFrame) then
								return foundFrame, instance
							end
						end
					end
				end
			end

			return foundFrame, foundLabel
		end

		local function getBenchPromptFrame()
			if cachedBenchPromptFrame then
				local okClassName, className = pcall(function()
					return cachedBenchPromptFrame.ClassName
				end)
				if okClassName and (className == "Frame" or className == "CanvasGroup") then
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

			local scannedFrame, scannedLabel = scanBenchPromptObjects()
			cachedBenchPromptFrame = scannedFrame
			return cachedBenchPromptFrame
		end

		local function getPromptKeyFromPromptUi(promptUi)
			if not promptUi then
				return nil
			end

			local okDescendants, descendants = pcall(function()
				return promptUi:GetDescendants()
			end)
			if not okDescendants or type(descendants) ~= "table" then
				return nil
			end

			for _, instance in ipairs(descendants) do
				if instance and instance.Name == "TextLabel" then
					local key = getPromptLabelKey(instance)
					if key then
						return key
					end
				end
			end

			for _, instance in ipairs(descendants) do
				local key = getPromptLabelKey(instance)
				if key then
					return key
				end
			end

			return nil
		end

		local function getBenchPromptKey()
			local promptFrame = getBenchPromptFrame()
			if not promptFrame then
				return nil
			end

			local okChildren, children = pcall(function()
				return promptFrame:GetChildren()
			end)
			if okChildren and type(children) == "table" then
				for _, child in ipairs(children) do
					local key = getPromptKeyFromPromptUi(child)
					if key then
						return key
					end
				end
			end

			local keyFromFrame = getPromptKeyFromPromptUi(promptFrame)
			if keyFromFrame then
				return keyFromFrame
			end

			local scannedFrame, scannedLabel = scanBenchPromptObjects()
			if scannedFrame then
				cachedBenchPromptFrame = scannedFrame
			end
			if scannedLabel and getPromptLabelKey(scannedLabel) then
				return getPromptLabelKey(scannedLabel)
			end

			return nil
		end

		local function submitTrainingPromptKey(remote, key)
			if not remote or type(key) ~= "string" then
				return false
			end

			pcall(function()
				remote:FireServer("PressKey", {
					Key = key,
				})
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

		local function isRecoveryInProgress()
			return autoSleepInProgress or autoEatInProgress
		end

		local function leaveCurrentTrainingMachine()
			local trainingRemote = getCurrentTrainingMachineRemote()
			if trainingRemote then
				pcall(function()
					trainingRemote:FireServer("Leave")
				end)
				return true
			end

			return false
		end

		local function getBackpack()
			return LocalPlayer and LocalPlayer:FindFirstChildOfClass("Backpack")
		end

		local function getSelectedFoodNames()
			local selectedFoods = {}
			local dropdown = Options and Options.AutoEatFoods
			if dropdown and type(dropdown.GetActiveValues) == "function" then
				for _, foodName in ipairs(dropdown:GetActiveValues()) do
					if type(foodName) == "string" then
						table.insert(selectedFoods, foodName)
					end
				end
			end

			return selectedFoods
		end

		local function getFoodToolByName(foodName)
			if type(foodName) ~= "string" or foodName == "" then
				return nil
			end

			local backpack = getBackpack()
			local character = LocalPlayer and LocalPlayer.Character
			local tool = (backpack and backpack:FindFirstChild(foodName)) or (character and character:FindFirstChild(foodName))
			if tool and tool:IsA("Tool") then
				return tool
			end

			return nil
		end

		local function getFoodQuantityValue(foodName)
			local tool = getFoodToolByName(foodName)
			local quantityValue = tool and tool:FindFirstChild("Quantity")
			if quantityValue and quantityValue:IsA("IntValue") then
				return quantityValue
			end

			return nil
		end

		local function getFoodQuantity(foodName)
			local quantityValue = getFoodQuantityValue(foodName)
			local quantityNumber = quantityValue and tonumber(quantityValue.Value)
			return quantityNumber or 0
		end

		local function getPurchasableItemsCommonFolder()
			local purchasableItems = workspace:FindFirstChild("PurchasableItems")
			return purchasableItems and purchasableItems:FindFirstChild("Common")
		end

		local function resolveFoodPurchaseObject(foodName)
			local commonFolder = getPurchasableItemsCommonFolder()
			if not commonFolder then
				return nil
			end

			local directMappings = {
				Taco = function()
					local children = commonFolder:GetChildren()
					return children[2] and children[2]:FindFirstChild("Taco")
				end,
				Burger = function()
					local children = commonFolder:GetChildren()
					return children[11] and (children[11]:FindFirstChild("burger") or children[11]:FindFirstChild("Burger"))
				end,
				Hotdog = function()
					local part = commonFolder:FindFirstChild("Part")
					return part and part:FindFirstChild("Meshes/Food drinkfbx_Hotdog")
				end,
				Kebab = function()
					local children = commonFolder:GetChildren()
					return children[16] and (children[16]:FindFirstChild("kebab") or children[16]:FindFirstChild("Kebab"))
				end,
				Pizza = function()
					local children = commonFolder:GetChildren()
					return children[15] and (children[15]:FindFirstChild("Pizza") or children[15]:FindFirstChild("pizza"))
				end,
				Ramen = function()
					local children = commonFolder:GetChildren()
					return children[14] and (children[14]:FindFirstChild("Ramen") or children[14]:FindFirstChild("ramen"))
				end,
				Onigiri = function()
					local children = commonFolder:GetChildren()
					return children[13] and (children[13]:FindFirstChild("Onigiri") or children[13]:FindFirstChild("onigiri"))
				end,
				Fries = function()
					return commonFolder:FindFirstChild("Fries", true) or commonFolder:FindFirstChild("fries", true)
				end,
			}

			local resolver = directMappings[foodName]
			local purchaseObject = resolver and resolver()
			if purchaseObject then
				return purchaseObject
			end

			for _, descendant in ipairs(commonFolder:GetDescendants()) do
				local mappedName = autoEatPurchaseNameMap[string.lower(descendant.Name or "")]
				if mappedName == foodName then
					return descendant
				end
			end

			return nil
		end

		local function getFoodPurchaseClickDetector(foodName)
			local purchaseObject = resolveFoodPurchaseObject(foodName)
			if not purchaseObject then
				return nil
			end

			if purchaseObject:IsA("ClickDetector") then
				return purchaseObject
			end

			return purchaseObject:FindFirstChildWhichIsA("ClickDetector", true)
		end

		local function buyFoodUpToMax(foodName, maxQuantity)
			if type(foodName) ~= "string" or foodName == "" then
				return false
			end

			if type(fireclickdetector) ~= "function" then
				return false
			end

			local clickDetector = getFoodPurchaseClickDetector(foodName)
			if not clickDetector then
				return false
			end

			local boughtAny = false
			local cap = tonumber(maxQuantity) or 5
			local attempts = 0

			while attempts < cap do
				local currentQuantity = getFoodQuantity(foodName)
				if currentQuantity >= cap then
					break
				end

				pcall(function()
					fireclickdetector(clickDetector)
				end)
				boughtAny = true
				attempts += 1
				task.wait(0.18)
			end

			return boughtAny
		end

		local function equipFoodTool(tool)
			if not tool or not tool:IsA("Tool") then
				return false
			end

			local character = LocalPlayer and LocalPlayer.Character
			local humanoid = getCharacterHumanoid(character)
			local customHotbarRemote = ReplicatedStorage
				and ReplicatedStorage:FindFirstChild("Remotes")
				and ReplicatedStorage.Remotes:FindFirstChild("CustomHotbar")
			if not character then
				return false
			end

			if tool.Parent == character then
				return true
			end

			if customHotbarRemote and customHotbarRemote:IsA("RemoteEvent") then
				pcall(function()
					customHotbarRemote:FireServer(tool)
				end)
				task.wait(0.15)
			end

			if tool.Parent == character then
				return true
			end

			if humanoid then
				pcall(function()
					humanoid:EquipTool(tool)
				end)
			end

			if tool.Parent ~= character then
				pcall(function()
					tool.Parent = character
				end)
			end

			return tool.Parent == character
		end

		local function sendLeftClickVirtualInput()
			if not VirtualInputManager or not UserInputService then
				return false
			end

			local mousePosition = UserInputService:GetMouseLocation()
			local success = pcall(function()
				VirtualInputManager:SendMouseButtonEvent(mousePosition.X, mousePosition.Y, 0, true, game, 0)
				task.wait(0.08)
				VirtualInputManager:SendMouseButtonEvent(mousePosition.X, mousePosition.Y, 0, false, game, 0)
			end)

			return success
		end

		local function tapCombatKey()
			if not VirtualInputManager then
				return false
			end

			local success = pcall(function()
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
				task.wait(0.05)
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
			end)

			return success
		end

		local function clearTrainingPromptQueue()
			table.clear(trainingPromptQueue)
			lastBenchVisibleKey = nil
		end

		local function pruneExpiredTrainingPrompts()
			local now = os.clock()
			while #trainingPromptQueue > 0 do
				local prompt = trainingPromptQueue[1]
				if prompt and prompt.expiresAt and prompt.expiresAt > now then
					break
				end
				table.remove(trainingPromptQueue, 1)
			end
		end

		local function enqueueTrainingPrompt(payload)
			if type(payload) ~= "table" then
				return
			end

			local key = normalizeBenchPromptText(payload.Key)
			if not key then
				return
			end

			local now = os.clock()
			if lastTrainingPromptKey == key and (now - lastTrainingPromptAt) <= 0.03 then
				return
			end

			lastTrainingPromptKey = key
			lastTrainingPromptAt = now
			trainingPromptSequence += 1
			table.insert(trainingPromptQueue, {
				id = trainingPromptSequence,
				key = key,
				expiresAt = now + math.max(tonumber(payload.Duration) or 0.2, 0.05),
			})
		end

		local function handleTrainingClientEvent(eventName, payload)
			if eventName == "MakeKey" then
				enqueueTrainingPrompt(payload)
				return
			end

			if eventName == "ForceClose" or eventName == "HideLeave" then
				clearTrainingPromptQueue()
			end
		end

		local function disconnectTrainingPromptListeners()
			if trainingPromptRemoteConnection then
				pcall(function()
					trainingPromptRemoteConnection:Disconnect()
				end)
				trainingPromptRemoteConnection = nil
			end
			if trainingUiRemoteConnection then
				pcall(function()
					trainingUiRemoteConnection:Disconnect()
				end)
				trainingUiRemoteConnection = nil
			end
			activeTrainingPromptRemote = nil
			clearTrainingPromptQueue()
		end

		local function connectTrainingPromptListeners(spotRemote)
			if activeTrainingPromptRemote == spotRemote and trainingPromptRemoteConnection then
				return
			end

			disconnectTrainingPromptListeners()
			activeTrainingPromptRemote = spotRemote

			if spotRemote and spotRemote.OnClientEvent then
				trainingPromptRemoteConnection = spotRemote.OnClientEvent:Connect(function(eventName, payload)
					handleTrainingClientEvent(eventName, payload)
				end)
			end

			if trainingUiRemote and trainingUiRemote.OnClientEvent then
				trainingUiRemoteConnection = trainingUiRemote.OnClientEvent:Connect(function(eventName, payload)
					handleTrainingClientEvent(eventName, payload)
				end)
			end
		end

		local function getNextTrainingPrompt()
			pruneExpiredTrainingPrompts()
			local prompt = trainingPromptQueue[1]
			if not prompt then
				return nil
			end
			return prompt
		end

		local function consumeTrainingPrompt(promptId)
			if #trainingPromptQueue == 0 then
				return
			end

			local prompt = trainingPromptQueue[1]
			if prompt and prompt.id == promptId then
				table.remove(trainingPromptQueue, 1)
				return
			end

			for index, entry in ipairs(trainingPromptQueue) do
				if entry and entry.id == promptId then
					table.remove(trainingPromptQueue, index)
					return
				end
			end
		end

		local function getAutoTrainToken(toggleKey)
			if toggleKey == "AutoBenchEnabled" then
				return autoBenchToken
			end

			if toggleKey == "AutoPullUpEnabled" then
				return autoPullUpToken
			end

			if toggleKey == "AutoSquatMachineEnabled" then
				return autoSquatMachineToken
			end

			if toggleKey == "AutoTreadmillEnabled" then
				return autoTreadmillToken
			end

			if toggleKey == "AutoBikeEnabled" then
				return autoBikeToken
			end

			if toggleKey == "AutoBagsEnabled" then
				return autoBagsToken
			end

			if toggleKey == "AutoSleepEnabled" then
				return autoSleepToken
			end

			return -1
		end

		local autoTrainToggleKeys = {
			"AutoBenchEnabled",
			"AutoPullUpEnabled",
			"AutoSquatMachineEnabled",
			"AutoTreadmillEnabled",
			"AutoBikeEnabled",
			"AutoBagsEnabled",
		}

		local function isAnyOtherAutoTrainEnabled(activeToggleKey)
			for _, toggleKey in ipairs(autoTrainToggleKeys) do
				if toggleKey ~= activeToggleKey and Toggles and Toggles[toggleKey] and Toggles[toggleKey].Value then
					return true
				end
			end
			return false
		end

		local function disableOtherAutoTrainToggles(activeToggleKey)
			for _, toggleKey in ipairs(autoTrainToggleKeys) do
				if toggleKey ~= activeToggleKey and Toggles and Toggles[toggleKey] and Toggles[toggleKey].Value then
					pcall(function()
						Toggles[toggleKey]:SetValue(false)
					end)
				end
			end
		end

		local function startTrainingSpotAutomation(toggleKey, spotName, options)
			local currentToken = getAutoTrainToken(toggleKey)
			options = options or {}
			
			task.spawn(function()
				while currentToken == getAutoTrainToken(toggleKey) and Toggles[toggleKey] and Toggles[toggleKey].Value do
					if isRecoveryInProgress() then
						task.wait(0.2)
						continue
					end

					local spotFolder = getClosestTrainingSpot(spotName)
					local character = LocalPlayer and LocalPlayer.Character
					
					if spotFolder and character then
						local spotModel = getTrainingSpotTeleportModel(spotFolder)
						local spotRemote = getTrainingSpotRemote(spotFolder)
						
						if spotModel and spotRemote then
							connectTrainingPromptListeners(spotRemote)
							clearTrainingPromptQueue()

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
								if isRecoveryInProgress() then
									break
								end

								local prompt = getNextTrainingPrompt()
								if prompt then
									lastBenchVisibleKey = prompt.key
									submitTrainingPromptKey(spotRemote, prompt.key)
									consumeTrainingPrompt(prompt.id)
									task.wait(0.005)
								else
									lastBenchVisibleKey = nil
									task.wait(0.01)
								end
							end
						end
					end
					task.wait(1)
				end

				if not isAnyOtherAutoTrainEnabled(nil) and not (Toggles[toggleKey] and Toggles[toggleKey].Value) then
					disconnectTrainingPromptListeners()
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

		local function startAutoSquatMachine()
			autoSquatMachineToken += 1
			startTrainingSpotAutomation("AutoSquatMachineEnabled", "Squat", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoTreadmill()
			autoTreadmillToken += 1
			startTrainingSpotAutomation("AutoTreadmillEnabled", "Treadmill", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoBike()
			autoBikeToken += 1
			startTrainingSpotAutomation("AutoBikeEnabled", "Bike", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function getPunchingBagContainer()
			local punchingBagRoot = workspace:FindFirstChild("Punching bag")
			return punchingBagRoot and punchingBagRoot:FindFirstChild("PUNCHING BAG")
		end

		local function getPunchingBagReservedValue(bagModel)
			local bagNode = bagModel and bagModel:FindFirstChild("Bag")
			local reserved = bagNode and bagNode:FindFirstChild("Reserved")
			return reserved
		end

		local function isPunchingBagReservedByAnyoneElse(bagModel)
			local reserved = getPunchingBagReservedValue(bagModel)
			if not reserved then
				return false
			end

			if reserved:IsA("ObjectValue") then
				local value = reserved.Value
				return value ~= nil and value ~= LocalPlayer and value ~= (LocalPlayer and LocalPlayer.Character)
			end

			local textValue = tostring(reserved.Value or "")
			textValue = textValue:match("^%s*(.-)%s*$") or ""
			if textValue == "" then
				return false
			end

			return textValue ~= LocalPlayer.Name
		end

		local function isPunchingBagTrainingFinished(bagModel)
			local reserved = getPunchingBagReservedValue(bagModel)
			if not reserved then
				return true
			end

			if reserved:IsA("ObjectValue") then
				return reserved.Value == nil
			end

			local textValue = tostring(reserved.Value or "")
			textValue = textValue:match("^%s*(.-)%s*$") or ""
			return textValue == ""
		end

		local function getPunchingBagRemote(bagModel)
			local bagNode = bagModel and bagModel:FindFirstChild("Bag")
			local remote = bagNode and bagNode:FindFirstChild("RemoteEvent")
			if remote and remote:IsA("RemoteEvent") then
				return remote
			end

			return nil
		end

		local function getPunchingBagPart(bagModel)
			if not bagModel then
				return nil
			end

			local bagNode = bagModel:FindFirstChild("Bag")
			if bagNode then
				local humanoidRootPart = bagNode:FindFirstChild("HumanoidRootPart", true)
				if humanoidRootPart and humanoidRootPart:IsA("BasePart") then
					return humanoidRootPart
				end

				if bagNode:IsA("BasePart") then
					return bagNode
				end

				local bestPart = nil
				local bestMagnitude = -math.huge
				for _, descendant in ipairs(bagNode:GetDescendants()) do
					if descendant:IsA("BasePart") then
						local size = descendant.Size
						local magnitude = size.X * size.Y * size.Z
						if magnitude > bestMagnitude then
							bestMagnitude = magnitude
							bestPart = descendant
						end
					end
				end

				if bestPart then
					return bestPart
				end
			end

			return bagModel:FindFirstChildWhichIsA("BasePart", true)
		end

		local function teleportCharacterToPunchingBag(character, bagModel)
			local bagPart = getPunchingBagPart(bagModel)
			local root = character and getCharacterRoot(character)
			if not bagPart or not root then
				return false
			end

			local axisName = autoBagPlacementConfig.Axis or "LookVector"
			local axisVector = bagPart.CFrame.LookVector
			if axisName == "RightVector" then
				axisVector = bagPart.CFrame.RightVector
			elseif axisName == "UpVector" then
				axisVector = bagPart.CFrame.UpVector
			end

			local standDistance = tonumber(autoBagPlacementConfig.ManualDistance) or 3.5
			if autoBagPlacementConfig.UseBagAndPlayerDepth ~= false then
				local bagDepth = axisName == "RightVector" and bagPart.Size.X or bagPart.Size.Z
				local playerDepth = axisName == "RightVector" and root.Size.X or root.Size.Z
				standDistance = math.max(bagDepth * 0.5, 0.5) + math.max(playerDepth * 0.5, 0.5) + (tonumber(autoBagPlacementConfig.DistanceOffset) or 0.35)
			end

			local targetPosition = bagPart.Position + (axisVector * standDistance) + Vector3.new(0, tonumber(autoBagPlacementConfig.VerticalOffset) or 0.15, 0)
			local targetCFrame = CFrame.lookAt(targetPosition, Vector3.new(bagPart.Position.X, targetPosition.Y, bagPart.Position.Z))
			local yawOffsetRadians = math.rad(tonumber(autoBagPlacementConfig.YawOffsetDegrees) or 0)
			targetCFrame = targetCFrame * CFrame.Angles(0, yawOffsetRadians, 0)
			local success = pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				root.CFrame = targetCFrame
				task.wait()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end)

			return success
		end

		local function getClosestAvailablePunchingBag()
			local container = getPunchingBagContainer()
			local root = getCharacterRoot(LocalPlayer and LocalPlayer.Character)
			if not container or not root then
				return nil
			end

			local closestBag = nil
			local closestDistance = math.huge

			for _, descendant in ipairs(container:GetDescendants()) do
				if descendant:IsA("Model") then
					local bagNode = descendant:FindFirstChild("Bag")
					local reserved = bagNode and bagNode:FindFirstChild("Reserved")
					local remote = bagNode and bagNode:FindFirstChild("RemoteEvent")
					local bagPart = getPunchingBagPart(descendant)

					if bagNode and reserved and remote and bagPart and not isPunchingBagReservedByAnyoneElse(descendant) then
						local distance = (root.Position - bagPart.Position).Magnitude
						if distance < closestDistance then
							closestDistance = distance
							closestBag = descendant
						end
					end
				end
			end

			return closestBag
		end

		local function getAutoBagRemoteMode()
			local selectedMode = getOptionValue("AutoBagsMode", "Strength")
			if selectedMode == "Attack Speed" then
				return "atkspd"
			end

			return "str"
		end

		local function startAutoBags()
			autoBagsToken += 1
			local currentToken = autoBagsToken

			task.spawn(function()
				while currentToken == autoBagsToken and Toggles.AutoBagsEnabled and Toggles.AutoBagsEnabled.Value do
					if isRecoveryInProgress() then
						task.wait(0.2)
						continue
					end

					local character = LocalPlayer and LocalPlayer.Character
					local bagModel = getClosestAvailablePunchingBag()
					local bagRemote = bagModel and getPunchingBagRemote(bagModel)
					if character and bagModel and bagRemote then
						disconnectTrainingPromptListeners()

						if teleportCharacterToPunchingBag(character, bagModel) then
							task.wait(0.2)
							holdInteractionKey(0.3)
							task.wait(0.15)
							pcall(function()
								bagRemote:FireServer(getAutoBagRemoteMode())
							end)
							task.wait(0.2)

							while currentToken == autoBagsToken and Toggles.AutoBagsEnabled and Toggles.AutoBagsEnabled.Value do
								if isPunchingBagTrainingFinished(bagModel) then
									break
								end

								sendLeftClickVirtualInput()
								task.wait(0.08)
							end
						end
					end

					task.wait(0.6)
				end
			end)
		end

		local function startAutoSleep()
			autoSleepToken += 1
			local currentToken = autoSleepToken

			task.spawn(function()
				while currentToken == autoSleepToken and Toggles.AutoSleepEnabled and Toggles.AutoSleepEnabled.Value do
					if not autoSleepInProgress and not autoEatInProgress then
						local bodyFatique = getBodyFatiqueValue()
						local threshold = getOptionValue("AutoSleepThreshold", 80)
						local currentFatique = bodyFatique and tonumber(bodyFatique.Value)

						if currentFatique and currentFatique >= threshold then
							local bedFolder = getClosestTrainingSpotByNames({ "HospitalBed", "Hospitalbed" })
							local character = LocalPlayer and LocalPlayer.Character
							local bedModel = bedFolder and getTrainingSpotTeleportModel(bedFolder)
							local bedRemote = bedFolder and getTrainingSpotRemote(bedFolder)

							if character and bedModel and bedRemote then
								autoSleepInProgress = true
								if leaveCurrentTrainingMachine() then
									task.wait(0.2)
								end
								disconnectTrainingPromptListeners()
								teleportCharacterToTrainingSpot(character, bedModel)
								task.wait(0.35)
								holdInteractionKey(3)
								task.wait(0.2)

								while currentToken == autoSleepToken and Toggles.AutoSleepEnabled.Value do
									local fatigueValue = getBodyFatiqueValue()
									local fatigueNumber = fatigueValue and tonumber(fatigueValue.Value)
									if fatigueNumber ~= nil and fatigueNumber <= 0 then
										pcall(function()
											bedRemote:FireServer("Leave")
										end)
										task.wait(0.3)
										break
									end
									task.wait(0.2)
								end

								autoSleepInProgress = false
							end
						end
					end

					task.wait(0.2)
				end

				autoSleepInProgress = false
			end)
		end

		local function startAutoEat()
			autoEatToken += 1
			local currentToken = autoEatToken

			task.spawn(function()
				while currentToken == autoEatToken and Toggles.AutoEatEnabled and Toggles.AutoEatEnabled.Value do
					if not autoEatInProgress and not autoSleepInProgress then
						local hungerValue = getHungerValue()
						local threshold = getOptionValue("AutoEatThreshold", 60)
						local currentHunger = hungerValue and tonumber(hungerValue.Value)

						if currentHunger and currentHunger <= threshold then
							autoEatInProgress = true
							if leaveCurrentTrainingMachine() then
								task.wait(0.2)
							end
							disconnectTrainingPromptListeners()

							while currentToken == autoEatToken and Toggles.AutoEatEnabled.Value do
								local liveHungerValue = getHungerValue()
								local liveHunger = liveHungerValue and tonumber(liveHungerValue.Value)
								if liveHunger and liveHunger >= 100 then
									break
								end

								local selectedFoods = getSelectedFoodNames()
								local usedFood = false
								for _, foodName in ipairs(selectedFoods) do
									local foodTool = getFoodToolByName(foodName)
									if foodTool and equipFoodTool(foodTool) then
										local beforeHunger = liveHunger or 0
										sendLeftClickVirtualInput()
										local hungerRaised = false
										local waitUntil = os.clock() + 1.5
										while os.clock() < waitUntil do
											local currentHungerValue = getHungerValue()
											local currentHungerNumber = currentHungerValue and tonumber(currentHungerValue.Value)
											if currentHungerNumber and currentHungerNumber > beforeHunger then
												hungerRaised = true
												break
											end
											task.wait(0.1)
										end
										usedFood = hungerRaised or foodTool.Parent ~= (LocalPlayer and LocalPlayer.Character)
										if usedFood then
											break
										end
									end
								end

								if not usedFood then
									if Toggles.AutoBuyFoodEnabled and Toggles.AutoBuyFoodEnabled.Value then
										local selectedFoods = getSelectedFoodNames()
										local boughtFood = false
										for _, foodName in ipairs(selectedFoods) do
											if getFoodQuantity(foodName) < 5 and buyFoodUpToMax(foodName, 5) then
												boughtFood = true
												task.wait(0.3)
											end
										end
										if boughtFood then
											task.wait(0.2)
										end
									end
									task.wait(0.5)
								else
									task.wait(0.2)
								end
							end

							autoEatInProgress = false
						end
					end

					task.wait(0.2)
				end

				autoEatInProgress = false
			end)
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

		localCheatsGroup:AddToggle("ModeratorDetectorEnabled", {
			Text = "Mod Detector",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startModeratorDetector()
			else
				stopModeratorDetector()
			end
		end)

		autoTrainGroup:AddToggle("AutoBenchEnabled", {
			Text = "Auto Bench",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBenchEnabled")
				startAutoBench()
			else
				autoBenchToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoBenchEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoPullUpEnabled", {
			Text = "Auto PullUp",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoPullUpEnabled")
				startAutoPullUp()
			else
				autoPullUpToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoPullUpEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoSquatMachineEnabled", {
			Text = "Auto Squat Machine",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoSquatMachineEnabled")
				startAutoSquatMachine()
			else
				autoSquatMachineToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoSquatMachineEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoTreadmillEnabled", {
			Text = "Auto Treadmill",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoTreadmillEnabled")
				startAutoTreadmill()
			else
				autoTreadmillToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoTreadmillEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoBikeEnabled", {
			Text = "Auto Bike",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBikeEnabled")
				startAutoBike()
			else
				autoBikeToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoBikeEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoBagsEnabled", {
			Text = "Auto Bags",
			Default = false,
		})

		local autoBagsOptions = autoTrainGroup:AddDependencyBox()
		autoBagsOptions:SetupDependencies({
			{ Toggles.AutoBagsEnabled, true },
		})

		autoBagsOptions:AddDropdown("AutoBagsMode", {
			Text = "Bag Mode",
			Values = autoBagModes,
			Default = "Strength",
			Multi = false,
		})

		Toggles.AutoBagsEnabled:OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBagsEnabled")
				startAutoBags()
			else
				autoBagsToken += 1
				if not isAnyOtherAutoTrainEnabled("AutoBagsEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		autoTrainGroup:AddToggle("AutoSleepEnabled", {
			Text = "Auto Sleep",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startAutoSleep()
			else
				autoSleepToken += 1
				autoSleepInProgress = false
			end
		end)

		local autoSleepOptions = autoTrainGroup:AddDependencyBox()
		autoSleepOptions:SetupDependencies({
			{ Toggles.AutoSleepEnabled, true },
		})

		autoSleepOptions:AddSlider("AutoSleepThreshold", {
			Text = "Sleep Fatigue",
			Default = 80,
			Min = 0,
			Max = 100,
			Rounding = 0,
		})

		autoEatGroup:AddToggle("AutoEatEnabled", {
			Text = "Auto Eat",
			Default = false,
		})

		local autoEatOptions = autoEatGroup:AddDependencyBox()
		autoEatOptions:SetupDependencies({
			{ Toggles.AutoEatEnabled, true },
		})

		autoEatOptions:AddSlider("AutoEatThreshold", {
			Text = "Eat Hunger",
			Default = 60,
			Min = 0,
			Max = 100,
			Rounding = 0,
		})

		autoEatOptions:AddDropdown("AutoEatFoods", {
			Text = "Foods",
			Values = autoEatFoodNames,
			Default = autoEatFoodNames,
			Multi = true,
		})

		autoEatOptions:AddToggle("AutoBuyFoodEnabled", {
			Text = "Auto Buy Food",
			Default = false,
		})

		Toggles.AutoEatEnabled:OnChanged(function(enabled)
			if enabled then
				startAutoEat()
			else
				autoEatToken += 1
				autoEatInProgress = false
			end
		end)

		registerLibraryUnloadCallback(function()
			stopInfiniteRhythmLoop()
			stopInfiniteStaminaHook()
			disconnectTrainingPromptListeners()
			stopModeratorDetector()
			setSpeedBoostEnabled(false)
			autoBenchToken += 1
			autoPullUpToken += 1
			autoSquatMachineToken += 1
			autoTreadmillToken += 1
			autoBikeToken += 1
			autoSleepToken += 1
			autoEatToken += 1
			autoSleepInProgress = false
			autoEatInProgress = false
			if Toggles and Toggles.InfiniteRhythmEnabled then
				pcall(function() Toggles.InfiniteRhythmEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.InfiniteStaminaEnabled then
				pcall(function() Toggles.InfiniteStaminaEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.SpeedBoostEnabled then
				pcall(function() Toggles.SpeedBoostEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.ModeratorDetectorEnabled then
				pcall(function() Toggles.ModeratorDetectorEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoBenchEnabled then
				pcall(function() Toggles.AutoBenchEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoPullUpEnabled then
				pcall(function() Toggles.AutoPullUpEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoSquatMachineEnabled then
				pcall(function() Toggles.AutoSquatMachineEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoTreadmillEnabled then
				pcall(function() Toggles.AutoTreadmillEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoBikeEnabled then
				pcall(function() Toggles.AutoBikeEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoBagsEnabled then
				pcall(function() Toggles.AutoBagsEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoSleepEnabled then
				pcall(function() Toggles.AutoSleepEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.AutoEatEnabled then
				pcall(function() Toggles.AutoEatEnabled:SetValue(false) end)
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
