local GLOBAL_ENV = getgenv and getgenv() or _G
local HUAJ_HUB_ANTI_KICK_HOOK_KEY = "__huaj_hub_antikick_hook_v1"
local HUAJ_HUB_LOADER_GUI_KEY = "__huaj_hub_loader_gui_v1"

local REPO_OWNER = GLOBAL_ENV.HuajHubRepoOwner or "huajvam"
local REPO_NAME = GLOBAL_ENV.HuajHubRepoName or "HuajHub"
local REPO_BRANCH = GLOBAL_ENV.HuajHubRepoBranch or "main"
local RAW_BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/"):format(REPO_OWNER, REPO_NAME, REPO_BRANCH)
local LOCAL_REPO_BASE_DIR = "C:\\Users\\kevvu\\Desktop\\HuajHub"

GLOBAL_ENV.HuajHubRawBaseUrl = RAW_BASE_URL

local function destroyLoaderGui()
	local existing = GLOBAL_ENV[HUAJ_HUB_LOADER_GUI_KEY]
	if not existing then
		return
	end

	GLOBAL_ENV[HUAJ_HUB_LOADER_GUI_KEY] = nil
	pcall(function()
		existing:Destroy()
	end)
end

local function createLoaderGui()
	destroyLoaderGui()

	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local CoreGui = game:GetService("CoreGui")
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer and LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local guiParent = CoreGui or playerGui
	if not guiParent then
		return {
			setStatus = function() end,
			destroy = function() end,
		}
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HuajHubLoader"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "Container"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(360, 150)
	frame.BackgroundColor3 = Color3.fromRGB(22, 22, 24)
	frame.BorderSizePixel = 0
	frame.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 86)
	stroke.Thickness = 1
	stroke.Transparency = 0.15
	stroke.Parent = frame

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 14)
	title.Size = UDim2.new(1, -32, 0, 26)
	title.Font = Enum.Font.GothamBold
	title.Text = "HUAJ HUB LOADER"
	title.TextColor3 = Color3.fromRGB(245, 245, 245)
	title.TextSize = 22
	title.Parent = frame

	local spinner = Instance.new("Frame")
	spinner.Name = "Spinner"
	spinner.BackgroundTransparency = 1
	spinner.AnchorPoint = Vector2.new(0.5, 0.5)
	spinner.Position = UDim2.fromScale(0.5, 0.52)
	spinner.Size = UDim2.fromOffset(54, 54)
	spinner.Parent = frame

	local spinnerDots = {}
	local spinnerDotCount = 8
	local spinnerRadius = 18
	local spinnerDotSize = 8

	for index = 1, spinnerDotCount do
		local angle = ((index - 1) / spinnerDotCount) * (math.pi * 2)
		local dot = Instance.new("Frame")
		dot.Name = "Dot" .. index
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Size = UDim2.fromOffset(spinnerDotSize, spinnerDotSize)
		dot.Position = UDim2.new(
			0.5,
			math.cos(angle) * spinnerRadius,
			0.5,
			math.sin(angle) * spinnerRadius
		)
		dot.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
		dot.BorderSizePixel = 0
		dot.Parent = spinner

		local dotCorner = Instance.new("UICorner")
		dotCorner.CornerRadius = UDim.new(1, 0)
		dotCorner.Parent = dot

		spinnerDots[index] = dot
	end

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.AnchorPoint = Vector2.new(0.5, 1)
	status.Position = UDim2.new(0.5, 0, 1, -16)
	status.Size = UDim2.new(1, -32, 0, 28)
	status.Font = Enum.Font.Gotham
	status.Text = "Starting up"
	status.TextColor3 = Color3.fromRGB(220, 220, 225)
	status.TextSize = 18
	status.Parent = frame

	screenGui.Parent = guiParent
	GLOBAL_ENV[HUAJ_HUB_LOADER_GUI_KEY] = screenGui

	local spinnerStart = os.clock()
	local spinnerConnection = RunService.RenderStepped:Connect(function()
		local elapsed = (os.clock() - spinnerStart) * 2.2
		for index, dot in ipairs(spinnerDots) do
			if dot and dot.Parent then
				local phase = elapsed - ((index - 1) / spinnerDotCount)
				local alpha = 0.25 + (0.75 * (0.5 + 0.5 * math.sin(phase * math.pi * 2)))
				dot.BackgroundTransparency = 1 - alpha
				local scale = 0.8 + (0.35 * alpha)
				dot.Size = UDim2.fromOffset(
					math.floor(spinnerDotSize * scale + 0.5),
					math.floor(spinnerDotSize * scale + 0.5)
				)
			end
		end
	end)

	return {
		setStatus = function(message)
			if status and status.Parent then
				status.Text = tostring(message or "")
			end
		end,
		destroy = function()
			pcall(function()
				spinnerConnection:Disconnect()
			end)
			destroyLoaderGui()
		end,
	}
end

local loaderGui = createLoaderGui()

local function installAntiKick()
	if GLOBAL_ENV[HUAJ_HUB_ANTI_KICK_HOOK_KEY] then
		return
	end

	if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
		return
	end

	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer
	local hookWrapper = newcclosure or function(callback)
		return callback
	end

	local originalNamecall
	originalNamecall = hookmetamethod(game, "__namecall", hookWrapper(function(self, ...)
		local method = getnamecallmethod()
		local isCallerCheckAvailable = type(checkcaller) == "function"

		if not isCallerCheckAvailable or not checkcaller() then
			if self == LocalPlayer and method == "Kick" then
				return nil
			end

			if self == game and method == "Shutdown" then
				return nil
			end
		end

		return originalNamecall(self, ...)
	end))

	GLOBAL_ENV[HUAJ_HUB_ANTI_KICK_HOOK_KEY] = true
end

installAntiKick()
loaderGui.setStatus("Checking data")

local function compileChunk(source, chunkName)
	local chunk, compileError = loadstring(source, chunkName)
	if not chunk then
		error(("HuajHub compile failed for %s: %s"):format(chunkName, tostring(compileError)))
	end

	return chunk
end

local function executeChunk(source, chunkName)
	local chunk = compileChunk(source, chunkName)
	local ok, result = pcall(chunk)
	if not ok then
		error(("HuajHub runtime failed for %s: %s"):format(chunkName, tostring(result)))
	end

	return result
end

local function looksLikeLocalPath(path)
	if type(path) ~= "string" or path == "" then
		return false
	end

	if path:find("^https?://") then
		return false
	end

	return path:find("^[A-Za-z]:[\\/]")
		or path:find("^[\\/][\\/]")
		or not path:find("[:*?\"<>|]")
end

local function canReadLocalFile(path)
	if type(isfile) ~= "function" or type(readfile) ~= "function" or not looksLikeLocalPath(path) then
		return false
	end

	local ok, result = pcall(isfile, path)
	return ok and result == true
end

local function tryReadLocalFile(path)
	if type(readfile) ~= "function" or not looksLikeLocalPath(path) then
		return nil
	end

	local ok, result = pcall(readfile, path)
	if ok and type(result) == "string" and result ~= "" then
		return result
	end

	return nil
end

local function readModuleSource(path)
	local localCandidates = {
		LOCAL_REPO_BASE_DIR .. "\\" .. path:gsub("/", "\\"),
		path,
	}

	for _, candidate in ipairs(localCandidates) do
		local localSource = tryReadLocalFile(candidate)
		if localSource then
			return localSource, candidate
		end

		if canReadLocalFile(candidate) then
			return readfile(candidate), candidate
		end
	end

	if canReadLocalFile(path) then
		return readfile(path), "local"
	end

	local url = RAW_BASE_URL .. path
	return game:HttpGet(url), url
end

local function requireModule(path)
	local source, sourceName = readModuleSource(path)
	GLOBAL_ENV.__huaj_hub_last_module_source = GLOBAL_ENV.__huaj_hub_last_module_source or {}
	GLOBAL_ENV.__huaj_hub_last_module_source[path] = sourceName
	return executeChunk(source, sourceName)
end

local function normalizeModulePath(path)
	if type(path) ~= "string" then
		error("HuajHub sharedRequire expected string path")
	end

	local normalized = path:gsub("\\", "/")
	if normalized:sub(1, 1) == "@" then
		normalized = normalized:sub(2)
	end

	return normalized
end

GLOBAL_ENV.sharedRequire = function(path)
	return requireModule(normalizeModulePath(path))
end

local function resolveGameKey(gameMap)
	if type(gameMap) ~= "table" then
		error("HuajHub expected a game map table")
	end

	local placeMatch = gameMap.Places and gameMap.Places[game.PlaceId]
	if placeMatch then
		return placeMatch
	end

	local gameMatch = gameMap.GameIds and gameMap.GameIds[game.GameId]
	if gameMatch then
		return gameMatch
	end

	return gameMap.DefaultGame or "Universal"
end

local gameMap = sharedRequire("games/gameList.lua")
local gameKey = resolveGameKey(gameMap)

if gameKey == "MashleAcademy" then
	GLOBAL_ENV.__huaj_hub_mashle_initialized_v1 = nil
	GLOBAL_ENV.__huaj_hub_mashle_library_v1 = nil
end

local gameModule = sharedRequire(("games/%s.lua"):format(gameKey))
local loadedGameModulePath = GLOBAL_ENV.__huaj_hub_last_module_source and GLOBAL_ENV.__huaj_hub_last_module_source[("games/%s.lua"):format(gameKey)]

if type(gameModule) ~= "table" or type(gameModule.init) ~= "function" then
	error(("HuajHub game module '%s' is missing init(context)"):format(tostring(gameKey)))
end

local ok, initError = pcall(gameModule.init, {
	gameKey = gameKey,
	repoOwner = REPO_OWNER,
	repoName = REPO_NAME,
	repoBranch = REPO_BRANCH,
	rawBaseUrl = RAW_BASE_URL,
})

if not ok then
	loaderGui.setStatus("All Done")
	task.delay(1.5, function()
		loaderGui.destroy()
	end)
	return
end

loaderGui.setStatus("All Done")
task.delay(0.75, function()
	loaderGui.destroy()
end)
