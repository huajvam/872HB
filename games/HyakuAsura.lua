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
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local TweenService = game:GetService("TweenService")

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
local VirtualUser = game:GetService("VirtualUser")
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

		if Toggles and Toggles.PathfindingDeliveryFarmEnabled and Toggles.PathfindingDeliveryFarmEnabled.Value then
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
		Misc = Window:AddTab("Misc"),
		Stats = Window:AddTab("Stats"),
		Settings = Window:AddTab("Settings"),
	}

	do
		local uiGroups = {
			localCheats = Tabs.Main:AddLeftGroupbox("Local Cheats"),
			autoFarm = Tabs.Main:AddLeftGroupbox("Auto Farm"),
			autoTrain = Tabs.Main:AddRightGroupbox("Auto Train"),
			autoEat = Tabs.Main:AddRightGroupbox("Auto Eat"),
		}
		local runtimeState = {
			infiniteRhythmLoopToken = 0,
			deliveryFarmToken = 0,
			pathfindingDeliveryFarmToken = 0,
			deliveryRouteRecorderToken = 0,
			autoBenchToken = 0,
			autoPullUpToken = 0,
			autoSquatMachineToken = 0,
			autoTreadmillToken = 0,
			autoBikeToken = 0,
			autoBagsToken = 0,
			autoSleepToken = 0,
			autoEatToken = 0,
			activeAutoBagModel = nil,
			activeDeliveryFarmTween = nil,
			activeDeliveryFarmPlatform = nil,
			autoSleepInProgress = false,
			autoEatInProgress = false,
			antiAfkConnection = nil,
			deliveryRunWHeld = false,
			cachedBenchPromptFrame = nil,
			lastBenchVisibleKey = nil,
			lastBenchPromptScanAt = 0,
			moderatorDetectorConnection = nil,
			rhythmChargeConnection = nil,
			staminaConnection = nil,
		}
		local deliveryRouteState = {
			savedRoute = {},
		}
		deliveryRouteState.recordedRoute = table.clone and table.clone(deliveryRouteState.savedRoute) or {}
		local deliveryRecorderState = {
			macroEvents = {},
			statusLabel = nil,
			routeStoragePath = "HuajHub\\hyaku_delivery_route.json",
			macroStoragePath = "HuajHub\\hyaku_delivery_macro.json",
			runSpeedThreshold = 18,
			cameraSampleInterval = 0.05,
			cameraDotThreshold = 0.9995,
			supportedKeys = {
				W = true,
				A = true,
				S = true,
				D = true,
				Space = true,
				LeftShift = true,
				LeftControl = true,
				Q = true,
				E = true,
			},
			supportedMouse = {
				MouseButton1 = true,
				MouseButton2 = true,
			},
		}
		local trainingPromptState = {
			uiRemote = ReplicatedStorage
				and ReplicatedStorage:FindFirstChild("Remotes")
				and ReplicatedStorage.Remotes:FindFirstChild("TrainingUi"),
			activeRemote = nil,
			remoteConnection = nil,
			uiConnection = nil,
			queue = {},
			sequence = 0,
			lastKey = nil,
			lastAt = 0,
		}
		local configState = {
			moderatorUserIds = {
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
			},
			autoEatFoodNames = {
				"Pizza",
				"Kebab",
				"Hotdog",
				"Taco",
				"Ramen",
				"Onigiri",
				"Fries",
				"Burger",
			},
			autoEatPurchaseNameMap = {
				["burger"] = "Burger",
				["kebab"] = "Kebab",
				["pizza"] = "Pizza",
				["ramen"] = "Ramen",
				["onigiri"] = "Onigiri",
				["taco"] = "Taco",
				["hotdog"] = "Hotdog",
				["fries"] = "Fries",
			},
			autoBagModes = {
				"Strength",
				"Attack Speed",
			},
			deliveryPathModes = {
				"Direct Target",
				"Recorded Route",
				"Recorded Macro",
			},
			deliveryRouteStorageFolder = "HuajHub",
			autoBagPlacement = {
				Axis = "LookVector",
				DistanceOffset = 0.35,
				VerticalOffset = 0.15,
				SideOffset = 0,
				BackOffset = 0,
				UseBagAndPlayerDepth = true,
				ManualDistance = 3.5,
				YawOffsetDegrees = 0,
			},
			deliveryQuestStartCFrame = CFrame.new(
				1439.07104, 25.3973007, -374.693085,
				-1.1920929e-07, 0, -1.00000012,
				0, 1, 0,
				1.00000012, 0, -1.1920929e-07
			),
			pathfindingDeliveryAllowedTargets = {
				CFrame.new(1786.80493, 21.8695087, -720.351196, 1, 0, 0, 0, 1, 0, 0, 0, 1),
				CFrame.new(1762.08618, 22.1983051, 367.691803, 1, 0, 0, 0, 0.999999702, -0.000776898232, 0, 0.000776898232, 0.999999702),
				CFrame.new(1156.96301, 22.1883698, -663.800781, 1, 0, 0, 0, 1, 0, 0, 0, 1),
			},
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

		local function getLocalEntityActiveEffectsFolder()
			local mainScript = getLocalEntityMainScript()
			if not mainScript then
				return nil
			end

			return mainScript:FindFirstChild("ActiveEffects")
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

			return trainingPromptState.activeRemote
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
			if runtimeState.rhythmChargeConnection then
				pcall(function()
					runtimeState.rhythmChargeConnection:Disconnect()
				end)
				runtimeState.rhythmChargeConnection = nil
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
			if runtimeState.staminaConnection then
				pcall(function()
					runtimeState.staminaConnection:Disconnect()
				end)
				runtimeState.staminaConnection = nil
			end
		end

		local function startInfiniteStaminaHook()
			stopInfiniteStaminaHook()
			local stamina = getStaminaValue()
			if not stamina then
				return
			end

			applyInfiniteStamina()
			runtimeState.staminaConnection = stamina:GetPropertyChangedSignal("Value"):Connect(function()
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
			if runtimeState.moderatorDetectorConnection then
				pcall(function()
					runtimeState.moderatorDetectorConnection:Disconnect()
				end)
				runtimeState.moderatorDetectorConnection = nil
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
			return userId ~= nil and configState.moderatorUserIds[userId] ~= nil
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

			runtimeState.moderatorDetectorConnection = Players.PlayerAdded:Connect(function(player)
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
			runtimeState.rhythmChargeConnection = rhythmCharge:GetPropertyChangedSignal("Value"):Connect(function()
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
			runtimeState.infiniteRhythmLoopToken += 1
			local currentToken = runtimeState.infiniteRhythmLoopToken
			startInfiniteRhythmChargeHook()
			task.spawn(function()
				fireInfiniteRhythmRemote(true)
				while currentToken == runtimeState.infiniteRhythmLoopToken and Toggles.InfiniteRhythmEnabled and Toggles.InfiniteRhythmEnabled.Value do
					fireInfiniteRhythmRemote(true)
					applyInfiniteRhythmCharge()
					task.wait(HYAKU_RHYTHM_REMOTE_INTERVAL)
				end
			end)
		end

		local function stopInfiniteRhythmLoop()
			runtimeState.infiniteRhythmLoopToken += 1
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

		local function getClosestHospitalBed()
			local trainingSpots = workspace:FindFirstChild("TrainingSpots")
			if not trainingSpots then
				return nil
			end

			local root = getCharacterRoot(LocalPlayer and LocalPlayer.Character)
			if not root then
				return nil
			end

			local closest = nil
			local dist = math.huge
			for _, folder in ipairs(trainingSpots:GetChildren()) do
				if folder.Name == "HospitalBed" or folder.Name == "Hospitalbed" then
					local seat = getTrainingSpotSeat(folder)
					local seatWeld = seat and seat:FindFirstChild("SeatWeld")
					if seat and seatWeld then
						continue
					end

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
			if runtimeState.cachedBenchPromptFrame then
				local okClassName, className = pcall(function()
					return runtimeState.cachedBenchPromptFrame.ClassName
				end)
				if okClassName and (className == "Frame" or className == "CanvasGroup") then
					return runtimeState.cachedBenchPromptFrame
				end
				runtimeState.cachedBenchPromptFrame = nil
			end

			local now = os.clock()
			if (now - runtimeState.lastBenchPromptScanAt) < HYAKU_PROMPT_SCAN_INTERVAL then
				return nil
			end
			runtimeState.lastBenchPromptScanAt = now

			local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
			local trainingGui = playerGui and playerGui:FindFirstChild("Training")
			if trainingGui then
				local directFrame = trainingGui:FindFirstChild("KeyMiniGame")
					or trainingGui:FindFirstChild("KeyMinigame")
					or trainingGui:FindFirstChild("KeyMiniGame", true)
					or trainingGui:FindFirstChild("KeyMinigame", true)
				if directFrame then
					runtimeState.cachedBenchPromptFrame = directFrame
					return runtimeState.cachedBenchPromptFrame
				end
			end

			local scannedFrame, scannedLabel = scanBenchPromptObjects()
			runtimeState.cachedBenchPromptFrame = scannedFrame
			return runtimeState.cachedBenchPromptFrame
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
				runtimeState.cachedBenchPromptFrame = scannedFrame
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
			return runtimeState.autoSleepInProgress or runtimeState.autoEatInProgress
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
				local mappedName = configState.autoEatPurchaseNameMap[string.lower(descendant.Name or "")]
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

		local function cancelDeliveryFarmTween()
			if runtimeState.activeDeliveryFarmTween then
				pcall(runtimeState.activeDeliveryFarmTween)
				runtimeState.activeDeliveryFarmTween = nil
			end
		end

		local function destroyDeliveryFarmPlatform()
			if runtimeState.activeDeliveryFarmPlatform then
				pcall(function()
					runtimeState.activeDeliveryFarmPlatform:Destroy()
				end)
				runtimeState.activeDeliveryFarmPlatform = nil
			end
		end

		local function ensureDeliveryFarmPlatform(root)
			if not root then
				return nil
			end

			if runtimeState.activeDeliveryFarmPlatform and runtimeState.activeDeliveryFarmPlatform.Parent then
				return runtimeState.activeDeliveryFarmPlatform
			end

			local platform = Instance.new("Part")
			platform.Name = "HuajHubDeliveryPlatform"
			platform.Size = Vector3.new(10, 1, 10)
			platform.Anchored = true
			platform.CanCollide = true
			platform.Transparency = 1
			platform.CastShadow = false
			platform.CFrame = root.CFrame * CFrame.new(0, -3.5, 0)
			platform.Parent = workspace
			runtimeState.activeDeliveryFarmPlatform = platform
			return platform
		end

local function getCurrentCamera()
			return workspace.CurrentCamera
		end

		local function getRecordedDeliveryRoutePointPosition(point)
			if typeof(point) == "Vector3" then
				return point
			end

			if type(point) == "table" and typeof(point.position) == "Vector3" then
				return point.position
			end

			return nil
		end

		local function getRecordedDeliveryRoutePointMoveMode(point)
			if type(point) == "table" and point.mode == "run" then
				return "run"
			end

			return "walk"
		end

		local function createRecordedDeliveryRoutePoint(position, moveMode)
			if typeof(position) ~= "Vector3" then
				return nil
			end

			return {
				position = position,
				mode = moveMode == "run" and "run" or "walk",
			}
		end

		local function getHorizontalSpeed(character)
			local root = character and getCharacterRoot(character)
			if not root then
				return 0
			end

			local velocity = root.AssemblyLinearVelocity
			return Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		end

		local function getDeliverySpotsFolder()
			local jobs = workspace:FindFirstChild("Jobs")
			local delivery = jobs and jobs:FindFirstChild("Delivery")
			return delivery and delivery:FindFirstChild("Spots")
		end

		local function getCancelJobRemote()
			local remotes = ReplicatedStorage and ReplicatedStorage:FindFirstChild("Remotes")
			local cancelJob = remotes and remotes:FindFirstChild("CancelJob")
			if cancelJob and cancelJob:IsA("RemoteEvent") then
				return cancelJob
			end

			return nil
		end

		local function hasDeliverySpotTouchInterest(spotPart)
			return spotPart and spotPart.Parent and spotPart:FindFirstChildOfClass("TouchInterest") ~= nil
		end

		local function getAllowedPathfindingDeliverySpots()
			local spotsFolder = getDeliverySpotsFolder()
			if not spotsFolder then
				return {}
			end

			local foundSpots = {}
			for _, targetCFrame in ipairs(configState.pathfindingDeliveryAllowedTargets) do
				local closestSpot = nil
				local closestDistanceSquared = math.huge
				for _, descendant in ipairs(spotsFolder:GetDescendants()) do
					if descendant:IsA("BasePart") and descendant.Name == "DeliverySpot" then
						local delta = descendant.Position - targetCFrame.Position
						local distanceSquared = delta:Dot(delta)
						if distanceSquared < closestDistanceSquared then
							closestDistanceSquared = distanceSquared
							closestSpot = descendant
						end
					end
				end

				if closestSpot and closestDistanceSquared <= (25 * 25) then
					table.insert(foundSpots, closestSpot)
				end
			end

			return foundSpots
		end

		local function isAllowedPathfindingDeliverySpot(spotPart)
			if not spotPart or not spotPart:IsA("BasePart") then
				return false
			end

			for _, allowedSpot in ipairs(getAllowedPathfindingDeliverySpots()) do
				if allowedSpot == spotPart then
					return true
				end
			end

			return false
		end

		local function getAllowedActivePathfindingDeliverySpot()
			for _, spotPart in ipairs(getAllowedPathfindingDeliverySpots()) do
				if hasDeliverySpotTouchInterest(spotPart) then
					return spotPart
				end
			end

			return nil
		end

		local function abandonCurrentDeliveryJob()
			local cancelJobRemote = getCancelJobRemote()
			if not cancelJobRemote then
				return false
			end

			local ok = pcall(function()
				cancelJobRemote:FireServer()
			end)

			if ok then
				task.wait(0.35)
			end

			return ok
		end

		local function updateDeliveryRouteStatusLabel()
			if deliveryRecorderState.statusLabel and type(deliveryRecorderState.statusLabel.SetText) == "function" then
				local recordingEnabled = Toggles
					and Toggles.RecordDeliveryRouteEnabled
					and Toggles.RecordDeliveryRouteEnabled.Value == true
				deliveryRecorderState.statusLabel:SetText(string.format(
					"Recorded Route: %d point%s | Macro: %d event%s%s",
					#deliveryRouteState.recordedRoute,
					#deliveryRouteState.recordedRoute == 1 and "" or "s",
					#deliveryRecorderState.macroEvents,
					#deliveryRecorderState.macroEvents == 1 and "" or "s",
					recordingEnabled and " | Recording" or ""
				))
			end
		end

		local function saveRecordedDeliveryRoute()
			if type(writefile) ~= "function" then
				return false
			end

			local payload = {
				points = {},
			}

			for _, point in ipairs(deliveryRouteState.recordedRoute) do
				local position = getRecordedDeliveryRoutePointPosition(point)
				if position then
					table.insert(payload.points, {
						x = position.X,
						y = position.Y,
						z = position.Z,
						mode = getRecordedDeliveryRoutePointMoveMode(point),
					})
				end
			end

			local encoded = HttpService:JSONEncode(payload)
			local ok = pcall(function()
				if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(configState.deliveryRouteStorageFolder) then
					makefolder(configState.deliveryRouteStorageFolder)
				end
				writefile(deliveryRecorderState.routeStoragePath, encoded)
			end)

			return ok
		end

		local function saveRecordedDeliveryMacro()
			if type(writefile) ~= "function" then
				return false
			end

			local payload = {
				events = deliveryRecorderState.macroEvents,
			}

			local encoded = HttpService:JSONEncode(payload)
			local ok = pcall(function()
				if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(configState.deliveryRouteStorageFolder) then
					makefolder(configState.deliveryRouteStorageFolder)
				end
				writefile(deliveryRecorderState.macroStoragePath, encoded)
			end)

			return ok
		end

		local function loadRecordedDeliveryRoute()
			if type(readfile) ~= "function" or type(isfile) ~= "function" then
				return false
			end

			local ok, exists = pcall(function()
				return isfile(deliveryRecorderState.routeStoragePath)
			end)
			if not ok or not exists then
				return false
			end

			local readOk, content = pcall(function()
				return readfile(deliveryRecorderState.routeStoragePath)
			end)
			if not readOk or type(content) ~= "string" or content == "" then
				return false
			end

			local decodeOk, decoded = pcall(function()
				return HttpService:JSONDecode(content)
			end)
			if not decodeOk or type(decoded) ~= "table" or type(decoded.points) ~= "table" then
				return false
			end

			table.clear(deliveryRouteState.recordedRoute)
			for _, point in ipairs(decoded.points) do
				if type(point) == "table" then
					local x = tonumber(point.x)
					local y = tonumber(point.y)
					local z = tonumber(point.z)
					if x and y and z then
						local routePoint = createRecordedDeliveryRoutePoint(
							Vector3.new(x, y, z),
							point.mode
						)
						if routePoint then
							table.insert(deliveryRouteState.recordedRoute, routePoint)
						end
					end
				end
			end

			updateDeliveryRouteStatusLabel()
			return #deliveryRouteState.recordedRoute > 0
		end

		local function loadRecordedDeliveryMacro()
			if type(readfile) ~= "function" or type(isfile) ~= "function" then
				return false
			end

			local ok, exists = pcall(function()
				return isfile(deliveryRecorderState.macroStoragePath)
			end)
			if not ok or not exists then
				return false
			end

			local readOk, content = pcall(function()
				return readfile(deliveryRecorderState.macroStoragePath)
			end)
			if not readOk or type(content) ~= "string" or content == "" then
				return false
			end

			local decodeOk, decoded = pcall(function()
				return HttpService:JSONDecode(content)
			end)
			if not decodeOk or type(decoded) ~= "table" or type(decoded.events) ~= "table" then
				return false
			end

			table.clear(deliveryRecorderState.macroEvents)
			for _, event in ipairs(decoded.events) do
				if type(event) == "table" and type(event.kind) == "string" and tonumber(event.t) then
					table.insert(deliveryRecorderState.macroEvents, event)
				end
			end

			updateDeliveryRouteStatusLabel()
			return #deliveryRecorderState.macroEvents > 0
		end

		local function clearRecordedDeliveryRoute()
			table.clear(deliveryRouteState.recordedRoute)
			saveRecordedDeliveryRoute()
			table.clear(deliveryRecorderState.macroEvents)
			saveRecordedDeliveryMacro()
			updateDeliveryRouteStatusLabel()
		end

		local function getDeliveryPlaybackMode()
			return getOptionValue("PathfindingDeliveryRouteMode", "Direct Target")
		end

		local function getClosestRecordedRouteIndex(position)
			if typeof(position) ~= "Vector3" or #deliveryRouteState.recordedRoute == 0 then
				return nil
			end

			local closestIndex = 1
			local closestDistanceSquared = math.huge
			for index, point in ipairs(deliveryRouteState.recordedRoute) do
				local routePosition = getRecordedDeliveryRoutePointPosition(point)
				if routePosition then
					local delta = routePosition - position
					local distanceSquared = delta:Dot(delta)
					if distanceSquared < closestDistanceSquared then
						closestDistanceSquared = distanceSquared
						closestIndex = index
					end
				end
			end

			return closestIndex
		end

		local function formatRecordedDeliveryRoute()
			local lines = {
				"local recordedDeliveryRoute = {",
			}

			for _, point in ipairs(deliveryRouteState.recordedRoute) do
				local position = getRecordedDeliveryRoutePointPosition(point)
				if position then
					table.insert(lines, string.format(
						"\t{ position = Vector3.new(%.3f, %.3f, %.3f), mode = %q },",
						position.X,
						position.Y,
						position.Z,
						getRecordedDeliveryRoutePointMoveMode(point)
					))
				end
			end

			table.insert(lines, "}")
			return table.concat(lines, "\n")
		end

		local function copyRecordedDeliveryRoute()
			local routeSource = formatRecordedDeliveryRoute()
			if type(setclipboard) == "function" then
				pcall(function()
					setclipboard(routeSource)
				end)
				return true
			end

			if type(toclipboard) == "function" then
				pcall(function()
					toclipboard(routeSource)
				end)
				return true
			end

			return false
		end

		local function getDeliveryMacroInputEventKind(inputObject)
			if not inputObject then
				return nil, nil
			end

			if inputObject.UserInputType == Enum.UserInputType.Keyboard then
				local keyName = inputObject.KeyCode and inputObject.KeyCode.Name
				if keyName and deliveryRecorderState.supportedKeys[keyName] then
					return "key", keyName
				end
			end

			local inputTypeName = inputObject.UserInputType and inputObject.UserInputType.Name
			if inputTypeName and deliveryRecorderState.supportedMouse[inputTypeName] then
				return "mouse", inputTypeName
			end

			return nil, nil
		end

		local function appendRecordedDeliveryMacroEvent(event)
			if type(event) ~= "table" or type(event.kind) ~= "string" or type(event.t) ~= "number" then
				return
			end

			table.insert(deliveryRecorderState.macroEvents, event)
			saveRecordedDeliveryMacro()
			updateDeliveryRouteStatusLabel()
		end

		local function captureDeliveryMacroCameraSample(recordingStartedAt)
			local camera = getCurrentCamera()
			if not camera then
				return
			end

			local lookVector = camera.CFrame.LookVector
			appendRecordedDeliveryMacroEvent({
				kind = "camera",
				t = os.clock() - recordingStartedAt,
				lx = lookVector.X,
				ly = lookVector.Y,
				lz = lookVector.Z,
			})
		end

		local function startDeliveryRouteRecorder()
			runtimeState.deliveryRouteRecorderToken += 1
			local currentToken = runtimeState.deliveryRouteRecorderToken

			task.spawn(function()
				local lastRecordedPosition = nil
				local recordingStartedAt = os.clock()
				local lastCameraSampleAt = 0
				local lastCameraLookVector = nil

				local function shouldKeepRecording()
					return currentToken == runtimeState.deliveryRouteRecorderToken
						and Toggles
						and Toggles.RecordDeliveryRouteEnabled
						and Toggles.RecordDeliveryRouteEnabled.Value
				end

				local function recordInputState(inputObject, state)
					local inputKind, inputName = getDeliveryMacroInputEventKind(inputObject)
					if not inputKind or not inputName then
						return
					end

					local event = {
						kind = inputKind,
						name = inputName,
						state = state == true,
						t = os.clock() - recordingStartedAt,
					}

					if inputKind == "mouse" and UserInputService then
						local mouseLocation = UserInputService:GetMouseLocation()
						if mouseLocation then
							event.x = mouseLocation.X
							event.y = mouseLocation.Y
						end
					end

					appendRecordedDeliveryMacroEvent(event)
				end

				local inputBeganConnection = UserInputService.InputBegan:Connect(function(inputObject, gameProcessed)
					if gameProcessed or not shouldKeepRecording() then
						return
					end

					recordInputState(inputObject, true)
				end)

				local inputEndedConnection = UserInputService.InputEnded:Connect(function(inputObject)
					if not shouldKeepRecording() then
						return
					end

					recordInputState(inputObject, false)
				end)

				while currentToken == runtimeState.deliveryRouteRecorderToken
					and Toggles
					and Toggles.RecordDeliveryRouteEnabled
					and Toggles.RecordDeliveryRouteEnabled.Value
				do
					local character = LocalPlayer and LocalPlayer.Character
					local root = character and getCharacterRoot(character)
					if root then
						local sampleDistance = math.max(tonumber(getOptionValue("DeliveryRouteSampleDistance", 8)) or 8, 1)
						local position = root.Position
						local moveMode = getHorizontalSpeed(character) >= deliveryRecorderState.runSpeedThreshold and "run" or "walk"

						if not lastRecordedPosition then
							local routePoint = createRecordedDeliveryRoutePoint(position, moveMode)
							if routePoint then
								table.insert(deliveryRouteState.recordedRoute, routePoint)
							end
							lastRecordedPosition = position
							saveRecordedDeliveryRoute()
							updateDeliveryRouteStatusLabel()
						else
							local delta = position - lastRecordedPosition
							if delta:Dot(delta) >= (sampleDistance * sampleDistance) then
								local routePoint = createRecordedDeliveryRoutePoint(position, moveMode)
								if routePoint then
									table.insert(deliveryRouteState.recordedRoute, routePoint)
								end
								lastRecordedPosition = position
								saveRecordedDeliveryRoute()
								updateDeliveryRouteStatusLabel()
							end
						end

						local now = os.clock()
						if now - lastCameraSampleAt >= deliveryRecorderState.cameraSampleInterval then
							local camera = getCurrentCamera()
							local lookVector = camera and camera.CFrame.LookVector
							if lookVector then
								if not lastCameraLookVector or lastCameraLookVector:Dot(lookVector) <= deliveryRecorderState.cameraDotThreshold then
									captureDeliveryMacroCameraSample(recordingStartedAt)
									lastCameraLookVector = lookVector
								end
							end
							lastCameraSampleAt = now
						end
					end

					task.wait(0.1)
				end

				inputBeganConnection:Disconnect()
				inputEndedConnection:Disconnect()

				updateDeliveryRouteStatusLabel()
			end)
		end

		local function getActiveDeliverySpot()
			local activeEffects = getLocalEntityActiveEffectsFolder()
			if not activeEffects then
				return nil
			end

			local navigationBeam = activeEffects:FindFirstChild("NavigationBeam")
			if not navigationBeam or not navigationBeam:IsA("StringValue") then
				return nil
			end

			local partValue = navigationBeam:FindFirstChild("Part")
			if not partValue or not partValue:IsA("ObjectValue") then
				return nil
			end

			local targetPart = partValue.Value
			if targetPart and targetPart:IsA("BasePart") and targetPart.Name == "DeliverySpot" then
				return targetPart
			end

			return nil
		end

		local function hasActiveDeliveryEffect()
			local activeEffects = getLocalEntityActiveEffectsFolder()
			if not activeEffects then
				return false
			end

			local navigationBeam = activeEffects:FindFirstChild("NavigationBeam")
			return navigationBeam ~= nil and navigationBeam:IsA("StringValue")
		end

		local function isPathfindingDeliveryFarmActive(currentToken)
			return currentToken == runtimeState.pathfindingDeliveryFarmToken
				and Toggles
				and Toggles.PathfindingDeliveryFarmEnabled
				and Toggles.PathfindingDeliveryFarmEnabled.Value == true
		end

		local function setDeliveryRunKeyHeld(held)
			if runtimeState.deliveryRunWHeld == held or not VirtualInputManager then
				runtimeState.deliveryRunWHeld = held
				return held
			end

			pcall(function()
				VirtualInputManager:SendKeyEvent(held, Enum.KeyCode.W, false, game)
			end)
			runtimeState.deliveryRunWHeld = held
			return held
		end

		local function stopDeliveryRunInput()
			setDeliveryRunKeyHeld(false)
			local character = LocalPlayer and LocalPlayer.Character
			local humanoid = character and getCharacterHumanoid(character)
			if humanoid then
				pcall(function()
					humanoid:Move(Vector3.zero, false)
				end)
			end
		end

		local function startDeliveryRunInput()
			if not VirtualInputManager then
				return false
			end

			stopDeliveryRunInput()
			pcall(function()
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
				task.wait(0.03)
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
				task.wait(0.03)
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)
				task.wait(0.03)
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
				task.wait(0.03)
			end)
			setDeliveryRunKeyHeld(true)
			return true
		end

		local function setMacroPlaybackInputState(event, state)
			if not event or type(event.kind) ~= "string" or type(event.name) ~= "string" then
				return
			end

			if event.kind == "key" then
				local keyCode = Enum.KeyCode[event.name]
				if keyCode then
					pcall(function()
						VirtualInputManager:SendKeyEvent(state, keyCode, false, game)
					end)
				end
				return
			end

			if event.kind == "mouse" then
				local mouseButton = event.name == "MouseButton2" and Enum.UserInputType.MouseButton2 or Enum.UserInputType.MouseButton1
				local mouseX = tonumber(event.x) or 0
				local mouseY = tonumber(event.y) or 0
				pcall(function()
					VirtualInputManager:SendMouseButtonEvent(mouseX, mouseY, mouseButton, state, game, 0)
				end)
			end
		end

		local function resetDeliveryMacroPlaybackInputs()
			for keyName in pairs(deliveryRecorderState.supportedKeys) do
				setMacroPlaybackInputState({
					kind = "key",
					name = keyName,
				}, false)
			end

			for mouseName in pairs(deliveryRecorderState.supportedMouse) do
				setMacroPlaybackInputState({
					kind = "mouse",
					name = mouseName,
					x = 0,
					y = 0,
				}, false)
			end
		end

		local function orientCameraToLookVector(lookVector)
			local camera = getCurrentCamera()
			if not camera or typeof(lookVector) ~= "Vector3" or lookVector.Magnitude <= 0.001 then
				return
			end

			local cameraPosition = camera.CFrame.Position
			pcall(function()
				camera.CFrame = CFrame.lookAt(cameraPosition, cameraPosition + lookVector)
			end)
		end

		local function runRecordedDeliveryMacro(character, finalTargetPosition, currentToken)
			if #deliveryRecorderState.macroEvents == 0 then
				return false
			end

			stopDeliveryRunInput()
			resetDeliveryMacroPlaybackInputs()
			local previousEventTime = 0
			for _, event in ipairs(deliveryRecorderState.macroEvents) do
				if currentToken and not isPathfindingDeliveryFarmActive(currentToken) then
					stopDeliveryRunInput()
					resetDeliveryMacroPlaybackInputs()
					return false
				end

				local eventTime = tonumber(event.t) or previousEventTime
				local waitDuration = math.max(eventTime - previousEventTime, 0)
				if waitDuration > 0 then
					task.wait(waitDuration)
				end
				previousEventTime = eventTime

				if event.kind == "camera" then
					local lookVector = Vector3.new(
						tonumber(event.lx) or 0,
						tonumber(event.ly) or 0,
						tonumber(event.lz) or -1
					)
					orientCameraToLookVector(lookVector)
				elseif event.kind == "key" or event.kind == "mouse" then
					setMacroPlaybackInputState(event, event.state == true)
				end
			end

			for _, event in ipairs(deliveryRecorderState.macroEvents) do
				if event.kind == "key" or event.kind == "mouse" then
					setMacroPlaybackInputState(event, false)
				end
			end

			stopDeliveryRunInput()
			resetDeliveryMacroPlaybackInputs()

			if typeof(finalTargetPosition) == "Vector3" then
				return walkCharacterToPosition(character, finalTargetPosition, 7, currentToken)
			end

			return true
		end

		local function nativeMoveCharacterToPosition(character, targetPosition, stopDistance, currentToken, moveMode)
			local humanoid = character and getCharacterHumanoid(character)
			local root = character and getCharacterRoot(character)
			if not humanoid or not root or not targetPosition then
				return false
			end

			stopDistance = math.max(tonumber(stopDistance) or 6, 2)
			local stopDistanceSquared = stopDistance * stopDistance
			local initialOffset = root.Position - targetPosition
			if initialOffset:Dot(initialOffset) <= stopDistanceSquared then
				return true
			end

			local shouldRun = moveMode == "run"
			local staminaLowThreshold = 20
			local staminaRecoveryThreshold = 95
			local timeoutAt = os.clock() + 30
			if shouldRun then
				startDeliveryRunInput()
			else
				stopDeliveryRunInput()
			end

			while os.clock() < timeoutAt do
				if currentToken and not isPathfindingDeliveryFarmActive(currentToken) then
					stopDeliveryRunInput()
					pcall(function()
						humanoid:Move(Vector3.zero, false)
					end)
					return false
				end

				local currentRoot = getCharacterRoot(character)
				if not currentRoot then
					stopDeliveryRunInput()
					pcall(function()
						humanoid:Move(Vector3.zero, false)
					end)
					return false
				end

				local currentOffset = currentRoot.Position - targetPosition
				if currentOffset:Dot(currentOffset) <= stopDistanceSquared then
					stopDeliveryRunInput()
					pcall(function()
						humanoid:Move(Vector3.zero, false)
					end)
					return true
				end

				if shouldRun then
					local staminaValue = getStaminaValue()
					local staminaNumber = staminaValue and tonumber(staminaValue.Value)
					if staminaNumber and staminaNumber <= staminaLowThreshold then
						stopDeliveryRunInput()
						pcall(function()
							humanoid:Move(Vector3.zero, false)
						end)
						local recoveryDeadline = os.clock() + 10
						while os.clock() < recoveryDeadline do
							if currentToken and not isPathfindingDeliveryFarmActive(currentToken) then
								pcall(function()
									humanoid:Move(Vector3.zero, false)
								end)
								return false
							end

							local liveStaminaValue = getStaminaValue()
							local liveStaminaNumber = liveStaminaValue and tonumber(liveStaminaValue.Value)
							if liveStaminaNumber and liveStaminaNumber >= staminaRecoveryThreshold then
								break
							end
							task.wait(0.1)
						end
						startDeliveryRunInput()
					end
				end

				local flatTarget = Vector3.new(targetPosition.X, currentRoot.Position.Y, targetPosition.Z)
				local flatDelta = flatTarget - currentRoot.Position
				if flatDelta:Dot(flatDelta) > 0.001 then
					local direction = flatDelta.Unit
					pcall(function()
						humanoid:Move(Vector3.new(direction.X, 0, direction.Z), false)
					end)
				end

				task.wait(0.05)
			end

			stopDeliveryRunInput()
			pcall(function()
				humanoid:Move(Vector3.zero, false)
			end)
			return false
		end

		local function walkCharacterToPosition(character, targetPosition, stopDistance, currentToken)
			local humanoid = character and getCharacterHumanoid(character)
			local root = character and getCharacterRoot(character)
			if not humanoid or not root or not targetPosition then
				return false
			end

			stopDistance = math.max(tonumber(stopDistance) or 6, 2)
			local stopDistanceSquared = stopDistance * stopDistance
			local initialOffset = root.Position - targetPosition
			if initialOffset:Dot(initialOffset) <= stopDistanceSquared then
				return true
			end

			local timeoutAt = os.clock() + 30

			while os.clock() < timeoutAt do
				if currentToken and not isPathfindingDeliveryFarmActive(currentToken) then
					return false
				end

				local currentRoot = getCharacterRoot(character)
				if not currentRoot then
					return false
				end

				local currentOffset = currentRoot.Position - targetPosition
				if currentOffset:Dot(currentOffset) <= stopDistanceSquared then
					return true
				end

				pcall(function()
					humanoid:MoveTo(targetPosition)
				end)

				task.wait(0.1)
			end

			return false
		end

		local function runCharacterAlongRecordedRoute(character, finalTargetPosition, currentToken)
			if #deliveryRouteState.recordedRoute == 0 then
				return false
			end

			local root = character and getCharacterRoot(character)
			if not root then
				return false
			end

			local startIndex = getClosestRecordedRouteIndex(root.Position) or 1
			for index = startIndex, #deliveryRouteState.recordedRoute do
				if currentToken and not isPathfindingDeliveryFarmActive(currentToken) then
					return false
				end

				local routePoint = deliveryRouteState.recordedRoute[index]
				local routePosition = getRecordedDeliveryRoutePointPosition(routePoint)
				if not routePosition then
					continue
				end

				local moveMode = getRecordedDeliveryRoutePointMoveMode(routePoint)
				if not nativeMoveCharacterToPosition(character, routePosition, 6, currentToken, moveMode) then
					return false
				end

				task.wait(0.05)
			end

			if typeof(finalTargetPosition) == "Vector3" then
				local finalRoutePoint = deliveryRouteState.recordedRoute[#deliveryRouteState.recordedRoute]
				return nativeMoveCharacterToPosition(
					character,
					finalTargetPosition,
					7,
					currentToken,
					getRecordedDeliveryRoutePointMoveMode(finalRoutePoint)
				)
			end

			return true
		end

		local function startPathfindingDeliveryQuest(character, currentToken)
			local allowedActiveSpot = getAllowedActivePathfindingDeliverySpot()
			if allowedActiveSpot then
				return true
			end

			local existingSpot = getActiveDeliverySpot()
			if existingSpot then
				if isAllowedPathfindingDeliverySpot(existingSpot) then
					return true
				end

				abandonCurrentDeliveryJob()
				return false
			end

			if hasActiveDeliveryEffect() then
				local effectTimeoutAt = os.clock() + 1.5
				while os.clock() < effectTimeoutAt do
					local currentAllowedSpot = getAllowedActivePathfindingDeliverySpot()
					if currentAllowedSpot then
						return true
					end

					local currentSpot = getActiveDeliverySpot()
					if currentSpot then
						if isAllowedPathfindingDeliverySpot(currentSpot) then
							return true
						end

						abandonCurrentDeliveryJob()
						return false
					end

					task.wait(0.1)
				end
			end

			local boardPosition = configState.deliveryQuestStartCFrame.Position
			if not walkCharacterToPosition(character, boardPosition, 8, currentToken) then
				return false
			end

			task.wait(0.15)
			holdInteractionKey(0.5)
			local timeoutAt = os.clock() + 2.5
			while os.clock() < timeoutAt do
				local currentAllowedSpot = getAllowedActivePathfindingDeliverySpot()
				if currentAllowedSpot then
					return true
				end

				local currentSpot = getActiveDeliverySpot()
				if currentSpot then
					if isAllowedPathfindingDeliverySpot(currentSpot) then
						return true
					end

					break
				end
				task.wait(0.1)
			end

			local unresolvedSpot = getActiveDeliverySpot()
			if unresolvedSpot and not isAllowedPathfindingDeliverySpot(unresolvedSpot) then
				abandonCurrentDeliveryJob()
			end

			return false
		end

		local function runPathfindingDeliveryToSpot(character, spotPart, currentToken)
			if not character or not spotPart then
				return false
			end

			if getDeliveryPlaybackMode() == "Recorded Macro" and #deliveryRecorderState.macroEvents > 0 then
				if not runRecordedDeliveryMacro(character, spotPart.Position, currentToken) then
					return false
				end
			elseif getDeliveryPlaybackMode() == "Recorded Route" and #deliveryRouteState.recordedRoute > 0 then
				if not runCharacterAlongRecordedRoute(character, spotPart.Position, currentToken) then
					return false
				end
			else
				if not walkCharacterToPosition(character, spotPart.Position, 7, currentToken) then
					return false
				end
			end

			local timeoutAt = os.clock() + 8
			while os.clock() < timeoutAt do
				if not spotPart.Parent then
					return true
				end

				if not spotPart:FindFirstChildOfClass("TouchInterest") then
					return true
				end

				task.wait(0.1)
			end

			return false
		end

		local function tweenCharacterRootTo(root, targetCFrame, overrideDuration)
			if not root or not targetCFrame then
				return false
			end

			cancelDeliveryFarmTween()

			local platform = ensureDeliveryFarmPlatform(root)
			local duration = tonumber(overrideDuration)
			if not duration then
				local distance = (root.Position - targetCFrame.Position).Magnitude
				duration = math.max(distance / getDeliveryTweenSpeed(), 0.05)
			end

			local cancelled = false
			runtimeState.activeDeliveryFarmTween = function()
				cancelled = true
			end

			local success = pcall(function()
				local startCFrame = root.CFrame
				local startTime = os.clock()
				local endTime = startTime + duration
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				while not cancelled do
					local now = os.clock()
					local alpha = duration <= 0 and 1 or math.clamp((now - startTime) / duration, 0, 1)
					local currentCFrame = startCFrame:Lerp(targetCFrame, alpha)
					root.CFrame = currentCFrame
					if platform then
						platform.CFrame = currentCFrame * CFrame.new(0, -3.5, 0)
					end
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					if now >= endTime or alpha >= 1 then
						break
					end
					RunService.Heartbeat:Wait()
				end

				if not cancelled then
					root.CFrame = targetCFrame
					if platform then
						platform.CFrame = targetCFrame * CFrame.new(0, -3.5, 0)
					end
				end
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end)

			runtimeState.activeDeliveryFarmTween = nil
			return success and not cancelled
		end

		local function setCharacterDeliveryPhysics(character, enabled)
			if not character then
				return nil
			end

			local humanoid = getCharacterHumanoid(character)
			local collisionStates = nil
			if enabled then
				collisionStates = {}
				for _, descendant in ipairs(character:GetDescendants()) do
					if descendant:IsA("BasePart") then
						collisionStates[descendant] = descendant.CanCollide
						descendant.CanCollide = false
					end
				end
			end

			if humanoid then
				if enabled then
					pcall(function()
						humanoid:ChangeState(Enum.HumanoidStateType.Physics)
					end)
					humanoid.PlatformStand = true
				else
					humanoid.PlatformStand = false
					pcall(function()
						humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
					end)
				end
			end

			return collisionStates
		end

		local function restoreCharacterCollisionStates(collisionStates)
			if type(collisionStates) ~= "table" then
				return
			end

			for part, canCollide in pairs(collisionStates) do
				if part and part.Parent then
					part.CanCollide = canCollide
				end
			end
		end


		local function clearTrainingPromptQueue()
			table.clear(trainingPromptState.queue)
			runtimeState.lastBenchVisibleKey = nil
		end

		local function pruneExpiredTrainingPrompts()
			local now = os.clock()
			while #trainingPromptState.queue > 0 do
				local prompt = trainingPromptState.queue[1]
				if prompt and prompt.expiresAt and prompt.expiresAt > now then
					break
				end
				table.remove(trainingPromptState.queue, 1)
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
			if trainingPromptState.lastKey == key and (now - trainingPromptState.lastAt) <= 0.03 then
				return
			end

			trainingPromptState.lastKey = key
			trainingPromptState.lastAt = now
			trainingPromptState.sequence += 1
			table.insert(trainingPromptState.queue, {
				id = trainingPromptState.sequence,
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
			if trainingPromptState.remoteConnection then
				pcall(function()
					trainingPromptState.remoteConnection:Disconnect()
				end)
				trainingPromptState.remoteConnection = nil
			end
			if trainingPromptState.uiConnection then
				pcall(function()
					trainingPromptState.uiConnection:Disconnect()
				end)
				trainingPromptState.uiConnection = nil
			end
			trainingPromptState.activeRemote = nil
			clearTrainingPromptQueue()
		end

		local function connectTrainingPromptListeners(spotRemote)
			if trainingPromptState.activeRemote == spotRemote and trainingPromptState.remoteConnection then
				return
			end

			disconnectTrainingPromptListeners()
			trainingPromptState.activeRemote = spotRemote

			if spotRemote and spotRemote.OnClientEvent then
				trainingPromptState.remoteConnection = spotRemote.OnClientEvent:Connect(function(eventName, payload)
					handleTrainingClientEvent(eventName, payload)
				end)
			end

			if trainingPromptState.uiRemote and trainingPromptState.uiRemote.OnClientEvent then
				trainingPromptState.uiConnection = trainingPromptState.uiRemote.OnClientEvent:Connect(function(eventName, payload)
					handleTrainingClientEvent(eventName, payload)
				end)
			end
		end

		local function getNextTrainingPrompt()
			pruneExpiredTrainingPrompts()
			local prompt = trainingPromptState.queue[1]
			if not prompt then
				return nil
			end
			return prompt
		end

		local function consumeTrainingPrompt(promptId)
			if #trainingPromptState.queue == 0 then
				return
			end

			local prompt = trainingPromptState.queue[1]
			if prompt and prompt.id == promptId then
				table.remove(trainingPromptState.queue, 1)
				return
			end

			for index, entry in ipairs(trainingPromptState.queue) do
				if entry and entry.id == promptId then
					table.remove(trainingPromptState.queue, index)
					return
				end
			end
		end

		local function getAutoTrainToken(toggleKey)
			if toggleKey == "AutoBenchEnabled" then
				return runtimeState.autoBenchToken
			end

			if toggleKey == "AutoPullUpEnabled" then
				return runtimeState.autoPullUpToken
			end

			if toggleKey == "AutoSquatMachineEnabled" then
				return runtimeState.autoSquatMachineToken
			end

			if toggleKey == "AutoTreadmillEnabled" then
				return runtimeState.autoTreadmillToken
			end

			if toggleKey == "AutoBikeEnabled" then
				return runtimeState.autoBikeToken
			end

			if toggleKey == "AutoBagsEnabled" then
				return runtimeState.autoBagsToken
			end

			if toggleKey == "AutoSleepEnabled" then
				return runtimeState.autoSleepToken
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

		local function getEnabledAutoTrainToggleKey()
			for _, toggleKey in ipairs(autoTrainToggleKeys) do
				if Toggles and Toggles[toggleKey] and Toggles[toggleKey].Value then
					return toggleKey
				end
			end

			return nil
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

		local function isAutoTrainLoopActive(toggleKey, currentToken)
			return currentToken == getAutoTrainToken(toggleKey)
				and Toggles
				and Toggles[toggleKey]
				and Toggles[toggleKey].Value == true
		end

		local function startTrainingSpotAutomation(toggleKey, spotName, options)
			local currentToken = getAutoTrainToken(toggleKey)
			options = options or {}
			
			task.spawn(function()
				while isAutoTrainLoopActive(toggleKey, currentToken) do
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
							if not isAutoTrainLoopActive(toggleKey, currentToken) then
								break
							end

							connectTrainingPromptListeners(spotRemote)
							clearTrainingPromptQueue()

							-- Stealth Teleport with micro-wait to settle physics
							teleportCharacterToTrainingSpot(character, spotModel)
							task.wait(0.35)
							if not isAutoTrainLoopActive(toggleKey, currentToken) then
								break
							end

							if options.HoldEBeforeStart then
								holdInteractionKey(options.HoldEDuration or 0.3)
								task.wait(0.1)
								if not isAutoTrainLoopActive(toggleKey, currentToken) then
									break
								end
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
							if not isAutoTrainLoopActive(toggleKey, currentToken) then
								break
							end
							
							-- Prompt-driven WASD loop
							runtimeState.lastBenchVisibleKey = nil
							local trainingEndAt = os.clock() + (options.Duration or 60)
							while isAutoTrainLoopActive(toggleKey, currentToken) and os.clock() < trainingEndAt do
								if isRecoveryInProgress() then
									break
								end

								local prompt = getNextTrainingPrompt()
								if prompt then
									runtimeState.lastBenchVisibleKey = prompt.key
									submitTrainingPromptKey(spotRemote, prompt.key)
									consumeTrainingPrompt(prompt.id)
									task.wait(0.005)
								else
									runtimeState.lastBenchVisibleKey = nil
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
			runtimeState.autoBenchToken += 1
			startTrainingSpotAutomation("AutoBenchEnabled", "Bench", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoPullUp()
			runtimeState.autoPullUpToken += 1
			startTrainingSpotAutomation("AutoPullUpEnabled", "PullUp", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoSquatMachine()
			runtimeState.autoSquatMachineToken += 1
			startTrainingSpotAutomation("AutoSquatMachineEnabled", "Squat", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoTreadmill()
			runtimeState.autoTreadmillToken += 1
			startTrainingSpotAutomation("AutoTreadmillEnabled", "Treadmill", {
				HoldEBeforeStart = true,
				HoldEDuration = 0.3,
				Duration = 60,
			})
		end

		local function startAutoBike()
			runtimeState.autoBikeToken += 1
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

		local function isPunchingBagReservedByLocalPlayer(bagModel)
			local reserved = getPunchingBagReservedValue(bagModel)
			if not reserved then
				return false
			end

			if reserved:IsA("ObjectValue") then
				local value = reserved.Value
				return value == LocalPlayer or value == (LocalPlayer and LocalPlayer.Character)
			end

			local textValue = tostring(reserved.Value or "")
			textValue = textValue:match("^%s*(.-)%s*$") or ""
			return textValue ~= "" and textValue == LocalPlayer.Name
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

		local function getPunchingBagTargetCFrame(character, bagModel)
			local bagPart = getPunchingBagPart(bagModel)
			local root = character and getCharacterRoot(character)
			if not bagPart or not root then
				return nil
			end

			local axisName = configState.autoBagPlacement.Axis or "LookVector"
			local axisVector = bagPart.CFrame.LookVector
			if axisName == "RightVector" then
				axisVector = bagPart.CFrame.RightVector
			elseif axisName == "UpVector" then
				axisVector = bagPart.CFrame.UpVector
			end

			local standDistance = tonumber(configState.autoBagPlacement.ManualDistance) or 3.5
			if configState.autoBagPlacement.UseBagAndPlayerDepth ~= false then
				local bagDepth = axisName == "RightVector" and bagPart.Size.X or bagPart.Size.Z
				local playerDepth = axisName == "RightVector" and root.Size.X or root.Size.Z
				standDistance = math.max(bagDepth * 0.5, 0.5) + math.max(playerDepth * 0.5, 0.5) + (tonumber(configState.autoBagPlacement.DistanceOffset) or 0.35)
			end

			local sideOffset = tonumber(configState.autoBagPlacement.SideOffset) or 0
			local backOffset = tonumber(configState.autoBagPlacement.BackOffset) or 0
			local verticalOffset = tonumber(configState.autoBagPlacement.VerticalOffset) or 0.15
			local targetPosition = bagPart.Position
				+ (axisVector * (standDistance + backOffset))
				+ (bagPart.CFrame.RightVector * sideOffset)
				+ Vector3.new(0, verticalOffset, 0)
			local delta = bagPart.Position - targetPosition
			local baseYaw = math.atan2(-delta.X, -delta.Z)
			local yawOffsetRadians = math.rad(tonumber(configState.autoBagPlacement.YawOffsetDegrees) or 0)
			return CFrame.new(targetPosition) * CFrame.Angles(0, baseYaw + yawOffsetRadians, 0)
		end

		local function isCharacterAlignedToPunchingBag(character, bagModel)
			local root = character and getCharacterRoot(character)
			local targetCFrame = getPunchingBagTargetCFrame(character, bagModel)
			if not root or not targetCFrame then
				return false
			end

			local positionDelta = (root.Position - targetCFrame.Position).Magnitude
			if positionDelta > 1.25 then
				return false
			end

			local lookDot = root.CFrame.LookVector:Dot(targetCFrame.LookVector)
			return lookDot >= 0.96
		end

		local function teleportCharacterToPunchingBag(character, bagModel)
			local root = character and getCharacterRoot(character)
			local targetCFrame = getPunchingBagTargetCFrame(character, bagModel)
			if not root or not targetCFrame then
				return false
			end

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

		local function getAutoBagsTargetBag()
			if runtimeState.activeAutoBagModel
				and runtimeState.activeAutoBagModel.Parent
				and not isPunchingBagTrainingFinished(runtimeState.activeAutoBagModel)
				and isPunchingBagReservedByLocalPlayer(runtimeState.activeAutoBagModel)
			then
				return runtimeState.activeAutoBagModel
			end

			runtimeState.activeAutoBagModel = getClosestAvailablePunchingBag()
			return runtimeState.activeAutoBagModel
		end

		local function getAutoBagRemoteMode()
			local selectedMode = getOptionValue("AutoBagsMode", "Strength")
			if selectedMode == "Attack Speed" then
				return "atkspd"
			end

			return "str"
		end

		local function startAutoBags()
			runtimeState.autoBagsToken += 1
			local currentToken = runtimeState.autoBagsToken

			task.spawn(function()
				while isAutoTrainLoopActive("AutoBagsEnabled", currentToken) do
					if isRecoveryInProgress() then
						task.wait(0.2)
						continue
					end

					local character = LocalPlayer and LocalPlayer.Character
					local bagModel = getAutoBagsTargetBag()
					local bagRemote = bagModel and getPunchingBagRemote(bagModel)
					if character and bagModel and bagRemote then
						disconnectTrainingPromptListeners()

						if not isCharacterAlignedToPunchingBag(character, bagModel) then
							teleportCharacterToPunchingBag(character, bagModel)
							task.wait(0.2)
						end

						if isAutoTrainLoopActive("AutoBagsEnabled", currentToken) then
							if not isAutoTrainLoopActive("AutoBagsEnabled", currentToken) then
								break
							end
							holdInteractionKey(0.3)
							task.wait(0.15)
							if not isAutoTrainLoopActive("AutoBagsEnabled", currentToken) then
								break
							end
							pcall(function()
								bagRemote:FireServer(getAutoBagRemoteMode())
							end)
							task.wait(0.2)
							if not isCharacterAlignedToPunchingBag(character, bagModel) then
								teleportCharacterToPunchingBag(character, bagModel)
								task.wait(0.1)
							end

							while isAutoTrainLoopActive("AutoBagsEnabled", currentToken) do
								if isPunchingBagTrainingFinished(bagModel) then
									if runtimeState.activeAutoBagModel == bagModel then
										runtimeState.activeAutoBagModel = nil
									end
									break
								end

								if not isCharacterAlignedToPunchingBag(character, bagModel) then
									teleportCharacterToPunchingBag(character, bagModel)
									task.wait(0.08)
								end

								sendLeftClickVirtualInput()
								task.wait(0.08)
							end
						end
					end

					task.wait(0.6)
				end

				runtimeState.activeAutoBagModel = nil
			end)
		end

		local function restartAutoTrainMode(toggleKey)
			if toggleKey == "AutoBenchEnabled" then
				startAutoBench()
				return
			end

			if toggleKey == "AutoPullUpEnabled" then
				startAutoPullUp()
				return
			end

			if toggleKey == "AutoSquatMachineEnabled" then
				startAutoSquatMachine()
				return
			end

			if toggleKey == "AutoTreadmillEnabled" then
				startAutoTreadmill()
				return
			end

			if toggleKey == "AutoBikeEnabled" then
				startAutoBike()
				return
			end

			if toggleKey == "AutoBagsEnabled" then
				startAutoBags()
			end
		end

		local function stopAntiAfk()
			if runtimeState.antiAfkConnection then
				pcall(function()
					runtimeState.antiAfkConnection:Disconnect()
				end)
				runtimeState.antiAfkConnection = nil
			end
		end

		local function startAntiAfk()
			stopAntiAfk()
			if not LocalPlayer or not LocalPlayer.Idled then
				return
			end

			runtimeState.antiAfkConnection = LocalPlayer.Idled:Connect(function()
				pcall(function()
					VirtualUser:CaptureController()
					VirtualUser:ClickButton2(Vector2.new(0, 0))
				end)
			end)
		end

		local function startDeliveryFarm()
			runtimeState.deliveryFarmToken += 1
			local currentToken = runtimeState.deliveryFarmToken

			task.spawn(function()
				local function isActive()
					return currentToken == runtimeState.deliveryFarmToken
						and Toggles.DeliveryFarmEnabled
						and Toggles.DeliveryFarmEnabled.Value
				end

				local character = LocalPlayer and LocalPlayer.Character
				local root = character and getCharacterRoot(character)
				if not character or not root then
					return
				end

				local humanoid = getCharacterHumanoid(character)
				local platform = ensureDeliveryFarmPlatform(root)
				local boardPos = configState.deliveryQuestStartCFrame.Position

				if humanoid then
					pcall(function()
						humanoid.PlatformStand = true
						humanoid:ChangeState(Enum.HumanoidStateType.Physics)
					end)
				end

				local function teleportUnderground(pos)
					local savedStates = {}
					for _, desc in ipairs(character:GetDescendants()) do
						if desc:IsA("BasePart") then
							savedStates[desc] = desc.CanCollide
							desc.CanCollide = false
						end
					end

					pcall(function()
						root.AssemblyLinearVelocity = Vector3.zero
						root.AssemblyAngularVelocity = Vector3.zero
						root.CFrame = CFrame.new(pos.X, pos.Y - 15, pos.Z)
						if platform and platform.Parent then
							platform.CFrame = CFrame.new(pos.X, pos.Y - 18.5, pos.Z)
						end
					end)

					task.wait()

					for desc, state in pairs(savedStates) do
						if desc and desc.Parent then
							desc.CanCollide = state
						end
					end
				end

				teleportUnderground(boardPos)

				while isActive() do
					character = LocalPlayer and LocalPlayer.Character
					root = character and getCharacterRoot(character)
					if not character or not root then
						task.wait(0.5)
						continue
					end

					humanoid = getCharacterHumanoid(character)
					if humanoid and not humanoid.PlatformStand then
						pcall(function()
							humanoid.PlatformStand = true
							humanoid:ChangeState(Enum.HumanoidStateType.Physics)
						end)
					end

					if not hasActiveDeliveryEffect() and not getActiveDeliverySpot() then
						pcall(function()
							local map = workspace:FindFirstChild("Map")
							local folder = map and map:FindFirstChild("Folder")
							local jobBoard = folder and folder:GetChildren()[57]
							local jobChild = jobBoard and jobBoard:FindFirstChild("Job")
							local proximityPrompt = jobChild and jobChild:FindFirstChild("ProximityPrompt")
							if proximityPrompt then
								fireproximityprompt(proximityPrompt)
							end
						end)

						local timeoutAt = os.clock() + 3
						while os.clock() < timeoutAt and isActive() do
							if hasActiveDeliveryEffect() or getActiveDeliverySpot() then
								break
							end
							task.wait(0.1)
						end

						if not isActive() then break end
					end

					while isActive() and (hasActiveDeliveryEffect() or getActiveDeliverySpot()) do
						local activeSpot = getActiveDeliverySpot()
						if not activeSpot then
							task.wait(0.1)
							continue
						end

						teleportUnderground(activeSpot.Position)
						task.wait(8)
						if not isActive() then break end

						pcall(function()
							firetouchinterest(activeSpot, root, 0)
						end)

						task.wait(8)
						if not isActive() then break end
					end

					if not isActive() then break end

					teleportUnderground(boardPos)
					task.wait(0.3)
				end

				if humanoid then
					pcall(function()
						humanoid.PlatformStand = false
						humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
					end)
				end
				cancelDeliveryFarmTween()
				destroyDeliveryFarmPlatform()
			end)
		end

		local function startPathfindingDeliveryFarm()
			runtimeState.pathfindingDeliveryFarmToken += 1
			local currentToken = runtimeState.pathfindingDeliveryFarmToken

			task.spawn(function()
				while isPathfindingDeliveryFarmActive(currentToken) do
					local character = LocalPlayer and LocalPlayer.Character
					local root = character and getCharacterRoot(character)
					if not character or not root then
						task.wait(0.5)
						continue
					end

					local activeSpot = getAllowedActivePathfindingDeliverySpot()
					local deliveryActive = activeSpot ~= nil
					if not deliveryActive then
						startPathfindingDeliveryQuest(character, currentToken)
						task.wait(0.4)
						activeSpot = getAllowedActivePathfindingDeliverySpot()
						deliveryActive = activeSpot ~= nil
					end

					if deliveryActive and activeSpot then
						runPathfindingDeliveryToSpot(character, activeSpot, currentToken)
						task.wait(0.2)
					else
						local currentSpot = getActiveDeliverySpot()
						if currentSpot and not isAllowedPathfindingDeliverySpot(currentSpot) then
							abandonCurrentDeliveryJob()
						end
						task.wait(0.5)
					end
				end
			end)
		end

		local function startAutoSleep()
			runtimeState.autoSleepToken += 1
			local currentToken = runtimeState.autoSleepToken

			task.spawn(function()
				while currentToken == runtimeState.autoSleepToken and Toggles.AutoSleepEnabled and Toggles.AutoSleepEnabled.Value do
					if not runtimeState.autoSleepInProgress and not runtimeState.autoEatInProgress then
						local bodyFatique = getBodyFatiqueValue()
						local threshold = getOptionValue("AutoSleepThreshold", 80)
						local currentFatique = bodyFatique and tonumber(bodyFatique.Value)

						if currentFatique and currentFatique >= threshold then
							local resumeAutoTrainToggleKey = getEnabledAutoTrainToggleKey()
							local bedFolder = getClosestHospitalBed()
							local character = LocalPlayer and LocalPlayer.Character
							local bedModel = bedFolder and getTrainingSpotTeleportModel(bedFolder)
							local bedRemote = bedFolder and getTrainingSpotRemote(bedFolder)

							if character and bedModel and bedRemote then
								runtimeState.autoSleepInProgress = true
								if leaveCurrentTrainingMachine() then
									task.wait(0.2)
								end
								disconnectTrainingPromptListeners()
								teleportCharacterToTrainingSpot(character, bedModel)
								task.wait(0.35)
								holdInteractionKey(3)
								task.wait(0.2)
								teleportCharacterToTrainingSpot(character, bedModel)
								task.wait(0.15)

								while currentToken == runtimeState.autoSleepToken and Toggles.AutoSleepEnabled.Value do
									local fatigueValue = getBodyFatiqueValue()
									local fatigueNumber = fatigueValue and tonumber(fatigueValue.Value)
									if fatigueNumber ~= nil and fatigueNumber <= 0 then
										pcall(function()
											bedRemote:FireServer("Leave")
										end)
										task.wait(0.3)
										if resumeAutoTrainToggleKey
											and Toggles
											and Toggles[resumeAutoTrainToggleKey]
											and Toggles[resumeAutoTrainToggleKey].Value
										then
											restartAutoTrainMode(resumeAutoTrainToggleKey)
										end
										break
									end
									task.wait(0.2)
								end

								runtimeState.autoSleepInProgress = false
							end
						end
					end

					task.wait(0.2)
				end

				runtimeState.autoSleepInProgress = false
			end)
		end

		local function startAutoEat()
			runtimeState.autoEatToken += 1
			local currentToken = runtimeState.autoEatToken

			task.spawn(function()
				while currentToken == runtimeState.autoEatToken and Toggles.AutoEatEnabled and Toggles.AutoEatEnabled.Value do
					if not runtimeState.autoEatInProgress and not runtimeState.autoSleepInProgress then
						local hungerValue = getHungerValue()
						local threshold = getOptionValue("AutoEatThreshold", 60)
						local currentHunger = hungerValue and tonumber(hungerValue.Value)

						if currentHunger and currentHunger <= threshold then
							runtimeState.autoEatInProgress = true
							if leaveCurrentTrainingMachine() then
								task.wait(0.2)
							end
							disconnectTrainingPromptListeners()

							while currentToken == runtimeState.autoEatToken and Toggles.AutoEatEnabled.Value do
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

							runtimeState.autoEatInProgress = false
						end
					end

					task.wait(0.2)
				end

				runtimeState.autoEatInProgress = false
			end)
		end

		uiGroups.localCheats:AddToggle("InfiniteRhythmEnabled", {
			Text = "Infinite Rhythm",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startInfiniteRhythmLoop()
			else
				stopInfiniteRhythmLoop()
			end
		end)

		uiGroups.localCheats:AddToggle("InfiniteStaminaEnabled", {
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

		uiGroups.localCheats:AddToggle("SpeedBoostEnabled", {
			Text = "Speed Boost",
			Default = false,
		}):OnChanged(function(enabled)
			setSpeedBoostEnabled(enabled)
		end)

		uiGroups.localCheats:AddToggle("ModeratorDetectorEnabled", {
			Text = "Mod Detector",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startModeratorDetector()
			else
				stopModeratorDetector()
			end
		end)

		uiGroups.localCheats:AddToggle("AntiAfkEnabled", {
			Text = "Anti-AFK",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startAntiAfk()
			else
				stopAntiAfk()
			end
		end)

		uiGroups.autoFarm:AddToggle("DeliveryFarmEnabled", {
			Text = "Delivery Farm",
			Default = false,
		})


		Toggles.DeliveryFarmEnabled:OnChanged(function(enabled)
			if enabled then
				startDeliveryFarm()
			else
				runtimeState.deliveryFarmToken += 1
				cancelDeliveryFarmTween()
				destroyDeliveryFarmPlatform()
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoBenchEnabled", {
			Text = "Auto Bench",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBenchEnabled")
				startAutoBench()
			else
				runtimeState.autoBenchToken += 1
				pcall(leaveCurrentTrainingMachine)
				if not isAnyOtherAutoTrainEnabled("AutoBenchEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoPullUpEnabled", {
			Text = "Auto PullUp",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoPullUpEnabled")
				startAutoPullUp()
			else
				runtimeState.autoPullUpToken += 1
				pcall(leaveCurrentTrainingMachine)
				if not isAnyOtherAutoTrainEnabled("AutoPullUpEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoSquatMachineEnabled", {
			Text = "Auto Squat Machine",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoSquatMachineEnabled")
				startAutoSquatMachine()
			else
				runtimeState.autoSquatMachineToken += 1
				pcall(leaveCurrentTrainingMachine)
				if not isAnyOtherAutoTrainEnabled("AutoSquatMachineEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoTreadmillEnabled", {
			Text = "Auto Treadmill",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoTreadmillEnabled")
				startAutoTreadmill()
			else
				runtimeState.autoTreadmillToken += 1
				pcall(leaveCurrentTrainingMachine)
				if not isAnyOtherAutoTrainEnabled("AutoTreadmillEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoBikeEnabled", {
			Text = "Auto Bike",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBikeEnabled")
				startAutoBike()
			else
				runtimeState.autoBikeToken += 1
				pcall(leaveCurrentTrainingMachine)
				if not isAnyOtherAutoTrainEnabled("AutoBikeEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoBagsEnabled", {
			Text = "Auto Bags",
			Default = false,
		})

		do
			local options = uiGroups.autoTrain:AddDependencyBox()
			options:SetupDependencies({
				{ Toggles.AutoBagsEnabled, true },
			})

			options:AddDropdown("AutoBagsMode", {
				Text = "Bag Mode",
				Values = configState.autoBagModes,
				Default = "Strength",
				Multi = false,
			})
		end

		Toggles.AutoBagsEnabled:OnChanged(function(enabled)
			if enabled then
				disableOtherAutoTrainToggles("AutoBagsEnabled")
				startAutoBags()
			else
				runtimeState.autoBagsToken += 1
				runtimeState.activeAutoBagModel = nil
				if not isAnyOtherAutoTrainEnabled("AutoBagsEnabled") then
					disconnectTrainingPromptListeners()
				end
			end
		end)

		uiGroups.autoTrain:AddToggle("AutoSleepEnabled", {
			Text = "Auto Sleep",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startAutoSleep()
			else
				runtimeState.autoSleepToken += 1
				runtimeState.autoSleepInProgress = false
			end
		end)

		do
			local options = uiGroups.autoTrain:AddDependencyBox()
			options:SetupDependencies({
				{ Toggles.AutoSleepEnabled, true },
			})

			options:AddSlider("AutoSleepThreshold", {
				Text = "Sleep Fatigue",
				Default = 80,
				Min = 0,
				Max = 100,
				Rounding = 0,
			})
		end

		uiGroups.autoEat:AddToggle("AutoEatEnabled", {
			Text = "Auto Eat",
			Default = false,
		})

		do
			local options = uiGroups.autoEat:AddDependencyBox()
			options:SetupDependencies({
				{ Toggles.AutoEatEnabled, true },
			})

			options:AddSlider("AutoEatThreshold", {
				Text = "Eat Hunger",
				Default = 60,
				Min = 0,
				Max = 100,
				Rounding = 0,
			})

			options:AddDropdown("AutoEatFoods", {
				Text = "Foods",
				Values = configState.autoEatFoodNames,
				Default = configState.autoEatFoodNames,
				Multi = true,
			})

			options:AddToggle("AutoBuyFoodEnabled", {
				Text = "Auto Buy Food",
				Default = false,
			})
		end

		Toggles.AutoEatEnabled:OnChanged(function(enabled)
			if enabled then
				startAutoEat()
			else
				runtimeState.autoEatToken += 1
				runtimeState.autoEatInProgress = false
			end
		end)

		registerLibraryUnloadCallback(function()
			stopInfiniteRhythmLoop()
			stopInfiniteStaminaHook()
			disconnectTrainingPromptListeners()
			stopModeratorDetector()
			stopAntiAfk()
			stopDeliveryRunInput()
			resetDeliveryMacroPlaybackInputs()
			runtimeState.deliveryRouteRecorderToken += 1
			cancelDeliveryFarmTween()
			destroyDeliveryFarmPlatform()
			setSpeedBoostEnabled(false)
			runtimeState.deliveryFarmToken += 1
			runtimeState.autoBenchToken += 1
			runtimeState.autoPullUpToken += 1
			runtimeState.autoSquatMachineToken += 1
			runtimeState.autoTreadmillToken += 1
			runtimeState.autoBikeToken += 1
			runtimeState.autoBagsToken += 1
			runtimeState.autoSleepToken += 1
			runtimeState.autoEatToken += 1
			runtimeState.activeAutoBagModel = nil
			runtimeState.autoSleepInProgress = false
			runtimeState.autoEatInProgress = false
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
			if Toggles and Toggles.AntiAfkEnabled then
				pcall(function() Toggles.AntiAfkEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.DeliveryFarmEnabled then
				pcall(function() Toggles.DeliveryFarmEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.PathfindingDeliveryFarmEnabled then
				pcall(function() Toggles.PathfindingDeliveryFarmEnabled:SetValue(false) end)
			end
			if Toggles and Toggles.RecordDeliveryRouteEnabled then
				pcall(function() Toggles.RecordDeliveryRouteEnabled:SetValue(false) end)
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
		local miscServerGroup = Tabs.Misc:AddLeftGroupbox("Server")

		local function decodeServerListResponse(body)
			if type(body) ~= "string" or body == "" then
				return nil
			end

			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(body)
			end)

			if ok and type(decoded) == "table" then
				return decoded
			end

			return nil
		end

		local function fetchPublicServerPage(cursor)
			local url = ("https://games.roblox.com/v1/games/%s/servers/Public?sortOrder=Asc&limit=100"):format(game.PlaceId)
			if type(cursor) == "string" and cursor ~= "" then
				url ..= "&cursor=" .. HttpService:UrlEncode(cursor)
			end

			local ok, body = pcall(function()
				return game:HttpGet(url)
			end)

			if not ok then
				return nil
			end

			return decodeServerListResponse(body)
		end

		local function getLowestPopulationServerId()
			local bestServerId = nil
			local bestPlayerCount = math.huge
			local cursor = nil
			local pagesChecked = 0

			while pagesChecked < 5 do
				local page = fetchPublicServerPage(cursor)
				if type(page) ~= "table" or type(page.data) ~= "table" then
					break
				end

				for _, server in ipairs(page.data) do
					local serverId = server.id
					local playing = tonumber(server.playing) or math.huge
					local maxPlayers = tonumber(server.maxPlayers) or 0
					if serverId
						and serverId ~= game.JobId
						and playing < maxPlayers
						and playing < bestPlayerCount
					then
						bestPlayerCount = playing
						bestServerId = serverId
					end
				end

				cursor = page.nextPageCursor
				pagesChecked += 1
				if type(cursor) ~= "string" or cursor == "" then
					break
				end
			end

			return bestServerId
		end

		miscServerGroup:AddButton("Lowest Population Server", function()
			local targetServerId = getLowestPopulationServerId()
			if not targetServerId then
				return
			end

			pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, targetServerId, LocalPlayer)
			end)
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




