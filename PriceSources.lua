-- CraftProfit :: PriceSources
-- Registry of price providers and the unified price lookups used by the calculator.
--
-- A source definition:
--   key            string, used in settings ("craftprofit", "auctionator", "tsm")
--   name           display name
--   IsAvailable()  provider addon loaded and its API present
--   HasData()      provider has at least some price data
--   GetCostPrice(itemID)   copper per unit to BUY a reagent, or nil
--   GetSalePrice(itemID)   copper per unit expected when SELLING the output, or nil
--   GetAge(itemID)         seconds since the price was recorded, or nil
--   GetSoldPerDay(itemID)  estimated units sold per day, or nil
--   Init()         optional, called once at PLAYER_LOGIN

local _, CP = ...
local Sources = { list = {}, byKey = {} }
CP.Sources = Sources

-- Order tried when the setting is "auto".
Sources.AUTO_ORDER = { "auctionator", "tsm", "craftprofit" }

function Sources:Register(def)
	assert(def and def.key, "price source needs a key")
	if self.byKey[def.key] then return end
	self.byKey[def.key] = def
	table.insert(self.list, def)
end

function Sources:Get(key)
	return self.byKey[key]
end

function Sources:Init()
	for _, def in ipairs(self.list) do
		if def.Init and def:IsAvailable() then
			local ok, err = pcall(def.Init, def)
			if not ok then CP:Debug("source %s init failed: %s", def.key, tostring(err)) end
		end
	end
end

-- Returns the source to use, or nil plus a reason string.
function Sources:Resolve()
	local want = (CP.settings and CP.settings.source) or "auto"
	if want ~= "auto" then
		local def = self.byKey[want]
		if def and def:IsAvailable() then return def end
		return nil, want .. " not available"
	end
	for _, key in ipairs(self.AUTO_ORDER) do
		local def = self.byKey[key]
		if def and def:IsAvailable() and def:HasData() then return def end
	end
	for _, key in ipairs(self.AUTO_ORDER) do
		local def = self.byKey[key]
		if def and def:IsAvailable() then return def end
	end
	return nil, "no source"
end

local function SafeCall(def, method, itemID)
	local fn = def[method]
	if not fn then return nil end
	local ok, value = pcall(fn, def, itemID)
	if ok and type(value) == "number" and value > 0 then return value end
	if not ok then CP:Debug("%s.%s(%s) error: %s", def.key, method, tostring(itemID), tostring(value)) end
	return nil
end

---------------------------------------------------------------------------
-- Unified lookups
---------------------------------------------------------------------------

function CP:GetSourceName()
	local def = Sources:Resolve()
	return def and def.name or "no price source"
end

-- Demo mode (Demo.lua) can multiply every price to test gold-scale layouts.
local function DemoScale(price)
	local scale = CP.demo and CP.demo.scale
	if price and scale then return price * scale end
	return price
end

-- copper per unit, source key
function CP:GetSalePrice(itemID)
	if not itemID then return nil end
	self:Touch(itemID)
	local def = Sources:Resolve()
	if not def then return nil end
	local price = SafeCall(def, "GetSalePrice", itemID)
	return DemoScale(price), def.key
end

-- copper per unit, kind ("ah" | "vendor")
function CP:GetReagentCost(itemID)
	if not itemID then return nil end
	self:Touch(itemID)
	local def = Sources:Resolve()
	local ah = def and SafeCall(def, "GetCostPrice", itemID) or nil
	local vendor = self.Vendor:GetPrice(itemID)
	if vendor and (not ah or (self.settings.useVendorWhenCheaper and vendor < ah)) then
		return DemoScale(vendor), "vendor"
	end
	if ah then return DemoScale(ah), "ah" end
	return nil
end

-- Cost of buying `quantity` units, walking the price ladder when one has been captured (see Scanner)
-- and falling back to unit price x quantity. Vendor wins when it is cheaper for the whole lot.
-- Returns total copper, average unit, kind ("ladder" | "ah" | "vendor"), info (see Scanner:GetBuyCost;
-- info.source is "min" when no ladder exists).
function CP:GetReagentCostFor(itemID, quantity)
	if not itemID then return nil end
	quantity = math.max(1, math.floor(tonumber(quantity) or 1))
	local total, avg, kind, info
	if self.Scanner and self.Scanner:GetLadder(itemID) then
		total, avg, info = self.Scanner:GetBuyCost(itemID, quantity)
		kind = "ladder"
	else
		local unit, unitKind = self:GetReagentCost(itemID)
		if unit then
			total, avg, kind = unit * quantity, unit, unitKind
			local listed = self.Scanner and self.Scanner:GetQuantity(itemID) or nil
			info = { source = "min", minPrice = unit, listed = listed, full = listed ~= nil,
				covered = listed and math.min(quantity, listed) or quantity,
				short = (listed and unitKind ~= "vendor") and math.max(0, quantity - listed) or 0,
				age = self:GetPriceAge(itemID) }
		end
	end
	local vendor = self.Vendor:GetPrice(itemID)
	if vendor and (not total or (self.settings.useVendorWhenCheaper and vendor * quantity <= total)) then
		return DemoScale(vendor * quantity), DemoScale(vendor), "vendor",
			{ source = "vendor", minPrice = vendor, covered = quantity, short = 0, full = true }
	end
	if not total then return nil end
	if kind == "ladder" and info then
		info.source = "ladder"
	end
	return DemoScale(total), DemoScale(avg), kind, info
end

-- units per day, source key. Sources without sales data (Auctionator) fall back to CraftProfit's own
-- scan history, so prices can come from one source and sold per day from another.
function CP:GetSoldPerDay(itemID)
	if not itemID then return nil end
	local def = Sources:Resolve()
	local value = def and SafeCall(def, "GetSoldPerDay", itemID) or nil
	if value then return value, def.key end
	local own = Sources.byKey.craftprofit
	if own and own ~= def then
		value = SafeCall(own, "GetSoldPerDay", itemID)
		if value then return value, own.key end
	end
	return nil
end

function CP:GetPriceAge(itemID)
	local def = Sources:Resolve()
	if not def or not def.GetAge then return nil end
	local ok, age = pcall(def.GetAge, def, itemID)
	if ok and type(age) == "number" then return age end
	return nil
end

---------------------------------------------------------------------------
-- Auctionator
---------------------------------------------------------------------------

local function AuctionatorAPI()
	local a = _G.Auctionator
	return a and a.API and a.API.v1 or nil
end

Sources:Register({
	key = "auctionator",
	name = "Auctionator",
	description = "Auctionator's scan database (Shopping tab > Full Scan).",
	IsAvailable = function()
		local api = AuctionatorAPI()
		return api ~= nil and type(api.GetAuctionPriceByItemID) == "function"
	end,
	HasData = function()
		return true -- no cheap way to ask; a full scan populates it
	end,
	GetCostPrice = function(_, itemID)
		return AuctionatorAPI().GetAuctionPriceByItemID(CP.CALLER_ID, itemID)
	end,
	GetSalePrice = function(_, itemID)
		return AuctionatorAPI().GetAuctionPriceByItemID(CP.CALLER_ID, itemID)
	end,
	GetAge = function(_, itemID)
		local api = AuctionatorAPI()
		if api and type(api.GetAuctionAgeByItemID) == "function" then
			local days = api.GetAuctionAgeByItemID(CP.CALLER_ID, itemID)
			if type(days) == "number" then return days * 86400 end
		end
		return nil
	end,
	GetSoldPerDay = function() return nil end,
	Init = function()
		local api = AuctionatorAPI()
		if api and type(api.RegisterForDBUpdate) == "function" then
			api.RegisterForDBUpdate(CP.CALLER_ID, function()
				CP:Fire("PRICES_UPDATED", "auctionator")
			end)
		end
	end,
})

---------------------------------------------------------------------------
-- TradeSkillMaster
---------------------------------------------------------------------------

local function TSMValue(priceString, itemID)
	local api = _G.TSM_API
	if not api or type(api.GetCustomPriceValue) ~= "function" then return nil end
	local value = api.GetCustomPriceValue(priceString, "i:" .. itemID)
	return value
end

Sources:Register({
	key = "tsm",
	name = "TradeSkillMaster",
	description = "TSM price sources. DB* sources need the TSM desktop app feeding Forever realm data.",
	IsAvailable = function()
		local api = _G.TSM_API
		return api ~= nil and type(api.GetCustomPriceValue) == "function"
	end,
	HasData = function()
		return true
	end,
	GetCostPrice = function(_, itemID)
		return TSMValue(CP.settings.tsmCost, itemID)
	end,
	GetSalePrice = function(_, itemID)
		return TSMValue(CP.settings.tsmSale, itemID)
	end,
	GetAge = function() return nil end,
	GetSoldPerDay = function(_, itemID)
		-- TSM returns its sold-per-day figure as a plain number; verify scaling in game.
		return TSMValue(CP.settings.tsmSoldPerDay, itemID)
	end,
})

-- The "craftprofit" source (own AH scan) is registered in Scanner.lua.
