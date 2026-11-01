-- CraftProfit :: VendorPrices
-- Vendor buy prices for reagents. Learned automatically from every merchant the player opens,
-- seeded with well-known vanilla trade-goods vendors so common reagents have a price before the first visit.
-- Also the vendor sell price of crafted items (vendor net), read from the item data.

local _, CP = ...
local Vendor = {}
CP.Vendor = Vendor

-- itemID -> copper per unit. Approximate seed values; learned prices override them.
Vendor.seed = {
	-- Tailoring / Leatherworking thread
	[2320]  = 10,     -- Coarse Thread
	[2321]  = 100,    -- Fine Thread
	[4291]  = 500,    -- Silken Thread
	[8343]  = 2000,   -- Heavy Silken Thread
	[14341] = 5000,   -- Rune Thread
	-- Dyes & bleach
	[2324]  = 25,     -- Bleach
	[2604]  = 50,     -- Red Dye
	[6260]  = 50,     -- Blue Dye
	[2605]  = 100,    -- Green Dye
	[4340]  = 100,    -- Gray Dye
	[6261]  = 250,    -- Orange Dye
	[4341]  = 500,    -- Yellow Dye
	[4342]  = 2500,   -- Purple Dye
	-- Blacksmithing / Engineering
	[2880]  = 100,    -- Weak Flux
	[3466]  = 2000,   -- Strong Flux
	[3857]  = 500,    -- Coal
	-- Alchemy
	[3371]  = 20,     -- Empty Vial
	[3372]  = 200,    -- Leaded Vial
	[8925]  = 2000,   -- Crystal Vial
	-- Enchanting
	[6217]  = 124,    -- Copper Rod
	-- Cooking
	[2678]  = 10,     -- Mild Spices
	[2692]  = 20,     -- Hot Spices
	[3713]  = 40,     -- Soothing Spices
	[159]   = 25,     -- Refreshing Spring Water
	[1179]  = 125,    -- Ice Cold Milk
	-- Leatherworking
	[4289]  = 5,      -- Salt
	-- Engineering / Blacksmithing wood
	[4470]  = 38,     -- Simple Wood
}

function Vendor:GetPrice(itemID)
	if not itemID then return nil end
	local learned = CP.db and CP.db.vendor and CP.db.vendor[itemID]
	if learned and learned > 0 then return learned, "learned" end
	local seed = self.seed[itemID]
	if seed then return seed, "seed" end
	return nil
end

local function ReadMerchantItem(index)
	local link = GetMerchantItemLink and GetMerchantItemLink(index)
	local itemID = CP:ItemIDFromLink(link)
	if not itemID then return nil end

	local price, stack, extended, numAvailable
	if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
		local info = C_MerchantFrame.GetItemInfo(index)
		if info then
			price = info.price
			stack = info.stackCount or info.quantity
			extended = info.hasExtendedCost
			numAvailable = info.numAvailable
		end
	elseif GetMerchantItemInfo then
		local _, _, p, q, na, _, _, ext = GetMerchantItemInfo(index)
		price, stack, numAvailable, extended = p, q, na, ext
	end

	if GetMerchantItemCostInfo then
		local costCount = GetMerchantItemCostInfo(index)
		if costCount and costCount > 0 then extended = true end
	end

	if not price or price <= 0 or extended then return nil end
	-- skip limited-stock items (numAvailable >= 0); unlimited stock is -1 or nil
	if numAvailable and numAvailable >= 0 then return nil end
	stack = (stack and stack > 0) and stack or 1
	return itemID, math.floor(price / stack + 0.5)
end

function Vendor:Learn()
	if not CP.db or not GetMerchantNumItems then return end
	local count = GetMerchantNumItems() or 0
	local changed = 0
	for i = 1, count do
		local ok, itemID, unit = pcall(ReadMerchantItem, i)
		if ok and itemID and unit then
			if CP.db.vendor[itemID] ~= unit then
				CP.db.vendor[itemID] = unit
				changed = changed + 1
			end
		end
	end
	if changed > 0 then
		CP:Debug("learned %d vendor prices", changed)
		CP:Fire("VENDOR_UPDATED", changed)
	end
end

CP:RegisterEvent("MERCHANT_SHOW", function() Vendor:Learn() end)
CP:RegisterEvent("MERCHANT_UPDATE", function() Vendor:Learn() end)

---------------------------------------------------------------------------
-- Vendor sell price (what a merchant pays for an item)
---------------------------------------------------------------------------
-- Part of the item data, so it needs no scan. The client may not have the item cached yet: then the data is
-- requested and VENDOR_UPDATED fires (debounced) once it arrives, which re-prices the open windows.
-- Kept in memory only; 0 = the item cannot be sold to a merchant.

local sellCache, sellRequested = {}, {}
local refreshPending = false

-- Returns the price per unit, or nil plus "pending" while the item data is still loading.
function Vendor:GetSellPrice(itemID)
	if not itemID then return nil end
	local cached = sellCache[itemID]
	if cached then return cached > 0 and cached or nil end
	if not (C_Item and C_Item.GetItemInfo) then return nil end
	local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
	if ok and name then
		sellCache[itemID] = (type(sellPrice) == "number" and sellPrice > 0) and sellPrice or 0
		return sellCache[itemID] > 0 and sellCache[itemID] or nil
	end
	if not sellRequested[itemID] and C_Item.RequestLoadItemDataByID then
		sellRequested[itemID] = true
		pcall(C_Item.RequestLoadItemDataByID, itemID)
	end
	return nil, "pending"
end

CP:RegisterEvent("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
	if not itemID or not sellRequested[itemID] then return end
	sellRequested[itemID] = nil
	if success == false then sellCache[itemID] = 0 return end
	if refreshPending then return end
	refreshPending = true
	local function Refresh()
		refreshPending = false
		CP:Fire("VENDOR_UPDATED")
	end
	if C_Timer and C_Timer.After then C_Timer.After(0.5, Refresh) else Refresh() end
end)
