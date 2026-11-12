-- CraftProfit :: Tooltip
-- Item tooltip lines: the auction price CraftProfit would use for the item, where it comes from and how
-- fresh it is, or why there is none (not listed in the last scan / no scan yet). Keep every right-hand
-- text short so the block never widens the item tooltip. This is
-- the one place to see whether an item has been scanned, so companion addons can rely on it instead of
-- adding their own price lines. Retail TooltipDataProcessor when available,
-- GameTooltip OnTooltipSetItem hook otherwise.

local _, CP = ...
local Tooltip = {}
CP.Tooltip = Tooltip

local function Muted(text) return CP:Color(CP.COLORS.muted, text) end

-- Layout: the right column holds only the value (money, age, verdict), so prices line up at the right edge;
-- details (listed count, units, days, ages) go into the label, muted.
local function Label(text, detail)
	if not detail or detail == "" then return text end
	return text .. "  " .. Muted(detail)
end

-- Returns a list of { left, right, hint } lines for the item (hint = grey right-hand text), or nil.
-- `stack` (> 1): every money value is for that many items (the hovered stack, while Shift is held).
function Tooltip:Lines(itemID, stack)
	if not itemID then return nil end
	local lines = {}
	local mult = (stack and stack > 1) and stack or 1
	local function Money(v) return CP:FormatMoney(v * mult) end
	if mult > 1 then lines[1] = { "Stack of " .. mult, "totals", true } end
	local def, reason = CP.Sources:Resolve()
	local scanner = CP.Scanner
	local lastScan = (scanner and scanner:GetLastScan()) or 0
	if not def then
		lines[#lines + 1] = { "Auction price", tostring(reason), true }
		return lines
	end
	local price = CP:GetSalePrice(itemID)
	if def.key == "craftprofit" then
		if price then
			local qty = scanner:GetQuantity(itemID)
			local basis = "Scanned"
			if CP.settings.saleBasis == "market" then
				local _, kind = scanner:GetMarket(itemID)
				basis = (kind == "depth") and "Scanned (depth)" or "Scanned (median)"
			end
			lines[#lines + 1] = { Label("Auction price", qty and qty > 0 and (qty .. " listed")), Money(price) }
			-- depth value (cheapest 20% of supply, max 1,000 units), also when it equals the price shown: then
			-- there is no cheap bait listing. Its age shows when it is older than the scan above.
			local mv, depth = scanner:GetFreshDepth(itemID)
			if mv then
				local note = "cheapest " .. depth[2]
				local age = scanner:GetAge(itemID)
				if age and time() - depth[3] > age + 3600 then note = CP:FormatAge(time() - depth[3]) end
				lines[#lines + 1] = { Label("Depth value", note), Money(mv) }
			end
			lines[#lines + 1] = { basis, CP:FormatAge(scanner:GetAge(itemID)), true }
		elseif lastScan > 0 then
			-- short right-hand text: a wide line widens the whole item tooltip and can flip the
			-- equipped-item comparison to the other side at the screen edge
			lines[#lines + 1] = { "Auction price", "not listed", true }
			lines[#lines + 1] = { "Last scan", CP:FormatAge(time() - lastScan), true }
		else
			lines[#lines + 1] = { "Auction price", "no scan yet", true }
			lines[#lines + 1] = { "Scan at the AH", "/cf scan", true }
		end
	else
		if price then
			lines[#lines + 1] = { "Auction price (" .. def.name .. ")", Money(price) }
			local age = CP:GetPriceAge(itemID)
			if age then lines[#lines + 1] = { "Updated", CP:FormatAge(age), true } end
		else
			lines[#lines + 1] = { "Auction price (" .. def.name .. ")", "none", true }
		end
		-- own scan as a second opinion when it has data
		if scanner and scanner:HasData() then
			local min = scanner:GetMin(itemID)
			if min then
				lines[#lines + 1] = { Label("Own scan", CP:FormatAge(scanner:GetAge(itemID))), Money(min) }
			elseif lastScan > 0 then
				lines[#lines + 1] = { "Own scan", "not listed", true }
			end
		end
	end
	self:AddVerdictLines(lines, itemID, mult)
	self:AddBreakEvenLine(lines, itemID, mult)
	return lines
end

-- Normal price (median of the last 7 days' depth values) and how today's depth value compares. Items with
-- some history but fewer than 3 days say how far along it is; items without history add nothing.
function Tooltip:AddVerdictLines(lines, itemID, mult)
	local scanner = CP.Scanner
	if not (scanner and scanner.GetVerdict) then return end
	if not scanner:GetDaily(itemID) then return end
	local now = scanner:GetFreshDepth(itemID)
	local v, days = scanner:GetVerdict(itemID, now)
	local normal = v and v.normal or scanner:GetNormal(itemID)
	if normal then
		local _, n = scanner:GetNormal(itemID)
		lines[#lines + 1] = { Label("Normal", n .. "-day median"), CP:FormatMoney(normal * (mult or 1)) }
		if v then lines[#lines + 1] = { "Now", CP:FormatVerdict(v) } end
	else
		lines[#lines + 1] = { "Normal price", string.format("learning, %d of %d days", days or 0, scanner.NORMAL_MIN_DAYS), true }
	end
end

-- While a recipe is open in the profession window: the most this reagent may cost before the craft stops
-- paying off (net 0).
function Tooltip:AddBreakEvenLine(lines, itemID, mult)
	local UI = CP.UI
	local eco = UI and UI.CurrentEco and UI:CurrentEco()
	if not eco then return end
	for _, r in ipairs(eco.reagents or {}) do
		if r.itemID == itemID and r.kind ~= "vendor" and r.kind ~= "craft" then
			local be = UI:BreakEven(eco, r)
			if be then
				lines[#lines + 1] = { "Break-even (recipe)", be > 0 and CP:FormatMoney(be * (mult or 1)) or "never pays off" }
			end
			return
		end
	end
end

-- Items that can never go to the Auction House get no CraftProfit block: quest items, bind-on-pickup /
-- quest-bound items, and any item whose tooltip already says it is bound (e.g. a BoE that was equipped).
local QUEST_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12
local BIND_PICKUP, BIND_QUEST = 1, 4

local BOUND_TEXTS = {}
for _, key in ipairs({ "ITEM_SOULBOUND", "ITEM_ACCOUNTBOUND", "ITEM_BNETACCOUNTBOUND", "ITEM_BIND_TO_ACCOUNT",
	"ITEM_BIND_TO_BNETACCOUNT", "ITEM_ACCOUNTBOUND_UNTIL_EQUIP", "ITEM_BIND_QUEST" }) do
	local text = _G[key]
	if type(text) == "string" and text ~= "" then BOUND_TEXTS[text] = true end
end

local function TooltipSaysBound(tooltip, data)
	if data and type(data.lines) == "table" then
		for i = 1, math.min(#data.lines, 8) do
			local line = data.lines[i]
			if line and line.leftText and BOUND_TEXTS[line.leftText] then return true end
		end
		return false
	end
	local name = tooltip.GetName and tooltip:GetName()
	if not name then return false end
	for i = 2, math.min(tooltip:NumLines() or 0, 8) do
		local fs = _G[name .. "TextLeft" .. i]
		local text = fs and fs:GetText()
		if text and BOUND_TEXTS[text] then return true end
	end
	return false
end

function Tooltip:IsUnsellable(itemID, tooltip, data)
	local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
	if getInfo then
		local ok, _, _, _, _, _, _, _, _, _, _, _, classID, _, bindType = pcall(getInfo, itemID)
		if ok then
			if classID == QUEST_CLASS then return true end
			if bindType == BIND_PICKUP or bindType == BIND_QUEST then return true end
		end
	end
	return tooltip and TooltipSaysBound(tooltip, data) or false
end

-- Size of the hovered stack, only when the client says so exactly (an item in a bag or bank slot);
-- nil for anything else (links, vendors, loot), so no total is ever guessed.
function Tooltip:StackCount(tooltip, data, itemID)
	if data and data.guid and C_Item and C_Item.GetItemLocation and C_Item.GetStackCount then
		local ok, loc = pcall(C_Item.GetItemLocation, data.guid)
		if ok and loc then
			local ok2, n = pcall(C_Item.GetStackCount, loc)
			if ok2 and type(n) == "number" and n > 0 then return n end
		end
	end
	-- bag slot buttons (Blizzard's and bag addons built on its template) know their bag and slot
	local owner = tooltip and type(tooltip.GetOwner) == "function" and tooltip:GetOwner()
	if owner and type(owner.GetBagID) == "function" and type(owner.GetID) == "function"
		and C_Container and C_Container.GetContainerItemInfo then
		local ok, info = pcall(C_Container.GetContainerItemInfo, owner:GetBagID(), owner:GetID())
		if ok and type(info) == "table" and info.itemID == itemID and type(info.stackCount) == "number" then
			return info.stackCount
		end
	end
	return nil
end

local function ShiftDown() return type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and true or false end

function Tooltip:AddLines(tooltip, itemID, data)
	if not (CP.settings and CP.settings.tooltip) then return end
	if self:IsUnsellable(itemID, tooltip, data) then return end
	local stack = self:StackCount(tooltip, data, itemID)
	if not (stack and stack > 1) then stack = nil end
	if tooltip == GameTooltip then self.stackShown = stack end -- Shift re-draws only tooltips with a stack
	local shift = stack and ShiftDown()
	local lines = self:Lines(itemID, shift and stack or nil)
	if not lines or #lines == 0 then return end
	if stack and not shift then lines[#lines + 1] = { "Stack of " .. stack, "Shift: totals", true } end
	tooltip:AddLine(" ")
	tooltip:AddLine("CraftProfit", 1, 0.82, 0)
	for _, l in ipairs(lines) do
		if l[3] then
			tooltip:AddDoubleLine(l[1], l[2], 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
		else
			tooltip:AddDoubleLine(l[1], l[2], 0.8, 0.8, 0.8, 1, 1, 1)
		end
	end
end

local function ItemIDFromTooltip(tooltip, data)
	if data and data.id then return data.id end
	if type(tooltip.GetItem) == "function" then
		local ok, _, link = pcall(tooltip.GetItem, tooltip)
		if ok then return CP:ItemIDFromLink(link) end
	end
	return nil
end

function Tooltip:Install()
	if self.installed then return end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
		local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
			if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
			local itemID = ItemIDFromTooltip(tooltip, data)
			if itemID then
				local ok2, err = pcall(Tooltip.AddLines, Tooltip, tooltip, itemID, data)
				if not ok2 then CP:Debug("tooltip failed: %s", tostring(err)) end
			end
		end)
		if ok then
			self.installed = "TooltipDataProcessor"
			return
		end
	end
	if GameTooltip and type(GameTooltip.HookScript) == "function" then
		local ok = pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetItem", function(tooltip)
			local itemID = ItemIDFromTooltip(tooltip)
			if itemID then pcall(Tooltip.AddLines, Tooltip, tooltip, itemID) end
		end)
		if ok then self.installed = "OnTooltipSetItem" end
	end
end

-- Pressing or releasing Shift over a stack re-draws the tooltip with per-item or stack totals.
function Tooltip:OnModifier(key)
	if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
	if not (self.stackShown and GameTooltip and GameTooltip:IsShown()) then return end
	if type(GameTooltip.RefreshData) == "function" then
		pcall(GameTooltip.RefreshData, GameTooltip)
		return
	end
	local owner = type(GameTooltip.GetOwner) == "function" and GameTooltip:GetOwner()
	local onEnter = owner and type(owner.GetScript) == "function" and owner:GetScript("OnEnter")
	if onEnter then pcall(onEnter, owner) end
end

CP:RegisterEvent("PLAYER_LOGIN", function() Tooltip:Install() end)
CP:RegisterEvent("MODIFIER_STATE_CHANGED", function(_, key) Tooltip:OnModifier(key) end)
