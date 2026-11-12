-- CraftProfit :: Scanner
-- Own Auction House price database built from a full browse scan (retail C_AuctionHouse API).
-- Stores lowest buyout + total quantity per itemID, plus a short history per item used to
-- derive a smoothed "market" price and a rough sold-per-day estimate.

local _, CP = ...
local Scanner = CreateFrame("Frame")
CP.Scanner = Scanner

local HISTORY_MAX = 30          -- samples kept per item
local STALL_TIMEOUT = 20        -- seconds without a results event before giving up
local DISAPPEAR_WINDOW = 7 * 86400

Scanner.ahOpen = false
Scanner.running = false

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function AppendHistory(realm, itemID, t, price, qty)
	local h = realm.history[itemID]
	if not h then
		h = {}
		realm.history[itemID] = h
	end
	table.insert(h, { t, price, qty })
	while #h > HISTORY_MAX do table.remove(h, 1) end
end

-- partial: the scan stopped early (stall, AH closed, Stop button). Items missing from a partial result were
-- probably just not reached, so they are not recorded as sold out (that would inflate sold per day).
function Scanner:Store(results, partial)
	if #results == 0 then return 0 end -- nothing came back: keep the previous scan as it is
	local realm = CP:GetRealmDB()
	local now = time()
	local agg = {}
	local keys = {}

	for _, r in ipairs(results) do
		local key = r.itemKey
		local itemID = key and key.itemID
		local price = r.minPrice
		if itemID and price and price > 0 then
			local a = agg[itemID]
			local qty = r.totalQuantity or 0
			if not a then
				agg[itemID] = { p = price, q = qty }
				keys[itemID] = key
			else
				if price < a.p then
					a.p = price
					keys[itemID] = key
				end
				a.q = a.q + qty
			end
		end
	end
	self.keysByItem = keys

	-- Items seen recently but absent now: record a zero-quantity sample (sold out / expired).
	for itemID, rec in pairs(partial and {} or realm.prices) do
		if not agg[itemID] and rec[3] and rec[3] > now - DISAPPEAR_WINDOW then
			local h = realm.history[itemID]
			local last = h and h[#h]
			if not last or last[3] ~= 0 then
				AppendHistory(realm, itemID, now, rec[1], 0)
			end
		end
	end

	local count = 0
	for itemID, a in pairs(agg) do
		realm.prices[itemID] = { a.p, a.q, now }
		AppendHistory(realm, itemID, now, a.p, a.q)
		count = count + 1
	end
	realm.lastScan = now
	return count
end

---------------------------------------------------------------------------
-- Queries
---------------------------------------------------------------------------

function Scanner:GetMin(itemID)
	local rec = CP:GetRealmDB().prices[itemID]
	return rec and rec[1] or nil
end

-- The AH item key of the cheapest browse row for this item in this session's last scan. Random-suffix
-- gear lists under suffixed keys ("Medicine Staff of the Owl"); the plain MakeItemKey(itemID) key
-- finds none of them. nil when this session has not scanned the item.
function Scanner:GetBrowseKey(itemID)
	return self.keysByItem and self.keysByItem[itemID] or nil
end

-- Browse key when known, else the plain item key (commodities and suffix-less items).
function Scanner:GetItemKey(itemID)
	local key = self:GetBrowseKey(itemID)
	if key then return key end
	if C_AuctionHouse and C_AuctionHouse.MakeItemKey then
		local ok, k = pcall(C_AuctionHouse.MakeItemKey, itemID)
		if ok then return k end
	end
	return nil
end

function Scanner:GetQuantity(itemID)
	local rec = CP:GetRealmDB().prices[itemID]
	return rec and rec[2] or nil
end

-- Market price: the depth value when it belongs to the latest scan (see "Depth market value"), else the
-- median of the lowest buyout over the last few scans where the item was listed.
-- Second return: "depth" | "median" | "min".
function Scanner:GetMarket(itemID)
	local mv = self:GetFreshDepth(itemID)
	if mv then return mv, "depth" end
	return self:GetMedian(itemID)
end

function Scanner:GetMedian(itemID)
	local h = CP:GetRealmDB().history[itemID]
	if not h or #h == 0 then return self:GetMin(itemID), "min" end
	local prices = {}
	for i = #h, math.max(1, #h - 6), -1 do
		local s = h[i]
		if s[2] and s[2] > 0 and s[3] and s[3] > 0 then table.insert(prices, s[2]) end
	end
	if #prices == 0 then return self:GetMin(itemID), "min" end
	table.sort(prices)
	local mid = math.floor((#prices + 1) / 2)
	if #prices % 2 == 1 then return prices[mid], "median" end
	return math.floor((prices[mid] + prices[mid + 1]) / 2), "median"
end

function Scanner:GetAge(itemID)
	local realm = CP:GetRealmDB()
	local rec = realm.prices[itemID]
	if rec and rec[3] then return time() - rec[3] end
	if realm.lastScan and realm.lastScan > 0 then return time() - realm.lastScan end
	return nil
end

-- Units that disappeared between consecutive scans, extrapolated to 24h. Needs >= 2 scans
-- at least an hour apart. Counts expired/cancelled auctions as sold, so treat it as an upper bound.
function Scanner:GetSoldPerDay(itemID)
	local h = CP:GetRealmDB().history[itemID]
	if not h or #h < 2 then return nil end
	local span = h[#h][1] - h[1][1]
	if span < 3600 then return nil end
	local sold = 0
	for i = 2, #h do
		local prev, cur = h[i - 1][3] or 0, h[i][3] or 0
		if prev > cur then sold = sold + (prev - cur) end
	end
	local perDay = sold / (span / 86400)
	return math.floor(perDay * 10 + 0.5) / 10
end

function Scanner:HasData()
	return next(CP:GetRealmDB().prices) ~= nil
end

function Scanner:GetLastScan()
	return CP:GetRealmDB().lastScan or 0
end

CP.Sources:Register({
	key = "craftprofit",
	name = "CraftProfit scan",
	description = "Own full browse scan of the Auction House (button in the AH or /cf scan).",
	IsAvailable = function() return C_AuctionHouse ~= nil and C_AuctionHouse.SendBrowseQuery ~= nil end,
	HasData = function() return Scanner:HasData() end,
	GetCostPrice = function(_, itemID) return Scanner:GetMin(itemID) end,
	GetSalePrice = function(_, itemID)
		if CP.settings.saleBasis == "market" then
			return (Scanner:GetMarket(itemID))
		end
		return Scanner:GetMin(itemID)
	end,
	GetAge = function(_, itemID) return Scanner:GetAge(itemID) end,
	GetSoldPerDay = function(_, itemID) return Scanner:GetSoldPerDay(itemID) end,
})

---------------------------------------------------------------------------
-- Scan flow
---------------------------------------------------------------------------

local SCAN_EVENTS = {
	"AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
	"AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
	"AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
}

local function UpdateButton()
	local b = Scanner.button
	if not b then return end
	if Scanner.running then
		b:SetText(string.format("Stop scan (%d)", Scanner.pages or 0))
	elseif Scanner.depthJob then
		local job = Scanner.depthJob
		b:SetText(Scanner.itemPausedForBuy and "Depth paused" or string.format("Depth %d/%d", job.done, job.total))
	else
		b:SetText("CraftProfit Scan")
	end
end

function Scanner:Start()
	if not self.ahOpen then
		CP:Print("open the Auction House first.")
		return false
	end
	if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then
		CP:Print("this client has no C_AuctionHouse browse API.")
		return false
	end
	if self.running then
		CP:Print("a scan is already running.")
		return false
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		CP:Print("the Auction House is busy, try again in a moment.")
		return false
	end

	self.running = true
	self.startTime = GetTime()
	self.lastProgress = GetTime()
	self.pages = 0
	self.waitingThrottle = false

	for _, ev in ipairs(SCAN_EVENTS) do pcall(self.RegisterEvent, self, ev) end
	self:SetScript("OnEvent", self.OnEvent)

	local query = {
		searchString = "",
		minLevel = 0,
		maxLevel = 0,
		filters = {},
		itemClassFilters = {},
		sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } },
	}
	local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, query)
	if not ok then
		CP:Print("browse query failed: %s", tostring(err))
		self:Finish(true)
		return false
	end

	if self.ticker then self.ticker:Cancel() end
	self.ticker = C_Timer.NewTicker(1, function() Scanner:Tick() end)

	CP:Print("scanning the Auction House...")
	UpdateButton()
	CP:Fire("SCAN_STARTED")
	return true
end

function Scanner:OnEvent(event, ...)
	if not self.running then return end
	if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
		self.lastProgress = GetTime()
		self.pages = (self.pages or 0) + 1
		UpdateButton()
		self:Continue()
	elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
		if self.waitingThrottle then
			self.waitingThrottle = false
			self:Continue()
		end
	end
end

function Scanner:Continue()
	if C_AuctionHouse.HasFullBrowseResults() then
		self:Finish(false)
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady() then
		C_AuctionHouse.RequestMoreBrowseResults()
	else
		self.waitingThrottle = true
	end
end

function Scanner:Tick()
	if not self.running then return end
	if GetTime() - self.lastProgress > STALL_TIMEOUT then
		CP:Print("no response from the Auction House for %ds, storing what we have.", STALL_TIMEOUT)
		self:Finish(true)
	end
end

function Scanner:Finish(partial)
	if not self.running then return end
	self.running = false
	for _, ev in ipairs(SCAN_EVENTS) do pcall(self.UnregisterEvent, self, ev) end
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end

	local results = {}
	if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then
		local ok, res = pcall(C_AuctionHouse.GetBrowseResults)
		if ok and type(res) == "table" then results = res end
	end
	local count = self:Store(results, partial)
	local elapsed = GetTime() - (self.startTime or GetTime())
	CP:Print("scan %s: %d items priced from %d result rows in %.0fs.",
		partial and "stopped early" or "complete", count, #results, elapsed)

	UpdateButton()
	CP:Fire("PRICES_UPDATED", "craftprofit")
	CP:Fire("SCAN_FINISHED", count, partial)
	if not partial and CP.settings.depthScan and self.ahOpen then self:StartDepth() end
end

---------------------------------------------------------------------------
-- Auction House integration
---------------------------------------------------------------------------

local function CreateScanButton()
	if Scanner.button or not AuctionHouseFrame then return end
	if not CP.settings or not CP.settings.scanButton then return end

	local b = CreateFrame("Button", "CraftProfitScanButton", AuctionHouseFrame, "UIPanelButtonTemplate")
	b:SetSize(120, 22)
	b:SetText("CraftProfit Scan")
	if AuctionHouseFrame.MoneyFrameBorder then
		b:SetPoint("LEFT", AuctionHouseFrame.MoneyFrameBorder, "RIGHT", 8, 0)
	else
		b:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMLEFT", 200, 4)
	end
	b:SetScript("OnClick", function()
		if Scanner.running then
			Scanner:Finish(true)
		elseif Scanner.depthJob then
			Scanner:StopDepth()
		else
			Scanner:Start()
		end
	end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("CraftProfit")
		local last = Scanner:GetLastScan()
		GameTooltip:AddLine(last > 0 and ("Last scan: " .. CP:FormatAge(time() - last)) or "No scan yet", 1, 1, 1)
		local n = 0
		for _ in pairs(CP:GetRealmDB().prices) do n = n + 1 end
		GameTooltip:AddLine(n .. " items priced", 1, 1, 1)
		GameTooltip:AddLine("Runs a full browse scan of the Auction House. Takes 10-60 seconds.", 0.6, 0.6, 0.6, true)
		if CP.settings.depthScan then
			GameTooltip:AddLine("Then reads the listings of your recipes' reagents and outputs (depth scan), so one cheap listing cannot fake the market price.", 0.6, 0.6, 0.6, true)
		end
		if Scanner.depthJob then GameTooltip:AddLine("Click to stop the depth scan.", 1, 0.82, 0) end
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", GameTooltip_Hide)
	Scanner.button = b
end

CP:RegisterEvent("AUCTION_HOUSE_SHOW", function()
	Scanner.ahOpen = true
	CreateScanButton()
end)

CP:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
	Scanner.ahOpen = false
	if Scanner.running then Scanner:Finish(true) end
end)

CP:RegisterEvent("ADDON_LOADED", function(_, name)
	if name == "Blizzard_AuctionHouseUI" then CreateScanButton() end
end)

CP:On("SETTINGS_CHANGED", function(key)
	if key == "scanButton" and Scanner.button then
		Scanner.button:SetShown(CP.settings.scanButton)
	end
end)

---------------------------------------------------------------------------
-- Price ladders (market depth)
---------------------------------------------------------------------------
-- The browse scan only knows the lowest buyout per item. Buying 200 units usually walks up several price
-- tiers, so per-item search results are captured as a "ladder": ascending { unitPrice, quantity } tiers.
-- Ladders come from (a) whatever the player looks at in the AH (Blizzard's own searches fire the same
-- events) and (b) Scanner:ScanItems(itemIDs), a sequential depth scan for companion addons.
-- Stored per realm: realm.ladders[itemID] = { t, tiers, total, full }.

local LADDER_MAX_TIERS = 40
local LADDER_MAX_QTY = 5000
local LADDER_STALE = 600            -- seconds before the planner asks for a fresh ladder
local ITEM_SCAN_TIMEOUT = 8          -- seconds without an answer before an item search counts as lost
local ITEM_SCAN_TIMEOUT_MIN = 3      -- once answers are measured: 4x the average answer time, within 3-8 s
Scanner.LADDER_STALE = LADDER_STALE

local function Ladders()
	local realm = CP:GetRealmDB()
	realm.ladders = realm.ladders or {}
	return realm.ladders
end

function Scanner:GetLadder(itemID)
	return itemID and Ladders()[itemID] or nil
end

function Scanner:GetLadderAge(itemID)
	local l = self:GetLadder(itemID)
	return l and (time() - (l.t or 0)) or nil
end

---------------------------------------------------------------------------
-- Depth market value
---------------------------------------------------------------------------
-- The lowest buyout is easy to fake: one listing at 2s in front of 500 at 50s says "2s". The depth value
-- (MV) is the quantity-weighted average of the cheapest 20% of listed supply, at most 1,000 units and at
-- least 5 (or everything when fewer are listed). A bait listing barely moves it and walls of overpriced
-- listings never count. Stored per realm: realm.mv[itemID] = { mv, units, t }, kept 14 days.

local MV_SHARE, MV_CAP, MV_MIN = 0.20, 1000, 5
local MV_TTL = 14 * 86400
-- How often the depth scan re-reads an item; a depth value counts until it is this much older than the browse
-- price (the depth scan would have replaced it). Same rule for skipping and for using it, so nothing read by
-- the depth scan is hidden while it is still too fresh to be read again.
local DEPTH_FRESH = 2 * 3600        -- commodities
local DEPTH_FRESH_ITEM = 24 * 3600  -- gear and other non-commodities: their market moves slower and they are
                                    -- most of the searches (2026-10-20: 191 of 238)
Scanner.MV_TTL = MV_TTL

-- tiers: ascending { unitPrice, quantity }; listed: total listed quantity when known (browse scan).
-- Returns mv, units used, target units (units < target when the ladder was not read deep enough).
function Scanner.DepthValue(tiers, listed)
	if not tiers then return nil end
	local total = 0
	for _, t in ipairs(tiers) do total = total + t[2] end
	listed = math.max(tonumber(listed) or 0, total)
	if listed <= 0 then return nil end
	local target = math.min(listed, MV_CAP, math.max(math.floor(listed * MV_SHARE), MV_MIN))
	local remaining, sum, used = target, 0, 0
	for _, t in ipairs(tiers) do
		if remaining <= 0 then break end
		local take = math.min(remaining, t[2])
		sum = sum + take * t[1]
		used = used + take
		remaining = remaining - take
	end
	if used <= 0 then return nil end
	return math.floor(sum / used + 0.5), used, target
end

local function DepthDB()
	local realm = CP:GetRealmDB()
	realm.mv = realm.mv or {}
	return realm.mv
end

-- { mv, units, t } or nil
function Scanner:GetDepth(itemID)
	return itemID and DepthDB()[itemID] or nil
end

-- The depth value when it was read in the same scan as the current browse price (so it is not older than
-- the lowest buyout we show), else nil.
function Scanner:GetFreshDepth(itemID)
	local d = self:GetDepth(itemID)
	if not d then return nil end
	local rec = CP:GetRealmDB().prices[itemID]
	local window = (self:IsCommodity(itemID, self:GetBrowseKey(itemID)) == false) and DEPTH_FRESH_ITEM or DEPTH_FRESH
	if rec and rec[3] and d[3] < rec[3] - window then return nil end
	-- never below the current lowest buyout: the cheap listings it averaged may have sold since
	local mv = d[1]
	if rec and rec[1] and rec[1] > mv and rec[3] and rec[3] > d[3] then mv = rec[1] end
	return mv, d
end

---------------------------------------------------------------------------
-- Price history and verdict
---------------------------------------------------------------------------
-- Daily depth values: realm.daily[itemID] = { { day, mv, reads }, ... } oldest first, one entry per day (the
-- average of that day's depth reads), 14 days. Merged by day (the entry with more reads wins), so merging a
-- copy into itself changes nothing. Only depth values go in: a lowest buyout can be a bait listing.
-- Normal price = median of the daily values of the last 7 days before today (today is what gets judged).

local DAILY_DAYS = 14
local NORMAL_DAYS, NORMAL_MIN_DAYS = 7, 3
local VERDICT_BAND = 0.10             -- cheap at 10% or more under normal, high at 10% or more over
Scanner.DAILY_DAYS, Scanner.NORMAL_DAYS, Scanner.NORMAL_MIN_DAYS = DAILY_DAYS, NORMAL_DAYS, NORMAL_MIN_DAYS

local function Today(t)
	return math.floor((t or time()) / 86400)
end
Scanner.Today = Today

local function DailyDB()
	local realm = CP:GetRealmDB()
	realm.daily = realm.daily or {}
	return realm.daily
end

function Scanner:RecordDaily(itemID, mv, t)
	if not itemID or not mv or mv <= 0 then return end
	local daily = DailyDB()
	local list = daily[itemID]
	if not list then
		list = {}
		daily[itemID] = list
	end
	local day = Today(t)
	local last = list[#list]
	if last and last[1] == day then
		last[2] = math.floor((last[2] * last[3] + mv) / (last[3] + 1) + 0.5)
		last[3] = last[3] + 1
	elseif not last or last[1] < day then
		list[#list + 1] = { day, mv, 1 }
	end
	while list[1] and list[1][1] <= day - DAILY_DAYS do table.remove(list, 1) end
end

-- Stores a depth read: the current depth value and today's history entry.
function Scanner:SetDepth(itemID, mv, units, t)
	t = t or time()
	DepthDB()[itemID] = { mv, units, t }
	self:RecordDaily(itemID, mv, t)
end

-- An item's daily history: the saved one, or invented history while /cf demo history is on (Demo.lua).
function Scanner:GetDaily(itemID)
	if CP.Demo and CP.Demo.HistoryFor then
		local fake = CP.Demo:HistoryFor(itemID)
		if fake then return fake end
	end
	return DailyDB()[itemID]
end

-- Items read before the history existed (or before this version): their current depth value becomes the
-- history's first day, so they show "learning" right away instead of waiting for the next read.
function Scanner:SeedDaily()
	local realm = CP:GetRealmDB()
	local daily = DailyDB()
	local n = 0
	for itemID, d in pairs(realm.mv or {}) do
		if not daily[itemID] and d[1] and d[3] and time() - d[3] < DAILY_DAYS * 86400 then
			self:RecordDaily(itemID, d[1], d[3])
			n = n + 1
		end
	end
	return n
end
CP:On("READY", function() Scanner:SeedDaily() end)
CP:On("DB_ADOPTED", function() Scanner:SeedDaily() end)

-- Daily values of the last 7 days before today (unsorted).
function Scanner:RecentDays(itemID)
	local list = self:GetDaily(itemID)
	local today = Today()
	local vals = {}
	for _, e in ipairs(list or {}) do
		if e[1] < today and e[1] >= today - NORMAL_DAYS then vals[#vals + 1] = e[2] end
	end
	return vals
end

-- normal, days, lowest day, highest day; or nil, days while fewer than 3 days are known.
function Scanner:GetNormal(itemID)
	local vals = self:RecentDays(itemID)
	if #vals < NORMAL_MIN_DAYS then return nil, #vals end
	table.sort(vals)
	local n, mid = #vals, math.floor((#vals + 1) / 2)
	local normal = (n % 2 == 1) and vals[mid] or math.floor((vals[mid] + vals[mid + 1]) / 2 + 0.5)
	return normal, n, vals[1], vals[n]
end

-- Judges a unit price against the normal price. Returns { verdict = "cheap" | "normal" | "high", pct (unit /
-- normal - 1), normal, days, dearer (recent days whose value was above `unit`), low, high }, or nil and the
-- number of days known while there is not enough history.
function Scanner:GetVerdict(itemID, unit)
	local normal, days, low, high = self:GetNormal(itemID)
	if not normal or normal <= 0 or not unit then return nil, days end
	local pct = unit / normal - 1
	local verdict = "normal"
	if pct <= -VERDICT_BAND then verdict = "cheap" elseif pct >= VERDICT_BAND then verdict = "high" end
	local dearer = 0
	for _, v in ipairs(self:RecentDays(itemID)) do
		if v > unit then dearer = dearer + 1 end
	end
	return { verdict = verdict, pct = pct, normal = normal, days = days, dearer = dearer, low = low, high = high }
end

function Scanner:StoreLadder(itemID, tiers, full)
	if not itemID or not tiers or #tiers == 0 then return end
	CP:Touch(itemID)
	local total = 0
	for _, t in ipairs(tiers) do total = total + t[2] end
	Ladders()[itemID] = { t = time(), tiers = tiers, total = total, full = full and true or false }
	-- keep the browse-scan record current too (lowest buyout is the first tier)
	local realm = CP:GetRealmDB()
	local rec = realm.prices[itemID]
	-- the browse scan knows the whole listed quantity; a ladder that was not read to the end does not
	local listed = total
	if not full and rec and rec[2] and rec[2] > total then listed = rec[2] end
	local mv, units = Scanner.DepthValue(tiers, listed)
	if mv then self:SetDepth(itemID, mv, units) end
	realm.prices[itemID] = { tiers[1][1], listed, time() }
	CP:Fire("LADDER_UPDATED", itemID)
end

-- Cost of buying `quantity` units at the current listings.
-- Returns total, averageUnit, info = { source = "ladder" | "min", covered, short, full, tiers = {{price, qty}},
-- age, minPrice, listed }. `short` units were not covered by the ladder: with info.full they are not on the
-- AH at all; otherwise they are beyond the scanned depth and priced at the highest tier seen.
function Scanner:GetBuyCost(itemID, quantity)
	quantity = math.max(1, math.floor(tonumber(quantity) or 1))
	local ladder = self:GetLadder(itemID)
	if ladder and ladder.tiers and #ladder.tiers > 0 then
		local remaining, total, used = quantity, 0, {}
		for _, tier in ipairs(ladder.tiers) do
			if remaining <= 0 then break end
			local take = math.min(remaining, tier[2])
			if take > 0 then
				total = total + take * tier[1]
				remaining = remaining - take
				table.insert(used, { tier[1], take })
			end
		end
		if remaining > 0 then
			total = total + remaining * ladder.tiers[#ladder.tiers][1]
		end
		return total, total / quantity, {
			source = "ladder", covered = quantity - remaining, short = remaining, full = ladder.full,
			tiers = used, age = time() - (ladder.t or 0), minPrice = ladder.tiers[1][1], listed = ladder.total,
		}
	end
	local min = self:GetMin(itemID)
	if not min then return nil end
	local listed = self:GetQuantity(itemID)
	return min * quantity, min, {
		source = "min", covered = listed and math.min(quantity, listed) or quantity,
		short = listed and math.max(0, quantity - listed) or 0, full = listed ~= nil,
		tiers = { { min, quantity } }, age = self:GetAge(itemID), minPrice = min, listed = listed,
	}
end

-- After a purchase the cheapest tiers are gone; keep the ladder honest until the next search.
function Scanner:ConsumeLadder(itemID, quantity)
	local ladder = self:GetLadder(itemID)
	if not ladder or not quantity or quantity <= 0 then return end
	local remaining = quantity
	while remaining > 0 and ladder.tiers[1] do
		local tier = ladder.tiers[1]
		if tier[2] > remaining then
			tier[2] = tier[2] - remaining
			remaining = 0
		else
			remaining = remaining - tier[2]
			table.remove(ladder.tiers, 1)
		end
	end
	ladder.total = math.max(0, (ladder.total or 0) - quantity)
	if #ladder.tiers == 0 then Ladders()[itemID] = nil end
	CP:Fire("LADDER_UPDATED", itemID)
end

local function ReadCommodityResults(itemID)
	if not (C_AuctionHouse.GetNumCommoditySearchResults and C_AuctionHouse.GetCommoditySearchResultInfo) then return nil end
	local ok, n = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
	if not ok or not n or n == 0 then return nil end
	local tiers, last, qty = {}, nil, 0
	for i = 1, n do
		local ok2, r = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, i)
		if ok2 and r and r.unitPrice and r.quantity then
			if last and last[1] == r.unitPrice then
				last[2] = last[2] + r.quantity
			else
				last = { r.unitPrice, r.quantity }
				table.insert(tiers, last)
			end
			qty = qty + r.quantity
			if #tiers >= LADDER_MAX_TIERS or qty >= LADDER_MAX_QTY then break end
		end
	end
	local full = true
	if C_AuctionHouse.HasFullCommoditySearchResults then
		local ok3, f = pcall(C_AuctionHouse.HasFullCommoditySearchResults, itemID)
		full = ok3 and f or false
	end
	return tiers, full, qty
end

local function ReadItemResults(itemKey)
	if not (C_AuctionHouse.GetNumItemSearchResults and C_AuctionHouse.GetItemSearchResultInfo) then return nil end
	local ok, n = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
	if not ok or not n or n == 0 then return nil end
	local tiers, last = {}, nil
	for i = 1, n do
		local ok2, r = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
		local price = ok2 and r and r.buyoutAmount
		if ok2 and r and r.auctionID and itemKey.itemID then Scanner:CacheListing(r.auctionID, itemKey.itemID, r.quantity, price) end
		if price and price > 0 then
			local q = r.quantity or 1
			if last and last[1] == price then last[2] = last[2] + q else
				last = { price, q }
				table.insert(tiers, last)
			end
			if #tiers >= LADDER_MAX_TIERS then break end
		end
	end
	table.sort(tiers, function(a, b) return a[1] < b[1] end)
	local full = true
	if C_AuctionHouse.HasFullItemSearchResults then
		local ok3, f = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey)
		full = ok3 and f or false
	end
	return tiers, full
end

-- Answer times of our own item searches (session): the timeout follows them, so a lost search costs ~4x a
-- normal answer instead of a fixed 8 s.
Scanner.answerTime, Scanner.answerCount = 0, 0

function Scanner:ItemTimeout()
	if self.answerCount < 3 then return ITEM_SCAN_TIMEOUT end
	local avg = self.answerTime / self.answerCount
	return math.min(ITEM_SCAN_TIMEOUT, math.max(ITEM_SCAN_TIMEOUT_MIN, avg * 4))
end

-- true for commodities (stackable trade goods searched per item ID), false for items, nil when unknown.
-- GetItemKeyInfo answers once the item's data is loaded (the browse scan loads it); a commodity answer seen
-- for the item this session also counts.
Scanner.commodityIDs = {}
function Scanner:IsCommodity(itemID, key)
	if self.commodityIDs[itemID] ~= nil then return self.commodityIDs[itemID] end
	if C_AuctionHouse.GetItemKeyInfo and key then
		local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, key)
		if ok and type(info) == "table" and info.isCommodity ~= nil then
			self.commodityIDs[itemID] = info.isCommodity and true or false
			return self.commodityIDs[itemID]
		end
	end
	return nil
end

-- Depth-pass counters (nil when no depth pass runs).
local function JobStats()
	return Scanner.depthJob and Scanner.depthJob.stats
end

local function ArmTimeout(cur)
	if not (C_Timer and C_Timer.After) then return end
	cur.seq = (cur.seq or 0) + 1
	cur.sent = GetTime()
	local seq, limit = cur.seq, Scanner:ItemTimeout()
	C_Timer.After(limit, function()
		if Scanner.itemCurrent ~= cur or cur.seq ~= seq or GetTime() - cur.sent < limit - 0.5 then return end
		CP:Debug("item search %s timed out after %.1fs", tostring(cur.itemID), limit)
		local st = JobStats()
		if st then st.timeouts = st.timeouts + 1 end
		-- a depth-pass item gets one more try at the end of the queue
		local job = Scanner.depthJob
		-- (an item-style search that got nothing is retried the commodity way: its status may not have been known)
		if job and job.ids[cur.itemID] and not job.retried[cur.itemID] and Scanner.itemQueue then
			job.retried[cur.itemID] = true
			if not cur.commodity then
				Scanner.commodityIDs[cur.itemID] = true
				job.flipped[cur.itemID] = true
			end
			table.insert(Scanner.itemQueue, cur.itemID)
			Scanner.itemCurrent = nil
			Scanner:NextItem()
		else
			if job and job.flipped[cur.itemID] then Scanner.commodityIDs[cur.itemID] = nil end
			Scanner:FinishItem(cur.itemID)
		end
	end)
end

-- First answer to our current search: count it for the timeout and the depth-pass report.
local function Answered(cur)
	if cur.answered then return end
	cur.answered = true
	local dt = GetTime() - cur.t
	Scanner.answerTime = Scanner.answerTime + dt
	Scanner.answerCount = Scanner.answerCount + 1
	local st = JobStats()
	if st then
		st.answers = st.answers + 1
		st.answerTime = st.answerTime + dt
	end
end

-- Units the depth value needs for this item (min(20% of listed, 1000), at least 5). Depth-pass items stop
-- requesting more pages once they have that many; ladders for buying (companion addons) still read deeper.
function Scanner:DepthTarget(itemID)
	local rec = CP:GetRealmDB().prices[itemID]
	local listed = rec and rec[2] or 0
	return math.min(MV_CAP, math.max(MV_MIN, math.floor(listed * MV_SHARE)))
end

-- Sequential depth scan of specific items (AH must be open). Fires ITEM_SCAN_FINISHED when the queue drains.
-- opts.shallow: the caller only needs the depth value (stop paging at DepthTarget); a later call without it
-- for the same item asks for the full ladder again.
function Scanner:ScanItems(itemIDs, opts)
	if not self.ahOpen then return false, "open the Auction House first" end
	if not (C_AuctionHouse and C_AuctionHouse.SendSearchQuery and C_AuctionHouse.MakeItemKey) then
		return false, "this client has no per-item search API"
	end
	if self.running then return false, "a full scan is running" end
	self.itemQueue = self.itemQueue or {}
	local queued = {}
	for _, id in ipairs(self.itemQueue) do queued[id] = true end
	if self.itemCurrent then queued[self.itemCurrent.itemID] = true end
	self.shallow = self.shallow or {}
	local shallow = opts and opts.shallow
	local added = 0
	for _, id in ipairs(itemIDs or {}) do
		if id then
			if not shallow then
				self.shallow[id] = nil
			elseif not queued[id] then
				self.shallow[id] = true
			end
			if not queued[id] then
				table.insert(self.itemQueue, id)
				queued[id] = true
				added = added + 1
			end
		end
	end
	self:NextItem()
	return true, added
end

function Scanner:IsItemScanRunning()
	return self.itemCurrent ~= nil or (self.itemQueue ~= nil and #self.itemQueue > 0)
end

-- A per-item search replaces the AH's current search context. While the player is on a buy page that
-- context belongs to the purchase (a stale one fails with "That item is no longer available"), so the
-- depth scan waits until the player leaves the buy page.
local function BuyPageOpen()
	local ah = AuctionHouseFrame
	local modes = AuctionHouseFrameDisplayMode
	if not (ah and modes and ah.displayMode) then return false end
	return ah.displayMode == modes.CommoditiesBuy or ah.displayMode == modes.ItemBuy
end
Scanner.BuyPageOpen = BuyPageOpen

function Scanner:NextItem()
	if self.itemCurrent then return end
	local queue = self.itemQueue
	if queue and #queue > 0 and BuyPageOpen() then
		self.itemPausedForBuy = true
		CP:Debug("depth scan paused: buy page open")
		UpdateButton()
		return
	end
	local id = queue and table.remove(queue, 1)
	if not id then
		self.itemQueue = nil
		CP:Fire("ITEM_SCAN_FINISHED")
		return
	end
	if not self.ahOpen then
		self.itemQueue = nil
		return
	end
	if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
		table.insert(queue, 1, id)
		if not self.itemWaitingThrottle then self.throttleSince = GetTime() end
		self.itemWaitingThrottle = true
		return
	end
	local okKey, key = pcall(Scanner.GetItemKey, Scanner, id)
	if not okKey or not key then
		return self:NextItem()
	end
	-- Commodities are searched exactly like Blizzard's buy page does it: plain item key, NO sorts (its sort
	-- table has no entry for the BuyCommodities context). With a Price sort, commodity searches on Forever
	-- were never answered (2026-10-20: 5 searches, 0 answers, 0 result events).
	local commodity = Scanner:IsCommodity(id, key)
	local sorts
	if commodity then
		local okPlain, plain = pcall(C_AuctionHouse.MakeItemKey, id)
		if okPlain and plain then key = plain end
		sorts = {}
	else
		sorts = { { sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price) or 0, reverseSort = false } }
	end
	local ok, err = pcall(C_AuctionHouse.SendSearchQuery, key, sorts, false)
	if not ok then
		CP:Debug("item search %s failed: %s", tostring(id), tostring(err))
		return self:NextItem()
	end
	self.itemCurrent = { itemID = id, t = GetTime(), commodity = commodity }
	local st = JobStats()
	if st then
		st.searches = st.searches + 1
		if commodity then st.commodities = st.commodities + 1 end
	end
	ArmTimeout(self.itemCurrent)
end

function Scanner:FinishItem(itemID)
	local cur = self.itemCurrent
	if cur and cur.itemID == itemID then
		self.itemCurrent = nil
		local job = self.depthJob
		self.lastItemID = itemID
		if self.shallow then self.shallow[itemID] = nil end
		if job and job.ids[itemID] then
			job.ids[itemID] = nil
			job.done = job.done + 1
			UpdateButton()
		end
		self:NextItem()
	end
end

local function Foreign(itemID)
	local st = JobStats()
	if st and itemID ~= Scanner.lastItemID then st.foreign = st.foreign + 1 end
end

local function CountEvent(event)
	local st = JobStats()
	if st then st.events[event] = (st.events[event] or 0) + 1 end
end

local function OnCommodityResults(event, itemID)
	CountEvent(event)
	if not itemID then return end
	Scanner.commodityIDs[itemID] = true
	local cur = Scanner.itemCurrent
	local mine = cur and cur.itemID == itemID
	if mine then
		Answered(cur)
	else
		Foreign(itemID)
	end
	local tiers, full, qty = ReadCommodityResults(itemID)
	if not tiers then
		-- nothing listed: an old ladder would be stale, and our scan can move on
		if mine then
			Ladders()[itemID] = nil
			Scanner:FinishItem(itemID)
		end
		return
	end
	local enough = Scanner.shallow and Scanner.shallow[itemID] and (qty or 0) >= Scanner:DepthTarget(itemID)
	if mine and not full and not enough and #tiers < LADDER_MAX_TIERS and (qty or 0) < LADDER_MAX_QTY
		and C_AuctionHouse.RequestMoreCommoditySearchResults
		and (not C_AuctionHouse.IsThrottledMessageSystemReady or C_AuctionHouse.IsThrottledMessageSystemReady()) then
		local ok = pcall(C_AuctionHouse.RequestMoreCommoditySearchResults, itemID)
		if ok then
			local st = JobStats()
			if st then st.pages = st.pages + 1 end
			ArmTimeout(cur) -- a page that never comes must not hold up the queue
			return -- results event fires again with more rows
		end
	end
	if #tiers > 0 then Scanner:StoreLadder(itemID, tiers, full) end
	if mine then Scanner:FinishItem(itemID) end
end

local function OnItemResults(event, itemKey)
	CountEvent(event)
	local itemID = type(itemKey) == "table" and itemKey.itemID or nil
	if not itemID then return end
	local cur = Scanner.itemCurrent
	local mine = cur and cur.itemID == itemID
	if mine then
		Answered(cur)
	else
		Foreign(itemID)
	end
	-- A search for one random-suffix variant ("... of the Bear", opened by the player or another addon) only
	-- lists that variant; storing it per itemID would replace the cheapest-variant price from the browse scan.
	-- Our own depth scan searches the cheapest variant's key, so its results are kept.
	local suffixed = (tonumber(itemKey.itemSuffix) or 0) ~= 0
	if mine or not suffixed then
		local tiers, full = ReadItemResults(itemKey)
		if tiers and #tiers > 0 then Scanner:StoreLadder(itemID, tiers, full) end
	else
		ReadItemResults(itemKey) -- still cache the listings so a buyout here is recorded as a purchase
	end
	if mine then Scanner:FinishItem(itemID) end
end

CP:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED", OnCommodityResults)
CP:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED", OnCommodityResults)
-- Blizzard's commodity list also treats RECEIVED as "results are in". It may carry no item ID; then it is
-- taken as the answer to our current commodity search.
CP:RegisterEvent("COMMODITY_SEARCH_RESULTS_RECEIVED", function(event, itemID)
	local cur = Scanner.itemCurrent
	if not itemID and cur and cur.commodity then itemID = cur.itemID end
	local n
	if itemID and C_AuctionHouse.GetNumCommoditySearchResults then
		local ok, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
		n = ok and count or nil
	end
	if not (n and n > 0) then
		CountEvent(event) -- nothing readable yet: UPDATED brings the rows
		return
	end
	OnCommodityResults(event, itemID)
end)
CP:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED", OnItemResults)
CP:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED", OnItemResults)
CP:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
	if Scanner.itemWaitingThrottle then
		Scanner.itemWaitingThrottle = false
		local st = JobStats()
		if st and Scanner.throttleSince then st.throttle = st.throttle + (GetTime() - Scanner.throttleSince) end
		Scanner.throttleSince = nil
		Scanner:NextItem()
	end
end)
CP:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
	Scanner:FinishDepth("Auction House closed")
	Scanner.itemQueue = nil
	Scanner.itemCurrent = nil
	Scanner.itemWaitingThrottle = false
	Scanner.itemPausedForBuy = false
end)

-- Resume a paused depth scan when the player leaves the buy page.
local displayModeHooked
local function HookDisplayMode()
	if displayModeHooked or not (AuctionHouseFrame and type(AuctionHouseFrame.SetDisplayMode) == "function" and hooksecurefunc) then return end
	displayModeHooked = true
	pcall(hooksecurefunc, AuctionHouseFrame, "SetDisplayMode", function()
		if Scanner.itemPausedForBuy and not BuyPageOpen() then
			Scanner.itemPausedForBuy = false
			Scanner:NextItem()
		end
	end)
end
CP:RegisterEvent("AUCTION_HOUSE_SHOW", HookDisplayMode)
CP:RegisterEvent("ADDON_LOADED", function(_, name) if name == "Blizzard_AuctionHouseUI" then HookDisplayMode() end end)

---------------------------------------------------------------------------
-- Depth pass after a full scan
---------------------------------------------------------------------------
-- The browse scan cannot see past the lowest buyout, so after a complete scan the listings of the items that
-- matter are read one by one (ScanItems): reagents and outputs of every recipe learned on this account (from
-- the saved schematic cache) and anything bought. Reagents go first. Skipped: vendor-bought reagents, items
-- not listed in the last scan, items whose listings were read in the last 2 hours. The rest go stalest first
-- (never read, then oldest depth value), so runs that stop early still cover everything over time. Each read
-- stores a ladder and a depth value; it stops paging at the units the depth value needs. The finish message
-- reports the time per item and where it went (answer time, timeouts, extra pages, throttle, other searches).

local DEPTH_MAX_ITEMS = 400

-- Returns the itemIDs to read and skip counts { vendor, unlisted, fresh, capped }.
function Scanner:DepthWatchlist()
	local db, realm = CP.db, CP:GetRealmDB()
	local cache = db.recipeCache or {}
	local recipes, seenRecipe = {}, {}
	for _, set in pairs(db.learned or {}) do
		for rid in pairs(set) do
			if not seenRecipe[rid] then
				seenRecipe[rid] = true
				recipes[#recipes + 1] = rid
			end
		end
	end
	table.sort(recipes)
	local reagents, outputs, seen = {}, {}, {}
	local function Add(list, id)
		if id and id > 0 and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	for _, rid in ipairs(recipes) do
		local c = cache[rid]
		for _, slot in ipairs(c and c.r or {}) do
			for i = 2, #slot do Add(reagents, slot[i]) end
		end
	end
	local bought = {}
	for id in pairs(realm.purchases or {}) do bought[#bought + 1] = id end
	table.sort(bought)
	for _, id in ipairs(bought) do Add(reagents, id) end
	for _, rid in ipairs(recipes) do
		local c = cache[rid]
		if c then Add(outputs, c.o) end
	end

	local candidates, info = {}, { vendor = 0, unlisted = 0, fresh = 0, freshItems = 0, single = 0, capped = 0 }
	local listedSince = (realm.lastScan or 0) - 60
	local function Take(list, rank)
		for i, id in ipairs(list) do
			local rec = realm.prices[id]
			local age = self:GetLadderAge(id)
			if db.vendor and db.vendor[id] then
				info.vendor = info.vendor + 1
			elseif not rec or (rec[3] or 0) < listedSince then
				info.unlisted = info.unlisted + 1
			elseif age and age < DEPTH_FRESH then
				info.fresh = info.fresh + 1
			elseif age and age < DEPTH_FRESH_ITEM and self:IsCommodity(id, self:GetItemKey(id)) == false then
				info.freshItems = info.freshItems + 1
			elseif (rec[2] or 0) == 1 then
				-- one listing on the whole AH: its price is the depth value, no search needed
				self:SetDepth(id, rec[1], 1, rec[3])
				CP:Touch(id)
				info.single = info.single + 1
			else
				local d = realm.mv and realm.mv[id]
				candidates[#candidates + 1] = { id = id, t = d and d[3] or 0, rank = rank, i = i }
			end
		end
	end
	Take(reagents, 1)
	Take(outputs, 2)
	table.sort(candidates, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.i < b.i
	end)
	local ids = {}
	for _, c in ipairs(candidates) do
		if #ids < DEPTH_MAX_ITEMS then ids[#ids + 1] = c.id else info.capped = info.capped + 1 end
	end
	return ids, info
end

local function SkipText(info)
	local parts = {}
	if info.fresh > 0 then parts[#parts + 1] = info.fresh .. " read in the last 2 h" end
	if info.freshItems > 0 then parts[#parts + 1] = info.freshItems .. " gear read in the last 24 h" end
	if info.single > 0 then parts[#parts + 1] = info.single .. " with a single listing" end
	if info.unlisted > 0 then parts[#parts + 1] = info.unlisted .. " not listed" end
	if info.vendor > 0 then parts[#parts + 1] = info.vendor .. " from vendors" end
	if info.capped > 0 then parts[#parts + 1] = info.capped .. " for the next run" end
	return #parts > 0 and (" (skipped: " .. table.concat(parts, ", ") .. ")") or ""
end

function Scanner:StartDepth()
	if not self.ahOpen then
		CP:Print("open the Auction House first.")
		return false
	end
	if self.running then
		CP:Print("a full scan is running.")
		return false
	end
	if self.depthJob then
		CP:Print("a depth scan is already running.")
		return false
	end
	local ids, info = self:DepthWatchlist()
	if #ids == 0 then
		local skipped = SkipText(info)
		CP:Print("depth scan: nothing to read%s.", skipped ~= "" and skipped or " - open your professions once so their recipes are known")
		return false
	end
	local set = {}
	for _, id in ipairs(ids) do set[id] = true end
	self.depthJob = { start = GetTime(), total = #ids, ids = set, done = 0, retried = {}, flipped = {},
		stats = { searches = 0, commodities = 0, answers = 0, answerTime = 0, timeouts = 0, pages = 0, throttle = 0, foreign = 0, events = {} } }
	-- ask for every item's key info now (loads it), so its commodity status is known when its search goes out
	if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
		for _, id in ipairs(ids) do
			local okKey, key = pcall(self.GetItemKey, self, id)
			if okKey and key then self:IsCommodity(id, key) end
		end
	end
	local ok, err = self:ScanItems(ids, { shallow = true })
	if not ok then
		self.depthJob = nil
		CP:Print("depth scan did not start: %s", tostring(err))
		return false
	end
	if self.depthJob then
		CP:Print("depth scan: reading the listings of %d items%s...", #ids, SkipText(info))
		UpdateButton()
	end
	return true
end

-- Drops the rest of the queue; the item being read finishes and ends the job.
function Scanner:StopDepth()
	local job = self.depthJob
	if not job then return end
	job.stopped = true
	self.itemQueue = nil
	if not self.itemCurrent then self:NextItem() end
end

function Scanner:FinishDepth(reason)
	local job = self.depthJob
	if not job then return end
	self.depthJob = nil
	reason = reason or (job.stopped and "stopped") or nil
	local elapsed = GetTime() - job.start
	if self.throttleSince then job.stats.throttle = job.stats.throttle + (GetTime() - self.throttleSince) end
	local st = job.stats
	self.lastDepth = { at = time(), done = job.done, total = job.total, elapsed = elapsed, reason = reason, stats = st }
	local per = job.done > 0 and elapsed / job.done or 0
	if reason then
		CP:Print("depth scan %s: %d of %d items read in %.0fs (%.1fs per item).", reason == "stopped" and reason or ("stopped (" .. reason .. ")"),
			job.done, job.total, elapsed, per)
	else
		CP:Print("depth scan complete: %d items in %.0fs (%.1fs per item).", job.done, elapsed, per)
	end
	CP:Print("  %d searches (%d commodities), answer %.1fs avg, %d timed out (limit %.0fs), %d extra pages, %.0fs waiting for the AH throttle, %d answers to other addons' searches.",
		st.searches, st.commodities, st.answers > 0 and st.answerTime / st.answers or 0, st.timeouts, self:ItemTimeout(), st.pages, st.throttle, st.foreign)
	if st.timeouts > 0 then
		local names = {}
		for event, n in pairs(st.events) do names[#names + 1] = event:gsub("_SEARCH_RESULTS_", " "):lower() .. " " .. n end
		table.sort(names)
		CP:Print("  result events seen: %s.", #names > 0 and table.concat(names, ", ") or "none")
	end
	UpdateButton()
	CP:Fire("PRICES_UPDATED", "depth")
	CP:Fire("DEPTH_SCAN_FINISHED", job.done, reason)
end

CP:On("ITEM_SCAN_FINISHED", function() Scanner:FinishDepth() end)

---------------------------------------------------------------------------
-- Actual purchases
---------------------------------------------------------------------------
-- StartCommoditiesPurchase(itemID, qty) -> COMMODITY_PRICE_UPDATED(unitPrice, totalPrice) is the server's
-- quote; ConfirmCommoditiesPurchase then COMMODITY_PURCHASE_SUCCEEDED means it was paid. Recorded per realm
-- (realm.purchases[itemID] = last 20 { t, qty, unit }) and the ladder is reduced accordingly.

local PURCHASES_MAX = 20
local lastQuote, pendingPurchase

function Scanner:RecordPurchase(itemID, quantity, total)
	if not itemID or not quantity or quantity <= 0 or not total then return end
	CP:Touch(itemID)
	local realm = CP:GetRealmDB()
	realm.purchases = realm.purchases or {}
	local list = realm.purchases[itemID] or {}
	realm.purchases[itemID] = list
	local unit = total / quantity
	table.insert(list, { time(), quantity, unit })
	while #list > PURCHASES_MAX do table.remove(list, 1) end
	self:ConsumeLadder(itemID, quantity)
	CP:Debug("bought %dx %s for %s", quantity, tostring(itemID), CP:FormatMoney(total))
	CP:Fire("PURCHASE_RECORDED", itemID, quantity, total, unit)
end

-- Most recent price actually paid per unit, and how long ago.
function Scanner:GetLastPaid(itemID)
	local realm = CP:GetRealmDB()
	local list = realm.purchases and realm.purchases[itemID]
	local last = list and list[#list]
	if not last then return nil end
	return last[3], time() - last[1], last[2]
end

CP:RegisterEvent("COMMODITY_PRICE_UPDATED", function(_, unitPrice, totalPrice)
	lastQuote = { unit = unitPrice, total = totalPrice, t = GetTime() }
end)
CP:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED", function()
	local p = pendingPurchase
	pendingPurchase = nil
	if p then Scanner:RecordPurchase(p.itemID, p.quantity, p.total) end
end)
CP:RegisterEvent("COMMODITY_PURCHASE_FAILED", function() pendingPurchase = nil end)
CP:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE", function() lastQuote = nil end)

if C_AuctionHouse and type(C_AuctionHouse.ConfirmCommoditiesPurchase) == "function" and hooksecurefunc then
	pcall(hooksecurefunc, C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
		local q = lastQuote
		local total = q and q.total
		if not total and q and q.unit then total = q.unit * (quantity or 0) end
		pendingPurchase = { itemID = itemID, quantity = quantity, total = total }
	end)
end

-- Item auctions (gear and everything else that is not a commodity): the Buy tab calls
-- C_AuctionHouse.PlaceBid(auctionID, amount); the auctionID is looked up among the listings seen in the item
-- search results, and AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID) (or, failing that, a matching drop in
-- money) means it was paid. A bid below the buyout is not a purchase.
local MONEY_MATCH_WINDOW = 5
local listings, pendingBids, lastMoney = {}, {}, nil

function Scanner:CacheListing(auctionID, itemID, quantity, buyout)
	listings[auctionID] = { itemID = itemID, qty = quantity or 1, buyout = buyout }
end

local function ListingFor(auctionID)
	local l = listings[auctionID]
	if l then return l end
	if C_AuctionHouse.GetAuctionInfoByID then
		local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
		local itemID = ok and type(info) == "table" and type(info.itemKey) == "table" and info.itemKey.itemID
		if itemID then return { itemID = itemID, qty = info.quantity or 1, buyout = info.buyoutAmount } end
	end
end

local function CommitBid(auctionID)
	local p = pendingBids[auctionID]
	if not p then return end
	pendingBids[auctionID] = nil
	listings[auctionID] = nil
	Scanner:RecordPurchase(p.itemID, p.qty, p.total)
end

if C_AuctionHouse and type(C_AuctionHouse.PlaceBid) == "function" and hooksecurefunc then
	pcall(hooksecurefunc, C_AuctionHouse, "PlaceBid", function(auctionID, amount)
		if not auctionID or not amount then return end
		local l = ListingFor(auctionID)
		if not l then
			CP:Debug("PlaceBid on unknown auction %s, not recorded", tostring(auctionID))
			return
		end
		if l.buyout and amount < l.buyout then return end
		-- A result row's buyout is the price of one unit and its quantity is how many the row holds (WoW Forever
		-- groups identical auctions into one row: "860 at 1s"). What was bought is what the amount pays for,
		-- never the whole row.
		local qty = 1
		if l.buyout and l.buyout > 0 then
			qty = math.max(1, math.min(l.qty or 1, math.floor(amount / l.buyout + 0.5)))
		end
		pendingBids[auctionID] = { itemID = l.itemID, qty = qty, total = amount, t = GetTime() }
	end)
end
CP:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
	if auctionID then CommitBid(auctionID) end
end)
CP:RegisterEvent("PLAYER_MONEY", function()
	local money = GetMoney and GetMoney() or 0
	local prev = lastMoney
	lastMoney = money
	if not prev or money >= prev then return end
	for auctionID, p in pairs(pendingBids) do
		if p.total == prev - money and GetTime() - p.t <= MONEY_MATCH_WINDOW then
			CommitBid(auctionID)
			return
		end
	end
end)
CP:RegisterEvent("PLAYER_LOGIN", function() lastMoney = GetMoney and GetMoney() or 0 end)
CP:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
	wipe(listings)
	wipe(pendingBids)
end)
