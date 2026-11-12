-- CraftProfit :: Shopping
-- A shopping list of recipes to craft. "Shop" in the profit panel adds the selected recipe (times the
-- craft count in Blizzard's quantity box); at the Auction House a side panel lists every reagent the
-- list needs, how many you already have (bags + bank) and what the rest costs at the scanned listings.
-- "Search all" puts every missing reagent into the AH's own results list in one search (like Blizzard's
-- Favorites); clicking a row searches just that item.
-- Stored account-wide in CraftProfitDB.shopping = { [recipeID] = { n = crafts, name = recipe name } }, so a
-- bank alt can buy for the crafter.
-- AH purchases go to the mailbox, so they count as "in the mail" until collected: each recorded purchase
-- (Scanner's PURCHASE_RECORDED) adds to CraftProfitDB.shoppingMail[charKey][itemID], and whenever the inbox
-- is open the count is replaced by what the inbox actually holds.

local _, CP = ...
local Shop = {}
CP.Shopping = Shop

local C = CP.COLORS
local WIDTH, PAD = 360, 8
local ROWS, ROW_H = 16, 20
local LIST_TOP, HEADER_H = -78, 19
local FOOTER_H = 60
local RECIPE_LINES = 3
local PORTRAIT_ICON = "Interface\\Icons\\INV_Misc_Note_01"
-- Item | Have | Need | Cost (0 = the item column takes the rest)
local COLS = { { "Item", 0, "LEFT" }, { "Have", 44, "RIGHT" }, { "Need", 40, "RIGHT" }, { "Cost", 96, "RIGHT" } }

local function List()
	if not CP.db then return {} end
	CP.db.shopping = CP.db.shopping or {}
	return CP.db.shopping
end

local function ItemName(itemID)
	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
	if not name and GetItemInfo then name = GetItemInfo(itemID) end
	return name
end

local function ItemIcon(itemID)
	if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(itemID) end
	if GetItemIcon then return GetItemIcon(itemID) end
	return nil
end

-- Bags + bank (+ reagent bank where the client has one).
local function Owned(itemID)
	local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID, true, false, true)
	if count == nil and GetItemCount then count = GetItemCount(itemID, true) end
	return count or 0
end
Shop.Owned = Owned

-- Items bought at the AH and not yet taken from the mailbox, for this character.
local function MailDB()
	if not CP.db then return {} end
	CP.db.shoppingMail = CP.db.shoppingMail or {}
	local key = CP:GetCharKey()
	CP.db.shoppingMail[key] = CP.db.shoppingMail[key] or {}
	return CP.db.shoppingMail[key]
end

function Shop:InMail(itemID)
	return MailDB()[itemID] or 0
end

---------------------------------------------------------------------------
-- List model
---------------------------------------------------------------------------

function Shop:Add(recipeID, crafts, name)
	if not recipeID then return end
	crafts = math.max(1, math.floor(tonumber(crafts) or 1))
	local list = List()
	local e = list[recipeID] or { n = 0 }
	e.n = e.n + crafts
	e.name = name or e.name
	list[recipeID] = e
	CP:Fire("SHOPPING_CHANGED")
	return e.n
end

function Shop:Remove(recipeID)
	local list = List()
	if not list[recipeID] then return end
	list[recipeID] = nil
	CP:Fire("SHOPPING_CHANGED")
end

function Shop:Clear()
	wipe(List())
	wipe(MailDB())
	CP:Fire("SHOPPING_CHANGED")
end

function Shop:Crafts(recipeID)
	local e = List()[recipeID]
	return e and e.n or 0
end

-- Recipes on the list, sorted by name: { recipeID, n, name }.
function Shop:Recipes()
	local out = {}
	for recipeID, e in pairs(List()) do
		out[#out + 1] = { recipeID = recipeID, n = e.n, name = e.name or ("Recipe " .. recipeID) }
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

function Shop:IsEmpty()
	return next(List()) == nil
end

-- Every reagent the list needs: { itemID, name, need, have, missing, vendor, cost, costInfo }, sorted with
-- the items still to buy first (AH before vendor), then by name. `cost` = what `missing` costs at the
-- scanned listings (nil without a price); vendor items are bought from a merchant, not searched.
function Shop:Items()
	local byID, order = {}, {}
	for recipeID, e in pairs(List()) do
		local eco = CP.Calc and CP.Calc:Get(recipeID)
		for _, r in ipairs(eco and eco.reagents or {}) do
			if r.itemID and not r.isCurrency then
				local it = byID[r.itemID]
				if not it then
					it = { itemID = r.itemID, need = 0, vendor = false }
					byID[r.itemID] = it
					order[#order + 1] = it
				end
				it.need = it.need + (r.qty or 1) * e.n
				if r.kind == "vendor" then it.vendor = true end
			end
		end
	end
	local scanner = CP.Scanner
	for _, it in ipairs(order) do
		it.name = ItemName(it.itemID) or ("Item " .. it.itemID)
		it.have = Owned(it.itemID)
		it.mail = Shop:InMail(it.itemID)
		it.missing = math.max(0, it.need - it.have - it.mail)
		if it.missing > 0 and not it.vendor and scanner and scanner.GetBuyCost then
			it.cost, _, it.costInfo = scanner:GetBuyCost(it.itemID, it.missing)
		elseif it.missing > 0 and it.vendor and CP.Vendor and CP.Vendor.GetPrice then
			local unit = CP.Vendor:GetPrice(it.itemID)
			it.cost = unit and unit * it.missing or nil
		end
	end
	local function rank(it)
		if it.missing == 0 then return 3 end
		return it.vendor and 2 or 1
	end
	table.sort(order, function(a, b)
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then return ra < rb end
		return a.name < b.name
	end)
	return order
end

-- Total cost of everything still missing; `complete` is false when an item has no price.
function Shop:TotalCost(items)
	local total, complete = 0, true
	for _, it in ipairs(items or self:Items()) do
		if it.missing > 0 then
			if it.cost then total = total + it.cost else complete = false end
		end
	end
	return total, complete
end

---------------------------------------------------------------------------
-- Auction House search
---------------------------------------------------------------------------

local function ShowBuyTab(ah)
	local modes = AuctionHouseFrameDisplayMode
	if modes and modes.Buy and ah.displayMode ~= modes.Buy and type(ah.SetDisplayMode) == "function" then
		pcall(ah.SetDisplayMode, ah, modes.Buy)
	end
end

-- Searches the AH for one item through Blizzard's own search bar (so results, sorting and buying work
-- exactly as when you type the name). Returns true when the search was started.
function Shop:Search(itemID)
	local ah = AuctionHouseFrame
	if not (ah and ah:IsShown()) then return false end
	local name = ItemName(itemID)
	local bar = ah.SearchBar
	local box = bar and bar.SearchBox
	if not (name and box and type(box.SetText) == "function" and type(bar.StartSearch) == "function") then return false end
	ShowBuyTab(ah) -- the search bar lives on the Buy tab; leave a buy/sell page first
	box:SetText(name)
	local ok = pcall(bar.StartSearch, bar)
	self.lastSearched = itemID
	self.searchedAll = false
	if self.frame then self:Refresh() end
	return ok
end

-- The AH items still to buy (vendor items and finished ones left out).
function Shop:ToBuy(items)
	local todo = {}
	for _, it in ipairs(items or self:Items()) do
		if it.missing > 0 and not it.vendor then todo[#todo + 1] = it end
	end
	return todo
end

-- One search for every reagent still to buy: the results fill the AH's own browse list, cheapest first,
-- and each result opens Blizzard's buy page as usual. Returns the number of items searched, or nil.
function Shop:SearchAll()
	local ah = AuctionHouseFrame
	if not (ah and ah:IsShown()) then return nil end
	if CP.Scanner and CP.Scanner.running then
		CP:Print("Wait for the CraftProfit scan to finish, then search again.")
		return nil
	end
	local todo = self:ToBuy()
	if #todo == 0 then return nil end
	local api = C_AuctionHouse and C_AuctionHouse.SearchForItemKeys
	if not api then
		-- client without multi-item search: search the first item by name
		return self:Search(todo[1].itemID) and 1 or nil
	end
	local keys = {}
	for _, it in ipairs(todo) do
		local key = CP.Scanner and CP.Scanner:GetItemKey(it.itemID)
		if key then keys[#keys + 1] = key end
	end
	if #keys == 0 then return nil end
	ShowBuyTab(ah)
	local results = ah.BrowseResultsFrame
	if results and type(results.Reset) == "function" then pcall(results.Reset, results) end
	local sorts = {}
	if Enum and Enum.AuctionHouseSortOrder then
		sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
	end
	local ok, err = pcall(api, keys, sorts)
	if not ok then
		CP:Debug("SearchForItemKeys failed: %s", tostring(err))
		return self:Search(todo[1].itemID) and 1 or nil
	end
	self.lastSearched = nil
	self.searchedAll = true
	if self.frame then self:Refresh() end
	return #keys
end

---------------------------------------------------------------------------
-- Mailbox: purchases waiting to be collected
---------------------------------------------------------------------------

local function NeededItems()
	local set = {}
	for recipeID in pairs(List()) do
		local eco = CP.Calc and CP.Calc:Get(recipeID)
		for _, r in ipairs(eco and eco.reagents or {}) do
			if r.itemID then set[r.itemID] = true end
		end
	end
	return set
end

-- A recorded AH purchase of an item on the list is in the mail until the inbox says otherwise.
function Shop:OnPurchase(itemID, quantity)
	if not (itemID and quantity and quantity > 0) or not NeededItems()[itemID] then return end
	local mail = MailDB()
	mail[itemID] = (mail[itemID] or 0) + quantity
	CP:Fire("SHOPPING_CHANGED")
end

-- With the mailbox open the inbox is the truth: count each listed item across all loaded mail. When the
-- server holds more mail than the client shows (over 50), items may hide in the unshown part, so a count
-- is only lowered when every mail is loaded.
function Shop:ReadInbox()
	if not (GetInboxNumItems and GetInboxItem) then return end
	local shown, total = GetInboxNumItems()
	shown, total = shown or 0, total or shown or 0
	local needed = NeededItems()
	local counts = {}
	local slots = ATTACHMENTS_MAX_RECEIVE or 16
	for i = 1, shown do
		for j = 1, slots do
			local _, itemID, _, count = GetInboxItem(i, j)
			if itemID and needed[itemID] then counts[itemID] = (counts[itemID] or 0) + (count or 1) end
		end
	end
	local mail = MailDB()
	local complete = total <= shown
	local changed = false
	for itemID in pairs(needed) do
		local now = counts[itemID] or 0
		local old = mail[itemID] or 0
		local new = complete and now or math.max(now, old)
		if new ~= old then
			mail[itemID] = new > 0 and new or nil
			changed = true
		end
	end
	for itemID in pairs(mail) do
		if not needed[itemID] then mail[itemID] = nil; changed = true end
	end
	if changed then CP:Fire("SHOPPING_CHANGED") end
end

CP:On("PURCHASE_RECORDED", function(itemID, quantity) Shop:OnPurchase(itemID, quantity) end)
CP:RegisterEvent("MAIL_INBOX_UPDATE", function()
	if MailFrame and MailFrame:IsShown() then Shop:ReadInbox() end
end)

---------------------------------------------------------------------------
-- Auction House window
---------------------------------------------------------------------------
-- Built like the AH itself: a portrait frame docked to the AH's right
-- edge, the recipes next to the portrait, then the AH's inset with its background art, column headers
-- and row highlight, and the buttons at the bottom.

local function Color(color, text) return CP:Color(color, text) end

local function Try(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

-- x / width of each column across the row; the item column flexes.
local function Layout()
	local rowW = WIDTH - 2 * PAD - 8
	local fixed = 0
	for _, c in ipairs(COLS) do fixed = fixed + c[2] end
	local x, w, cx = {}, {}, 0
	for i, c in ipairs(COLS) do
		w[i] = c[2] > 0 and c[2] or (rowW - fixed)
		x[i] = cx
		cx = cx + w[i]
	end
	return x, w
end

local function CreateHeader(area, i, x, w)
	local c = COLS[i]
	local ok, h = pcall(CreateFrame, "Button", nil, area, "AuctionHouseTableHeaderStringTemplate")
	if not ok or not h then
		h = CreateFrame("Button", nil, area)
		local fs = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetPoint("LEFT", h, "LEFT", 8, 0)
		h.Text = fs
	end
	if h.Arrow then h.Arrow:Hide() end
	h:SetScript("OnClick", nil) -- the template's click sorts an AH table; this list has its own order
	h:SetSize(w, HEADER_H)
	h:SetPoint("TOPLEFT", area, "TOPLEFT", x + 4, 0)
	if h.SetText then h:SetText(c[1]) end
	if h.Text and h.Text ~= h and h.Text.SetText then h.Text:SetText(c[1]) end
	return h
end

local function CreateRow(area, i, x, w)
	local row = CreateFrame("Button", nil, area)
	row:SetHeight(ROW_H)
	local y = -HEADER_H - 3 - (i - 1) * ROW_H
	row:SetPoint("TOPLEFT", area, "TOPLEFT", 4, y)
	row:SetPoint("TOPRIGHT", area, "TOPRIGHT", -4, y)
	local hl = row:CreateTexture(nil, "HIGHLIGHT")
	Try(hl, "SetAllPoints", row)
	if not (hl.SetAtlas and pcall(hl.SetAtlas, hl, "auctionhouse-ui-row-highlight")) then
		Try(hl, "SetColorTexture", 1, 1, 1, 0.08)
	end
	Try(hl, "SetBlendMode", "ADD")

	row.Icon = row:CreateTexture(nil, "ARTWORK")
	row.Icon:SetSize(16, 16)
	row.Icon:SetPoint("LEFT", row, "LEFT", 6, 0)
	Try(row.Icon, "SetTexCoord", 0.07, 0.93, 0.07, 0.93)
	row.Name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.Name:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)
	row.Name:SetJustifyH("LEFT")
	Try(row.Name, "SetWordWrap", false)
	Try(row.Name, "SetWidth", math.max(40, w[1] - 34))
	local function Cell(col)
		local l = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		l:SetJustifyH(COLS[col][3])
		Try(l, "SetWordWrap", false)
		l:SetPoint("LEFT", row, "LEFT", x[col] + 6, 0)
		Try(l, "SetWidth", math.max(8, w[col] - 12))
		return l
	end
	row.Have, row.Need, row.Cost = Cell(2), Cell(3), Cell(4)

	row:SetScript("OnClick", function(self)
		if self.item and not self.item.vendor then Shop:Search(self.item.itemID) end
	end)
	row:SetScript("OnEnter", function(self)
		local it = self.item
		if not it then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if GameTooltip.SetItemByID then GameTooltip:SetItemByID(it.itemID) else GameTooltip:AddLine(it.name) end
		GameTooltip:AddLine(" ")
		GameTooltip:AddDoubleLine("Needed", tostring(it.need), 0.8, 0.8, 0.8, 1, 1, 1)
		GameTooltip:AddDoubleLine("In your bags and bank", tostring(it.have), 0.8, 0.8, 0.8, 1, 1, 1)
		if it.mail > 0 then GameTooltip:AddDoubleLine("In the mail", tostring(it.mail), 0.8, 0.8, 0.8, 1, 1, 1) end
		if it.vendor then
			GameTooltip:AddLine("Sold by a vendor: buy it there.", 0.6, 0.6, 0.6, true)
		elseif it.missing > 0 then
			GameTooltip:AddLine("Click to search the Auction House for this item.", 1, 0.82, 0, true)
		end
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", GameTooltip_Hide)
	return row
end

local function RecipeLine(f, i)
	local b = f.RecipeLines[i]
	if b then return b end
	b = CreateFrame("Button", nil, f)
	b:SetHeight(14)
	b:SetPoint("TOPLEFT", f, "TOPLEFT", f.cpX0, -30 - (i - 1) * 14)
	b:SetPoint("RIGHT", f, "RIGHT", -PAD - 4, 0)
	b.Text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	b.Text:SetPoint("LEFT", b, "LEFT", 0, 0)
	b.Text:SetPoint("RIGHT", b, "RIGHT", 0, 0)
	b.Text:SetJustifyH("LEFT")
	Try(b.Text, "SetWordWrap", false)
	b:SetScript("OnClick", function(self) if self.recipeID then Shop:Remove(self.recipeID) end end)
	b:SetScript("OnEnter", function(self)
		if not self.recipeID then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.label or "")
		GameTooltip:AddLine("Click to take this recipe off the list.", 1, 0.82, 0)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	f.RecipeLines[i] = b
	return b
end

local function Tip(owner, title, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(title)
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", GameTooltip_Hide)
end

local function CreateWindow()
	local ah = AuctionHouseFrame
	if Shop.frame or not ah then return Shop.frame end
	local name = "CraftProfitShoppingFrame"
	local f
	for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset" }) do
		local ok, frame = pcall(CreateFrame, "Frame", name, ah, template)
		if ok and frame then f = frame break end
	end
	if not f then
		f = CreateFrame("Frame", name, ah, BackdropTemplateMixin and "BackdropTemplate" or nil)
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
		f.CloseButton = CreateFrame("Button", nil, f, "UIPanelCloseButton")
		f.CloseButton:SetPoint("TOPRIGHT", -4, -4)
	end
	if f.Inset and f.Inset.Hide then f.Inset:Hide() end
	local height = -LIST_TOP + HEADER_H + ROWS * ROW_H + 8 + FOOTER_H
	f:SetSize(WIDTH, height)
	f:SetPoint("TOPLEFT", ah, "TOPRIGHT", 4, 0)
	f:EnableMouse(true)
	local title = "Shopping list"
	if f.SetTitle then pcall(f.SetTitle, f, title) elseif f.TitleText then f.TitleText:SetText(title) end
	local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
	if f.SetPortraitToAsset then
		pcall(f.SetPortraitToAsset, f, PORTRAIT_ICON)
	elseif portrait and SetPortraitToTexture then
		pcall(SetPortraitToTexture, portrait, PORTRAIT_ICON)
	end
	f.cpX0 = portrait and 64 or 14
	if f.CloseButton then
		f.CloseButton:SetScript("OnClick", function() Shop.hidden = true; f:Hide(); Shop:UpdateToggle() end)
	end

	-- recipes on the list next to the portrait; click one to take it off
	f.RecipeLines = {}
	for i = 1, RECIPE_LINES do RecipeLine(f, i) end

	-- the list: AH column headers on the window background, the inset with the Buy tab's art under them
	local x, w = Layout()
	local area = CreateFrame("Frame", nil, f)
	area:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, LIST_TOP)
	area:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -PAD, FOOTER_H)
	f.ListArea = area
	local ok, box = pcall(CreateFrame, "Frame", nil, area, "InsetFrameTemplate")
	if ok and box then
		box:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -HEADER_H)
		box:SetPoint("BOTTOMRIGHT", area, "BOTTOMRIGHT", 0, 0)
		box:SetFrameLevel(area:GetFrameLevel())
		local art = box:CreateTexture(nil, "BACKGROUND", nil, 2)
		if art.SetAtlas and pcall(art.SetAtlas, art, "auctionhouse-background-index") then
			art:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
			art:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
		else
			art:Hide()
		end
		f.ListBox = box
	end
	f.Columns = {}
	for i = 1, #COLS do f.Columns[i] = CreateHeader(area, i, x[i], w[i]) end
	f.Rows = {}
	for i = 1, ROWS do f.Rows[i] = CreateRow(area, i, x, w) end
	f.offset = 0
	if f.EnableMouseWheel then f:EnableMouseWheel(true) end
	f:SetScript("OnMouseWheel", function(_, delta) Shop:Scroll(-delta * 3) end)

	-- footer: what is left to buy, then the buttons along the bottom like the AH's own
	f.Total = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	f.Total:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 36)
	f.Total:SetPoint("RIGHT", f, "RIGHT", -14, 0)
	f.Total:SetJustifyH("LEFT")
	Try(f.Total, "SetWordWrap", false)

	f.SearchAll = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.SearchAll:SetSize(120, 22)
	f.SearchAll:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
	f.SearchAll:SetText("Search all")
	f.SearchAll:SetScript("OnClick", function() Shop:SearchAll() end)
	Tip(f.SearchAll, "Search all", "Shows every reagent you still need in the Auction House results, in one search. Click a result to buy it, then go back to the list. Click a row here to search just that item.")

	f.ClearButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	f.ClearButton:SetSize(90, 22)
	f.ClearButton:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 8)
	f.ClearButton:SetText("Clear list")
	f.ClearButton:SetScript("OnClick", function() Shop:Clear() end)
	Tip(f.ClearButton, "Clear list", "Takes every recipe off the shopping list.")

	Shop.frame = f
	return f
end

function Shop:Scroll(delta)
	local f = self.frame
	if not f then return end
	local maxOffset = math.max(0, (f.itemCount or 0) - ROWS)
	f.offset = math.min(maxOffset, math.max(0, (f.offset or 0) + delta))
	self:Refresh()
end

local function CostText(it)
	if it.missing == 0 then
		if it.mail > 0 and it.have < it.need then return Color(C.label, "in the mail") end
		return Color(C.profit, "done")
	end
	if it.vendor then return Color(C.muted, "vendor ") .. (it.cost and CP:FormatMoney(it.cost) or "") end
	if it.cost then return CP:FormatMoney(it.cost) end
	return Color(C.muted, "no price")
end

function Shop:Refresh()
	local f = self.frame
	if not f then return end
	local recipes = self:Recipes()
	if #recipes == 0 or self.hidden then
		f:Hide()
		self:UpdateToggle()
		return
	end
	f:Show()

	-- recipe lines (the last one says how many more when they do not all fit)
	for i = 1, RECIPE_LINES do
		local b = RecipeLine(f, i)
		local r = recipes[i]
		if i == RECIPE_LINES and #recipes > RECIPE_LINES then
			b.recipeID = nil
			b.Text:SetText(Color(C.muted, string.format("+%d more recipes (/cf shop)", #recipes - RECIPE_LINES + 1)))
			b:Show()
		elseif r then
			b.recipeID, b.label = r.recipeID, r.n .. "x " .. r.name
			b.Text:SetText(Color(C.body, r.n .. "x ") .. Color(C.gold, r.name) .. "  " .. Color(C.muted, "\195\151"))
			b:Show()
		else
			b.recipeID = nil
			b:Hide()
		end
	end

	-- reagent rows
	local items = self:Items()
	f.itemCount = #items
	f.offset = math.min(f.offset or 0, math.max(0, #items - ROWS))
	for i, row in ipairs(f.Rows) do
		local it = items[i + f.offset]
		row.item = it
		row:SetShown(it ~= nil)
		if it then
			row.Icon:SetTexture(ItemIcon(it.itemID))
			local done = it.missing == 0
			local nameColor = done and C.gray or (it.itemID == self.lastSearched and C.gold or C.body)
			row.Name:SetText(Color(nameColor, it.name))
			local have = it.have + it.mail
			row.Have:SetText(Color(done and C.profit or C.body, tostring(have)))
			row.Need:SetText(Color(C.body, tostring(it.need)))
			row.Cost:SetText(CostText(it))
		end
	end

	local total, complete = self:TotalCost(items)
	local todo = #self:ToBuy(items)
	if todo == 0 and total == 0 then
		f.Total:SetText(Color(C.profit, "You have everything on the list."))
	else
		f.Total:SetText(Color(C.label, "Still to buy  ") .. CP:FormatMoney(total) .. (complete and "" or Color(C.muted, "  + unpriced")))
	end
	f.SearchAll:SetEnabled(todo > 0)
	self:UpdateToggle()
end

-- "Shop" next to the scan button: shows or hides the shopping window. Kept narrow so it ends before the
-- AH's bid / buyout boxes on the bottom bar.
function Shop:UpdateToggle()
	local ah = AuctionHouseFrame
	if not ah then return end
	if not self.toggle then
		local b = CreateFrame("Button", "CraftProfitShoppingButton", ah, "UIPanelButtonTemplate")
		b:SetSize(56, 22)
		b:SetText("Shop")
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("Shopping list")
			GameTooltip:AddLine(string.format("%d recipes on the list. Click to show or hide the list.", #Shop:Recipes()), 1, 1, 1, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", GameTooltip_Hide)
		local anchor = CP.Scanner and CP.Scanner.button
		if anchor then
			b:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
		elseif ah.MoneyFrameBorder then
			b:SetPoint("LEFT", ah.MoneyFrameBorder, "RIGHT", 8, 0)
		else
			b:SetPoint("BOTTOMLEFT", ah, "BOTTOMLEFT", 200, 4)
		end
		b:SetScript("OnClick", function()
			Shop.hidden = (Shop.frame and Shop.frame:IsShown()) and true or false
			Shop:Refresh()
		end)
		self.toggle = b
	end
	self.toggle:SetShown(#self:Recipes() > 0)
end

function Shop:OnAuctionHouseShow()
	if not CreateWindow() then return end
	self.hidden = false
	self:Refresh()
end

---------------------------------------------------------------------------
-- Buy quantity
---------------------------------------------------------------------------
-- When Blizzard's commodities buy page opens for an item the list still needs (from Search all, a row
-- click or your own search), its quantity is set to what is missing. The quantity goes out the way typing
-- it does: the AH frame's CommoditiesQuantitySelectionChanged event, which both the buy box and the price list
-- follow, so the price preview matches the server's quote (setting the input box alone leaves the preview at
-- one unit and the purchase fails with "no longer available"). SetQuantitySelected is the fallback. Same
-- calls as our companion addons use, verified in game. The price list re-announces its own number on every
-- refresh, so it is applied again on each results event for 10 s after the page opens. Item (non-stacking)
-- auctions have no quantity box and are left alone.
local APPLY_WINDOW = 10
local applying -- { itemID, qty, t } for the buy page on screen

function Shop:ApplyQuantity(itemID, qty)
	local ah = AuctionHouseFrame
	local frame = ah and ah.CommoditiesBuyFrame
	local display = frame and frame.BuyDisplay
	if not display then return false end
	if type(display.GetItemID) == "function" then
		local ok, current = pcall(display.GetItemID, display)
		if ok and current and current ~= itemID then return false end
	end
	local event = AuctionHouseFrameMixin and AuctionHouseFrameMixin.Event and AuctionHouseFrameMixin.Event.CommoditiesQuantitySelectionChanged
	if event and type(ah.TriggerEvent) == "function" then
		return (pcall(ah.TriggerEvent, ah, event, qty))
	end
	if type(display.SetQuantitySelected) == "function" then return (pcall(display.SetQuantitySelected, display, qty)) end
	return false
end

local function OnCommodityResults(_, itemID)
	local ah = AuctionHouseFrame
	if not (ah and ah:IsShown()) or Shop:IsEmpty() then return end
	local modes = AuctionHouseFrameDisplayMode
	if modes and modes.CommoditiesBuy and ah.displayMode ~= modes.CommoditiesBuy then return end
	if not itemID then
		local display = ah.CommoditiesBuyFrame and ah.CommoditiesBuyFrame.BuyDisplay
		local ok, id = pcall(function() return display:GetItemID() end)
		itemID = ok and id or nil
	end
	if not itemID then return end
	local now = GetTime()
	if not applying or applying.itemID ~= itemID then
		-- a newly opened buy page: only for items still to buy
		applying = nil
		for _, it in ipairs(Shop:ToBuy()) do
			if it.itemID == itemID then applying = { itemID = itemID, qty = it.missing, t = now } break end
		end
		if not applying then return end
	elseif now - applying.t > APPLY_WINDOW then
		return
	end
	local a = applying
	if C_Timer and C_Timer.After then
		C_Timer.After(0, function() Shop:ApplyQuantity(a.itemID, a.qty) end) -- after Blizzard's own handler
	else
		Shop:ApplyQuantity(a.itemID, a.qty)
	end
end
for _, ev in ipairs({ "COMMODITY_SEARCH_RESULTS_RECEIVED", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED" }) do
	CP:RegisterEvent(ev, OnCommodityResults)
end
-- leaving the buy page (or buying) ends it: opening the item again fills in what is still missing then
CP:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED", function() applying = nil end)
CP:RegisterEvent("AUCTION_HOUSE_CLOSED", function() applying = nil end)
local displayHooked
local function HookDisplayMode()
	local ah = AuctionHouseFrame
	if displayHooked or not (ah and type(ah.SetDisplayMode) == "function" and hooksecurefunc) then return end
	displayHooked = true
	pcall(hooksecurefunc, ah, "SetDisplayMode", function(_, mode)
		local modes = AuctionHouseFrameDisplayMode
		if not (modes and mode == modes.CommoditiesBuy) then applying = nil end
	end)
end

CP:RegisterEvent("AUCTION_HOUSE_SHOW", function()
	HookDisplayMode()
	Shop:OnAuctionHouseShow()
end)
CP:RegisterEvent("BAG_UPDATE_DELAYED", function()
	if Shop.frame and Shop.frame:IsShown() then Shop:Refresh() end
end)
CP:On("SHOPPING_CHANGED", function()
	if Shop.frame and AuctionHouseFrame and AuctionHouseFrame:IsShown() then Shop:Refresh() end
end)
CP:On("PRICES_UPDATED", function()
	if Shop.frame and Shop.frame:IsShown() then Shop:Refresh() end
end)
