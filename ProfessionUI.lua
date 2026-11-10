-- CraftProfit :: ProfessionUI
-- Integration with the default profession window (retail Blizzard_Professions, used by WoW Forever):
--   * profit tag + margin on every recipe row
--   * unit price / line total under every reagent
--   * "Profit - Auction House" (or "- Vendor", per the netBasis setting) panel in the recipe details
--   * optional sort-by-profit within categories (Filter dropdown, panel checkbox, /cf sort); see "Sort by profit"
--   * optional profitable-only filter (Filter dropdown, /cf profit); see "Profitable only"

local _, CP = ...
local UI = {}
CP.UI = UI

local C = CP.COLORS
-- Fixed width budget for the row tag so the recipe name always gets a predictable remainder.
-- Rows are ~250px; Blizzard uses ~21px (skill-up arrow) + the "[n]" craftable count.
local TAG_WIDTH = { profit = 46, margin = 40, both = 84 }

local function BasicReagentType()
	return (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
end

local function NodeData(node)
	if not node then return nil end
	if type(node.GetData) == "function" then return node:GetData() end
	return node.data or node
end

local function Muted(text) return CP:Color(C.muted, text) end
local function Body(text) return CP:Color(C.body, text) end
local function Gray(text) return CP:Color(C.gray, text) end

---------------------------------------------------------------------------
-- Extension point for companion addons
---------------------------------------------------------------------------
-- Another addon can take over what the recipe rows, the sort order and the details panel show:
--   UI:SetOverride({
--     key = "shuffle",
--     GetEco = function(recipeID) -> table with .net / .margin (same shape as CP.Calc:Get)
--     UpdateDetail = function(form, recipeInfo)   -- draws its own panel; ours is hidden
--   })
-- UI:SetOverride(nil) returns to the normal profit view.

UI.override = nil

function UI:GetEco(recipeID)
	local o = self.override
	if o and type(o.GetEco) == "function" then
		local ok, eco = pcall(o.GetEco, recipeID)
		if ok then return eco end
		CP:Debug("override GetEco failed: %s", tostring(eco))
	end
	return CP.Calc:Get(recipeID)
end

-- Net, margin and kind ("ah" | "vendor") shown for an economics table. A companion override defines its own
-- net, so the AH / vendor choice (netBasis) only applies to the normal profit view.
function UI:DisplayNet(eco)
	if not eco then return nil end
	if self.override then return eco.net, eco.margin, nil end
	return CP.Calc:PickNet(eco)
end

function UI:GetNet(recipeID)
	return (self:DisplayNet(self:GetEco(recipeID)))
end

-- Reagent unit price for the slot lines; an override can supply its own (e.g. pricing self-crafted
-- intermediates whenever that is cheaper).
function UI:ReagentCost(itemID)
	local o = self.override
	if o and type(o.ReagentCost) == "function" then
		local ok, unit, kind = pcall(o.ReagentCost, itemID)
		if ok then return unit, kind end
	end
	return CP.Calc:ReagentCost(itemID)
end

function UI:SetOverride(override)
	if override == self.override then return end
	self.override = override
	CP.Calc:Invalidate()
	self:RefreshAll() -- re-sorts too when sort by profit is on
	CP:Fire("OVERRIDE_CHANGED", override and override.key or nil)
end

---------------------------------------------------------------------------
-- Recipe list rows
---------------------------------------------------------------------------

local function EnsureRowWidgets(row)
	if row.cpProfit then return end
	local tag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	tag:SetJustifyH("RIGHT")
	tag:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	if tag.SetWordWrap then tag:SetWordWrap(false) end
	row.cpProfit = tag
	if row.cpMargin then row.cpMargin:Hide() end -- widget from an older version
end

-- Tag text for a net / margin pair according to the rowTag setting (shared with the trainer tags).
function UI:TagText(net, margin)
	if not net then return Gray("\226\128\148") end -- em dash
	local hex = net >= 0 and C.profit or C.loss
	local mode = CP.settings.rowTag or "profit"
	local profit = CP:Color(hex, CP:FormatMoneyShort(net, { sign = true }))
	local pct = margin and CP:FormatMargin(margin, true) or nil
	local text = profit
	if mode == "margin" then
		text = pct and CP:Color(hex, pct) or profit
	elseif mode == "both" then
		text = profit .. (pct and ("  " .. Muted(pct)) or "")
	end
	return text
end

local function RowTagText(eco)
	local net, margin = UI:DisplayNet(eco)
	return UI:TagText(net, margin)
end

function UI:UpdateRow(row, node)
	local data = NodeData(node)
	local info = data and data.recipeInfo
	if not info or not row.Label then return end
	EnsureRowWidgets(row)

	if not CP.settings.showRowTags then
		row.cpProfit:Hide()
		return
	end

	local eco = self:GetEco(info.recipeID)
	local tagWidth = TAG_WIDTH[CP.settings.rowTag or "profit"] or TAG_WIDTH.profit
	row.cpProfit:SetWidth(tagWidth)
	row.cpProfit:SetText(RowTagText(eco))
	row.cpProfit:Show()

	row.cpProfit:ClearAllPoints()
	if row.LockedIcon and row.LockedIcon:IsShown() then
		row.cpProfit:SetPoint("RIGHT", row.LockedIcon, "LEFT", -2, 0)
	else
		row.cpProfit:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	end

	-- Blizzard sized Label to min(available, stringWidth) without knowing about our tag. Re-shrink.
	local reserve = tagWidth + 10
	local countWidth = (row.Count and row.Count:IsShown()) and row.Count:GetStringWidth() or 0
	local skillWidth = row.SkillUps and row.SkillUps:GetWidth() or 26
	local labelLeft = skillWidth - 9 + 4
	local available = row:GetWidth() - labelLeft - countWidth - reserve
	if available < 30 then available = 30 end
	local stringWidth = row.Label:GetStringWidth()
	row.Label:SetWidth(math.min(stringWidth, available))
end

---------------------------------------------------------------------------
-- Reagent slots
---------------------------------------------------------------------------

-- Verdict for buying `qty` of a reagent now (walking the listings when they were read), or nil.
function UI:ReagentVerdict(itemID, qty)
	local scanner = CP.Scanner
	if not (itemID and scanner and scanner.GetVerdict) then return nil end
	local _, avg, kind = CP:GetReagentCostFor(itemID, qty or 1)
	if not avg or kind == "vendor" then return nil end
	return (scanner:GetVerdict(itemID, avg))
end

-- Slot layout (ProfessionsReagentSlotBaseTemplate): 180x50, icon 40px at LEFT, Name 108x36 at x=46
-- vertically centred. A one- or two-line name ends by y=-38, the next slot's name starts around y=-62,
-- so a single small line at y=-39 fits without touching anything.
local REAGENT_LINE_X, REAGENT_LINE_Y, REAGENT_LINE_WIDTH = 46, -39, 132

local function ReagentLine(rss)
	local basic = BasicReagentType()
	if not rss or rss.reagentType ~= basic then return nil end
	local qty = rss.quantityRequired or 1
	local best, bestKind, bestID
	for _, reagent in ipairs(rss.reagents or {}) do
		if reagent.itemID then
			local unit, kind = UI:ReagentCost(reagent.itemID)
			if unit and (not best or unit < best) then best, bestKind, bestID = unit, kind, reagent.itemID end
		end
	end
	if not best then return Gray("no price") end
	-- bought reagents: the line total is colored by the price verdict (cheap / high against the normal price)
	local color = C.body
	if bestKind ~= "craft" and bestKind ~= "vendor" then
		color = CP:VerdictColor(UI:ReagentVerdict(bestID, qty), C.body)
	end
	local total = CP:Color(color, CP:FormatMoney(best * qty, { compact = true, size = 10 }))
	if bestKind == "craft" then
		-- Crafted intermediates: the unit price is our own craft cost, so just say so.
		return total .. Muted(" crafted")
	end
	if qty <= 1 then
		return total .. (bestKind == "vendor" and Muted("*") or "")
	end
	local unit = CP:FormatMoney(best, { compact = true, size = 10 }) .. " ea" .. (bestKind == "vendor" and "*" or "")
	return total .. Muted("  (" .. unit .. ")")
end

local function EnsureSlotWidget(slot)
	if slot.cpPrice then return slot.cpPrice end
	local fs = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", slot, "TOPLEFT", REAGENT_LINE_X, REAGENT_LINE_Y)
	fs:SetWidth(REAGENT_LINE_WIDTH)
	fs:SetJustifyH("LEFT")
	if fs.SetWordWrap then fs:SetWordWrap(false) end -- clip the secondary unit price rather than wrap
	if fs.SetMaxLines then fs:SetMaxLines(1) end
	slot.cpPrice = fs
	return fs
end

local function UpdateSlotPrice(slot)
	local fs = EnsureSlotWidget(slot)
	if not CP.settings.showReagentPrices or type(slot.GetReagentSlotSchematic) ~= "function" then
		fs:Hide()
		return
	end
	local ok, rss = pcall(slot.GetReagentSlotSchematic, slot)
	local line = ok and rss and ReagentLine(rss) or nil
	if not line then
		fs:Hide()
		return
	end
	fs:SetText(line)
	fs:Show()
end

-- Basic reagent slots currently shown: Blizzard's plus any demo dummies (Demo.lua).
local function BasicSlots(form)
	local slots = form.reagentSlots and form.reagentSlots[BasicReagentType()]
	local list = {}
	if type(slots) == "table" then
		for _, s in ipairs(slots) do table.insert(list, s) end
	end
	if type(form.cpDemoSlots) == "table" then
		for _, s in ipairs(form.cpDemoSlots) do table.insert(list, s) end
	end
	return list
end
UI.BasicSlots = BasicSlots

function UI:DecorateSlots(form)
	for _, slot in ipairs(BasicSlots(form)) do
		UpdateSlotPrice(slot)
	end
end

local function RefreshSlots(form)
	UI:DecorateSlots(form)
end

---------------------------------------------------------------------------
-- Profit panel in the recipe details
---------------------------------------------------------------------------

local PANEL_MAX_WIDTH = 340
local PANEL_HEIGHT = 151    -- height when nothing above constrains it (no reagent slots to anchor to)
local PANEL_INSET = 28      -- matches the OutputIcon / Reagents left edge
local PANEL_BOTTOM = 48     -- clears the Track Recipe checkbox row
local PANEL_GAP = 10        -- gap below the last reagent slot
local STAT_ROW_H = 15
local REAGENT_STRIDE = 4    -- Blizzard fills reagent slots 4 per column, top to bottom

-- Layout constraints on the Forever client: the recipe pane is ~360x480 (retail: 793x553), reagent
-- slots stack 4 high (each 55px incl. spacing) from ~y=-135, and the Track Recipe checkbox sits at the
-- bottom-left. A fixed-size panel cannot coexist with a four-reagent recipe, so the panel is anchored
-- between the last reagent slot and the bottom inset, and its rows collapse to whatever height results.

local function PanelRightInset(form)
	local formWidth = form:GetWidth() or 0
	if formWidth > 200 then
		return math.max(PANEL_INSET, formWidth - PANEL_INSET - PANEL_MAX_WIDTH)
	end
	return PANEL_INSET
end

local function AnchorPanel(p, form)
	local slots = BasicSlots(form)
	local anchor
	if #slots > 0 then
		-- bottom of the first column: the lowest slot on screen
		anchor = slots[math.min(#slots, REAGENT_STRIDE)]
		if anchor and type(anchor.IsShown) == "function" and not anchor:IsShown() then anchor = nil end
	end
	-- Blizzard stacks the OptionalReagents container under the reagents; enchants use it for the
	-- "Enchant" target-item slot, which must stay clickable, so the panel goes below it.
	local optional = form.OptionalReagents
	if anchor and optional and type(optional.IsShown) == "function" and optional:IsShown() then
		anchor = optional
	end

	p:ClearAllPoints()
	local rightInset = PanelRightInset(form)
	p.cpAnchor = anchor
	if anchor then
		-- Stretch between the last slot and the bottom inset first; LayoutPanel caps the result at
		-- PANEL_HEIGHT once the real height is known (we cannot measure positions before layout).
		p.cpStretch = true
		p:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -PANEL_GAP)
		p:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -rightInset, PANEL_BOTTOM)
	else
		p.cpStretch = false
		p:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", PANEL_INSET, PANEL_BOTTOM)
		p:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -rightInset, PANEL_BOTTOM)
		p:SetHeight(PANEL_HEIGHT)
	end
end

-- Called from OnSizeChanged: if the stretched panel got more room than it needs, pin it to the
-- design height under the last reagent instead of leaving dead space above Track Recipe.
local function CapPanelHeight(p)
	if not p.cpStretch or not p.cpAnchor then return false end
	local h = p:GetHeight() or 0
	if h <= PANEL_HEIGHT + 0.5 then return false end
	local width = p:GetWidth() or PANEL_MAX_WIDTH
	p.cpStretch = false
	p:ClearAllPoints()
	p:SetPoint("TOPLEFT", p.cpAnchor, "BOTTOMLEFT", 0, -PANEL_GAP)
	p:SetSize(width, PANEL_HEIGHT)
	return true -- OnSizeChanged fires again with the capped height
end

-- Show as many stat rows as the current height allows; below ~88px the checkbox row goes too.
local function LayoutPanel(p)
	if CapPanelHeight(p) then return end
	local h = p:GetHeight() or PANEL_HEIGHT
	local fixed = 30 + 8 + 18 + 6          -- title area, divider gap, net row, bottom pad
	local showChecks = h >= fixed + 26
	if showChecks then fixed = fixed + 26 end
	local rows = { { p.CostLabel, p.Cost }, { p.SaleLabel, p.Sale }, { p.AltLabel, p.Alt }, { p.SoldLabel, p.Sold } }
	local nStats = math.floor((h - fixed) / STAT_ROW_H)
	if nStats < 0 then nStats = 0 end
	if nStats > #rows then nStats = #rows end

	for i, row in ipairs(rows) do
		local shown = i <= nStats
		local y = -30 - (i - 1) * STAT_ROW_H
		row[1]:ClearAllPoints()
		row[1]:SetPoint("TOPLEFT", 10, y)
		row[2]:ClearAllPoints()
		row[2]:SetPoint("TOPRIGHT", -10, y)
		row[1]:SetShown(shown)
		row[2]:SetShown(shown)
	end

	local y = -30 - nStats * STAT_ROW_H + 3
	p.Divider:ClearAllPoints()
	p.Divider:SetPoint("TOPLEFT", 10, y)
	p.Divider:SetPoint("TOPRIGHT", -10, y)
	p.Divider:SetShown(nStats > 0)
	p.NetLabel:ClearAllPoints()
	p.NetLabel:SetPoint("TOPLEFT", 10, y - 7)
	p.Net:ClearAllPoints()
	p.Net:SetPoint("TOPRIGHT", -10, y - 5)

	p.SortCheck:SetShown(showChecks)
	p.CraftCheck:SetShown(showChecks)
	p.VendorCheck:SetShown(showChecks)
	p.cpStatsShown = nStats
end

local function CreatePanel(form)
	local template = BackdropTemplateMixin and "BackdropTemplate" or nil
	local p = CreateFrame("Frame", "CraftProfitPanel", form, template)
	p:SetSize(PANEL_MAX_WIDTH, PANEL_HEIGHT)
	p:SetFrameLevel(form:GetFrameLevel() + 5)

	-- CraftingPage:Init() runs SchematicForm:Init() (our hook) before CraftingPage:Refresh() applies the
	-- final form width, so on first open we measure the retail default. Re-anchor whenever the form resizes.
	if type(form.HookScript) == "function" then
		form:HookScript("OnSizeChanged", function(f)
			if f.cpPanel and f.cpPanel:IsShown() then AnchorPanel(f.cpPanel, f) end
		end)
	end
	p:SetScript("OnSizeChanged", function(self) LayoutPanel(self) end)

	if p.SetBackdrop then
		p:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 12,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		})
		p:SetBackdropColor(0.07, 0.05, 0.03, 0.92)
		p:SetBackdropBorderColor(0.42, 0.35, 0.24, 1)
	end

	p.Title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	p.Title:SetPoint("TOPLEFT", 10, -9)
	p.Title:SetText("Profit \226\128\148 Auction House")

	-- Scan age (and the source when it is not our own scan) on the header's right side. Anchored to
	-- both the title and the right edge so it clips instead of overlapping the title when narrow.
	p.Age = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	p.Age:SetPoint("LEFT", p.Title, "RIGHT", 8, -1)
	p.Age:SetPoint("RIGHT", p, "RIGHT", -10, 0)
	p.Age:SetJustifyH("RIGHT")
	if p.Age.SetWordWrap then p.Age:SetWordWrap(false) end
	if p.Age.SetMaxLines then p.Age:SetMaxLines(1) end

	local function StatRow(label)
		local l = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetJustifyH("LEFT")
		l:SetText(CP:Color(C.label, label))
		local v = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		v:SetJustifyH("RIGHT")
		return l, v
	end
	p.CostLabel, p.Cost = StatRow("Total craft cost")
	p.SaleLabel, p.Sale = StatRow("Expected sale price")
	p.AltLabel, p.Alt = StatRow("Vendor net")   -- the other way to sell: vendor net, or AH net when the vendor leads
	p.SoldLabel, p.Sold = StatRow("Sold per day")

	p.Divider = p:CreateTexture(nil, "ARTWORK")
	p.Divider:SetColorTexture(0.23, 0.18, 0.12, 1)
	p.Divider:SetHeight(1)

	p.NetLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	p.NetLabel:SetText(CP:Color(C.label, "Net profit"))

	p.Net = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightMedium")
	p.Net:SetJustifyH("RIGHT")

	local function Checkbox(text, onClick)
		local cb = CreateFrame("CheckButton", nil, p, "UICheckButtonTemplate")
		cb:SetSize(22, 22)
		local label = cb.Text or cb.text
		if label then
			label:SetText(CP:Color(C.muted, text))
			label:SetFontObject("GameFontHighlightSmall")
		end
		cb.label = label
		cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
		return cb
	end
	p.SortCheck = Checkbox("Sort by profit", function(checked) UI:SetSortByProfit(checked) end)
	p.SortCheck:SetPoint("BOTTOMLEFT", 6, 4)
	p.CraftCheck = Checkbox("Craft reagents", function(checked) CP:SetSetting("craftIntermediates", checked) end)
	if p.SortCheck.label then
		p.CraftCheck:SetPoint("LEFT", p.SortCheck.label, "RIGHT", 10, 0)
	else
		p.CraftCheck:SetPoint("LEFT", p.SortCheck, "RIGHT", 100, 0)
	end
	p.CraftCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Craft reagents I can make")
		GameTooltip:AddLine("Reagents you have a learned recipe for (e.g. Bolt of Woolen Cloth) are priced at their own craft cost instead of the auction price.", 1, 1, 1, true)
		local n = 0
		for _ in pairs(CP.crafts or {}) do n = n + 1 end
		GameTooltip:AddLine(string.format("%d craftable items known this session. Open each profession once to register its recipes.", n), 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	p.CraftCheck:SetScript("OnLeave", GameTooltip_Hide)
	-- Switches the whole recipe list (tags, sort, this panel) between AH net and vendor net.
	p.VendorCheck = Checkbox("Vendor net", function(checked) CP:SetSetting("netBasis", checked and "vendor" or "ah") end)
	if p.CraftCheck.label then
		p.VendorCheck:SetPoint("LEFT", p.CraftCheck.label, "RIGHT", 10, 0)
	else
		p.VendorCheck:SetPoint("LEFT", p.CraftCheck, "RIGHT", 100, 0)
	end
	p.VendorCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Vendor net")
		GameTooltip:AddLine("Show every recipe's profit for selling to a vendor instead of the Auction House (vendor price x items per craft - craft cost).", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	p.VendorCheck:SetScript("OnLeave", GameTooltip_Hide)

	p:EnableMouse(true)
	p:SetScript("OnEnter", function(self)
		local eco = self.cpEco
		if not eco then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("CraftProfit")
		GameTooltip:AddLine("Source: " .. CP:GetSourceName(), 1, 1, 1)
		if (self.cpStatsShown or 4) < 4 then
			-- rows hidden for lack of space: repeat them here
			GameTooltip:AddDoubleLine("Total craft cost", eco.cost > 0 and CP:FormatMoney(eco.cost) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Expected sale price", eco.sale and CP:FormatMoney(eco.sale) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Auction House net", eco.net and CP:FormatMoney(eco.net, { sign = true }) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Vendor net", eco.vendorNet and CP:FormatMoney(eco.vendorNet, { sign = true }) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("Sold per day", eco.soldPerDay and string.format("%.1f", eco.soldPerDay) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
		end
		if eco.quantity and eco.quantity ~= 1 then
			GameTooltip:AddLine(string.format("Output per craft: %g", eco.quantity), 1, 1, 1)
		end
		if eco.cut then
			GameTooltip:AddLine(string.format("AH cut (%d%%): %s", math.floor((CP.settings.ahCut or 0) * 100 + 0.5),
				CP:FormatMoney(eco.cut)), 1, 1, 1)
		end
		if eco.vendorUnit then
			GameTooltip:AddLine("Vendor sell price: " .. CP:FormatMoney(eco.vendorUnit) .. " each (no cut)", 1, 1, 1)
		elseif eco.outputItemID and not eco.vendorPending then
			GameTooltip:AddLine("Vendors do not buy this item.", 0.6, 0.6, 0.6)
		end
		GameTooltip:AddLine(" ")
		for _, r in ipairs(eco.reagents or {}) do
			local name = r.itemID and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID)
			name = name or (r.itemID and ("item " .. r.itemID)) or "currency"
			local right
			if not r.unit then
				right = "no price"
			elseif r.kind == "craft" then
				right = CP:FormatMoney(r.unit) .. " crafted" .. (r.buyUnit and (" (buy " .. CP:FormatMoney(r.buyUnit) .. ")") or "")
			else
				right = CP:FormatMoney(r.unit) .. (r.kind == "vendor" and " (vendor)" or "")
				local v = r.kind ~= "vendor" and UI:ReagentVerdict(r.itemID, r.qty) or nil
				if v then right = right .. "  " .. CP:FormatVerdict(v) end
			end
			GameTooltip:AddDoubleLine(string.format("%dx %s", r.qty or 1, name), right, 0.8, 0.8, 0.8, 1, 1, 1)
		end
		-- the most each bought reagent may cost before this craft stops paying off
		local shownBreakEven
		for _, r in ipairs(eco.reagents or {}) do
			local be = r.kind ~= "vendor" and r.kind ~= "craft" and UI:BreakEven(eco, r) or nil
			if be then
				if not shownBreakEven then
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("Break-even price per reagent (net 0)", 0.8, 0.8, 0.8)
					shownBreakEven = true
				end
				local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(r.itemID) or ("item " .. r.itemID)
				local right = be > 0 and CP:FormatMoney(be) or "never pays off"
				GameTooltip:AddDoubleLine(name, right, 0.8, 0.8, 0.8, 1, 1, 1)
			end
		end
		-- the same craft with every bought reagent at its normal price: is it good only because of today?
		local atNormal, judged = UI:CostAtNormal(eco)
		if judged > 0 and eco.cost and eco.cost > 0 then
			local diff = atNormal - eco.cost
			local line = "At normal reagent prices: cost " .. CP:FormatMoney(atNormal)
			if eco.net then line = line .. ", net " .. CP:FormatMoney(eco.net - diff, { sign = true }) end
			GameTooltip:AddLine(line, 1, 1, 1, true)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("* = vendor price. Sold/day is an estimate from consecutive scans. Cheap/high: today's price against the normal price (median of the last 7 days).", 0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	p:SetScript("OnLeave", GameTooltip_Hide)

	LayoutPanel(p)
	return p
end

-- The economics of the recipe shown in the open profession window, or nil.
function UI:CurrentEco()
	local frame = ProfessionsFrame
	local form = frame and frame.CraftingPage and frame.CraftingPage.SchematicForm
	if not (form and frame:IsShown() and form.cpPanel) then return nil end
	return form.cpPanel.cpEco
end

-- Highest unit price for reagent entry `r` of `eco` at which the craft still breaks even (net 0 after the AH
-- cut), with every other reagent at its current cost. nil without a sale price or a complete cost.
function UI:BreakEven(eco, r)
	if not (eco and r and eco.sale and eco.costComplete and r.qty and r.qty > 0) then return nil end
	local cut = eco.cut or 0
	local others = (eco.cost or 0) - (r.total or (r.unit or 0) * r.qty)
	return math.floor((eco.sale - cut - others) / r.qty)
end

-- Craft cost with every bought reagent that has a normal price at that price (vendor and crafted reagents
-- unchanged). Returns the cost and how many reagents had a normal price.
function UI:CostAtNormal(eco)
	local cost, judged = 0, 0
	local scanner = CP.Scanner
	for _, r in ipairs(eco and eco.reagents or {}) do
		local normal = r.itemID and r.kind ~= "vendor" and r.kind ~= "craft" and scanner and scanner.GetNormal
			and scanner:GetNormal(r.itemID)
		if normal then
			cost = cost + normal * (r.qty or 1)
			judged = judged + 1
		else
			cost = cost + (r.total or (r.unit or 0) * (r.qty or 1))
		end
	end
	return cost, judged
end

function UI:UpdateDetail(form, recipeInfo)
	local p = form.cpPanel
	if not p then return end
	local o = self.override
	if o and type(o.UpdateDetail) == "function" then
		p:Hide()
		local ok, err = pcall(o.UpdateDetail, form, recipeInfo)
		if not ok then CP:Debug("override UpdateDetail failed: %s", tostring(err)) end
		return
	end
	if not CP.settings.showPanel or not recipeInfo or not recipeInfo.recipeID then
		p:Hide()
		return
	end

	local eco = CP.Calc:Get(recipeInfo.recipeID)
	p.cpEco = eco
	AnchorPanel(p, form)
	LayoutPanel(p)
	p:Show()

	local ageText = eco.age and ("scanned " .. CP:FormatAge(eco.age)) or "no price data"
	local source = CP.Sources:Resolve()
	if source and source.key ~= "craftprofit" then
		ageText = source.name .. " \194\183 " .. (eco.age and CP:FormatAge(eco.age) or "no data")
	end
	p.Age:SetText(ageText)

	local costText
	if eco.costComplete and #eco.reagents > 0 then
		costText = Body(CP:FormatMoney(eco.cost))
	elseif eco.cost > 0 then
		costText = Body(CP:FormatMoney(eco.cost)) .. Muted(string.format(" +%d unpriced", eco.missing))
	else
		costText = Gray("\226\128\148")
	end
	if (eco.crafted or 0) > 0 then
		p.CostLabel:SetText(CP:Color(C.label, string.format("Total craft cost (%d crafted)", eco.crafted)))
	else
		p.CostLabel:SetText(CP:Color(C.label, "Total craft cost"))
	end
	p.Cost:SetText(costText)

	-- Lead with the net the netBasis setting picks; the other way to sell goes in the extra row.
	local net, margin, kind = UI:DisplayNet(eco)
	local vendorLead = kind == "vendor" or (kind == nil and CP.settings.netBasis == "vendor")
	p.Title:SetText(vendorLead and "Profit \226\128\148 Vendor" or "Profit \226\128\148 Auction House")

	local qtyText = (eco.quantity and eco.quantity ~= 1) and string.format(" (x%g)", eco.quantity) or ""
	local function Signed(value)
		if not value then return Gray("\226\128\148") end
		return CP:Color(value >= 0 and C.profit or C.loss, CP:FormatMoney(value, { sign = true }))
	end
	if vendorLead then
		p.SaleLabel:SetText(CP:Color(C.label, "Vendor sell price" .. qtyText))
		p.Sale:SetText(eco.vendorSale and Body(CP:FormatMoney(eco.vendorSale)) or Gray("\226\128\148"))
		p.AltLabel:SetText(CP:Color(C.label, "Auction House net"))
		p.Alt:SetText(Signed(eco.net))
	else
		p.SaleLabel:SetText(CP:Color(C.label, "Expected sale price" .. qtyText))
		p.Sale:SetText(eco.sale and Body(CP:FormatMoney(eco.sale)) or Gray("\226\128\148"))
		p.AltLabel:SetText(CP:Color(C.label, "Vendor net"))
		if eco.outputItemID and not eco.vendorUnit and not eco.vendorPending then
			p.Alt:SetText(Gray("vendors don't buy it"))
		else
			p.Alt:SetText(Signed(eco.vendorNet))
		end
	end
	p.Sold:SetText(eco.soldPerDay and Body(string.format("%.1f", eco.soldPerDay)) or Gray("\226\128\148"))

	if net then
		local hex = net >= 0 and C.profit or C.loss
		local pct = CP:FormatMargin(margin)
		local marginText = pct and ("  (" .. pct .. ")") or ""
		p.Net:SetText(CP:Color(hex, CP:FormatMoney(net, { sign = true }) .. marginText))
	elseif not eco.outputItemID then
		p.Net:SetText(Gray("no sellable output"))
	elseif vendorLead and not eco.vendorUnit and not eco.vendorPending then
		p.Net:SetText(Gray("no vendor price"))
	else
		p.Net:SetText(Gray("\226\128\148"))
	end

	p.SortCheck:SetChecked(CP.settings.sortByProfit and true or false)
	p.CraftCheck:SetChecked(CP.settings.craftIntermediates and true or false)
	p.VendorCheck:SetChecked(CP.settings.netBasis == "vendor")
end

local function OnFormInit(form, recipeInfo)
	if not form.cpPanel then form.cpPanel = CreatePanel(form) end
	if CP.Demo then
		local ok, err = pcall(CP.Demo.ApplySlots, CP.Demo, form, recipeInfo)
		if not ok then CP:Debug("demo slots failed: %s", tostring(err)) end
	end
	UI:UpdateDetail(form, recipeInfo)
	if recipeInfo then UI:DecorateSlots(form) end
	CP:Fire("FORM_INIT", form, recipeInfo)
end

-- Re-run Blizzard's form init for the current recipe (public method), which re-triggers our hook.
function UI:ReinitForm()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local form = page and page.SchematicForm
	if not form or not ProfessionsFrame:IsShown() then return end
	local info = type(form.GetRecipeInfo) == "function" and form:GetRecipeInfo() or nil
	if info and type(form.Init) == "function" then
		local ok, err = pcall(form.Init, form, info)
		if not ok then CP:Debug("form reinit failed: %s", tostring(err)) end
	end
end

---------------------------------------------------------------------------
-- Sort by profit
---------------------------------------------------------------------------

-- How it stays out of the default UI's way:
--   * Only the sort comparator of category nodes is swapped, through the tree node's own SetSortComparator
--     (the same call Blizzard uses when it builds the list). Nothing is inserted, removed or re-parented, so
--     categories, favorites, the unlearned divider, padding rows and collapse state are untouched.
--   * Within a category only recipe rows that both have a profit are reordered (highest net first, recipes
--     without a price after them). Every other comparison, and every tie, is answered by Blizzard's own
--     comparator, so headers and unpriced recipes keep the default order.
--   * Turning it off puts Blizzard's comparator back on the same nodes; the next list Blizzard builds (search,
--     filter, new profession) uses its own order anyway.
--   * We never call Blizzard's page or list Init; the current list is re-sorted in place.
-- The tree caches its flattened row list; node:Sort() does not clear that cache (TreeListDataProvider.lua),
-- so after sorting the provider is invalidated, which is what makes the ScrollBox show the new order.

local blizzardSort -- Blizzard's comparator for category nodes (SortCategoryData), captured from the list

local function ProfitComparator(lhs, rhs)
	local a, b = NodeData(lhs), NodeData(rhs)
	local ar, br = a and a.recipeInfo, b and b.recipeInfo
	if ar and br and not a.categoryInfo and not b.categoryInfo and (a.order or 0) == (b.order or 0) then
		local pa, pb = UI:GetNet(ar.recipeID), UI:GetNet(br.recipeID)
		if pa ~= pb then
			if pa == nil then return false end
			if pb == nil then return true end
			return pa > pb
		end
	end
	if blizzardSort then return blizzardSort(lhs, rhs) end
	-- no Blizzard comparator seen (should not happen): categories first, then padding order, then name
	if (a and a.categoryInfo) or (b and b.categoryInfo) then return (a and a.categoryInfo and not (b and b.categoryInfo)) and true or false end
	local ao, bo = a and a.order or 0, b and b.order or 0
	if ao ~= bo then return ao < bo end
	return strcmputf8i((ar and ar.name) or "", (br and br.name) or "") < 0
end

-- Applies (or removes) the profit order on a recipe list data provider. Returns true when it re-sorted.
function UI:ApplySort(dataProvider)
	if not dataProvider or type(dataProvider.EnumerateEntireRange) ~= "function" then return false end
	local want = CP.settings.sortByProfit and true or false
	local changed = false
	local ok, err = pcall(function()
		local nodes = {}
		for _, node in dataProvider:EnumerateEntireRange() do
			local d = NodeData(node)
			if d and d.categoryInfo and type(node.SetSortComparator) == "function" then
				table.insert(nodes, node)
				local current = node.sortComparator
				if current and current ~= ProfitComparator then blizzardSort = current end
			end
		end
		for _, node in ipairs(nodes) do
			if want then
				node:SetSortComparator(ProfitComparator, false, false) -- also re-sorts with fresh prices
				changed = true
			elseif node.sortComparator == ProfitComparator and blizzardSort then
				node:SetSortComparator(blizzardSort, false, false)
				changed = true
			end
		end
	end)
	if not ok then CP:Debug("sort failed: %s", tostring(err)) end
	if changed and type(dataProvider.Invalidate) == "function" then
		local ok2, err2 = pcall(dataProvider.Invalidate, dataProvider)
		if not ok2 then CP:Debug("sort refresh failed: %s", tostring(err2)) end
	end
	return changed
end

-- Re-sorts the list that is on screen (no rebuild).
function UI:ResortList()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local scrollBox = page and page.RecipeList and page.RecipeList.ScrollBox
	if not scrollBox or type(scrollBox.GetDataProvider) ~= "function" then return false end
	return self:ApplySort(scrollBox:GetDataProvider())
end

function UI:SetSortByProfit(enabled)
	CP.settings.sortByProfit = enabled and true or false
	CP.touched.sortByProfit = true -- keep the choice if a late-loaded database is adopted
	self:ResortList()
	local form = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
	if form and form.cpPanel then form.cpPanel.SortCheck:SetChecked(CP.settings.sortByProfit) end
	CP:Fire("SORT_CHANGED", CP.settings.sortByProfit)
end

---------------------------------------------------------------------------
-- Profitable only
---------------------------------------------------------------------------

-- Removes recipe rows whose current net is negative from the tree Blizzard just built.
-- Recipes with no price (nil net) stay; only known losses are dropped. Empty categories are
-- culled afterwards so headers without remaining crafts do not linger. Turning the filter off
-- (or changing Blizzard's own filters) rebuilds the list through Init, which restores everything.

local rebuildingList = false

function UI:RebuildList()
	if rebuildingList then return end
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	if not page or not page.professionInfo or not ProfessionsFrame:IsShown() then return end
	if type(page.Init) ~= "function" then return end
	rebuildingList = true
	local ok, err = pcall(page.Init, page, page.professionInfo)
	rebuildingList = false
	if not ok then CP:Debug("list rebuild failed: %s", tostring(err)) end
end

local function CategoryHasContent(node)
	for _, child in ipairs(node:GetNodes() or {}) do
		local d = NodeData(child)
		if d and d.recipeInfo then return true end
		if d and d.categoryInfo and CategoryHasContent(child) then return true end
	end
	return false
end

-- Drops negative-profit recipes (and then empty categories) from a recipe list data provider.
function UI:ApplyFilter(dataProvider)
	if not dataProvider or not CP.settings.profitableOnly then return false end
	if type(dataProvider.EnumerateEntireRange) ~= "function" or type(dataProvider.Remove) ~= "function" then
		return false
	end
	local changed = false
	local ok, err = pcall(function()
		local drop = {}
		for _, node in dataProvider:EnumerateEntireRange() do
			local d = NodeData(node)
			local info = d and d.recipeInfo
			if info and info.recipeID and not d.categoryInfo then
				local net = UI:GetNet(info.recipeID)
				if net ~= nil and net < 0 then
					table.insert(drop, node)
				end
			end
		end
		for _, node in ipairs(drop) do
			dataProvider:Remove(node)
			changed = true
		end
		-- Cull categories that no longer hold a recipe (or a non-empty subcategory).
		local again = true
		while again do
			again = false
			local empty = {}
			for _, node in dataProvider:EnumerateEntireRange() do
				local d = NodeData(node)
				if d and d.categoryInfo and not CategoryHasContent(node) then
					table.insert(empty, node)
				end
			end
			for _, node in ipairs(empty) do
				dataProvider:Remove(node)
				changed = true
				again = true
			end
		end
	end)
	if not ok then CP:Debug("filter failed: %s", tostring(err)) end
	if changed and type(dataProvider.Invalidate) == "function" then
		local ok2, err2 = pcall(dataProvider.Invalidate, dataProvider)
		if not ok2 then CP:Debug("filter refresh failed: %s", tostring(err2)) end
	end
	return changed
end

function UI:SetProfitableOnly(enabled)
	CP.settings.profitableOnly = enabled and true or false
	CP.touched.profitableOnly = true
	-- Rebuild so turning it off restores removed rows (and turning it on starts from a full list).
	self:RebuildList()
	CP:Fire("FILTER_CHANGED", CP.settings.profitableOnly)
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

function UI:RefreshAll()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	if not page or not ProfessionsFrame:IsShown() then return end

	local list = page.RecipeList
	if list and list.ScrollBox and type(list.ScrollBox.ForEachFrame) == "function" then
		list.ScrollBox:ForEachFrame(function(frame, elementData)
			if frame.Label and frame.SkillUps then
				local node = elementData
				if not node and type(frame.GetElementData) == "function" then
					local ok, ed = pcall(frame.GetElementData, frame)
					if ok then node = ed end
				end
				if node then UI:UpdateRow(frame, node) end
			end
		end)
		-- prices changed: drop newly unprofitable rows, then re-sort with the new numbers
		if type(list.ScrollBox.GetDataProvider) == "function" then
			local dataProvider = list.ScrollBox:GetDataProvider()
			if CP.settings.profitableOnly then self:ApplyFilter(dataProvider) end
			if CP.settings.sortByProfit then self:ApplySort(dataProvider) end
		end
	end

	local form = page.SchematicForm
	if form and form.cpPanel then
		local info = type(form.GetRecipeInfo) == "function" and form:GetRecipeInfo() or nil
		self:UpdateDetail(form, info)
		if info then RefreshSlots(form) end
	end
end

CP:On("PRICES_UPDATED", function() UI:RefreshAll() end)
CP:On("VENDOR_UPDATED", function() UI:RefreshAll() end)
CP:On("SETTINGS_CHANGED", function() UI:RefreshAll() end)

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

function UI:Setup()
	if self.ready then return end
	if not ProfessionsFrame or not ProfessionsFrame.CraftingPage then return end
	local page = ProfessionsFrame.CraftingPage
	if not page.SchematicForm or not page.RecipeList or not page.RecipeList.ScrollBox then return end
	self.ready = true

	-- Row tags: listen to the ScrollBox's own OnInitializedFrame event (fires after Blizzard's row Init
	-- on every acquire/update). This touches no Blizzard table. Build 1.60.1.69977 started failing rows
	-- whose mixin Init had been wrapped with hooksecurefunc ("attempt to call a nil value" inside
	-- secureexecuterange), so the mixin hook is only a fallback for clients without the event.
	local scrollBox = page.RecipeList.ScrollBox
	local initEvent = ScrollBoxListMixin and ScrollBoxListMixin.Event and ScrollBoxListMixin.Event.OnInitializedFrame
	if initEvent and type(scrollBox.RegisterCallback) == "function" then
		scrollBox:RegisterCallback(initEvent, function(_, frame, elementData)
			if frame and frame.Label and frame.SkillUps then
				UI:UpdateRow(frame, elementData)
			end
		end, UI)
		self.rowHook = "scrollbox"
	elseif ProfessionsRecipeListRecipeMixin and type(ProfessionsRecipeListRecipeMixin.Init) == "function" then
		hooksecurefunc(ProfessionsRecipeListRecipeMixin, "Init", function(row, node)
			UI:UpdateRow(row, node)
		end)
		self.rowHook = "mixin"
	end

	hooksecurefunc(page.SchematicForm, "Init", OnFormInit)

	hooksecurefunc(page.RecipeList.ScrollBox, "SetDataProvider", function(_, dataProvider)
		UI:ApplyFilter(dataProvider)
		UI:ApplySort(dataProvider)
	end)

	if Menu and type(Menu.ModifyMenu) == "function" then
		pcall(Menu.ModifyMenu, "MENU_PROFESSIONS_FILTER", function(_, rootDescription)
			rootDescription:CreateDivider()
			rootDescription:CreateTitle("CraftProfit")
			rootDescription:CreateCheckbox("Sort by profit",
				function() return CP.settings.sortByProfit end,
				function() UI:SetSortByProfit(not CP.settings.sortByProfit) end)
			rootDescription:CreateCheckbox("Profitable only",
				function() return CP.settings.profitableOnly end,
				function() UI:SetProfitableOnly(not CP.settings.profitableOnly) end)
			rootDescription:CreateCheckbox("Vendor net",
				function() return CP.settings.netBasis == "vendor" end,
				function() CP:SetSetting("netBasis", CP.settings.netBasis == "vendor" and "ah" or "vendor") end)
		end)
	end

	-- Decorate whatever is already shown.
	local form = page.SchematicForm
	local info = type(form.GetRecipeInfo) == "function" and form:GetRecipeInfo() or nil
	if info then OnFormInit(form, info) end
	self:RefreshAll()
	CP:Debug("profession UI hooks installed")
	CP:Fire("UI_READY", page)
end

CP:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_Professions" then UI:Setup() end
end)

CP:RegisterEvent("PLAYER_LOGIN", function()
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Professions") then
		UI:Setup()
	end
end)

CP:RegisterEvent("TRADE_SKILL_SHOW", function()
	UI:Setup()
	if not UI.ready and not UI.warned then
		UI.warned = true
		CP:Print("could not find the retail profession window (ProfessionsFrame). This client's profession UI is not supported yet.")
	end
end)
