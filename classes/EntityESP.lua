local EntityESP = {}
EntityESP.__index = EntityESP

local function safeRemoveDrawing(object)
	if not object then
		return
	end

	pcall(function()
		object.Visible = false
	end)

	pcall(function()
		if type(object.Remove) == "function" then
			object:Remove()
			return
		end
	end)

	pcall(function()
		if type(object.Destroy) == "function" then
			object:Destroy()
		end
	end)
end

function EntityESP.createDrawing(registry, className, properties, shuttingDownFlag)
	if shuttingDownFlag and shuttingDownFlag() then
		return nil
	end

	local object = Drawing.new(className)
	for key, value in pairs(properties or {}) do
		object[key] = value
	end

	table.insert(registry, object)
	return object
end

function EntityESP.new(registry, accentColor, shuttingDownFlag)
	local self = setmetatable({
		objects = {},
		boxLines = {},
		skeletonLines = {},
	}, EntityESP)

	for index = 1, 4 do
		self.boxLines[index] = EntityESP.createDrawing(registry, "Line", {
			Thickness = 1,
			Transparency = 1,
			Color = accentColor,
			Visible = false,
		}, shuttingDownFlag)
		table.insert(self.objects, self.boxLines[index])
	end

	self.healthBarOutline = EntityESP.createDrawing(registry, "Square", {
		Filled = false,
		Thickness = 1,
		Transparency = 1,
		Color = Color3.fromRGB(20, 20, 20),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.healthBarOutline)

	self.healthBarFill = EntityESP.createDrawing(registry, "Square", {
		Filled = true,
		Thickness = 1,
		Transparency = 1,
		Color = Color3.fromRGB(80, 255, 120),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.healthBarFill)

	self.staminaBarOutline = EntityESP.createDrawing(registry, "Square", {
		Filled = false,
		Thickness = 1,
		Transparency = 1,
		Color = Color3.fromRGB(20, 20, 20),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.staminaBarOutline)

	self.staminaBarFill = EntityESP.createDrawing(registry, "Square", {
		Filled = true,
		Thickness = 1,
		Transparency = 1,
		Color = Color3.fromRGB(240, 200, 60),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.staminaBarFill)

	self.nameText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 14,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(255, 255, 255),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.nameText)

	self.distanceText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(220, 220, 220),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.distanceText)

	self.healthText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(170, 255, 170),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.healthText)

	self.yenText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(255, 215, 0),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.yenText)

	self.playerYenText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(255, 215, 0),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.playerYenText)

	self.staminaText = EntityESP.createDrawing(registry, "Text", {
		Center = true,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(240, 200, 60),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.staminaText)

	self.magicMarksText = EntityESP.createDrawing(registry, "Text", {
		Center = false,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(190, 110, 255),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.magicMarksText)

	self.rankText = EntityESP.createDrawing(registry, "Text", {
		Center = false,
		Outline = true,
		Size = 13,
		Font = 2,
		Transparency = 1,
		Color = Color3.fromRGB(255, 255, 255),
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.rankText)

	self.tracerLine = EntityESP.createDrawing(registry, "Line", {
		Thickness = 1,
		Transparency = 1,
		Color = accentColor,
		Visible = false,
	}, shuttingDownFlag)
	table.insert(self.objects, self.tracerLine)

	for index = 1, 20 do
		self.skeletonLines[index] = EntityESP.createDrawing(registry, "Line", {
			Thickness = 1,
			Transparency = 1,
			Color = accentColor,
			Visible = false,
		}, shuttingDownFlag)
		table.insert(self.objects, self.skeletonLines[index])
	end

	return self
end

function EntityESP:setAccentColor(accentColor)
	for _, line in ipairs(self.boxLines) do
		if line then
			line.Color = accentColor
		end
	end

	for _, line in ipairs(self.skeletonLines) do
		if line then
			line.Color = accentColor
		end
	end

	if self.tracerLine then
		self.tracerLine.Color = accentColor
	end
end

function EntityESP:setGroupVisible(objects, visible)
	for _, object in ipairs(objects or {}) do
		if object then
			object.Visible = visible
		end
	end
end

function EntityESP:hideSkeletonFrom(startIndex)
	for index = startIndex or 1, #self.skeletonLines do
		local line = self.skeletonLines[index]
		if line then
			line.Visible = false
		end
	end
end

function EntityESP:setBox(points, color, visible)
	local boxVisible = visible == true
	for index, pair in ipairs(points or {}) do
		local line = self.boxLines[index]
		if line then
			line.From = pair[1]
			line.To = pair[2]
			line.Color = color or line.Color
			line.Visible = boxVisible
		end
	end
end

function EntityESP:setHealthBar(position, size, fillPosition, fillSize, fillColor, visible)
	if self.healthBarOutline then
		self.healthBarOutline.Position = position
		self.healthBarOutline.Size = size
		self.healthBarOutline.Visible = visible == true
	end

	if self.healthBarFill then
		self.healthBarFill.Position = fillPosition
		self.healthBarFill.Size = fillSize
		self.healthBarFill.Color = fillColor or self.healthBarFill.Color
		self.healthBarFill.Visible = visible == true
	end
end

function EntityESP:setStaminaBar(position, size, fillPosition, fillSize, fillColor, visible)
	if self.staminaBarOutline then
		self.staminaBarOutline.Position = position
		self.staminaBarOutline.Size = size
		self.staminaBarOutline.Visible = visible == true
	end

	if self.staminaBarFill then
		self.staminaBarFill.Position = fillPosition
		self.staminaBarFill.Size = fillSize
		self.staminaBarFill.Color = fillColor or self.staminaBarFill.Color
		self.staminaBarFill.Visible = visible == true
	end
end

function EntityESP:setText(textObject, text, position, visible)
	if not textObject then
		return
	end

	textObject.Text = text or ""
	textObject.Position = position or Vector2.zero
	textObject.Visible = visible == true
end

function EntityESP:setTracer(fromPoint, toPoint, color, visible)
	if not self.tracerLine then
		return
	end

	self.tracerLine.From = fromPoint
	self.tracerLine.To = toPoint
	self.tracerLine.Color = color or self.tracerLine.Color
	self.tracerLine.Visible = visible == true
end

function EntityESP:hide()
	self:setGroupVisible(self.boxLines, false)
	self:setGroupVisible(self.skeletonLines, false)
	if self.healthBarOutline then
		self.healthBarOutline.Visible = false
	end
	if self.healthBarFill then
		self.healthBarFill.Visible = false
	end
	if self.staminaBarOutline then
		self.staminaBarOutline.Visible = false
	end
	if self.staminaBarFill then
		self.staminaBarFill.Visible = false
	end
	if self.nameText then
		self.nameText.Visible = false
	end
	if self.distanceText then
		self.distanceText.Visible = false
	end
	if self.healthText then
		self.healthText.Visible = false
	end
	if self.yenText then
		self.yenText.Visible = false
	end
	if self.playerYenText then
		self.playerYenText.Visible = false
	end
	if self.staminaText then
		self.staminaText.Visible = false
	end
	if self.magicMarksText then
		self.magicMarksText.Visible = false
	end
	if self.rankText then
		self.rankText.Visible = false
	end
	if self.tracerLine then
		self.tracerLine.Visible = false
	end
end

function EntityESP:Destroy()
	self:hide()

	for _, object in ipairs(self.objects) do
		safeRemoveDrawing(object)
	end
end

return EntityESP
