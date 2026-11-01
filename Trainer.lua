-- CraftProfit :: Trainer
-- Profit in the profession trainer window (the retail ClassTrainerFrame from Blizzard_TrainerUI, which the
-- Forever client uses), so players see which recipes are worth learning first:
--   * every recipe row gets its net per craft (same tag and AH / vendor choice as the profession window)
--   * the row tooltip adds craft cost, AH net, vendor net and how many crafts pay back the training cost
-- Unlearned recipes are priced like learned ones: GetRecipeSchematic answers for any recipe spell.
--
-- A trainer service is matched to its recipe spell in this order:
--   1. a spell / enchant link from GetTrainerServiceItemLink
--   2. the service's tooltip data (C_TooltipInfo.GetTrainerService) when it carries a spell ID
--   3. the service name, looked up in a once-per-session walk over spell IDs on profession skill lines
--      (C_TradeSkillUI.GetTradeSkillLineForRecipe, time-sliced); the output item and the trainer's skill line
--      settle duplicates.
-- No trainer had been recorded on Forever when this was written (2026-10-13), so every step is feature-detected
-- and a service that matches no recipe gets no tag. /cf trainer check prints what each service resolved to.

local _, CP = ...
local Trainer = {}
CP.Trainer = Trainer

Trainer.SCAN_MAX = 1500000  -- highest spell ID looked at
Trainer.BUDGET_MS = 8       -- scan time per frame
Trainer.resolved = {}       -- service key -> recipeID, or false when nothing matched (session cache)

local TAG_WIDTH = { profit = 56, margin = 46, both = 92 }

local function Gray(text) return CP:Color(CP.COLORS.gray, text) end

local function Now()
	if debugprofilestop then return debugprofilestop() end
	return (GetTime and GetTime() or 0) * 1000
end

local function After(seconds, fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

local function BasicReagentType()
	return (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
end

local function Results(ok, ...)
	if not ok then return nil end
	return ...
end

-- pcall that hands back the function's results (nil when it is missing or fails)
local function Call(fn, ...)
	if type(fn) ~= "function" then return nil end
	return Results(pcall(fn, ...))
end

local function IsTradeskillTrainerOpen()
	return Call(IsTradeskillTrainer) and true or false
end

---------------------------------------------------------------------------
-- Service -> recipe
---------------------------------------------------------------------------

-- The schematic when the spell is a recipe (makes an item or takes reagents), nil otherwise.
local function RecipeSchematic(spellID)
	if type(spellID) ~= "number" or spellID <= 0 then return nil end
	if not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic) then return nil end
	local ok, sch = pcall(C_TradeSkillUI.GetRecipeSchematic, spellID, false)
	if not ok or type(sch) ~= "table" then return nil end
	if type(sch.outputItemID) == "number" and sch.outputItemID > 0 then return sch end
	local basic = BasicReagentType()
	for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
		if slot.reagentType == basic then return sch end
	end
	return nil
end

-- What the client tells about a service: name, type, cost and any item / spell IDs it hands out.
function Trainer:ServiceInfo(index)
	local name, serviceType = Call(GetTrainerServiceInfo, index)
	local s = { index = index, name = name, type = serviceType }
	local link = Call(GetTrainerServiceItemLink, index)
	if type(link) == "string" then
		s.itemID = tonumber(link:match("item:(%d+)") or "")
		s.spellID = tonumber(link:match("spell:(%d+)") or link:match("enchant:(%d+)") or "")
	end
	if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
		local ok, data = pcall(C_TooltipInfo.GetTrainerService, index)
		if ok and type(data) == "table" and type(data.id) == "number" and data.id > 0 then
			local itemType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
			if itemType ~= nil and data.type == itemType then
				s.itemID = s.itemID or data.id
			else
				s.tipID = data.id
			end
		end
	end
	s.skillLine = Call(GetTrainerServiceSkillLine, index)
	local cost = Call(GetTrainerServiceCost, index)
	s.cost = (type(cost) == "number" and cost > 0) and cost or nil
	return s
end

local function SameLine(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	a, b = a:lower(), b:lower()
	return a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil
end

-- How well a candidate spell fits the service: nil when it is not a recipe or makes a different item.
local function Score(spellID, s, lineName)
	local sch = RecipeSchematic(spellID)
	if not sch then return nil end
	local score = 1
	local out = (type(sch.outputItemID) == "number" and sch.outputItemID > 0) and sch.outputItemID or nil
	if s.itemID and out then
		if out ~= s.itemID then return nil end
		score = score + 2
	end
	if s.skillLine and lineName and SameLine(lineName, s.skillLine) then score = score + 1 end
	return score
end

local function Key(s)
	return tostring(s.name) .. "|" .. tostring(s.itemID or "") .. "|" .. tostring(s.spellID or s.tipID or "")
end

-- Returns the recipe spell ID for a service, or nil plus "scanning" while the name lookup is being built.
function Trainer:Resolve(s)
	if not s or type(s.name) ~= "string" or s.name == "" or s.type == "header" then return nil end
	local key = Key(s)
	local cached = self.resolved[key]
	if cached then return cached end
	if cached == false then return nil end

	local found
	if s.spellID and Score(s.spellID, s) then
		found = s.spellID
	elseif s.tipID and Score(s.tipID, s) then
		found = s.tipID
	else
		if not self.names and not self:StartScan() then
			self.resolved[key] = false -- this client offers no way to look the name up
			return nil
		end
		if not self.names then return nil, "scanning" end
		local best, bestScore
		for _, id in ipairs(self.names[s.name:lower()] or {}) do
			local score = Score(id, s, self.lineOf[id])
			if score and (not bestScore or score > bestScore) then best, bestScore = id, score end
		end
		found = best
	end
	self.resolved[key] = found or false
	return found
end

---------------------------------------------------------------------------
-- Name lookup: one walk over spell IDs per session
---------------------------------------------------------------------------

local function SpellNameFunction()
	if C_Spell and type(C_Spell.GetSpellName) == "function" then
		return function(id)
			local ok, name = pcall(C_Spell.GetSpellName, id)
			return ok and name or nil
		end
	end
	if C_Spell and type(C_Spell.GetSpellInfo) == "function" then
		return function(id)
			local ok, info = pcall(C_Spell.GetSpellInfo, id)
			return ok and type(info) == "table" and info.name or nil
		end
	end
	return function(id)
		local sch = RecipeSchematic(id)
		return sch and sch.name or nil
	end
end

-- Returns true while a scan runs (or was just started), false when the client cannot do it.
function Trainer:StartScan()
	if self.names then return false end
	if self.scanning then return true end
	local T = C_TradeSkillUI
	if not (T and type(T.GetTradeSkillLineForRecipe) == "function") then return false end
	self.scanning = { next = 1, names = {}, lineOf = {}, started = Now(), nameOf = SpellNameFunction(), hits = 0 }
	CP:Debug("trainer: building the recipe name lookup (spell IDs 1..%d)", self.SCAN_MAX)
	After(0, function() Trainer:ScanChunk() end)
	return true
end

function Trainer:ScanChunk()
	local s = self.scanning
	if not s then return end
	local getLine = C_TradeSkillUI.GetTradeSkillLineForRecipe
	local deadline = Now() + self.BUDGET_MS
	local id, last = s.next, self.SCAN_MAX
	while id <= last do
		local ok, line, lineName = pcall(getLine, id)
		if ok and type(line) == "number" then
			local name = s.nameOf(id)
			if type(name) == "string" and name ~= "" then
				local k = name:lower()
				local list = s.names[k]
				if not list then list = {}; s.names[k] = list end
				list[#list + 1] = id
				if type(lineName) == "string" then s.lineOf[id] = lineName end
				s.hits = s.hits + 1
			end
		end
		id = id + 1
		if id % 1000 == 0 and Now() >= deadline then break end
	end
	s.next = id
	if id <= last then
		After(0, function() Trainer:ScanChunk() end)
		return
	end
	self.names, self.lineOf, self.scanning = s.names, s.lineOf, nil
	CP:Debug("trainer: recipe name lookup ready, %d spells in %.2f s", s.hits, (Now() - s.started) / 1000)
	for k, v in pairs(self.resolved) do
		if v == false then self.resolved[k] = nil end -- retry the misses with the lookup
	end
	self:RefreshAll()
end

---------------------------------------------------------------------------
-- Pricing
---------------------------------------------------------------------------

-- Economics for a trainer recipe. Unlearned recipes stay out of the saved schematic cache.
function Trainer:Price(recipeID)
	local Calc = CP.Calc
	local prev = Calc.skipSchematicCache
	Calc.skipSchematicCache = true
	local ok, eco = pcall(Calc.Get, Calc, recipeID)
	Calc.skipSchematicCache = prev
	return ok and eco or nil
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

-- Row layout (ClassTrainerSkillButtonTemplate, 298x47): icon left, name top-left, cost (money frame) top-right,
-- requirements line under the name. The tag sits bottom-right, under the cost.
local function EnsureTag(button)
	if button.cpTrainerTag then return button.cpTrainerTag end
	local tag = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	tag:SetJustifyH("RIGHT")
	tag:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -8, 7)
	if tag.SetWordWrap then tag:SetWordWrap(false) end
	button.cpTrainerTag = tag
	return tag
end

function Trainer:UpdateRow(button)
	if not button or not button.money or not button.subText then return end -- category headers have neither
	local tag = EnsureTag(button)
	button.cpService, button.cpRecipeID = nil, nil
	local index = type(button.GetID) == "function" and button:GetID() or nil
	if not CP.settings.trainerTags or not index or index <= 0 or not IsTradeskillTrainerOpen() then
		tag:Hide()
		return
	end
	local s = self:ServiceInfo(index)
	local recipeID, state = self:Resolve(s)
	button.cpService, button.cpRecipeID = s, recipeID
	tag:SetWidth(TAG_WIDTH[CP.settings.rowTag or "profit"] or TAG_WIDTH.profit)
	if not recipeID then
		if state == "scanning" then
			tag:SetText(Gray("..."))
			tag:Show()
		else
			tag:Hide()
		end
		return
	end
	local net, margin = CP.Calc:PickNet(self:Price(recipeID))
	tag:SetText(CP.UI:TagText(net, margin))
	tag:Show()
end

function Trainer:RefreshAll()
	local f = ClassTrainerFrame
	if not (f and f.ScrollBox and type(f.IsShown) == "function" and f:IsShown()) then return end
	if type(f.ScrollBox.ForEachFrame) ~= "function" then return end
	f.ScrollBox:ForEachFrame(function(frame) Trainer:UpdateRow(frame) end)
end

CP:On("PRICES_UPDATED", function() Trainer:RefreshAll() end)
CP:On("VENDOR_UPDATED", function() Trainer:RefreshAll() end)
CP:On("SETTINGS_CHANGED", function() Trainer:RefreshAll() end)

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

-- { left, right } lines for a trainer row (right may be nil for a full-width note).
function Trainer:TooltipLines(s, recipeID)
	local eco = self:Price(recipeID)
	if not eco then return nil end
	local lines = {}
	local function Signed(v) return v and CP:FormatMoney(v, { sign = true }) or nil end
	if eco.costComplete and #eco.reagents > 0 then
		lines[#lines + 1] = { "Craft cost", CP:FormatMoney(eco.cost) }
	elseif eco.cost > 0 then
		lines[#lines + 1] = { "Craft cost", CP:FormatMoney(eco.cost) .. string.format(" +%d unpriced", eco.missing) }
	else
		lines[#lines + 1] = { "Craft cost", "no reagent prices" }
	end
	if eco.outputItemID then
		lines[#lines + 1] = { "Auction House net", Signed(eco.net) or (eco.saleUnit and "-" or "no auction price") }
		if eco.vendorUnit then
			lines[#lines + 1] = { "Vendor net", Signed(eco.vendorNet) or "-" }
		elseif not eco.vendorPending then
			lines[#lines + 1] = { "Vendor net", "vendors don't buy it" }
		end
	else
		lines[#lines + 1] = { "Sale", "no sellable output" }
	end
	local net = CP.Calc:PickNet(eco)
	if s and s.cost then
		lines[#lines + 1] = { "Training cost", CP:FormatMoney(s.cost) }
		if net and net > 0 then
			local crafts = math.ceil(s.cost / net)
			lines[#lines + 1] = { "Pays back after", crafts == 1 and "1 craft" or (crafts .. " crafts") }
		end
	end
	return lines
end

local function AddTrainerLines(tooltip)
	if tooltip ~= GameTooltip or not (CP.settings and CP.settings.trainerTags) then return end
	local owner = type(tooltip.GetOwner) == "function" and tooltip:GetOwner() or nil
	if not owner or not owner.cpTrainerTag or not owner.cpRecipeID then return end
	if type(owner.GetID) == "function" and owner.cpService and owner:GetID() ~= owner.cpService.index then return end
	local lines = Trainer:TooltipLines(owner.cpService, owner.cpRecipeID)
	if not lines then return end
	tooltip:AddLine(" ")
	tooltip:AddLine("CraftProfit", 1, 0.82, 0)
	for _, l in ipairs(lines) do
		tooltip:AddDoubleLine(l[1], l[2] or "", 0.8, 0.8, 0.8, 1, 1, 1)
	end
	tooltip:Show()
end

function Trainer:InstallTooltip()
	if self.tooltipHook then return end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and TooltipDataProcessor.AllTypes then
		local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, TooltipDataProcessor.AllTypes, function(tooltip)
			local ok2, err = pcall(AddTrainerLines, tooltip)
			if not ok2 then CP:Debug("trainer tooltip failed: %s", tostring(err)) end
		end)
		if ok then self.tooltipHook = "TooltipDataProcessor" return end
	end
	if GameTooltip and type(GameTooltip.SetTrainerService) == "function" then
		hooksecurefunc(GameTooltip, "SetTrainerService", function(tooltip) pcall(AddTrainerLines, tooltip) end)
		self.tooltipHook = "SetTrainerService"
	end
end

---------------------------------------------------------------------------
-- Diagnostics (/cf trainer check)
---------------------------------------------------------------------------

function Trainer:Report()
	if not IsTradeskillTrainerOpen() then
		CP:Print("open a profession trainer first.")
		return
	end
	local n = Call(GetNumTrainerServices) or 0
	CP:Print("trainer: %d services, tooltip hook %s, name lookup %s.", n, tostring(self.tooltipHook or "none"),
		self.names and "ready" or (self.scanning and "building" or "not built"))
	for i = 1, n do
		local s = self:ServiceInfo(i)
		if s.type ~= "header" then
			local recipeID, state = self:Resolve(s)
			local how = (recipeID and recipeID == s.spellID and "link") or (recipeID and recipeID == s.tipID and "tooltip")
				or (recipeID and "name") or (state or "no match")
			local text = "-"
			if recipeID then
				local net, _, kind = CP.Calc:PickNet(self:Price(recipeID))
				text = net and (CP:FormatMoney(net, { sign = true }) .. (kind == "vendor" and " (vendor)" or "")) or "no price"
			end
			CP:Print("  %d %s [%s] item %s spell %s tip %s -> recipe %s (%s) %s", i, tostring(s.name), tostring(s.type),
				tostring(s.itemID), tostring(s.spellID), tostring(s.tipID), tostring(recipeID), how, text)
		end
	end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function Trainer:Setup()
	if self.ready then return end
	local f = ClassTrainerFrame
	if not (f and f.ScrollBox) then return end
	local initEvent = ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnInitializedFrame
	if not (initEvent and type(f.ScrollBox.RegisterCallback) == "function") then
		self.ready = "unsupported"
		CP:Debug("trainer list has no OnInitializedFrame event; trainer tags disabled")
		return
	end
	-- Same approach as the recipe list: the ScrollBox's own event after Blizzard initialised the row.
	f.ScrollBox:RegisterCallback(initEvent, function(_, frame) Trainer:UpdateRow(frame) end, Trainer)
	self.ready = true
	CP:Debug("trainer hooks installed")
end

CP:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_TrainerUI" then Trainer:Setup() end
end)

CP:RegisterEvent("PLAYER_LOGIN", function()
	Trainer:InstallTooltip()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_TrainerUI") then Trainer:Setup() end
end)

CP:RegisterEvent("TRAINER_SHOW", function()
	Trainer:Setup()
	After(0, function() Trainer:RefreshAll() end)
end)
