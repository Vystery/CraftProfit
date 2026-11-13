-- CraftProfit :: Missing
-- Side tab on the profession window listing crafts you have not learned yet that would make money
-- on the Auction House or sold to a vendor. Recipe list comes from ForeverMaster's Forever catalog
-- (ForeverMasterData.recipes): trainer recipes and Plans/Pattern/Formula item recipes alike.
-- Requires ForeverMaster. Without it the tab explains that and does nothing else.

local _, CP = ...
local Missing = {}
CP.Missing = Missing

Missing.BUDGET_MS = 8
Missing.ROW_HEIGHT = 28
Missing.MAX_ROWS = 200 -- list hard cap so the overlay does not spawn thousands of frames
Missing.sortKey = "best"     -- best | name | ah | vendor | source
Missing.sortDesc = true

-- Column layout shared by header buttons and rows (x from content left, width).
local COLS = {
	{ key = "name",   label = "Recipe",  x = 32,  w = 214, justify = "LEFT" },
	{ key = "ah",     label = "AH net",  x = 252, w = 78,  justify = "RIGHT" },
	{ key = "vendor", label = "Vendor",  x = 338, w = 78,  justify = "RIGHT" },
	{ key = "source", label = "Source",  x = 428, w = 200, justify = "LEFT" },
}

-- English skill line name -> profession skill spell (for localising GetProfessionInfo names).
local PROFESSIONS = {
	Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036,
	Leatherworking = 2108, Tailoring = 3908, Cooking = 2550, ["First Aid"] = 3273,
	Fishing = 7620, Mining = 2575,
}

local function After(seconds, fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

local function Now()
	if debugprofilestop then return debugprofilestop() end
	return (GetTime and GetTime() or 0) * 1000
end

local function SpellName(id)
	if C_Spell and C_Spell.GetSpellName then
		local ok, n = pcall(C_Spell.GetSpellName, id)
		if ok and n then return n end
	end
	if GetSpellInfo then
		local ok, n = pcall(GetSpellInfo, id)
		if ok and n then return n end
	end
end

local function SpellIcon(id)
	if C_Spell and C_Spell.GetSpellTexture then
		local ok, t = pcall(C_Spell.GetSpellTexture, id)
		if ok and t and t ~= 0 then return t end
	end
	if GetSpellTexture then
		local ok, t = pcall(GetSpellTexture, id)
		if ok and t and t ~= 0 then return t end
	end
end

-- Unlearned profession spells often have no cached spell texture (blue square). Prefer the
-- crafted item / recipe item icon; kick the client to load item data when it is still missing.
local function ItemIcon(itemID)
	if not itemID then return nil end
	if C_Item and C_Item.GetItemIconByID then
		local ok, t = pcall(C_Item.GetItemIconByID, itemID)
		if ok and t and t ~= 0 then return t end
	end
	if GetItemIcon then
		local ok, t = pcall(GetItemIcon, itemID)
		if ok and t and t ~= 0 then return t end
	end
	if C_Item and C_Item.RequestLoadItemDataByID then
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
end

local function RecipeIcon(spellID, makes, taughtBy)
	return ItemIcon(makes) or ItemIcon(taughtBy) or SpellIcon(spellID)
		or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local localName
local function ProfessionKey(name)
	if not name then return nil end
	if PROFESSIONS[name] ~= nil then return name end
	if not localName then
		localName = {}
		for key, spell in pairs(PROFESSIONS) do
			local n = spell and SpellName(spell)
			if n then localName[n] = key end
		end
	end
	return localName[name]
end

---------------------------------------------------------------------------
-- ForeverMaster catalog
---------------------------------------------------------------------------

function Missing:Catalog()
	local data = ForeverMasterData and ForeverMasterData.recipes
	if type(data) ~= "table" then return nil end
	return data
end

-- ForeverMaster packed string: learn|yellow|green|grey|makes|count|taughtBy|status|reagents
function Missing:Parse(text)
	if type(text) ~= "string" then return nil end
	local f = {}
	for part in (text .. "|"):gmatch("([^|]*)|") do f[#f + 1] = part end
	local r = {
		learn = tonumber(f[1]),
		yellow = tonumber(f[2]),
		green = tonumber(f[3]),
		grey = tonumber(f[4]),
		makes = tonumber(f[5]),
		count = tonumber(f[6]) or 1,
		taughtBy = tonumber(f[7]),
		status = (f[8] ~= "" and f[8]) or nil,
		reagents = {},
	}
	for piece in (f[9] or ""):gmatch("[^,]+") do
		local id, n = piece:match("^(%d+):?(%d*)$")
		if id then r.reagents[#r.reagents + 1] = { tonumber(id), tonumber(n) or 1 } end
	end
	return r
end

function Missing:HasForeverMaster()
	if self:Catalog() then return true end
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		return C_AddOns.IsAddOnLoaded("ForeverMaster") and true or false
	end
	return false
end

---------------------------------------------------------------------------
-- Player professions and known recipes
---------------------------------------------------------------------------

function Missing:MyProfessions()
	local out = {}
	if GetProfessions and GetProfessionInfo then
		local ok, a, b, c, d, e = pcall(GetProfessions)
		if ok then
			for _, idx in ipairs({ a, b, c, d, e }) do
				if idx then
					local ok2, name, _, rank, maxRank = pcall(GetProfessionInfo, idx)
					local key = ok2 and ProfessionKey(name)
					if key then out[#out + 1] = { name = name, key = key, rank = rank or 0, max = maxRank or 0 } end
				end
			end
		end
	end
	if #out == 0 and GetNumSkillLines and GetSkillLineInfo then
		for i = 1, GetNumSkillLines() or 0 do
			local name, header, _, rank, _, _, maxRank = GetSkillLineInfo(i)
			local key = not header and ProfessionKey(name)
			if key then out[#out + 1] = { name = name, key = key, rank = rank or 0, max = maxRank or 0 } end
		end
	end
	return out
end

local function SpellKnown(spellID)
	if IsPlayerSpell then
		local ok, k = pcall(IsPlayerSpell, spellID)
		if ok and k then return true end
	end
	if IsSpellKnown then
		local ok, k = pcall(IsSpellKnown, spellID)
		if ok and k then return true end
	end
	return false
end

function Missing:IsKnown(professionKey, spellID)
	if not spellID then return false end
	-- Authoritative when the client has recipe info: Forever's profession list includes unlearned
	-- rows, and ForeverMasterChar.recipes records everything it has *seen*, so that SV is not used.
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
		local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, spellID)
		if ok and type(info) == "table" and info.learned ~= nil then
			return info.learned and true or false
		end
	end
	local learned = CP:GetLearnedRecipes()
	if learned and learned[spellID] then return true end
	if SpellKnown(spellID) then return true end
	return false
end

---------------------------------------------------------------------------
-- Pricing
---------------------------------------------------------------------------

-- Economics for a catalog recipe. Prefer the live schematic (works for unlearned spells);
-- fall back to ForeverMaster's reagents + output when the client has no schematic.
function Missing:Price(spellID, packed)
	local Calc = CP.Calc
	local prev = Calc.skipSchematicCache
	Calc.skipSchematicCache = true
	local ok, eco = pcall(Calc.Get, Calc, spellID)
	Calc.skipSchematicCache = prev
	if ok and eco and not eco.error and (#(eco.reagents or {}) > 0 or eco.outputItemID) then
		return eco
	end
	return self:PriceFromCatalog(spellID, packed)
end

function Missing:PriceFromCatalog(spellID, packed)
	local r = type(packed) == "table" and packed or self:Parse(packed)
	if not r then return nil end
	local eco = {
		recipeID = spellID,
		reagents = {},
		cost = 0,
		costComplete = true,
		missing = 0,
		quantity = r.count or 1,
		outputItemID = r.makes,
		catalog = true,
	}
	if eco.quantity <= 0 then eco.quantity = 1 end
	for _, pair in ipairs(r.reagents) do
		local itemID, qty = pair[1], pair[2]
		local unit, kind = CP.Calc:ReagentCost(itemID)
		local entry = { itemID = itemID, qty = qty, unit = unit, kind = kind, total = unit and (unit * qty) or nil }
		eco.reagents[#eco.reagents + 1] = entry
		if unit then
			eco.cost = eco.cost + unit * qty
		else
			eco.costComplete = false
			eco.missing = eco.missing + 1
		end
	end
	if eco.outputItemID then
		local unit, sourceKey = CP:GetSalePrice(eco.outputItemID)
		eco.saleUnit = unit
		eco.source = sourceKey
		if unit then
			eco.sale = unit * eco.quantity
			eco.cut = eco.sale * (CP.settings.ahCut or 0)
		end
		if eco.sale and eco.costComplete and #eco.reagents > 0 then
			eco.net = eco.sale - eco.cut - eco.cost
			if eco.cost > 0 then eco.margin = eco.net / eco.cost end
		end
		local sell, sellState
		if CP.Vendor then sell, sellState = CP.Vendor:GetSellPrice(eco.outputItemID) end
		eco.vendorPending = (sellState == "pending") or nil
		if sell then
			eco.vendorUnit = sell
			eco.vendorSale = sell * eco.quantity
			if eco.costComplete and #eco.reagents > 0 then
				eco.vendorNet = eco.vendorSale - eco.cost
				if eco.cost > 0 then eco.vendorMargin = eco.vendorNet / eco.cost end
			end
		end
	end
	return eco
end

local function BestNet(eco)
	if not eco then return nil end
	local best, kind
	if eco.net and eco.net > 0 then best, kind = eco.net, "ah" end
	if eco.vendorNet and eco.vendorNet > 0 and (not best or eco.vendorNet > best) then
		best, kind = eco.vendorNet, "vendor"
	end
	return best, kind
end

function Missing:IsProfitable(eco)
	return BestNet(eco) ~= nil
end

---------------------------------------------------------------------------
-- Scan (time-sliced)
---------------------------------------------------------------------------

function Missing:BuildQueue(professionFilter)
	local catalog = self:Catalog()
	if not catalog then return {} end
	local queue = {}
	local professions = self:MyProfessions()
	for _, prof in ipairs(professions) do
		if not professionFilter or professionFilter == prof.key then
			local recipes = catalog[prof.key]
			if type(recipes) == "table" then
				for spellID, text in pairs(recipes) do
					if type(spellID) == "number" and not self:IsKnown(prof.key, spellID) then
						queue[#queue + 1] = {
							spellID = spellID,
							text = text,
							profession = prof.key,
							professionName = prof.name,
							rank = prof.rank,
						}
					end
				end
			end
		end
	end
	table.sort(queue, function(a, b)
		if a.profession ~= b.profession then return a.profession < b.profession end
		return a.spellID < b.spellID
	end)
	return queue
end

function Missing:StartScan(professionFilter)
	if self.scanning then
		self.scanRestart = { filter = professionFilter }
		return
	end
	self.rows = {}
	self.scan = {
		queue = self:BuildQueue(professionFilter),
		index = 1,
		filter = professionFilter,
		started = Now(),
		priced = 0,
		hits = 0,
	}
	self.scanning = true
	CP:Debug("missing: scanning %d unlearned recipes", #self.scan.queue)
	self:UpdateStatus()
	After(0, function() Missing:ScanChunk() end)
end

function Missing:ScanChunk()
	local s = self.scan
	if not s then self.scanning = false return end
	local deadline = Now() + self.BUDGET_MS
	while s.index <= #s.queue do
		local entry = s.queue[s.index]
		s.index = s.index + 1
		s.priced = s.priced + 1
		local packed = self:Parse(entry.text)
		local eco = self:Price(entry.spellID, packed or entry.text)
		if eco and self:IsProfitable(eco) then
			local best, kind = BestNet(eco)
			local makes = packed and packed.makes or eco.outputItemID
			local taughtBy = packed and packed.taughtBy or nil
			self.rows[#self.rows + 1] = {
				spellID = entry.spellID,
				name = SpellName(entry.spellID) or ("Spell " .. entry.spellID),
				icon = RecipeIcon(entry.spellID, makes, taughtBy),
				profession = entry.profession,
				professionName = entry.professionName,
				taughtBy = taughtBy,
				makes = makes,
				quantity = eco.quantity or (packed and packed.count) or 1,
				learn = packed and packed.learn or nil,
				eco = eco,
				best = best,
				bestKind = kind,
				ahNet = eco.net,
				vendorNet = eco.vendorNet,
				cost = eco.cost,
				costComplete = eco.costComplete,
			}
			s.hits = s.hits + 1
		end
		if Now() >= deadline then
			self:UpdateStatus()
			self:RefreshList()
			After(0, function() Missing:ScanChunk() end)
			return
		end
	end
	self.rowTotal = #self.rows
	self:SortRows()
	if #self.rows > self.MAX_ROWS then
		for i = #self.rows, self.MAX_ROWS + 1, -1 do self.rows[i] = nil end
	end
	self.scanning = false
	self.scan = nil
	local total = self.rowTotal or #self.rows
	CP:Debug("missing: done, %d profitable of %d priced in %.2fs", total, s.priced, (Now() - s.started) / 1000)
	-- Never Print completion to chat here: TRADE_SKILL_LIST_UPDATE / price ticks used to
	-- restart the scan while the tab stayed open, and every craft spammed General.
	-- The tab status line already shows the count; /cf missing uses FinishReport.
	self:UpdateStatus()
	self:RefreshList()
	if self.reportAfterScan then
		self.reportAfterScan = nil
		self:FinishReport()
	end
	if self.scanRestart then
		local filter = self.scanRestart.filter
		self.scanRestart = nil
		self:StartScan(filter)
	end
end

---------------------------------------------------------------------------
-- Sort
---------------------------------------------------------------------------

local function SortValue(row, key)
	if key == "ah" then return row.ahNet end
	if key == "vendor" then return row.vendorNet end
	if key == "best" then return row.best end
	if key == "name" then return row.name and row.name:lower() or "" end
	if key == "source" then
		-- stable without calling SourceLabel (defined later): trainer first, then by recipe-item id
		if row.taughtBy then return string.format("1:%09d", row.taughtBy) end
		return "0:trainer"
	end
	return row.best
end

function Missing:SortRows()
	local rows = self.rows
	if not rows or #rows == 0 then return end
	local key = self.sortKey or "best"
	local desc = self.sortDesc ~= false
	table.sort(rows, function(a, b)
		local va, vb = SortValue(a, key), SortValue(b, key)
		local aNil, bNil = (va == nil), (vb == nil)
		if aNil or bNil then
			if aNil and bNil then return (a.name or "") < (b.name or "") end
			return bNil -- nils always last
		end
		if va ~= vb then
			if desc then return va > vb end
			return va < vb
		end
		return (a.name or "") < (b.name or "")
	end)
end

function Missing:SetSort(key)
	if self.sortKey == key then
		self.sortDesc = not self.sortDesc
	else
		self.sortKey = key
		-- Money columns default to best-first; names default A-Z.
		self.sortDesc = (key == "name" or key == "source") and false or true
	end
	self:SortRows()
	self:UpdateHeaderLabels()
	self:RefreshList()
end

---------------------------------------------------------------------------
-- UI: side tab + overlay page
---------------------------------------------------------------------------

local function Gray(text) return CP:Color(CP.COLORS.gray, text) end
local function Muted(text) return CP:Color(CP.COLORS.muted, text) end
local function Body(text) return CP:Color(CP.COLORS.body, text) end

local function SourceLabel(row)
	if row.taughtBy then
		local price = CP:GetSalePrice(row.taughtBy) or (CP.Vendor and select(1, CP.Vendor:GetPrice(row.taughtBy)))
		local name
		if C_Item and C_Item.GetItemNameByID then
			local ok, n = pcall(C_Item.GetItemNameByID, row.taughtBy)
			if ok then name = n end
		end
		if not name and GetItemInfo then
			local ok, n = pcall(GetItemInfo, row.taughtBy)
			if ok then name = n end
		end
		local label = name or ("Item " .. row.taughtBy)
		if price then
			return label .. "  " .. CP:FormatMoneyShort(price)
		end
		return label
	end
	return "Trainer"
end

-- Same chrome as the profession profit panel: dark parchment fill, gold-brown edge.
local function ApplyPanelBackdrop(frame, alpha)
	if not frame.SetBackdrop then return end
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.07, 0.05, 0.03, alpha or 0.94)
	frame:SetBackdropBorderColor(0.42, 0.35, 0.24, 1)
end

local function ApplyInsetBackdrop(frame)
	if not frame.SetBackdrop then return end
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 12, edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	frame:SetBackdropColor(0.03, 0.025, 0.02, 0.88)
	frame:SetBackdropBorderColor(0.32, 0.26, 0.18, 1)
end

function Missing:EnsureUI()
	if self.ui then return self.ui end
	local book = ProfessionsFrame
	if not book then return nil end

	local template = BackdropTemplateMixin and "BackdropTemplate" or nil
	local page = CreateFrame("Frame", "CraftProfitMissingPage", book, template)
	page:Hide()
	page:SetPoint("TOPLEFT", book, "TOPLEFT", 2, -22)
	page:SetPoint("BOTTOMRIGHT", book, "BOTTOMRIGHT", -2, 2)
	page:EnableMouse(true)
	ApplyPanelBackdrop(page, 0.96)
	if not page.SetBackdrop then
		local bg = page:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.06, 0.05, 0.04, 0.97)
	end

	local titleIcon = page:CreateTexture(nil, "ARTWORK")
	titleIcon:SetSize(20, 20)
	titleIcon:SetPoint("TOPLEFT", 14, -12)
	titleIcon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
	local titleBorder = page:CreateTexture(nil, "OVERLAY")
	titleBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
	titleBorder:SetSize(30, 30)
	titleBorder:SetPoint("CENTER", titleIcon, "CENTER", 0, 0)
	titleBorder:SetVertexColor(0.85, 0.7, 0.35)

	local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 1)
	title:SetText("Missing profitable recipes")

	local rescan = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	rescan:SetSize(72, 22)
	rescan:SetPoint("TOPRIGHT", page, "TOPRIGHT", -14, -11)
	rescan:SetText("Rescan")
	rescan:SetScript("OnClick", function()
		if Missing.scanning then return end
		CP:Print("scanning missing profitable recipes…")
		Missing:StartScan(nil)
	end)
	rescan:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Rescan")
		GameTooltip:AddLine("Reprice every unlearned craft against current Auction House and vendor numbers.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	rescan:SetScript("OnLeave", GameTooltip_Hide)

	local status = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	status:SetPoint("TOPLEFT", titleIcon, "BOTTOMLEFT", 0, -8)
	status:SetPoint("RIGHT", rescan, "LEFT", -10, 0)
	pcall(status.SetJustifyH, status, "LEFT")
	if status.SetWordWrap then status:SetWordWrap(false) end
	status:SetText("")

	local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -2)
	hint:SetPoint("RIGHT", page, "RIGHT", -14, 0)
	pcall(hint.SetJustifyH, hint, "LEFT")
	hint:SetText("Nets are per craft. Click a column to sort.")

	local headerBar = CreateFrame("Frame", nil, page, template)
	headerBar:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)
	headerBar:SetPoint("RIGHT", page, "RIGHT", -14, 0)
	headerBar:SetHeight(24)
	ApplyInsetBackdrop(headerBar)
	if not headerBar.SetBackdrop then
		local hb = headerBar:CreateTexture(nil, "BACKGROUND")
		hb:SetAllPoints()
		hb:SetColorTexture(0.12, 0.09, 0.05, 0.9)
	end

	local headerButtons = {}
	for _, col in ipairs(COLS) do
		local btn = CreateFrame("Button", nil, headerBar)
		btn:SetPoint("TOPLEFT", headerBar, "TOPLEFT", col.x, -2)
		btn:SetSize(col.w, 20)
		local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
		label:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
		local justify = (col.justify == "RIGHT") and "RIGHT" or "LEFT"
		pcall(label.SetJustifyH, label, justify)
		btn.Label = label
		btn.colKey = col.key
		btn.colLabel = col.label
		btn:SetScript("OnClick", function(self) Missing:SetSort(self.colKey) end)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("Sort by " .. self.colLabel)
			GameTooltip:AddLine("Click again to reverse.", 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", GameTooltip_Hide)
		local hi = btn:CreateTexture(nil, "HIGHLIGHT")
		hi:SetAllPoints()
		hi:SetColorTexture(1, 0.82, 0, 0.10)
		headerButtons[col.key] = btn
	end

	local listWell = CreateFrame("Frame", nil, page, template)
	listWell:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, -4)
	listWell:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -14, 12)
	ApplyInsetBackdrop(listWell)
	if not listWell.SetBackdrop then
		local lw = listWell:CreateTexture(nil, "BACKGROUND")
		lw:SetAllPoints()
		lw:SetColorTexture(0.04, 0.03, 0.02, 0.9)
	end

	local empty = listWell:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	empty:SetPoint("TOPLEFT", listWell, "TOPLEFT", 14, -18)
	empty:SetPoint("RIGHT", listWell, "RIGHT", -14, 0)
	pcall(empty.SetJustifyH, empty, "LEFT")
	empty:SetText("")
	empty:Hide()

	local scroll = CreateFrame("ScrollFrame", "CraftProfitMissingScroll", listWell, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", listWell, "TOPLEFT", 6, -6)
	scroll:SetPoint("BOTTOMRIGHT", listWell, "BOTTOMRIGHT", -26, 6)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	local rows = {}

	-- Side tab (Forever uses LargeSideTabButtonTemplate as a Frame, same as WhatsTraining).
	local tab
	local okTab, made = pcall(CreateFrame, "Frame", "CraftProfitMissingTab", book, "LargeSideTabButtonTemplate")
	if okTab and made then
		tab = made
		if tab.EnableMouse then tab:EnableMouse(true) end
		if tab.SetFillToInterior then pcall(tab.SetFillToInterior, tab, true) end
		if tab.SetChecked then pcall(tab.SetChecked, tab, false) end
		if tab.InitializeIconAnchoring then pcall(tab.InitializeIconAnchoring, tab) end
	else
		tab = CreateFrame("Button", "CraftProfitMissingTab", book)
		tab:SetSize(32, 72)
		local tex = tab:CreateTexture(nil, "ARTWORK")
		tex:SetAllPoints()
		tex:SetColorTexture(0.15, 0.12, 0.08, 0.95)
		tab.Background = tex
		local icon = tab:CreateTexture(nil, "OVERLAY")
		icon:SetSize(20, 20)
		icon:SetPoint("CENTER")
		tab.Icon = icon
	end
	tab:Hide()
	if tab.Icon and tab.Icon.SetTexture then
		tab.Icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
	end
	tab.tooltipText = "CraftProfit: missing profitable recipes"
	tab:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(self.tooltipText or "CraftProfit")
		GameTooltip:AddLine("Unlearned crafts that would profit on the Auction House or at a vendor.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	tab:SetScript("OnLeave", GameTooltip_Hide)
	tab:ClearAllPoints()
	-- Sit above WhatsTraining's tab (y=10) on the right edge.
	tab:SetPoint("BOTTOMLEFT", book, "BOTTOMRIGHT", 0, 84)

	local ui = {
		book = book,
		page = page,
		title = title,
		status = status,
		hint = hint,
		headerBar = headerBar,
		headerButtons = headerButtons,
		listWell = listWell,
		empty = empty,
		scroll = scroll,
		content = content,
		rows = rows,
		tab = tab,
		rescan = rescan,
		active = false,
	}
	self.ui = ui
	self:UpdateHeaderLabels()

	local function Toggle()
		if ui.active then
			self:HidePage()
		else
			self:ShowPage()
		end
	end
	-- Forever side tabs swallow normal OnMouseUp; only one handler or a click toggles open then shut.
	if tab.SetCustomOnMouseUpHandler then
		tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
			if button == "LeftButton" and upInside then Toggle() end
		end)
	else
		tab:SetScript("OnMouseUp", function(_, button)
			if button == "LeftButton" then Toggle() end
		end)
		if tab.RegisterForClicks then pcall(tab.RegisterForClicks, tab, "LeftButtonUp") end
	end

	-- Clicking a native profession side tab closes our overlay.
	local native = {}
	if book.ProfessionsOverviewTab then native[#native + 1] = book.ProfessionsOverviewTab end
	for _, t in ipairs(book.rightProfessionTabs or {}) do native[#native + 1] = t end
	for _, t in ipairs(native) do
		if t.HookScript then
			t:HookScript("OnMouseUp", function() Missing:HidePage() end)
		end
	end

	return ui
end

function Missing:UpdateHeaderLabels()
	local ui = self.ui
	if not (ui and ui.headerButtons) then return end
	local key = self.sortKey or "best"
	local arrow = (self.sortDesc ~= false) and " ▼" or " ▲"
	for _, col in ipairs(COLS) do
		local btn = ui.headerButtons[col.key]
		if btn and btn.Label then
			local sorted = (key == col.key) or (key == "best" and col.key == "ah")
			local label = col.label .. (sorted and arrow or "")
			btn.Label:SetText(sorted and label or Muted(label))
		end
	end
end

function Missing:EnsureRow(index)
	local ui = self.ui
	if not ui then return nil end
	if ui.rows[index] then return ui.rows[index] end
	local row = CreateFrame("Button", nil, ui.content)
	row:SetHeight(self.ROW_HEIGHT)
	row:SetPoint("TOPLEFT", ui.content, "TOPLEFT", 0, -(index - 1) * self.ROW_HEIGHT)
	row:SetPoint("RIGHT", ui.content, "RIGHT", -2, 0)
	row.Stripe = row:CreateTexture(nil, "BACKGROUND")
	row.Stripe:SetAllPoints()
	row.Stripe:SetColorTexture(0.55, 0.42, 0.18, index % 2 == 0 and 0.10 or 0)
	local hi = row:CreateTexture(nil, "HIGHLIGHT")
	hi:SetAllPoints()
	hi:SetColorTexture(1, 0.82, 0, 0.10)
	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(20, 20)
	row.Icon:SetPoint("LEFT", 6, 0)
	if row.Icon.SetTexCoord then row.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
	row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.Name:SetPoint("LEFT", row, "LEFT", COLS[1].x, 0)
	row.Name:SetWidth(COLS[1].w)
	pcall(row.Name.SetJustifyH, row.Name, "LEFT")
	if row.Name.SetWordWrap then row.Name:SetWordWrap(false) end
	row.AH = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.AH:SetPoint("LEFT", row, "LEFT", COLS[2].x, 0)
	row.AH:SetWidth(COLS[2].w)
	pcall(row.AH.SetJustifyH, row.AH, "RIGHT")
	row.Vendor = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.Vendor:SetPoint("LEFT", row, "LEFT", COLS[3].x, 0)
	row.Vendor:SetWidth(COLS[3].w)
	pcall(row.Vendor.SetJustifyH, row.Vendor, "RIGHT")
	row.Source = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.Source:SetPoint("LEFT", row, "LEFT", COLS[4].x, 0)
	row.Source:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	pcall(row.Source.SetJustifyH, row.Source, "LEFT")
	if row.Source.SetWordWrap then row.Source:SetWordWrap(false) end
	row:SetScript("OnEnter", function(self)
		if not self.data then return end
		local d = self.data
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local eco = d.eco
		GameTooltip:SetText(d.name, 1, 0.82, 0)
		GameTooltip:AddLine(d.professionName or d.profession, 0.75, 0.7, 0.6)
		if d.learn then GameTooltip:AddLine("Learn at skill " .. d.learn, 0.55, 0.55, 0.55) end
		local qty = d.quantity or (eco and eco.quantity) or 1
		if qty ~= 1 then
			GameTooltip:AddLine(string.format("Output per craft: x%g  (nets are per craft)", qty), 0.65, 0.8, 1)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Craft cost", d.costComplete and CP:FormatMoney(d.cost) or (CP:FormatMoney(d.cost) .. " (incomplete)"), 0.8, 0.8, 0.8, 1, 1, 1)
		if eco and eco.sale then
			local saleLabel = (qty ~= 1 and eco.saleUnit)
				and string.format("Expected AH sale (x%g @ %s)", qty, CP:FormatMoney(eco.saleUnit))
				or "Expected AH sale"
			GameTooltip:AddDoubleLine(saleLabel, CP:FormatMoney(eco.sale), 0.8, 0.8, 0.8, 1, 1, 1)
			if eco.cut then
				GameTooltip:AddDoubleLine(string.format("AH cut (%d%%)", math.floor((CP.settings.ahCut or 0) * 100 + 0.5)),
					CP:FormatMoney(eco.cut), 0.8, 0.8, 0.8, 1, 1, 1)
			end
		end
		GameTooltip:AddDoubleLine("Auction House net", d.ahNet and CP:FormatMoney(d.ahNet, { sign = true }) or Gray("-"), 0.8, 0.8, 0.8, 1, 1, 1)
		if eco and eco.vendorSale then
			GameTooltip:AddDoubleLine("Vendor sale", CP:FormatMoney(eco.vendorSale), 0.8, 0.8, 0.8, 1, 1, 1)
		end
		GameTooltip:AddDoubleLine("Vendor net", d.vendorNet and CP:FormatMoney(d.vendorNet, { sign = true }) or Gray("-"), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("Source", SourceLabel(d), 0.8, 0.8, 0.8, 1, 1, 1)
		if eco and eco.reagents and #eco.reagents > 0 then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Reagents", 0.9, 0.82, 0.5)
			for _, r in ipairs(eco.reagents) do
				local link = r.itemID and (GetItemInfo and GetItemInfo(r.itemID)) or nil
				local left = string.format("%dx %s", r.qty or 1, link or ("item " .. tostring(r.itemID)))
				local right = r.total and CP:FormatMoney(r.total) or Gray("?")
				if r.kind == "vendor" then right = right .. "*" end
				GameTooltip:AddDoubleLine(left, right, 1, 1, 1, 0.9, 0.9, 0.9)
			end
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row:Hide()
	ui.rows[index] = row
	return row
end

function Missing:UpdateStatus()
	local ui = self.ui
	if not ui then return end
	if not self:HasForeverMaster() then
		ui.status:SetText(CP:Color(CP.COLORS.loss, "ForeverMaster is not loaded. Enable it to list missing recipes."))
	else
		local profs = self:MyProfessions()
		local names = {}
		for _, p in ipairs(profs) do names[#names + 1] = string.format("%s %d", p.name, p.rank) end
		local who = #names > 0 and table.concat(names, ", ") or "no professions"
		if self.scanning and self.scan then
			ui.status:SetText(Body(string.format("Scanning… %d / %d (%s)", self.scan.priced, #self.scan.queue, who)))
		else
			local n = #(self.rows or {})
			local capped = self.rowTotal and self.rowTotal > n
			ui.status:SetText(Body(string.format("%d missing profitable%s · %s", n,
				capped and string.format(" (top %d of %d)", n, self.rowTotal) or "", who)))
		end
	end
	if ui.rescan then
		local on = self:HasForeverMaster() and not self.scanning
		if ui.rescan.SetEnabled then
			ui.rescan:SetEnabled(on)
		elseif on then
			ui.rescan:Enable()
		else
			ui.rescan:Disable()
		end
	end
end

function Missing:RefreshList()
	local ui = self.ui
	if not ui or not ui.page:IsShown() then return end
	local data = self.rows or {}
	local n = #data
	ui.content:SetSize(math.max(400, ui.scroll:GetWidth() or 400), math.max(1, n * self.ROW_HEIGHT))
	for i = 1, math.max(n, #ui.rows) do
		local row = self:EnsureRow(i)
		local d = data[i]
		if d and row then
			row.data = d
			if row.Stripe then row.Stripe:SetColorTexture(0.55, 0.42, 0.18, i % 2 == 0 and 0.10 or 0) end
			local icon = d.icon or RecipeIcon(d.spellID, d.makes, d.taughtBy)
			d.icon = icon
			row.Icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			local skill = d.learn and Muted(" [" .. d.learn .. "]") or ""
			local qty = d.quantity or 1
			local yield = (qty ~= 1) and Muted(string.format(" x%g", qty)) or ""
			row.Name:SetText(Body(d.name) .. skill .. yield)
			local function NetText(v)
				if not v then return Gray("-") end
				local hex = v >= 0 and CP.COLORS.profit or CP.COLORS.loss
				return CP:Color(hex, CP:FormatMoneyShort(v, { sign = true }))
			end
			row.AH:SetText(NetText(d.ahNet))
			row.Vendor:SetText(NetText(d.vendorNet))
			row.Source:SetText(SourceLabel(d))
			row:Show()
		elseif row then
			row.data = nil
			row:Hide()
		end
	end
	if ui.empty then
		if n == 0 and not self.scanning then
			if not self:HasForeverMaster() then
				ui.empty:SetText(CP:Color(CP.COLORS.loss, "Enable ForeverMaster, then open this tab again."))
			elseif #(self:MyProfessions()) == 0 then
				ui.empty:SetText(Muted("No professions on this character."))
			else
				ui.empty:SetText(Muted("No missing crafts with a positive Auction House or vendor net right now.\nOpen each profession once so CraftProfit knows what you already learned, then rescan."))
			end
			ui.empty:Show()
		else
			ui.empty:Hide()
		end
	end
end

function Missing:ShowPage()
	local ui = self:EnsureUI()
	if not ui then
		CP:Print("could not attach the missing-recipes page to the profession window.")
		return
	end
	ui.active = true
	-- Sit above the crafting page chrome; +20 was still under Forever's content frames.
	if ui.page.SetFrameStrata then ui.page:SetFrameStrata("HIGH") end
	ui.page:SetFrameLevel((ui.book:GetFrameLevel() or 1) + 500)
	ui.page:Show()
	if ui.tab.SetChecked then pcall(ui.tab.SetChecked, ui.tab, true) end
	self:UpdateStatus()
	if self:HasForeverMaster() then
		CP:Print("scanning missing profitable recipes…")
		self:StartScan(nil)
	else
		self.rows = {}
		self:RefreshList()
		CP:Print("ForeverMaster is not loaded; enable it for the missing-recipes list.")
	end
end

function Missing:HidePage()
	local ui = self.ui
	if not ui then return end
	ui.active = false
	ui.page:Hide()
	if ui.tab.SetChecked then pcall(ui.tab.SetChecked, ui.tab, false) end
end

function Missing:SyncTab()
	if not CP.settings.missingTab then
		if self.ui then
			self:HidePage()
			self.ui.tab:Hide()
		end
		return
	end
	local book = ProfessionsFrame
	if not (book and book:IsShown()) then
		if self.ui then self.ui.tab:Hide() end
		return
	end
	local ui = self:EnsureUI()
	if not ui then return end
	ui.tab:Show()
	ui.tab:ClearAllPoints()
	ui.tab:SetPoint("BOTTOMLEFT", book, "BOTTOMRIGHT", 0, 80)
	if not ui.active then ui.page:Hide() end
end

function Missing:Setup()
	if self.ready then return end
	if not ProfessionsFrame then return end
	local ok, err = pcall(function()
		self:EnsureUI()
		self:SyncTab()
	end)
	if not ok then
		CP:Debug("missing tab setup failed: %s", tostring(err))
		self.ui = nil -- allow a later TRADE_SKILL_SHOW / reopen to retry
		return
	end
	self.ready = true
	CP:Debug("missing tab ready")
end

function Missing:Report()
	if not self:HasForeverMaster() then
		CP:Print("ForeverMaster is not loaded; cannot list missing recipes.")
		return
	end
	local profs = self:MyProfessions()
	if #profs == 0 then
		CP:Print("no professions on this character.")
		return
	end
	if self.scanning then
		CP:Print("still scanning missing recipes…")
		return
	end
	-- Always rescan for /cf missing so chat output is fresh.
	self.reportAfterScan = true
	self:StartScan(nil)
end

function Missing:FinishReport()
	local profs = self:MyProfessions()
	local n = #(self.rows or {})
	CP:Print("%d missing profitable recipes for %s.", n, (function()
		local names = {}
		for _, p in ipairs(profs) do names[#names + 1] = p.name end
		return table.concat(names, ", ")
	end)())
	for i = 1, math.min(n, 15) do
		local r = self.rows[i]
		local bits = {}
		if r.ahNet then bits[#bits + 1] = "AH " .. CP:FormatMoney(r.ahNet, { sign = true }) end
		if r.vendorNet then bits[#bits + 1] = "vendor " .. CP:FormatMoney(r.vendorNet, { sign = true }) end
		CP:Print("  %s (%s) %s [%s]", r.name, r.profession, table.concat(bits, ", "), SourceLabel(r))
	end
	if n > 15 then CP:Print("  … and %d more (coin tab on the profession window).", n - 15) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Coalesce auto-rescans: price/craft events can burst, and we must not kick off a
-- 500+ recipe pass (plus chat noise) on every single craft tick.
local rescanQueued = false
local function QueueActiveRescan()
	if not (Missing.ui and Missing.ui.active) or rescanQueued then return end
	rescanQueued = true
	After(0.5, function()
		rescanQueued = false
		if Missing.ui and Missing.ui.active then Missing:StartScan(nil) end
	end)
end

CP:On("PRICES_UPDATED", function() QueueActiveRescan() end)
CP:On("VENDOR_UPDATED", function() QueueActiveRescan() end)
CP:On("SETTINGS_CHANGED", function() Missing:SyncTab() end)
CP:On("CRAFTS_UPDATED", function() QueueActiveRescan() end)

CP:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_Professions" or name == "ForeverMaster" then Missing:Setup() end
end)

CP:RegisterEvent("PLAYER_LOGIN", function()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
		Missing:Setup()
	end
end)

CP:RegisterEvent("TRADE_SKILL_SHOW", function()
	Missing:Setup()
	After(0, function() Missing:SyncTab() end)
end)

-- Do not rescan on TRADE_SKILL_LIST_UPDATE: that fires on every craft (craftable
-- counts) and does not change which ForeverMaster recipes are still unlearned.

CP:RegisterEvent("NEW_RECIPE_LEARNED", function()
	QueueActiveRescan()
end)

-- Item icons for unlearned crafts often arrive after the first paint.
CP:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
	if not success or not itemID or not (Missing.ui and Missing.ui.active) then return end
	local changed
	for _, row in ipairs(Missing.rows or {}) do
		if row.makes == itemID or row.taughtBy == itemID then
			local icon = RecipeIcon(row.spellID, row.makes, row.taughtBy)
			if icon and icon ~= row.icon then
				row.icon = icon
				changed = true
			end
		end
	end
	if changed then Missing:RefreshList() end
end)

if EventRegistry and EventRegistry.RegisterCallback then
	pcall(EventRegistry.RegisterCallback, EventRegistry, "ProfessionsFrame.Show", function()
		Missing:Setup()
		After(0, function() Missing:SyncTab() end)
	end, Missing)
	pcall(EventRegistry.RegisterCallback, EventRegistry, "ProfessionsFrame.Hide", function()
		Missing:HidePage()
		if Missing.ui then Missing.ui.tab:Hide() end
	end, Missing)
end
