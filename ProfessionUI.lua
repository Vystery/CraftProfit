-- CraftProfit :: ProfessionUI
-- Integration with the default profession window (retail Blizzard_Professions, used by WoW Forever):
--   * profit tag + margin on every recipe row
--   * unit price / line total under every reagent
--   * "Profit (Auction House):" (or "(Vendor):", per the netBasis setting) section in the recipe details
--   * optional sort-by-profit within categories (Filter dropdown, panel checkbox, /cf sort); see "Sort by profit"
--   * optional profitable-only filter (Filter dropdown, options, /cf profit); see "Profitable only"

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

-- A long name wraps to three lines ("0/6 Large Glimmering Shard") and its last line reaches below y=-39.
-- The name is centred on its LEFT anchor, so the price line goes just under the name's real text height,
-- and never higher than the usual y=-39 spot.
local REAGENT_LINE_DROP = -REAGENT_LINE_Y - 25 -- the usual spot, measured from the slot's vertical centre (50px slot)

-- Two ways to show the price: in a right-aligned "column" on the same row as the name (the design, and
-- the default single-column layout leaves room for it, see UI:PlaceSlotLines), or "below" the name when
-- something sits to the right (ForeverRecipes' two-per-row reagents) or nothing is measurable yet.
local function PlaceSlotLine(slot)
	local fs, name = slot.cpPrice, slot.Name
	if not fs then return end
	fs:ClearAllPoints()
	local col = slot.cpColumn
	-- Under the name, a three-line name plus the price line is four lines in a 45px slot (crowded with a
	-- second reagent column). There the name is capped at two lines; the reagent's tooltip has the full name.
	if name and type(name.SetMaxLines) == "function" then
		local cap = not col and fs:IsShown()
		if cap ~= (slot.cpNameCapped or false) then
			name:SetMaxLines(cap and 2 or 0)
			slot.cpNameCapped = cap
		end
	end
	if col then
		fs:SetPoint("RIGHT", slot, "LEFT", col.x, 0)
		fs:SetWidth(col.w)
		fs:SetJustifyH("RIGHT")
		slot.cpLineMode, slot.cpLineDrop = "column", nil
		return
	end
	fs:SetWidth(REAGENT_LINE_WIDTH)
	fs:SetJustifyH("LEFT")
	slot.cpLineMode = "below"
	local h = name and type(name.GetStringHeight) == "function" and name:GetStringHeight() or nil
	if type(h) == "number" and h > 0 and h / 2 + 1 > REAGENT_LINE_DROP then
		fs:SetPoint("TOPLEFT", slot, "LEFT", REAGENT_LINE_X, -(h / 2 + 1))
	else
		fs:SetPoint("TOPLEFT", slot, "TOPLEFT", REAGENT_LINE_X, REAGENT_LINE_Y)
	end
	slot.cpLineDrop = type(h) == "number" and math.max(REAGENT_LINE_DROP, h / 2 + 1) or REAGENT_LINE_DROP
end

local function EnsureSlotWidget(slot)
	if slot.cpPrice then return slot.cpPrice end
	local fs = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	if fs.SetWordWrap then fs:SetWordWrap(false) end -- clip the secondary unit price rather than wrap
	if fs.SetMaxLines then fs:SetMaxLines(1) end
	slot.cpPrice = fs
	-- the quantity in the name ("0/6" -> "10/16") or another addon's width change can re-wrap it
	local name = slot.Name
	if name and hooksecurefunc then
		if type(name.SetText) == "function" then hooksecurefunc(name, "SetText", function() PlaceSlotLine(slot) end) end
		if type(name.SetWidth) == "function" then hooksecurefunc(name, "SetWidth", function() PlaceSlotLine(slot) end) end
	end
	PlaceSlotLine(slot)
	return fs
end

local function UpdateSlotPrice(slot)
	local fs = EnsureSlotWidget(slot)
	if not CP.settings.showReagentPrices or type(slot.GetReagentSlotSchematic) ~= "function" then
		fs:Hide()
		PlaceSlotLine(slot)
		return
	end
	local ok, rss = pcall(slot.GetReagentSlotSchematic, slot)
	local line = ok and rss and ReagentLine(rss) or nil
	if not line then
		fs:Hide()
		PlaceSlotLine(slot) -- gives the name its lines back
		return
	end
	fs:SetText(line)
	fs:Show()
	PlaceSlotLine(slot)
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
	self:PlaceSlotLines(form)
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

-- Other addons put their own rows under the reagents (Auctionator's reagent total, ForeverRecipes'
-- Difficulty block and Source tabs) and ForeverRecipes lays the reagents out two per row. So once the form
-- is laid out, the panel goes below whatever is actually there instead of assuming Blizzard's layout.
local PANEL_MIN_HEIGHT = 62     -- title + net row: the smallest panel that still says something
local PANEL_FLOOR = 8           -- how far the smallest panel may dip into the Track Recipe band (opts-less callers)
local PANEL_STRIP_HEIGHT = 26   -- one line: net profit + Shop
local PANEL_DOCK_GAP = 6        -- gap to the profession window: its border reaches a few px past its edge
local DOCK_TOP, DOCK_BOTTOM, DOCK_PAD = 30, 12, 14 -- docked window: title bar, bottom edge, side padding
local DOCK_RIGHT_WIDTH = 300    -- docked to the right: the window's width
local DOCK_RIGHT_GAP = 20       -- like Blizzard's crafting output log (TOPRIGHT x=20) when no tabs are in the way
local SETTLE_TIME = 0.5         -- neighbours (ForeverRecipes) place their rows a frame or more after us

-- Screen-space rect (scale-normalised), or nil when the region is not laid out yet.
local function Rect(f)
	if not (f and type(f.GetTop) == "function" and type(f.GetBottom) == "function") then return nil end
	local top, bottom = f:GetTop(), f:GetBottom()
	if type(top) ~= "number" or type(bottom) ~= "number" then return nil end
	local left = type(f.GetLeft) == "function" and f:GetLeft() or nil
	local right = type(f.GetRight) == "function" and f:GetRight() or nil
	local s = type(f.GetEffectiveScale) == "function" and f:GetEffectiveScale() or 1
	return { top = top * s, bottom = bottom * s, left = left and left * s, right = right and right * s, scale = s }
end

local function Visible(f)
	if type(f.IsShown) == "function" and not f:IsShown() then return false end
	if type(f.IsVisible) == "function" and not f:IsVisible() then return false end
	if type(f.GetAlpha) == "function" and (f:GetAlpha() or 1) <= 0.01 then return false end
	return true
end

-- Lowest screen y of everything in the reagent area and below it (reagent slots, Blizzard's optional
-- reagents, and any other addon's frame on the form or its page that sits inside the form's width), or nil
-- when nothing can be measured yet. Returns the form's rect too.
local function ContentBottom(p, form)
	local fr = Rect(form)
	if not (fr and fr.left and fr.right) then return nil end
	local lowest, reagentTop
	for _, slot in ipairs(BasicSlots(form)) do
		local r = Visible(slot) and Rect(slot)
		if r then
			if not lowest or r.bottom < lowest then lowest = r.bottom end
			if not reagentTop or r.top > reagentTop then reagentTop = r.top end
			-- our price line under a three-line name can reach below the slot
			local line = slot.cpPrice and Visible(slot.cpPrice) and Rect(slot.cpPrice)
			if line and line.bottom < lowest then lowest = line.bottom end
		end
	end
	if not lowest then return nil end
	local optional = form.OptionalReagents
	local r = optional and Visible(optional) and Rect(optional)
	if r and r.bottom < lowest then lowest = r.bottom end

	local formHeight = fr.top - fr.bottom
	local band = fr.bottom + PANEL_BOTTOM * fr.scale -- the Track Recipe row: not content
	local skip = { [p] = true, [p.cpDock or p] = true, [form] = true, [form.Reagents or p] = true, [optional or p] = true }
	local function scan(parent)
		if not (parent and type(parent.GetChildren) == "function") then return end
		for _, child in ipairs({ parent:GetChildren() }) do
			if not skip[child] and Visible(child) then
				local c = Rect(child)
				if c and c.left and c.right and c.top - c.bottom > 1
					and c.top - c.bottom <= formHeight * 0.6           -- not a backdrop / whole-form container
					and c.left >= fr.left - 4 and c.right <= fr.right + 4 -- inside the recipe pane
					and c.top <= reagentTop + 2 and c.top > band       -- in the space the panel would use
					and c.bottom < lowest then
					lowest = c.bottom
				end
			end
		end
	end
	scan(form)
	scan(type(form.GetParent) == "function" and form:GetParent() or nil)
	return lowest, fr
end

-- The profession window itself: the last ancestor of `form` below UIParent.
local function OuterFrame(form)
	local f = form
	for _ = 1, 10 do
		local parent = type(f.GetParent) == "function" and f:GetParent() or nil
		if not parent or parent == UIParent then break end
		f = parent
	end
	return f
end

-- Reagent prices go in a right-aligned column on the name's row when every shown slot has at least
-- REAGENT_COLUMN_MIN px between its name box and the column edge (the profit panel's right edge) with no
-- other slot in the way. Otherwise, or before layout, all of them go below the name. All slots use the same
-- mode so the prices line up.
local REAGENT_COLUMN_MIN, REAGENT_COLUMN_GAP = 80, 8

function UI:PlaceSlotLines(form)
	local slots = {}
	for _, slot in ipairs(BasicSlots(form)) do
		if slot.cpPrice and Visible(slot) then slots[#slots + 1] = slot end
	end
	local fr = Rect(form)
	local plan = fr and fr.right and #slots > 0 and {} or nil
	if plan then
		local s = fr.scale
		local edge = fr.right - PanelRightInset(form) * s
		local rects = {}
		for i, slot in ipairs(slots) do
			local sr, nr = Rect(slot), slot.Name and Rect(slot.Name)
			if not (sr and sr.left and nr and nr.right) then plan = nil break end
			rects[i] = { slot = sr, name = nr }
		end
		for i = 1, plan and #slots or 0 do
			local sr, nr = rects[i].slot, rects[i].name
			local right = edge
			for j, other in ipairs(rects) do
				local o = other.slot
				if j ~= i and o.left > nr.right - 1 and o.top > sr.bottom + 1 and o.bottom < sr.top - 1 then
					right = math.min(right, o.left - REAGENT_COLUMN_GAP * s)
				end
			end
			local room = (right - nr.right) / s - REAGENT_COLUMN_GAP
			if room < REAGENT_COLUMN_MIN then plan = nil break end
			plan[i] = { x = math.floor((right - sr.left) / s + 0.5), w = math.floor(room) }
		end
	end
	for i, slot in ipairs(slots) do
		slot.cpColumn = plan and plan[i] or nil
		PlaceSlotLine(slot)
	end
end

local DOCK_ART_ATLAS = "Profession-Background-Template2"
local DOCK_ART_TOP, DOCK_ART_INSET = 21, 3 -- where the profession window starts its art (TOPLEFT 3, -21)

-- Show the part of the background art the window would show at this spot: its bottom-right corner when
-- docked below (the recipe pane's side), its top-right when docked right. When the art is smaller than the
-- window it is stretched instead.
local function PaintDock(f, side)
	local art, info = f.cpArt, f.cpArtInfo
	if not art then return end
	local w = (f:GetWidth() or 0) - 2 * DOCK_ART_INSET
	local h = (f:GetHeight() or 0) - DOCK_ART_TOP - DOCK_ART_INSET
	local L, R = info.leftTexCoord or 0, info.rightTexCoord or 1
	local T, B = info.topTexCoord or 0, info.bottomTexCoord or 1
	local W, H = info.width or 0, info.height or 0
	if W <= 0 or H <= 0 or w <= 0 or h <= 0 then return end
	local u0 = R - (R - L) * math.min(1, w / W)
	local v0, v1 = T, T + (B - T) * math.min(1, h / H)
	if side ~= "right" then v0, v1 = B - (B - T) * math.min(1, h / H), B end
	art:SetTexCoord(u0, R, v0, v1)
end

-- The window a docked panel sits in: DefaultPanelFlatTemplate, the template of Blizzard's own crafting output
-- log next to the profession window on Forever (ScrollingFlatPanelTemplate inherits it), with older
-- templates as fallbacks. Created on first dock, child of the form so it hides with it. One per panel
-- (companion addons get their own), titled p.cpDockTitle (default "CraftProfit"). Shared as UI.DockFrame.
local function DockFrame(p, form)
	if p.cpDock then return p.cpDock end
	local name = type(p.GetName) == "function" and p:GetName() and (p:GetName() .. "Dock") or nil
	local dockTitle = p.cpDockTitle or "CraftProfit"
	local f
	for _, template in ipairs({ "DefaultPanelFlatTemplate", "DefaultPanelTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, frame = pcall(CreateFrame, "Frame", name, form, template)
		if ok and frame then f = frame break end
	end
	if not f then
		f = CreateFrame("Frame", name, form, BackdropTemplateMixin and "BackdropTemplate" or nil)
		if f.SetBackdrop then
			f:SetBackdrop({
				bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
				tile = true, tileSize = 32, edgeSize = 32,
				insets = { left = 11, right = 12, top = 12, bottom = 11 },
			})
		end
		f.TitleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		f.TitleText:SetPoint("TOP", 0, -14)
	end
	if f.PortraitContainer or f.portrait then -- ButtonFrameTemplate fallback
		if ButtonFrameTemplate_HidePortrait then pcall(ButtonFrameTemplate_HidePortrait, f) end
		if ButtonFrameTemplate_HideButtonBar then pcall(ButtonFrameTemplate_HideButtonBar, f) end
	end
	if f.CloseButton then f.CloseButton:Hide() end
	if f.Inset then f.Inset:Hide() end -- the panel draws on the window's own background, like the output log
	local title = (f.TitleContainer and f.TitleContainer.TitleText) or f.TitleText
	if title then title:SetText(dockTitle) elseif f.SetTitle then pcall(f.SetTitle, f, dockTitle) end
	f:EnableMouse(true)

	-- The profession window's own art (Forever: CraftingPage paints Profession-Background-Template2 at its atlas
	-- size), with the recipe pane's inset border around the content. Cropped, not stretched: see PaintDock.
	local art = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	art:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_ART_INSET, -DOCK_ART_TOP)
	art:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -DOCK_ART_INSET, DOCK_ART_INSET)
	local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(DOCK_ART_ATLAS)
	if info and art.SetAtlas and pcall(art.SetAtlas, art, DOCK_ART_ATLAS) then
		f.cpArt, f.cpArtInfo = art, info
		if f.Bg then f.Bg:Hide() end -- the flat panel's plain (and on Forever see-through) background
	else
		art:Hide()
	end
	local okNs, ns = pcall(CreateFrame, "Frame", nil, f, "NineSlicePanelTemplate")
	if okNs and ns and NineSliceUtil and NineSliceUtil.ApplyLayoutByName
		and pcall(NineSliceUtil.ApplyLayoutByName, ns, "InsetFrameTemplate") then
		ns:SetPoint("TOPLEFT", f, "TOPLEFT", DOCK_PAD - 6, -(DOCK_TOP - 6))
		ns:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(DOCK_PAD - 6), DOCK_BOTTOM - 6)
		f.cpInset = ns
	elseif okNs and ns then
		ns:Hide()
	end

	f:Hide()
	p.cpDock = f
	return f
end
UI.DockFrame = DockFrame

-- Puts panel `p` (a child of `form`) below everything in the reagent area, at most `designHeight` tall.
-- Returns false when the form is not laid out yet (the caller then uses its own fallback). Shared with
-- companion addons as UI.PlaceBelowContent.
--
-- With opts.modes the panel never reaches below the top of the Track Recipe row (so it cannot cover the
-- Create button): it is "full" when PANEL_MIN_HEIGHT fits, a one-line "strip" when only that fits, and
-- otherwise "dock"ed under the profession window at the full design height (inside opts.dockFrame(p, form)
-- when given: p is re-parented into it). The mode is returned and kept in p.cpMode. Without opts the old behaviour stays (the smallest panel may dip into the band).
local function PlaceBelowContent(p, form, designHeight, opts)
	local lowest, fr = ContentBottom(p, form)
	if not lowest then
		p.cpGeometry = nil
		return false
	end
	local s = fr.scale
	local design = designHeight or PANEL_HEIGHT
	local offset = (fr.top - lowest) / s + PANEL_GAP
	local room = (fr.top - fr.bottom) / s - offset - PANEL_BOTTOM
	local mode, height = "full", math.min(design, room)
	if opts and opts.modes then
		if room < PANEL_MIN_HEIGHT then
			mode = room >= PANEL_STRIP_HEIGHT and "strip" or "dock"
			height = mode == "strip" and PANEL_STRIP_HEIGHT or design
		end
	elseif height < PANEL_MIN_HEIGHT then
		height = math.min(PANEL_MIN_HEIGHT, room + PANEL_BOTTOM - PANEL_FLOOR)
	end
	height = math.floor(height + 0.5)

	local outer, dockX, dockY, dockWidth, dock, side
	if mode == "dock" then
		outer = OuterFrame(form)
		local orr = outer ~= form and Rect(outer)
		if not (orr and orr.left) then
			outer, orr = form, fr -- nothing measurable around the form: hang under the form itself
		end
		dock = opts.dockFrame and opts.dockFrame(p, form) or nil
		if dock then
			-- below: the window spans the recipe pane. right: beside the window, top aligned with the pane,
			-- clear of the profession tabs on its right edge. Below switches to the right (and the other way)
			-- when it would leave the screen.
			local tall = (height + DOCK_TOP + DOCK_BOTTOM + PANEL_DOCK_GAP) * s
			local tabsRight = orr.right
			for _, tab in ipairs(type(outer.rightProfessionTabs) == "table" and outer.rightProfessionTabs or {}) do
				local r = Visible(tab) and Rect(tab)
				if r and r.right and r.right > tabsRight then tabsRight = r.right end
			end
			local rightX = (tabsRight - orr.right) / s + (tabsRight > orr.right and 4 or DOCK_RIGHT_GAP)
			local screen = UIParent and Rect(UIParent)
			side = opts.side == "right" and "right" or "below"
			if screen and screen.right then
				local belowFits = orr.bottom - tall >= screen.bottom
				local rightFits = orr.right + (rightX + DOCK_RIGHT_WIDTH) * s <= screen.right
				if side == "below" and not belowFits and rightFits then side = "right" end
				if side == "right" and not rightFits and belowFits then side = "below" end
			end
			if side == "right" then
				dockX = math.floor(rightX + 0.5)
				dockY = math.floor((fr.top - orr.top) / s + 0.5)
				dockWidth = DOCK_RIGHT_WIDTH
			else
				dockX = math.floor((fr.left - orr.left) / s + 0.5)
				dockWidth = math.floor((fr.right - fr.left) / s + 0.5)
			end
		else
			dockX = math.floor((fr.left - orr.left) / s + PANEL_INSET + 0.5)
			dockWidth = math.floor((fr.right - fr.left) / s - PANEL_INSET - PanelRightInset(form) + 0.5)
		end
	end

	local g = p.cpGeometry
	if g and g.mode == mode and math.abs(g.offset - offset) < 0.5 and g.height == height and g.side == side
		and (not dock or dock:IsShown()) then
		return true, mode -- already there; avoid re-anchoring every frame while settling
	end
	p.cpGeometry = { offset = offset, height = height, mode = mode, room = room, side = side }
	p.cpMode = mode
	p:ClearAllPoints()
	if not dock and p.cpDock then -- back inside the recipe pane
		p.cpDock:Hide()
		if p:GetParent() ~= form then
			p:SetParent(form)
			p:SetFrameLevel(form:GetFrameLevel() + 5)
		end
	end
	if dock then
		dock:ClearAllPoints()
		if side == "right" then
			dock:SetPoint("TOPLEFT", outer, "TOPRIGHT", dockX, dockY)
		else
			dock:SetPoint("TOPLEFT", outer, "BOTTOMLEFT", dockX, -PANEL_DOCK_GAP)
		end
		dock:SetSize(dockWidth, height + DOCK_TOP + DOCK_BOTTOM)
		PaintDock(dock, side)
		dock:Show()
		-- Above the profession window's border (its NineSlice sits at a high frame level), so where the two
		-- borders meet ours is not drawn underneath. Children follow: inset +1, panel +5, title +10.
		local top = type(outer.GetFrameLevel) == "function" and outer:GetFrameLevel() or 0
		local ns = outer.NineSlice
		if ns and type(ns.GetFrameLevel) == "function" then top = math.max(top, ns:GetFrameLevel()) end
		if dock:GetFrameLevel() <= top then
			dock:SetFrameLevel(top + 1)
			if dock.NineSlice then dock.NineSlice:SetFrameLevel(top + 2) end
			if dock.cpInset then dock.cpInset:SetFrameLevel(top + 2) end
			if dock.TitleContainer then dock.TitleContainer:SetFrameLevel(top + 12) end
		end
		if p:GetParent() ~= dock then p:SetParent(dock) end
		p:SetFrameLevel(dock:GetFrameLevel() + 5)
		if not p.cpDockHooked and type(p.HookScript) == "function" then
			-- the panel hidden (no recipe, Sell <-> Shuffle, option off) takes its window with it
			p.cpDockHooked = true
			p:HookScript("OnHide", function(self)
				if self.cpDock and self:GetParent() == self.cpDock then self.cpDock:Hide() end
			end)
		end
		p:SetPoint("TOPLEFT", dock, "TOPLEFT", DOCK_PAD, -DOCK_TOP)
		p:SetSize(dockWidth - 2 * DOCK_PAD, height)
	elseif mode == "dock" then
		p:SetPoint("TOPLEFT", outer, "BOTTOMLEFT", dockX, -PANEL_DOCK_GAP)
		p:SetSize(dockWidth, height)
	else
		p:SetPoint("TOPLEFT", form, "TOPLEFT", PANEL_INSET, -offset)
		p:SetPoint("RIGHT", form, "RIGHT", -PanelRightInset(form), 0)
		p:SetHeight(height)
	end
	return true, mode
end
UI.PlaceBelowContent = PlaceBelowContent

-- Re-check the placement for a short while after a recipe is shown: other addons place their rows after
-- the form's Init (ForeverRecipes on the next frame, and again on its own refreshes). `anchor(p, form)` is
-- the panel's own placement function. Shared with companion addons as UI.SettlePanel.
local function SettlePanel(p, form, anchor)
	p.cpSettleUntil = GetTime() + SETTLE_TIME
	p.cpSettleAnchor = anchor
	if p.cpSettling then return end
	p.cpSettling = true
	p:SetScript("OnUpdate", function(self)
		if not self:IsShown() or GetTime() > (self.cpSettleUntil or 0) then
			self.cpSettling = false
			self:SetScript("OnUpdate", nil)
			return
		end
		self.cpSettleAnchor(self, form)
	end)
end
UI.SettlePanel = SettlePanel

local function AnchorPanel(p, form)
	local wasMode = p.cpMode
	UI:PlaceSlotLines(form) -- reagents may have moved (ForeverRecipes re-lays them out after us)
	if PlaceBelowContent(p, form, PANEL_HEIGHT, { modes = true, dockFrame = DockFrame, side = CP.settings.panelDock }) then
		p.cpStretch = false
		p.cpAnchor = nil
		-- strip <-> full at the same height does not fire OnSizeChanged
		if p.cpMode ~= wasMode then p:cpLayout() end
		return
	end
	p.cpMode = "full"
	if p.cpDock and p.cpDock:IsShown() then -- not measurable: back into the pane
		p.cpDock:Hide()
		p:SetParent(form)
		p:SetFrameLevel(form:GetFrameLevel() + 5)
	end

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

-- Header right side: "scanned 3h ago", or "Auctionator · 3h" for another source. When that does not fit
-- between the title and Shop, the source name goes (the panel tooltip names it).
local function FitHeader(p)
	local full, short = p.cpAgeFull or "", p.cpAgeShort or p.cpAgeFull or ""
	local title = type(p.Title.GetStringWidth) == "function" and p.Title:GetStringWidth() or 0
	local room = (p:GetWidth() or PANEL_MAX_WIDTH) - title - 8 - 6 - 44
	p.Age:SetText(full)
	if full ~= short and type(p.Age.GetStringWidth) == "function" and p.Age:GetStringWidth() > room then
		p.Age:SetText(short)
	end
end

local function SetStripMode(p, strip)
	p.ShopButton:ClearAllPoints()
	if strip then
		p.ShopButton:SetPoint("RIGHT", p, "RIGHT", 0, 0)
	else
		p.ShopButton:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
	end
	p.Title:SetShown(not strip)
	p.Age:SetShown(not strip)
end

-- Laid out like the default UI's own sections in the recipe pane ("Reagents:", "Optional Target:"): a gold
-- section label, then plain rows on the pane's background, no box. Inside the docked window the same.
-- Shows as many stat rows as the height allows; the checkboxes only once all four rows fit.
-- A "strip" panel (see PlaceBelowContent) is one line: Net profit, value, Shop.
local PANEL_HEADER_H = 24
local function LayoutPanel(p)
	if CapPanelHeight(p) then return end
	if p.cpMode == "strip" then
		SetStripMode(p, true)
		for _, fs in ipairs({ p.CostLabel, p.Cost, p.SaleLabel, p.Sale, p.AltLabel, p.Alt, p.SoldLabel, p.Sold }) do fs:Hide() end
		p.Divider:Hide()
		p.NetLabel:ClearAllPoints()
		p.NetLabel:SetPoint("LEFT", p, "LEFT", 0, 0)
		p.Net:ClearAllPoints()
		p.Net:SetPoint("RIGHT", p.ShopButton, "LEFT", -8, 0)
		p.SortCheck:Hide()
		p.CraftCheck:Hide()
		p.VendorCheck:Hide()
		p.cpStatsShown = 0
		return
	end
	SetStripMode(p, false)
	FitHeader(p)
	local h = p:GetHeight() or PANEL_HEIGHT
	local fixed = PANEL_HEADER_H + 8 + 18 + 2 -- section label, divider gap, net row, bottom
	local rows = { { p.CostLabel, p.Cost }, { p.SaleLabel, p.Sale }, { p.AltLabel, p.Alt }, { p.SoldLabel, p.Sold } }
	local nStats = math.floor((h - fixed) / STAT_ROW_H)
	if nStats < 0 then nStats = 0 end
	if nStats > #rows then nStats = #rows end
	local showChecks = nStats == #rows and h >= fixed + #rows * STAT_ROW_H + 26

	for i, row in ipairs(rows) do
		local shown = i <= nStats
		local y = -PANEL_HEADER_H - (i - 1) * STAT_ROW_H
		row[1]:ClearAllPoints()
		row[1]:SetPoint("TOPLEFT", 0, y)
		row[2]:ClearAllPoints()
		row[2]:SetPoint("TOPRIGHT", 0, y)
		row[1]:SetShown(shown)
		row[2]:SetShown(shown)
	end

	local y = -PANEL_HEADER_H - nStats * STAT_ROW_H + 3
	p.Divider:ClearAllPoints()
	p.Divider:SetPoint("TOPLEFT", 0, y)
	p.Divider:SetPoint("TOPRIGHT", 0, y)
	p.Divider:SetShown(nStats > 0)
	p.NetLabel:ClearAllPoints()
	p.NetLabel:SetPoint("TOPLEFT", 0, y - 7)
	p.Net:ClearAllPoints()
	p.Net:SetPoint("TOPRIGHT", 0, y - 5)

	p.SortCheck:SetShown(showChecks)
	p.CraftCheck:SetShown(showChecks)
	p.VendorCheck:SetShown(showChecks)
	p.cpStatsShown = nStats
end

local function CreatePanel(form)
	local p = CreateFrame("Frame", "CraftProfitPanel", form)
	p:SetSize(PANEL_MAX_WIDTH, PANEL_HEIGHT)
	p:SetFrameLevel(form:GetFrameLevel() + 5)

	-- CraftingPage:Init() runs SchematicForm:Init() (our hook) before CraftingPage:Refresh() applies the
	-- final form width, so on first open we measure the retail default. Re-anchor whenever the form resizes.
	if type(form.HookScript) == "function" then
		form:HookScript("OnSizeChanged", function(f)
			if f.cpPanel and f.cpPanel:IsShown() then
				f.cpPanel.cpGeometry = nil
				AnchorPanel(f.cpPanel, f)
			end
		end)
	end
	p:SetScript("OnSizeChanged", function(self) LayoutPanel(self) end)
	p.cpLayout = LayoutPanel

	-- no box: the pane's (or the docked window's) own background, like the default sections above it
	p.Title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	p.Title:SetPoint("TOPLEFT", 0, -3)
	p.Title:SetText("Profit (Auction House):")

	-- Scan age (and the source when it is not our own scan) on the header's right side. Anchored to
	-- both the title and the right edge so it clips instead of overlapping the title when narrow.
	-- "Shop": adds this recipe (times Blizzard's craft count) to the AH shopping list (Shopping.lua).
	p.ShopButton = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
	p.ShopButton:SetSize(44, 18)
	p.ShopButton:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
	p.ShopButton:SetText("Shop")
	if p.ShopButton.RegisterForClicks then p.ShopButton:RegisterForClicks("LeftButtonUp", "RightButtonUp") end
	p.ShopButton:SetScript("OnClick", function(self, button) UI:ShopClicked(self, button) end)
	p.ShopButton:SetScript("OnEnter", function(self) UI:ShopTooltip(self) end)
	p.ShopButton:SetScript("OnLeave", GameTooltip_Hide)

	p.Age = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	p.Age:SetPoint("LEFT", p.Title, "RIGHT", 8, -1)
	p.Age:SetPoint("RIGHT", p.ShopButton, "LEFT", -6, 0)
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
	p.SortCheck:SetPoint("BOTTOMLEFT", -4, -2) -- the checkbox art has ~4px padding: line the box up with the text
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
		if eco.soldSource and eco.soldSource ~= eco.source then
			local def = CP.Sources:Get(eco.soldSource)
			GameTooltip:AddLine("Sold per day: " .. (def and def.name or eco.soldSource), 1, 1, 1)
		end
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

-- How many crafts "Shop" adds: Blizzard's craft-count box under the recipe, at least 1.
local function CraftCount()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local box = page and page.CreateMultipleInputBox
	local n = box and type(box.GetValue) == "function" and tonumber(box:GetValue())
	if not n or n < 1 then n = 1 end
	return math.floor(n)
end

function UI:ShopClicked(button, mouse)
	local p = button:GetParent()
	local info = p and p.cpRecipeInfo
	local shop = CP.Shopping
	if not (info and info.recipeID and shop) then return end
	local name = info.name or ("Recipe " .. info.recipeID)
	if mouse == "RightButton" then
		if shop:Crafts(info.recipeID) > 0 then
			shop:Remove(info.recipeID)
			CP:Print("%s taken off the shopping list.", name)
		end
	else
		local crafts = CraftCount()
		local total = shop:Add(info.recipeID, crafts, name)
		CP:Print("Shopping list: %s x%d%s. Open the Auction House to buy the reagents.", name, total,
			total > crafts and string.format(" (+%d)", crafts) or "")
	end
	if type(GameTooltip.IsOwned) == "function" and GameTooltip:IsOwned(button) then self:ShopTooltip(button) end
end

function UI:ShopTooltip(button)
	local p = button:GetParent()
	local info = p and p.cpRecipeInfo
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:AddLine("Add to shopping list")
	local n = CraftCount()
	GameTooltip:AddLine(string.format("Adds %d craft%s of this recipe. At the Auction House, CraftProfit lists the reagents you still need and searches for them.",
		n, n == 1 and "" or "s"), 1, 1, 1, true)
	local have = info and CP.Shopping and CP.Shopping:Crafts(info.recipeID) or 0
	if have > 0 then
		GameTooltip:AddLine(string.format("On the list: %d crafts. Right-click to take it off.", have), 1, 0.82, 0, true)
	end
	GameTooltip:AddLine("Set the craft count in the box next to Create.", 0.6, 0.6, 0.6, true)
	GameTooltip:Show()
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
	p.cpRecipeInfo = recipeInfo
	p.cpGeometry = nil -- new recipe: measure again
	AnchorPanel(p, form)
	LayoutPanel(p)
	p:Show()
	SettlePanel(p, form, AnchorPanel)

	local ageText = eco.age and ("scanned " .. CP:FormatAge(eco.age)) or "no price data"
	local shortText = ageText
	local source = CP.Sources:Resolve()
	if source and source.key ~= "craftprofit" then
		shortText = eco.age and CP:FormatAge(eco.age) or "no data"
		ageText = source.name .. " \194\183 " .. shortText
	end
	p.cpAgeFull, p.cpAgeShort = ageText, shortText

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
	p.Title:SetText(vendorLead and "Profit (Vendor):" or "Profit (Auction House):")
	FitHeader(p)

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

-- Shows only recipes with a known net above zero (the one the row tag shows):
--   * Recipe rows that lose or break even are hidden, and so are recipes without a net (a reagent or the
--     output has no price, or nothing sellable is made): an unknown result is not shown as profitable.
--   * Rows are taken out of the list Blizzard built with the tree's own node:Remove (no invalidation per
--     node; the provider is invalidated once at the end). A category left without recipes also loses its
--     padding rows; a category left with nothing loses its header; the unlearned divider goes when no
--     unlearned category is left. Only what this filter emptied is removed, never anything Blizzard kept.
--   * The removed nodes are remembered for the list on screen and put back first on every pass (the same node
--     objects, so children and collapse state survive). So new prices, the AH / vendor basis, an override
--     and turning the filter off all work on the list that is on screen.
--   * We never call Blizzard's page or list Init (see "Sort by profit").

-- Only the list on screen is remembered: Blizzard builds a new provider for every rebuild and drops the old
-- one, so state for an older provider is simply forgotten (a weak table would not free it: the nodes point
-- back at their provider).
local hiddenFor, hiddenList -- data provider, { { parent, node, index }, ... }

-- Puts every node the filter took out of `dataProvider` back. Returns the nodes that were hidden (a set) or nil.
local function RestoreHidden(dataProvider)
	local hidden = hiddenFor == dataProvider and hiddenList or nil
	hiddenFor, hiddenList = nil, nil
	if not hidden then return nil end
	local was, parents = {}, {}
	for i = #hidden, 1, -1 do -- reverse order: a header goes back before the rows that were taken out of it
		local h = hidden[i]
		local nodes = h.parent:GetNodes()
		table.insert(nodes, math.min(h.index, #nodes + 1), h.node)
		parents[h.parent] = true
		was[h.node] = true
	end
	-- The parent's own comparator (Blizzard's, or ours while sorting by profit) puts them back in place.
	for parent in pairs(parents) do
		if parent.sortComparator then table.sort(parent:GetNodes(), parent.sortComparator) end
	end
	return was
end

local function FilteredOut(data)
	local net = UI:GetNet(data.recipeInfo.recipeID)
	return net == nil or net <= 0
end

local function Hide(parent, child, hidden)
	for index, n in ipairs(parent:GetNodes()) do
		if n == child then
			parent:Remove(child, true) -- TreeNodeMixin:Remove(node, skipInvalidation)
			hidden[#hidden + 1] = { parent = parent, node = child, index = index }
			return
		end
	end
end

-- Hides the losing recipes under `node` (the root or a category), depth first. Returns whether the node still
-- shows a recipe, and whether this filter removed anything below it.
local function FilterNode(node, hidden)
	local drop, paddings = {}, {}
	local hasRecipe, hasCategory, removed = false, false, false
	for _, child in ipairs(node:GetNodes() or {}) do
		local d = NodeData(child)
		if d and d.categoryInfo then
			local shows, sub = FilterNode(child, hidden)
			removed = removed or sub
			if shows or not sub then hasCategory = true else drop[#drop + 1] = child end
		elseif d and d.recipeInfo and d.recipeInfo.recipeID then
			if FilteredOut(d) then drop[#drop + 1] = child else hasRecipe = true end
		elseif d and (d.topPadding or d.bottomPadding) then
			paddings[#paddings + 1] = child
		end
	end
	if #drop > 0 then removed = true end
	if removed and not hasRecipe then
		for _, p in ipairs(paddings) do drop[#drop + 1] = p end
	end
	for _, child in ipairs(drop) do Hide(node, child, hidden) end
	return hasRecipe or hasCategory, removed
end

-- Applies (or removes) the filter on a recipe list data provider. Returns true when the visible rows changed.
function UI:ApplyFilter(dataProvider)
	if not dataProvider then return false end
	local want = CP.settings.profitableOnly and true or false
	if not want and hiddenFor ~= dataProvider then return false end
	if type(dataProvider.GetRootNode) ~= "function" then return false end
	local changed = false
	local ok, err = pcall(function()
		local was = RestoreHidden(dataProvider)
		local hidden = {}
		if want then
			hiddenFor, hiddenList = dataProvider, hidden -- recorded as we go, so an error cannot lose rows
			local root = dataProvider:GetRootNode()
			local _, removed = FilterNode(root, hidden)
			-- the unlearned divider only makes sense above an unlearned category
			if removed then
				local divider, unlearned
				for _, child in ipairs(root:GetNodes() or {}) do
					local d = NodeData(child)
					if d and d.isDivider then divider = child end
					if d and d.categoryInfo and d.categoryInfo.unlearned then unlearned = true end
				end
				if divider and not unlearned then Hide(root, divider, hidden) end
			end
		end
		if #hidden == 0 then hiddenFor, hiddenList = nil, nil end
		-- changed unless exactly the same rows were hidden again
		local same = (was ~= nil) == (#hidden > 0)
		if same and was then
			local n = 0
			for _ in pairs(was) do n = n + 1 end
			same = n == #hidden
			for _, h in ipairs(hidden) do
				if not was[h.node] then same = false break end
			end
		end
		changed = not same
	end)
	if not ok then CP:Debug("filter failed: %s", tostring(err)) end
	if changed and type(dataProvider.Invalidate) == "function" then
		local ok2, err2 = pcall(dataProvider.Invalidate, dataProvider)
		if not ok2 then CP:Debug("filter refresh failed: %s", tostring(err2)) end
	end
	return changed
end

-- Re-filters the list that is on screen (no rebuild).
function UI:RefilterList()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local list = page and page.RecipeList
	local scrollBox = list and list.ScrollBox
	if not scrollBox or type(scrollBox.GetDataProvider) ~= "function" then return false end
	local dataProvider = scrollBox:GetDataProvider()
	if not self:ApplyFilter(dataProvider) then return false end
	-- rows that came back may carry the other comparator if the sort was toggled while they were hidden
	self:ApplySort(dataProvider)
	if list.NoResultsText and type(dataProvider.IsEmpty) == "function" then
		list.NoResultsText:SetShown(dataProvider:IsEmpty())
	end
	return true
end

function UI:SetProfitableOnly(enabled)
	CP.settings.profitableOnly = enabled and true or false
	CP.touched.profitableOnly = true -- keep the choice if a late-loaded database is adopted
	self:RefilterList()
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
		-- prices changed: re-filter (hidden rows come back when they no longer lose), then re-sort
		if type(list.ScrollBox.GetDataProvider) == "function" then
			if not self:RefilterList() and CP.settings.sortByProfit then
				self:ApplySort(list.ScrollBox:GetDataProvider())
			end
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
