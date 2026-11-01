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
function Tooltip:Lines(itemID)
	if not itemID then return nil end
	local lines = {}
	local def, reason = CP.Sources:Resolve()
	local scanner = CP.Scanner
	local lastScan = (scanner and scanner:GetLastScan()) or 0
	if not def then
		lines[1] = { "Auction price", tostring(reason), true }
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
			lines[#lines + 1] = { Label("Auction price", qty and qty > 0 and (qty .. " listed")), CP:FormatMoney(price) }
			-- depth value (cheapest 20% of supply, max 1,000 units), also when it equals the price shown: then
			-- there is no cheap bait listing. Its age shows when it is older than the scan above.
			local mv, depth = scanner:GetFreshDepth(itemID)
			if mv then
				local note = "cheapest " .. depth[2]
				local age = scanner:GetAge(itemID)
				if age and time() - depth[3] > age + 3600 then note = CP:FormatAge(time() - depth[3]) end
				lines[#lines + 1] = { Label("Depth value", note), CP:FormatMoney(mv) }
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
			lines[#lines + 1] = { "Auction price (" .. def.name .. ")", CP:FormatMoney(price) }
			local age = CP:GetPriceAge(itemID)
			if age then lines[#lines + 1] = { "Updated", CP:FormatAge(age), true } end
		else
			lines[#lines + 1] = { "Auction price (" .. def.name .. ")", "none", true }
		end
		-- own scan as a second opinion when it has data
		if scanner and scanner:HasData() then
			local min = scanner:GetMin(itemID)
			if min then
				lines[#lines + 1] = { Label("Own scan", CP:FormatAge(scanner:GetAge(itemID))), CP:FormatMoney(min) }
			elseif lastScan > 0 then
				lines[#lines + 1] = { "Own scan", "not listed", true }
			end
		end
	end
	self:AddVerdictLines(lines, itemID)
	self:AddBreakEvenLine(lines, itemID)
	return lines
end

-- Normal price (median of the last 7 days' depth values) and how today's depth value compares. Items with
-- some history but fewer than 3 days say how far along it is; items without history add nothing.
function Tooltip:AddVerdictLines(lines, itemID)
	local scanner = CP.Scanner
	if not (scanner and scanner.GetVerdict) then return end
	if not scanner:GetDaily(itemID) then return end
	local now = scanner:GetFreshDepth(itemID)
	local v, days = scanner:GetVerdict(itemID, now)
	local normal = v and v.normal or scanner:GetNormal(itemID)
	if normal then
		local _, n = scanner:GetNormal(itemID)
		lines[#lines + 1] = { Label("Normal", n .. "-day median"), CP:FormatMoney(normal) }
		if v then lines[#lines + 1] = { "Now", CP:FormatVerdict(v) } end
	else
		lines[#lines + 1] = { "Normal price", string.format("learning, %d of %d days", days or 0, scanner.NORMAL_MIN_DAYS), true }
	end
end

-- While a recipe is open in the profession window: the most this reagent may cost before the craft stops
-- paying off (net 0).
function Tooltip:AddBreakEvenLine(lines, itemID)
	local UI = CP.UI
	local eco = UI and UI.CurrentEco and UI:CurrentEco()
	if not eco then return end
	for _, r in ipairs(eco.reagents or {}) do
		if r.itemID == itemID and r.kind ~= "vendor" and r.kind ~= "craft" then
			local be = UI:BreakEven(eco, r)
			if be then
				lines[#lines + 1] = { "Break-even (recipe)", be > 0 and CP:FormatMoney(be) or "never pays off" }
			end
			return
		end
	end
end

function Tooltip:AddLines(tooltip, itemID)
	if not (CP.settings and CP.settings.tooltip) then return end
	local lines = self:Lines(itemID)
	if not lines or #lines == 0 then return end
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
				local ok2, err = pcall(Tooltip.AddLines, Tooltip, tooltip, itemID)
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

CP:RegisterEvent("PLAYER_LOGIN", function() Tooltip:Install() end)
