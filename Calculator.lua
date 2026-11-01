-- CraftProfit :: Calculator
-- Turns a recipe schematic plus price lookups into cost / sale / net / margin numbers.
-- Results are cached per recipe and invalidated whenever prices or settings change.

local _, CP = ...
local Calc = {}
CP.Calc = Calc

local cache = {}
local cacheCrafted = {}       -- same numbers with self-crafted intermediates always considered (GetCrafted)
local forceCraft = false      -- true while computing for GetCrafted / ReagentCostCrafted
local computing = {}          -- recipeID -> true while its cost is being computed (cycle guard)
local MAX_CRAFT_DEPTH = 3     -- Bolt <- Cloth is depth 1; three levels covers every vanilla chain

-- outputItemID -> recipeID for recipes the player has learned. Filled from every profession window
-- opened this session, so cross-profession intermediates work once each profession has been opened.
CP.crafts = {}
local craftsSignature

local function BasicReagentType()
	return (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
end

function Calc:Invalidate()
	wipe(cache)
	wipe(cacheCrafted)
end

CP:On("PRICES_UPDATED", function() Calc:Invalidate() end)
CP:On("VENDOR_UPDATED", function() Calc:Invalidate() end)
CP:On("SETTINGS_CHANGED", function() Calc:Invalidate() end)

---------------------------------------------------------------------------
-- Learned recipes -> craftable items
---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Schematic cache
---------------------------------------------------------------------------
-- The client only serves recipe schematics while that profession's window is open. Every schematic we
-- read is stored compactly in the saved variables, so costs (and companion addons) keep working
-- after a /reload or relog without opening the profession first.
--   cache[recipeID] = { o = outputItemID, qmin, qmax, r = { { qty, itemID1, itemID2, ... }, ... } }

-- Calc.skipSchematicCache: set by callers that price recipes nobody on the account has learned (a recipe
-- browser can read ~1,500 of them); those would bloat the saved cache without ever being needed offline.
local function CacheSchematic(recipeID, schematic)
	if Calc.skipSchematicCache then return end
	if not CP.db or not CP.db.recipeCache then return end
	local basic = BasicReagentType()
	local slots = {}
	for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
		if slot.reagentType == basic and slot.required ~= false then
			local entry = { slot.quantityRequired or 1 }
			for _, reagent in ipairs(slot.reagents or {}) do
				if reagent.itemID then table.insert(entry, reagent.itemID) end
			end
			table.insert(slots, entry)
		end
	end
	if #slots == 0 and not (schematic.outputItemID and schematic.outputItemID > 0) then return end
	CP.db.recipeCache[recipeID] = {
		o = (schematic.outputItemID and schematic.outputItemID > 0) and schematic.outputItemID or nil,
		qmin = schematic.quantityMin or 1, qmax = schematic.quantityMax or schematic.quantityMin or 1, r = slots,
	}
end

local function ExpandCached(c)
	local basic = BasicReagentType()
	local schematic = { outputItemID = c.o, quantityMin = c.qmin, quantityMax = c.qmax, reagentSlotSchematics = {}, cached = true }
	for _, entry in ipairs(c.r or {}) do
		local reagents = {}
		for i = 2, #entry do table.insert(reagents, { itemID = entry[i] }) end
		table.insert(schematic.reagentSlotSchematics, { reagentType = basic, quantityRequired = entry[1], required = true, reagents = reagents })
	end
	return schematic
end

-- Live schematic when the client has it (and caches it), the saved copy otherwise.
local function ReadSchematic(recipeID)
	local live
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
		local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
		if ok and type(schematic) == "table" then live = schematic end
	end
	if live and #(live.reagentSlotSchematics or {}) > 0 then
		CacheSchematic(recipeID, live)
		return live
	end
	local cached = CP.db and CP.db.recipeCache and CP.db.recipeCache[recipeID]
	if cached then return ExpandCached(cached) end
	return live
end
Calc.ReadSchematic = ReadSchematic

local function GetOutputItemIDFor(recipeID)
	local schematic = ReadSchematic(recipeID)
	if schematic and schematic.outputItemID and schematic.outputItemID > 0 then
		return schematic.outputItemID
	end
	if C_TradeSkillUI.GetRecipeItemLink then
		local ok2, link = pcall(C_TradeSkillUI.GetRecipeItemLink, recipeID)
		if ok2 then return CP:ItemIDFromLink(link) end
	end
	return nil
end

-- Learned recipes of this character as saved (recipeID -> true), for use before a profession is opened.
function CP:GetLearnedRecipes()
	local key = self:GetCharKey()
	return (self.db and self.db.learned and self.db.learned[key]) or {}
end

-- At login: rebuild the craftable-item map from the saved learned list and schematic cache.
function Calc:RestoreCrafts()
	local learned = CP:GetLearnedRecipes()
	local cache = CP.db and CP.db.recipeCache or {}
	local n = 0
	for recipeID in pairs(learned) do
		local c = cache[recipeID]
		if c and c.o and not CP.crafts[c.o] then
			CP.crafts[c.o] = recipeID
			n = n + 1
		end
	end
	if n > 0 then
		self:Invalidate()
		CP:Fire("CRAFTS_UPDATED")
	end
	CP:Debug("restored %d craftable items from the saved recipe cache", n)
	return n
end

-- Returns true when the craftable-item map changed.
function Calc:RefreshCrafts()
	if not (C_TradeSkillUI and C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo) then return false end
	-- Only learn from the player's own professions, not linked or guild views.
	if C_TradeSkillUI.IsTradeSkillLinked and C_TradeSkillUI.IsTradeSkillLinked() then return false end
	if C_TradeSkillUI.IsTradeSkillGuild and C_TradeSkillUI.IsTradeSkillGuild() then return false end
	if C_TradeSkillUI.IsNPCCrafting and C_TradeSkillUI.IsNPCCrafting() then return false end

	local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
	if not ok or type(ids) ~= "table" then return false end

	local learned = {}
	for _, id in ipairs(ids) do
		local ok2, info = pcall(C_TradeSkillUI.GetRecipeInfo, id)
		if ok2 and info and info.learned then table.insert(learned, id) end
	end
	table.sort(learned)
	local signature = table.concat(learned, ",")
	if signature == craftsSignature then return false end
	craftsSignature = signature

	-- remember this character's learned recipes (merged: other professions were saved on earlier opens)
	if CP.db and CP.db.learned then
		local key = CP:GetCharKey()
		CP.db.learned[key] = CP.db.learned[key] or {}
		for _, id in ipairs(learned) do CP.db.learned[key][id] = true end
	end

	local changed = false
	for _, id in ipairs(learned) do
		local itemID = GetOutputItemIDFor(id) -- also fills the schematic cache
		if itemID and CP.crafts[itemID] ~= id then
			-- Prefer the first recipe found for an item; ranks/variants share the output.
			if not CP.crafts[itemID] then
				CP.crafts[itemID] = id
				changed = true
			end
		end
	end
	if changed then
		self:Invalidate()
		CP:Fire("CRAFTS_UPDATED")
	end
	CP:Debug("craftable items known: %d", (function() local n = 0 for _ in pairs(CP.crafts) do n = n + 1 end return n end)())
	return changed
end

function Calc:GetCraftRecipe(itemID)
	return itemID and CP.crafts[itemID] or nil
end

CP:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() Calc:RefreshCrafts() end)
CP:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED", function() Calc:RefreshCrafts() end)

---------------------------------------------------------------------------
-- Reagent cost honouring the "craft intermediates" option
---------------------------------------------------------------------------

-- Returns unit cost, kind ("craft" | "ah" | "vendor"), and for crafted reagents the recipeID
-- plus the buy price it replaced (nil when unknown).
-- Self-crafting is considered when the "craft intermediates" option is on (or inside GetCrafted), and
-- with "only when cheaper" (default) a learned recipe is only used when its cost beats the buy price.
function Calc:ReagentCost(itemID, depth)
	if not itemID then return nil end
	depth = depth or 0
	if (forceCraft or CP.settings.craftIntermediates) and depth < MAX_CRAFT_DEPTH then
		local recipeID = CP.crafts[itemID]
		if recipeID and not computing[recipeID] then
			local sub = self:Get(recipeID, depth + 1)
			if sub and sub.costComplete and #sub.reagents > 0 and (sub.quantity or 0) > 0 then
				local craftUnit = sub.cost / sub.quantity
				local buy = CP:GetReagentCost(itemID)
				local onlyCheaper = forceCraft or CP.settings.craftOnlyWhenCheaper
				if not (onlyCheaper and buy and buy <= craftUnit) then
					return craftUnit, "craft", recipeID, buy
				end
			end
		end
	end
	return CP:GetReagentCost(itemID)
end

-- Same as ReagentCost but always considers a learned recipe (used when it is cheaper than buying),
-- regardless of the craftIntermediates setting. For companion addons.
function Calc:ReagentCostCrafted(itemID)
	local prev = forceCraft
	forceCraft = true
	local ok, unit, kind, recipeID, buy = pcall(self.ReagentCost, self, itemID, 0)
	forceCraft = prev
	if ok then return unit, kind, recipeID, buy end
	CP:Debug("ReagentCostCrafted %s failed: %s", tostring(itemID), tostring(unit))
	return nil
end

local function GetOutputItemID(recipeID, schematic)
	if schematic and schematic.outputItemID and schematic.outputItemID > 0 then
		return schematic.outputItemID
	end
	if C_TradeSkillUI and C_TradeSkillUI.GetRecipeItemLink then
		local ok, link = pcall(C_TradeSkillUI.GetRecipeItemLink, recipeID)
		if ok then return CP:ItemIDFromLink(link) end
	end
	return nil
end

-- Returns the economics table for a recipe:
--   outputItemID, quantity, reagents = { {itemID, qty, unit, total, kind} }, cost, costComplete, missing,
--   saleUnit, sale, cut, net, margin, soldPerDay, age, source,
--   vendorUnit, vendorSale, vendorNet, vendorMargin (sold to a merchant; nil when the item has no vendor price)
function Calc:Get(recipeID, depth)
	if not recipeID then return nil end
	local store = forceCraft and cacheCrafted or cache
	local eco = store[recipeID]
	if eco then return eco end
	eco = self:Compute(recipeID, depth or 0)
	store[recipeID] = eco
	return eco
end

-- Economics with self-crafted intermediates always considered (used when cheaper than buying), whatever
-- the craftIntermediates setting says. Separate cache; same table shape as Get.
function Calc:GetCrafted(recipeID)
	if not recipeID then return nil end
	local prev = forceCraft
	forceCraft = true
	local ok, eco = pcall(self.Get, self, recipeID)
	forceCraft = prev
	if ok then return eco end
	CP:Debug("GetCrafted %s failed: %s", tostring(recipeID), tostring(eco))
	return nil
end

function Calc:GetNet(recipeID)
	local eco = self:Get(recipeID)
	return eco and eco.net or nil
end

-- The net to show for an economics table, by the netBasis setting (or `basis`): "ah" = auction net,
-- "vendor" = sold to a merchant. Returns net, margin, kind ("ah" | "vendor").
function Calc:PickNet(eco, basis)
	if not eco then return nil end
	basis = basis or (CP.settings and CP.settings.netBasis) or "ah"
	if basis == "vendor" then
		if eco.vendorNet then return eco.vendorNet, eco.vendorMargin, "vendor" end
		return nil
	end
	if eco.net then return eco.net, eco.margin, "ah" end
	return nil
end

function Calc:Compute(recipeID, depth)
	computing[recipeID] = true
	local ok, eco = pcall(self.ComputeInternal, self, recipeID, depth or 0)
	computing[recipeID] = nil
	if not ok then
		CP:Debug("compute %s failed: %s", tostring(recipeID), tostring(eco))
		return { recipeID = recipeID, reagents = {}, cost = 0, costComplete = false, missing = 0, quantity = 1, error = tostring(eco) }
	end
	return eco
end

function Calc:ComputeInternal(recipeID, depth)
	local eco = { recipeID = recipeID, reagents = {}, cost = 0, costComplete = true, missing = 0, quantity = 1, crafted = 0 }

	local schematic = ReadSchematic(recipeID)
	if type(schematic) ~= "table" then
		eco.error = "no schematic"
		eco.costComplete = false
		return eco
	end
	eco.cachedSchematic = schematic.cached or nil

	local qMin = schematic.quantityMin or 1
	local qMax = schematic.quantityMax or qMin
	eco.quantity = (qMin + qMax) / 2
	if eco.quantity <= 0 then eco.quantity = 1 end
	eco.outputItemID = GetOutputItemID(recipeID, schematic)

	local basic = BasicReagentType()
	for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
		if slot.reagentType == basic and slot.required ~= false then
			local qty = slot.quantityRequired or 1
			local firstID, best, bestKind, bestID, bestRecipe, bestBuy
			for _, reagent in ipairs(slot.reagents or {}) do
				if reagent.itemID then
					firstID = firstID or reagent.itemID
					local unit, kind, subRecipe, buy = self:ReagentCost(reagent.itemID, depth)
					if unit and (not best or unit < best) then
						best, bestKind, bestID, bestRecipe, bestBuy = unit, kind, reagent.itemID, subRecipe, buy
					end
				end
			end
			local entry = {
				itemID = bestID or firstID,
				qty = qty,
				unit = best,
				kind = bestKind,
				total = best and (best * qty) or nil,
				isCurrency = (firstID == nil),
				craftRecipeID = bestRecipe,   -- set when the reagent is priced at its own craft cost
				buyUnit = bestBuy,            -- the AH/vendor price it replaced, for the tooltip
			}
			table.insert(eco.reagents, entry)
			if best then
				eco.cost = eco.cost + best * qty
				if bestKind == "craft" then eco.crafted = eco.crafted + 1 end
			else
				eco.costComplete = false
				eco.missing = eco.missing + 1
			end
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
		eco.soldPerDay = CP:GetSoldPerDay(eco.outputItemID)
		eco.age = CP:GetPriceAge(eco.outputItemID)
	end

	if eco.sale and eco.costComplete and #eco.reagents > 0 then
		eco.net = eco.sale - eco.cut - eco.cost
		if eco.cost > 0 then eco.margin = eco.net / eco.cost end
	end

	-- Sold to a merchant instead: vendor sell price x output, no cut.
	local sell, sellState
	if eco.outputItemID and CP.Vendor then sell, sellState = CP.Vendor:GetSellPrice(eco.outputItemID) end
	eco.vendorPending = (sellState == "pending") or nil
	if sell then
		eco.vendorUnit = sell
		eco.vendorSale = sell * eco.quantity
		if eco.costComplete and #eco.reagents > 0 then
			eco.vendorNet = eco.vendorSale - eco.cost
			if eco.cost > 0 then eco.vendorMargin = eco.vendorNet / eco.cost end
		end
	end

	-- Demo mode: force the net profit (layout testing), keeping sale/cut consistent with it.
	local forced = CP.demo and CP.demo.net
	if forced and eco.outputItemID and #eco.reagents > 0 then
		local cutRate = CP.settings.ahCut or 0
		eco.net = forced
		eco.sale = (forced + eco.cost) / (1 - cutRate)
		eco.cut = eco.sale * cutRate
		eco.saleUnit = eco.sale / eco.quantity
		eco.margin = eco.cost > 0 and (forced / eco.cost) or nil
		eco.demo = true
	end

	return eco
end
