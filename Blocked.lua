-- CraftProfit :: Blocked
-- Records the times the game blocks a protected action and names CraftProfit for it (the "CraftProfit has been
-- blocked from an action only available to the Blizzard UI" popup). The events only say which protected
-- function was blocked, not where the taint came from, so each record also notes what was on screen: the
-- tooltip and its owner, the open windows, how long ago CraftProfit last re-drew a tooltip on Shift, and the
-- call stack at that moment.
-- A chat line points at /cf blocked, which prints the records for a bug report. Nothing here changes behaviour.

local ADDON_NAME, CP = ...
local Blocked = { max = 20, noticeGap = 30 }
CP.Blocked = Blocked

local fmtDate = date or (os and os.date)
local WINDOWS = {
	{ "AuctionHouseFrame", "auction house" }, { "ProfessionsFrame", "professions" }, { "MerchantFrame", "merchant" },
	{ "ClassTrainerFrame", "trainer" }, { "MailFrame", "mail" }, { "BankFrame", "bank" }, { "TradeFrame", "trade" },
}

local function Try(fn, ...)
	local ok, v = pcall(fn, ...)
	if ok then return v end
	return nil
end

-- plain strings and numbers only: the record is saved and printed
local function Plain(v)
	if type(v) == "string" or type(v) == "number" then return v end
	return nil
end

function Blocked:Context()
	local c = {}
	c.combat = Try(function() return InCombatLockdown and InCombatLockdown() end) and true or false
	local tip = GameTooltip
	if tip and Try(function() return tip.IsShown and tip:IsShown() end) then
		c.owner = Plain(Try(function()
			local owner = tip:GetOwner()
			if not owner then return nil end
			return (owner.GetDebugName and owner:GetDebugName()) or (owner.GetName and owner:GetName())
		end)) or "?"
		if CP.Tooltip and CP.Tooltip:ShowsItem(tip) then
			c.item = Plain(Try(function()
				local data = tip.GetPrimaryTooltipData and tip:GetPrimaryTooltipData()
				if type(data) == "table" and data.id then return data.id end
				local _, link = tip:GetItem()
				return CP:ItemIDFromLink(link)
			end)) or "?"
		end
	end
	local last = CP.Tooltip and CP.Tooltip.lastRefresh
	if last and GetTime then c.shiftAgo = math.floor(GetTime() - last) end
	local open = {}
	for _, w in ipairs(WINDOWS) do
		if Try(function() local f = _G[w[1]]; return f and f.IsShown and f:IsShown() end) then open[#open + 1] = w[2] end
	end
	if #open > 0 then c.open = table.concat(open, ", ") end
	return c
end

-- The code that was running when the call was refused: the game raises the event from inside the blocked
-- call, so the stack still holds the Blizzard functions that led to it. CraftProfit's own frames (this
-- handler) are left out, the rest is cut to STACK_FRAMES lines so the saved record stays small.
local STACK_FRAMES, STACK_LINE = 10, 160

function Blocked:Stack()
	local raw = Try(function() return debugstack and debugstack(2, 30, 0) end)
	if type(raw) ~= "string" then return nil end
	local frames = {}
	for line in raw:gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("Interface/AddOns/", ""):gsub("Interface\\AddOns\\", "")
		if line ~= "" and not line:find(ADDON_NAME, 1, true) then
			if #line > STACK_LINE then line = line:sub(1, STACK_LINE) .. "..." end
			frames[#frames + 1] = line
			if #frames >= STACK_FRAMES then break end
		end
	end
	if #frames == 0 then return nil end
	return table.concat(frames, "\n")
end

function Blocked:Record(kind, addon, fn)
	if addon ~= ADDON_NAME then return end
	local db = CP.db
	if not db then return end
	local stack = self:Stack() -- first: nothing below may add frames
	local rec = self:Context()
	rec.stack = stack
	rec.t, rec.kind, rec.fn = time(), kind, Plain(fn) or "?"
	rec.version = CP.version
	rec.build = Plain(Try(function() return (select(4, GetBuildInfo())) end))
	db.blocked = db.blocked or {}
	table.insert(db.blocked, rec)
	while #db.blocked > self.max do table.remove(db.blocked, 1) end
	-- say so in chat, but not for every blocked call of a burst
	local now = GetTime and GetTime() or rec.t
	if not self.noticeAt or now - self.noticeAt >= self.noticeGap then
		self.noticeAt = now
		CP:Print("the game blocked %s and named CraftProfit. Please type |cffffffff/cf blocked|r and send what it prints to the author; it shows what was on screen when it happened.", rec.fn)
	end
end

function Blocked:Line(rec)
	local parts = { string.format("%s %s %s", fmtDate and fmtDate("%Y-%m-%d %H:%M:%S", rec.t) or tostring(rec.t), tostring(rec.fn), tostring(rec.kind)) }
	parts[#parts + 1] = string.format("v%s interface %s", tostring(rec.version), tostring(rec.build))
	parts[#parts + 1] = rec.combat and "in combat" or "not in combat"
	if rec.owner then
		parts[#parts + 1] = "tooltip on " .. tostring(rec.owner) .. (rec.item and (" (item " .. tostring(rec.item) .. ")") or " (not an item)")
	else
		parts[#parts + 1] = "no tooltip"
	end
	parts[#parts + 1] = rec.shiftAgo and ("Shift re-draw " .. rec.shiftAgo .. "s before") or "no Shift re-draw this session"
	parts[#parts + 1] = "open: " .. (rec.open or "nothing")
	return table.concat(parts, " | ")
end

-- The records as plain text for a bug report: the newest 10, each followed by its call stack.
function Blocked:Text()
	local list = CP.db and CP.db.blocked or {}
	local out = {}
	for i = math.max(1, #list - 9), #list do
		out[#out + 1] = self:Line(list[i])
		if type(list[i].stack) == "string" then
			for line in list[i].stack:gmatch("[^\n]+") do out[#out + 1] = "    " .. line end
		end
	end
	return table.concat(out, "\n")
end

-- optional widget methods: not every client (or the test harness) has all of them
local function Call(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

-- A window with the records as selectable text, so they can be copied instead of typed off the chat.
function Blocked:ShowCopy(text)
	local f = self.copyFrame
	if not f then
		f = CreateFrame("Frame", "CraftProfitBlockedCopy", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
		f:SetSize(640, 360)
		f:SetPoint("CENTER")
		Call(f, "SetFrameStrata", "DIALOG")
		Call(f, "SetBackdrop", { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
		Call(f, "SetBackdropColor", 0, 0, 0, 0.95)
		f:EnableMouse(true)
		Call(f, "SetMovable", true)
		Call(f, "RegisterForDrag", "LeftButton")
		f:SetScript("OnDragStart", function(self) Call(self, "StartMoving") end)
		f:SetScript("OnDragStop", function(self) Call(self, "StopMovingOrSizing") end)

		local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -12)
		title:SetText("CraftProfit: blocked actions")
		local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
		hint:SetText("Press Ctrl+C to copy, then paste it into your report. Escape closes this window.")

		local ok, close = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
		if ok and close then
			close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
			close:SetScript("OnClick", function() f:Hide() end)
		end

		-- the text scrolls when it is longer than the window
		local parent, scroll = f, nil
		local ok2, sf = pcall(CreateFrame, "ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
		if ok2 and sf and type(sf.SetScrollChild) == "function" then
			sf:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -50)
			sf:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -34, 14)
			parent, scroll = sf, sf
		end
		local edit = CreateFrame("EditBox", nil, parent)
		Call(edit, "SetMultiLine", true)
		Call(edit, "SetAutoFocus", false)
		Call(edit, "SetFontObject", ChatFontNormal or GameFontHighlightSmall)
		edit:SetWidth(590)
		if scroll then
			scroll:SetScrollChild(edit)
		else
			edit:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -50)
		end
		edit:SetScript("OnEscapePressed", function() f:Hide() end)
		-- read-only: typing puts the text back, still selected
		edit:SetScript("OnTextChanged", function(self, userInput)
			if userInput and f.text then
				self:SetText(f.text)
				Call(self, "HighlightText")
			end
		end)
		f.Edit = edit
		self.copyFrame = f
	end
	f.text = text
	f.Edit:SetText(text)
	f:Show()
	Call(f.Edit, "SetCursorPosition", 0)
	Call(f.Edit, "SetFocus")
	Call(f.Edit, "HighlightText")
end

-- /cf blocked taint: which fields of the default UI's windows the game currently counts as written by an
-- addon, and by which one. Reading such a field is what makes the game block a later protected action, so
-- this shows where a block comes from before it happens. Only reads; nothing is changed.
local TAINT_ROOTS = {
	{ "ProfessionsFrame", function() return ProfessionsFrame end },
	{ "ProfessionsFrame.CraftingPage", function() return ProfessionsFrame.CraftingPage end },
	{ "CraftingPage.SchematicForm", function() return ProfessionsFrame.CraftingPage.SchematicForm end },
	{ "SchematicForm.currentRecipeInfo", function() return ProfessionsFrame.CraftingPage.SchematicForm.currentRecipeInfo end },
	{ "SchematicForm.transaction", function() return ProfessionsFrame.CraftingPage.SchematicForm.transaction end },
	{ "CraftingPage.RecipeList", function() return ProfessionsFrame.CraftingPage.RecipeList end },
	{ "RecipeList.ScrollBox", function() return ProfessionsFrame.CraftingPage.RecipeList.ScrollBox end },
	{ "BankFrame", function() return BankFrame end },
	{ "BankFrame.BankPanel", function() return BankFrame.BankPanel end },
	{ "ContainerFrameCombinedBags", function() return ContainerFrameCombinedBags end },
	{ "MerchantFrame", function() return MerchantFrame end },
	{ "AuctionHouseFrame", function() return AuctionHouseFrame end },
	{ "ItemButtonUtil", function() return ItemButtonUtil end },
	{ "UIParent", function() return UIParent end },
}
local TAINT_DEPTH, TAINT_FIELDS, TAINT_LINES = 3, 60000, 300

function Blocked:TaintReport()
	local check = issecurevariable
	if type(check) ~= "function" then return nil, "this client has no issecurevariable()" end
	-- seen: per root, so each root is walked to its own depth; checked: a table's fields are reported once
	local seen, checked, found, counts, fields = {}, {}, {}, {}, 0
	local function Walk(tbl, path, depth)
		if seen[tbl] or fields > TAINT_FIELDS then return end
		seen[tbl] = true
		local keys = {}
		local ok = pcall(function() for k in pairs(tbl) do keys[#keys + 1] = k end end)
		if not ok then return end
		local first = not checked[tbl]
		checked[tbl] = true
		for _, k in ipairs(keys) do
			local ok2, secure, who = true, true, nil
			if first then
				fields = fields + 1
				ok2, secure, who = pcall(check, tbl, k)
			end
			if ok2 and not secure then
				who = Plain(who) or "?"
				counts[who] = (counts[who] or 0) + 1
				if #found < TAINT_LINES then found[#found + 1] = string.format("%s.%s  <- %s", path, tostring(k), who) end
			end
			if depth < TAINT_DEPTH then
				local ok3, v = pcall(rawget, tbl, k)
				if ok3 and type(v) == "table" and type(k) == "string" then Walk(v, path .. "." .. k, depth + 1) end
			end
		end
	end
	for _, root in ipairs(TAINT_ROOTS) do
		local tbl = Try(root[2])
		if type(tbl) == "table" then
			seen = {}
			Walk(tbl, root[1], 1)
		end
	end
	local who = {}
	for name, n in pairs(counts) do who[#who + 1] = string.format("%s %d", name, n) end
	table.sort(who)
	local head = string.format("%s v%s: %d fields checked, written by an addon: %s",
		fmtDate and fmtDate("%Y-%m-%d %H:%M:%S") or "", tostring(CP.version), fields, #who > 0 and table.concat(who, ", ") or "none")
	table.sort(found)
	return head .. (#found > 0 and ("\n" .. table.concat(found, "\n")) or "")
end

-- /cf blocked watch: repeats the check twice a second and says in chat the moment a field becomes
-- addon-written, with the windows open at that time. Off again with the same command or a reload.
function Blocked:Watch()
	if self.watch then
		self.watch:Cancel()
		self.watch = nil
		CP:Print("taint watch off.")
		-- everything it saw, in order, as text to copy
		if self.watchLog and #self.watchLog > 0 then
			pcall(self.ShowCopy, self, table.concat(self.watchLog, "\n\n"))
		end
		self.watchLog = nil
		return
	end
	if not (C_Timer and C_Timer.NewTicker) then CP:Print("taint watch not possible on this client.") return end
	local function Lines()
		local text = self:TaintReport()
		local set = {}
		if text then
			for line in text:gmatch("[^\n]+") do
				if line:find("  <- ", 1, true) then set[line] = true end
			end
		end
		return set
	end
	local known = Lines()
	self.watch = C_Timer.NewTicker(0.5, function()
		local ok, now = pcall(Lines)
		if not ok then return end
		-- a rebuild taints hundreds of fields at once: the first few (sorted) say what ran, the rest is a count
		local fresh = {}
		for line in pairs(now) do
			if not known[line] then
				known[line] = true
				fresh[#fresh + 1] = line
			end
		end
		if #fresh == 0 then return end
		table.sort(fresh)
		CP:Print("taint watch %s: %d new | open: %s", fmtDate and fmtDate("%H:%M:%S") or "", #fresh, self:Context().open or "nothing")
		for i = 1, math.min(#fresh, 12) do CP:Print("  %s", fresh[i]) end
		self.watchLog = self.watchLog or {}
		self.watchLog[#self.watchLog + 1] = string.format("%s: %d new | open: %s\n%s", fmtDate and fmtDate("%H:%M:%S") or "", #fresh,
			self:Context().open or "nothing", table.concat(fresh, "\n"))
	end)
	CP:Print("taint watch on: new addon-written fields are reported here as they appear. /cf blocked watch turns it off.")
end

function Blocked:Command(rest)
	local db = CP.db
	local list = db and db.blocked or {}
	if (rest or ""):lower() == "watch" then return self:Watch() end
	if (rest or ""):lower() == "taint" then
		local text, err = self:TaintReport()
		if not text then
			CP:Print("taint check not possible: %s", tostring(err))
			return
		end
		CP:Print("%s", (text:match("^[^\n]*")))
		local ok, err2 = pcall(self.ShowCopy, self, text)
		if not ok then CP:Debug("taint window failed: %s", tostring(err2)) end
		return
	end
	if (rest or ""):lower() == "clear" then
		if db then db.blocked = nil end
		if self.copyFrame then self.copyFrame:Hide() end
		CP:Print("blocked-action records cleared.")
		return
	end
	if #list == 0 then
		CP:Print("no blocked actions recorded. When the game blocks an action and names CraftProfit, it is noted here.")
		return
	end
	CP:Print("%d blocked action%s recorded (newest last). /cf blocked clear empties the list.", #list, #list == 1 and "" or "s")
	for i = math.max(1, #list - 9), #list do CP:Print("  %s", self:Line(list[i])) end
	-- the newest record's call stack, one line per function
	local last = list[#list]
	if type(last.stack) == "string" and last.stack ~= "" then
		CP:Print("  what was running (newest):")
		for line in last.stack:gmatch("[^\n]+") do CP:Print("    %s", line) end
	end
	-- the same as text that can be copied; chat stays the fallback if the window cannot be built
	local ok, err = pcall(self.ShowCopy, self, self:Text())
	if not ok then CP:Debug("blocked copy window failed: %s", tostring(err)) end
end

CP:RegisterEvent("ADDON_ACTION_BLOCKED", function(_, addon, fn) Blocked:Record("blocked", addon, fn) end)
CP:RegisterEvent("ADDON_ACTION_FORBIDDEN", function(_, addon, fn) Blocked:Record("forbidden", addon, fn) end)
