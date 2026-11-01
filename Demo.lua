-- CraftProfit :: Demo
-- Layout test mode (session only, never saved). Lets us stress the UI without a real recipe:
--   /cf demo slots <n>    show n reagent slots in the details pane (real ones + dummies, max 8)
--   /cf demo scale <x>    multiply every price by x (e.g. 1000 turns silver into gold)
--   /cf demo net <amt>    force every recipe's net profit, e.g. 128g42s16c or -35s or 1284216 (copper)
--   /cf demo history      invent 7 days of price history for every priced item (a third each cheap, normal,
--                         high), so the price verdicts can be seen before real history exists
--   /cf demo off          back to normal

local _, CP = ...
local Demo = {}
CP.Demo = Demo

CP.demo = { slots = 0, scale = nil, net = nil, history = nil }

local DUMMY_ITEMS = { 2996, 2320, 2589, 2592, 4306, 4338, 14047, 2318 } -- cloth/thread/leather for icons
local MAX_SLOTS = 8

function Demo:IsActive()
	local d = CP.demo
	return (d.slots or 0) > 0 or d.scale ~= nil or d.net ~= nil or d.history ~= nil
end

---------------------------------------------------------------------------
-- Invented price history
---------------------------------------------------------------------------
-- Built on first use per item from its current price (depth value, else lowest buyout): the item ID picks
-- the outcome (cheap: normal 25% above today, normal: 3% above, high: 20% below), the 7 days wobble +-4%
-- around it. Session only, never written to the saved history.

local OUTCOME = { [0] = 1.25, [1] = 1.03, [2] = 0.8 }

function Demo:HistoryFor(itemID)
	local h = CP.demo.history
	if not h or not itemID then return nil end
	if h[itemID] ~= nil then return h[itemID] or nil end
	local scanner = CP.Scanner
	local price = scanner and (scanner:GetFreshDepth(itemID) or scanner:GetMin(itemID))
	if not price or price <= 0 then
		h[itemID] = false
		return nil
	end
	local normal = price * OUTCOME[itemID % 3]
	local today = scanner.Today()
	local list = {}
	for d = 7, 1, -1 do
		local wobble = 1 + (((itemID + d) % 5) - 2) * 0.02
		list[#list + 1] = { today - d, math.floor(normal * wobble + 0.5), 3 }
	end
	h[itemID] = list
	return list
end

-- "128g42s16c", "128g 42s 16c", "-35s", "1284216" -> copper
function Demo:ParseMoney(text)
	if not text then return nil end
	text = text:lower():gsub("%s+", "")
	local sign = 1
	if text:sub(1, 1) == "-" then
		sign = -1
		text = text:sub(2)
	end
	if text:match("^%d+$") then return sign * tonumber(text) end
	local total, matched = 0, false
	for amount, unit in text:gmatch("(%d+)([gsc])") do
		matched = true
		amount = tonumber(amount)
		if unit == "g" then total = total + amount * 10000
		elseif unit == "s" then total = total + amount * 100
		else total = total + amount end
	end
	if not matched then return nil end
	return sign * total
end

---------------------------------------------------------------------------
-- Dummy reagent slots in the details pane
---------------------------------------------------------------------------

local function BasicType()
	return (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 0
end

local function ConfigureDummy(slot, index)
	local itemID = DUMMY_ITEMS[((index - 1) % #DUMMY_ITEMS) + 1]
	local qty = index + 1
	local rss = {
		reagentType = BasicType(),
		quantityRequired = qty,
		slotIndex = 100 + index,
		dataSlotIndex = 100 + index,
		required = true,
		reagents = { { itemID = itemID } },
	}
	-- Our decorations read this through the mixin getter.
	if type(slot.SetReagentSlotSchematic) == "function" then
		pcall(slot.SetReagentSlotSchematic, slot, rss)
	end
	slot.reagentSlotSchematic = slot.reagentSlotSchematic or rss
	slot.cpDemoSchematic = rss

	local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID) or ("Dummy Reagent " .. index)
	if slot.Name then
		slot.Name:SetText(string.format("0/%d %s", qty, name))
		slot.Name:Show()
	end
	if slot.Button then
		local ok = pcall(function()
			if type(slot.Button.SetReagent) == "function" then
				slot.Button:SetReagent({ itemID = itemID })
				if type(slot.Button.Update) == "function" then slot.Button:Update() end
			end
		end)
		if not ok and SetItemButtonTexture then
			local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
			if icon then pcall(SetItemButtonTexture, slot.Button, icon) end
		end
		slot.Button:EnableMouse(false) -- no tooltips/clicks on fakes
	end
end

local function GetDummy(form, index)
	form.cpDemoPool = form.cpDemoPool or {}
	local slot = form.cpDemoPool[index]
	if not slot then
		local ok, frame = pcall(CreateFrame, "Frame", nil, form.Reagents or form, "ProfessionsReagentSlotTemplate")
		if not ok or not frame then return nil end
		frame.cpDemo = true
		form.cpDemoPool[index] = frame
		slot = frame
	end
	return slot
end

-- Called from the SchematicForm Init hook, before the panel is anchored and slots are decorated.
function Demo:ApplySlots(form, recipeInfo)
	form.cpDemoSlots = nil
	if form.cpDemoPool then
		for _, slot in ipairs(form.cpDemoPool) do slot:Hide() end
	end
	local want = CP.demo.slots or 0
	if want <= 0 or not recipeInfo or not form.Reagents then return end

	local real = form.reagentSlots and form.reagentSlots[BasicType()] or {}
	if #real >= want then return end

	local shown = {}
	for i = 1, math.min(want, MAX_SLOTS) - #real do
		local slot = GetDummy(form, i)
		if not slot then break end
		ConfigureDummy(slot, i)
		slot:Show()
		table.insert(shown, slot)
	end
	if #shown == 0 then return end
	form.cpDemoSlots = shown

	-- Same layout call Blizzard uses for basic reagents, over real + dummy slots.
	if Professions and Professions.LayoutReagentSlots and GridLayoutMixin then
		local all = {}
		for _, s in ipairs(real) do table.insert(all, s) end
		for _, s in ipairs(shown) do table.insert(all, s) end
		local ok, err = pcall(Professions.LayoutReagentSlots, all, form.Reagents, 5, -5, 4,
			GridLayoutMixin.Direction.TopLeftToBottomRightVertical)
		if not ok then CP:Debug("demo layout failed: %s", tostring(err)) end
	end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function Refresh()
	CP.Calc:Invalidate()
	if CP.UI and CP.UI.ReinitForm then CP.UI:ReinitForm() end
	if CP.UI and CP.UI.RefreshAll then CP.UI:RefreshAll() end
end

function Demo:Status()
	local d = CP.demo
	if not self:IsActive() then
		CP:Print("demo mode off. /cf demo slots <n> | scale <x> | net <amount> | history | off")
		return
	end
	CP:Print("demo: slots %d, price scale %s, forced net %s, invented price history %s", d.slots or 0,
		d.scale and tostring(d.scale) or "off", d.net and CP:FormatMoney(d.net) or "off", d.history and "on" or "off")
end

function Demo:Command(rest)
	local sub, arg = (rest or ""):match("^(%S+)%s*(.*)$")
	sub = sub and sub:lower() or ""
	if sub == "" or sub == "status" then
		self:Status()
		return
	elseif sub == "off" then
		CP.demo.slots, CP.demo.scale, CP.demo.net, CP.demo.history = 0, nil, nil, nil
	elseif sub == "slots" then
		local n = tonumber(arg)
		if not n or n < 0 or n > MAX_SLOTS then CP:Print("usage: /cf demo slots <0-%d>", MAX_SLOTS) return end
		CP.demo.slots = math.floor(n)
	elseif sub == "scale" then
		local x = tonumber(arg)
		if not x or x <= 0 then CP:Print("usage: /cf demo scale <multiplier>, e.g. 1000") return end
		CP.demo.scale = (x == 1) and nil or x
	elseif sub == "history" then
		if arg:lower() == "off" then
			CP.demo.history = nil
		else
			CP.demo.history = {}
			CP:Print("invented price history on (session only, not saved): hover items and open a recipe. /cf demo history off ends it.")
		end
	elseif sub == "net" then
		if arg:lower() == "off" then
			CP.demo.net = nil
		else
			local copper = self:ParseMoney(arg)
			if not copper then CP:Print("usage: /cf demo net <amount>, e.g. 128g42s16c, -35s or 1284216") return end
			CP.demo.net = copper
		end
	else
		CP:Print("unknown demo option '%s'", sub)
		self:Status()
		return
	end
	Refresh()
	self:Status()
end
