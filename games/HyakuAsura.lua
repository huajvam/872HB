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
local HYAKU_RHYTHM_REMOTE_INTERVAL = 0.03

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

	local gameTabName = getGameTabName()

	Library:OnUnload(function()
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

		-- Auto Bench Automation Module
		local function getClosestBench()
			local TRAINING_SPOTS = workspace:FindFirstChild("TrainingSpots")
			if not TRAINING_SPOTS then return nil end
			
			local closest, dist = nil, math.huge
			local root = getCharacterRoot(LocalPlayer.Character)
			if not root then return nil end

			for _, folder in ipairs(TRAINING_SPOTS:GetChildren()) do
				if folder.Name == "Bench" then
					local model = folder:FindFirstChildOfClass("Model")
					local part = model and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart"))
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

		local function getBenchRemote(benchFolder)
			local trainingSpots = workspace:FindFirstChild("TrainingSpots")
			local radio = benchFolder and benchFolder:FindFirstChild("Radio")
			local remote = radio and radio:FindFirstChild("Remote")
			if remote and remote:IsA("RemoteEvent") then
				return remote
			end

			local directBench = trainingSpots and trainingSpots:FindFirstChild("Bench")
			local directRadio = directBench and directBench:FindFirstChild("Radio")
			local directRemote = directRadio and directRadio:FindFirstChild("Remote")
			if directRemote and directRemote:IsA("RemoteEvent") then
				return directRemote
			end

			return nil
		end

		local function startAutoBench()
			autoBenchToken += 1
			local currentToken = autoBenchToken
			
			task.spawn(function()
				while currentToken == autoBenchToken and Toggles.AutoBenchEnabled and Toggles.AutoBenchEnabled.Value do
					local benchFolder = getClosestBench()
					local root = getCharacterRoot(LocalPlayer.Character)
					
					if benchFolder and root then
						local benchModel = benchFolder:FindFirstChildOfClass("Model")
						local benchRemote = getBenchRemote(benchFolder)
						
						if benchModel and benchRemote then
							-- Stealth Teleport with micro-wait to settle physics
							root.CFrame = benchModel:GetPivot() * CFrame.new(0, 2, 0)
							task.wait(0.2)

							-- Simulate "E" Interaction
							if VirtualInputManager then
								VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
								task.wait(0.3)
								VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
							end
							
							-- Start Training Remote
							benchRemote:FireServer("Start", { Macro = false })

							local function fireBenchKey(key)
								local args = {
									"PressKey",
									{
										Key = key,
									},
								}

								pcall(function()
									benchRemote:FireServer(unpack(args))
								end)
							end
							
							-- WASD Spam Loop
							local keys = {"W", "A", "S", "D"}
							while currentToken == autoBenchToken and Toggles.AutoBenchEnabled.Value do
								for _, key in ipairs(keys) do
									if not Toggles.AutoBenchEnabled.Value then break end
									fireBenchKey(key)
									task.wait(0.05)
								end
							end
						end
					end
					task.wait(1)
				end
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

		autoTrainGroup:AddToggle("AutoBenchEnabled", {
			Text = "Auto Bench",
			Default = false,
		}):OnChanged(function(enabled)
			if enabled then
				startAutoBench()
			else
				autoBenchToken += 1
			end
		end)

		registerLibraryUnloadCallback(function()
			stopInfiniteRhythmLoop()
			stopInfiniteStaminaHook()
			setSpeedBoostEnabled(false)
			autoBenchToken += 1
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
