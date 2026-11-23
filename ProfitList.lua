-- CraftProfit :: ProfitList
-- "Sort by profit" and "Profitable only" without changing the default UI's recipe list.
--
-- Anything an addon writes into that list (a comparator, a re-sorted or removed entry, a refresh it starts)
-- is marked as addon-written by the game. The profession window reads the list all the time, so the mark
-- spreads to whatever it sets up next, and a protected action that later reads one of those values is
-- blocked ("CraftProfit has been blocked", e.g. using an item after the bank was opened next to the
-- profession window). So the list is only READ here:
--   * the rows Blizzard built (categories, recipes, what search and filters left) are copied into a list of
--     our own, sorted and filtered there;
--   * that list is drawn by a frame of our own in the place of Blizzard's, which stays underneath, unchanged
--     and invisible;
--   * a click asks the game to open the recipe (C_TradeSkillUI.OpenRecipe); the default UI answers the
--     game's event itself and selects it.
-- With both options off the frame is hidden and Blizzard's list is shown as it is.

local _, CP = ...
local UI = CP.UI
local List = { offset = 0, rows = {}, collapsed = {} }
UI.ProfitList = List

local ROW_H = 20
local WHEEL_ROWS = 3
local PENDING_SECONDS = 3 -- how long a clicked row stays highlighted while the game has not opened it yet
local LABEL_X = 21 -- where Blizzard's recipe names start (after the skill-up arrow)
local SKILL_ATLAS = { "Professions-Icon-Skill-High", "Professions-Icon-Skill-Medium", "Professions-Icon-Skill-Low" }

local function NodeData(node)
	if not node then return nil end
	if type(node.GetData) == "function" then return node:GetData() end
	return node.data or node
end

local function Children(node)
	if type(node.GetNodes) == "function" then return node:GetNodes() or {} end
	return node.nodes or {}
end

-- optional widget methods: not every client (or the test harness) has all of them
local function Call(obj, method, ...)
	if obj and type(obj[method]) == "function" then return pcall(obj[method], obj, ...) end
end

function List:Active()
	local s = CP.settings
	return s and (s.sortByProfit or s.profitableOnly) and true or false
end

---------------------------------------------------------------------------
-- Model: Blizzard's tree -> our rows (read only)
---------------------------------------------------------------------------

local function CategoryKey(data)
	local info = data.categoryInfo
	return info.categoryID or info.name or "?"
end

-- Collapsed the way the player left it here; until they touch a header, the way Blizzard has it.
function List:IsCollapsed(node, data)
	local own = self.collapsed[CategoryKey(data)]
	if own ~= nil then return own end
	if type(node.IsCollapsed) == "function" then
		local ok, c = pcall(node.IsCollapsed, node)
		return ok and c and true or false
	end
	return node.collapsed and true or false
end

-- Items for everything under `node`, as a tree: categories hold their own items. Returns the items, the
-- number of recipes shown below the node and whether Blizzard's list holds any recipe there at all (a header
-- Blizzard keeps without recipes is not ours to drop). Every item keeps the data table of the node it was
-- read from (`data`), which is only ever read.
function List:Emit(node, depth)
	local sort, only = CP.settings.sortByProfit, CP.settings.profitableOnly
	local items, recipes, had = {}, {}, false
	for _, child in ipairs(Children(node)) do
		local d = NodeData(child)
		if d and d.recipeInfo and d.recipeInfo.recipeID and not d.categoryInfo then
			had = true
			local net = UI:GetNet(d.recipeInfo.recipeID)
			if net ~= nil then self.priced = (self.priced or 0) + 1 end
			-- profitable only: a loss, break-even or unknown result is not shown as profitable
			if not (only and (net == nil or net <= 0)) then
				recipes[#recipes + 1] = { kind = "recipe", recipeID = d.recipeInfo.recipeID, info = d.recipeInfo, net = net,
					data = d, depth = depth, index = #recipes + 1 }
			end
		end
	end
	if sort then
		-- highest net first; recipes without one keep Blizzard's order after them
		table.sort(recipes, function(a, b)
			if a.net ~= b.net then
				if a.net == nil then return false end
				if b.net == nil then return true end
				return a.net > b.net
			end
			return a.index < b.index
		end)
	end

	local shown, placed = #recipes, false
	for _, child in ipairs(Children(node)) do
		local d = NodeData(child)
		if d and d.categoryInfo then
			local sub, n, subHad = self:Emit(child, depth + 1)
			had = had or subHad
			shown = shown + n
			-- a category the filter emptied goes with its recipes
			if not (only and n == 0 and subHad) then
				items[#items + 1] = { kind = "category", name = d.categoryInfo.name, unlearned = d.categoryInfo.unlearned and true or false,
					key = CategoryKey(d), collapsed = self:IsCollapsed(child, d), data = d, depth = depth, children = sub }
			end
		elseif d and d.isDivider then
			items[#items + 1] = { kind = "divider", data = d, depth = depth }
		elseif d and (d.topPadding or d.bottomPadding) then
			items[#items + 1] = { kind = "pad", data = d, depth = depth }
		elseif d and d.recipeInfo and d.recipeInfo.recipeID and not placed then
			-- the category's recipes go where its first recipe stood
			placed = true
			for _, r in ipairs(recipes) do items[#items + 1] = r end
		end
	end
	return items, shown, had
end

local function AnyUnlearned(items, from)
	for j = from, #items do
		if items[j].kind == "category" and items[j].unlearned then return true end
	end
	return false
end

-- The tree of what our list shows, read from Blizzard's list.
function List:BuildTree(dataProvider)
	if not dataProvider or type(dataProvider.GetRootNode) ~= "function" then return {} end
	local ok, root = pcall(dataProvider.GetRootNode, dataProvider)
	if not ok or not root then return {} end
	local items = self:Emit(root, 0)
	-- the divider stands above the unlearned categories: without one below it, it goes
	for i = #items, 1, -1 do
		if items[i].kind == "divider" and (i == 1 or not AnyUnlearned(items, i + 1)) then table.remove(items, i) end
	end
	return items
end

-- The rows on screen, top to bottom: collapsed categories keep their rows to themselves, padding is no row.
local function Flatten(items, out)
	for _, it in ipairs(items) do
		if it.kind == "category" then
			out[#out + 1] = it
			if not it.collapsed then Flatten(it.children, out) end
		elseif it.kind ~= "pad" then
			out[#out + 1] = it
		end
	end
	return out
end

-- Every recipe in the tree (also under a collapsed header), and the one listed first.
local function Recipes(items, set, first)
	for _, it in ipairs(items) do
		if it.kind == "recipe" then
			set[it.recipeID] = true
			first = first or it.recipeID
		elseif it.kind == "category" then
			first = Recipes(it.children, set, first)
		end
	end
	return first
end

function List:Build(dataProvider)
	self.priced = 0 -- recipes with a known profit, counted while reading Blizzard's list
	self.tree = self:BuildTree(dataProvider)
	self.recipeSet = {}
	self.firstRecipe = Recipes(self.tree, self.recipeSet, nil)
	return Flatten(self.tree, {})
end

-- What the list shows, as text (tests, /cf status).
function List:Names()
	local names = {}
	for _, r in ipairs(self.rows) do
		names[#names + 1] = r.kind == "category" and ("[" .. tostring(r.name) .. "]") or r.kind == "divider" and "--" or tostring(r.info.name)
	end
	return table.concat(names, ",")
end

---------------------------------------------------------------------------
-- View
---------------------------------------------------------------------------

local function Blizzard()
	local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
	local list = page and page.RecipeList
	local scrollBox = list and list.ScrollBox
	if not scrollBox then return nil end
	return page, list, scrollBox
end

local function Color(name, r, g, b)
	local c = _G[name]
	if type(c) == "table" and type(c.GetRGB) == "function" then return c:GetRGB() end
	return r, g, b
end

function List:SelectedRecipe()
	local page = Blizzard()
	local form = page and page.SchematicForm
	local info = form and type(form.GetRecipeInfo) == "function" and form:GetRecipeInfo() or nil
	return info and info.recipeID or nil
end

-- The default list's click sound.
local function ClickSound()
	if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT.UI_90_BLACKSMITHING_TREEITEMCLICK then
		pcall(PlaySound, SOUNDKIT.UI_90_BLACKSMITHING_TREEITEMCLICK)
	end
end

-- Is the recipe in the list Blizzard shows right now? Read from the list at this moment, not from our copy.
local function InBlizzardList(recipeID)
	local _, _, scrollBox = Blizzard()
	local dp = scrollBox and type(scrollBox.GetDataProvider) == "function" and scrollBox:GetDataProvider() or nil
	if not dp or type(dp.GetRootNode) ~= "function" then return false end
	local function Has(node)
		for _, child in ipairs(Children(node)) do
			local d = NodeData(child)
			if d and d.recipeInfo and d.recipeInfo.recipeID == recipeID then return true end
			if Has(child) then return true end
		end
		return false
	end
	local ok, found = pcall(function() return Has(dp:GetRootNode()) end)
	return ok and found or false
end

-- false when the game says the recipe belongs to another profession than the open one, nil when it cannot say.
local function InOpenProfession(recipeID)
	local T = C_TradeSkillUI
	if not (T and T.GetTradeSkillLineForRecipe and T.GetBaseProfessionInfo) then return nil end
	local ok, line, _, parent = pcall(T.GetTradeSkillLineForRecipe, recipeID)
	local ok2, base = pcall(T.GetBaseProfessionInfo)
	if not (ok and ok2 and line and type(base) == "table" and base.professionID) then return nil end
	return line == base.professionID or parent == base.professionID
end

-- Asks the game to open a recipe of the profession that is open. Never for any other recipe: opening a recipe
-- of another profession makes the game open that profession, which addons may not do ("Interface action
-- failed because of an AddOn", seen when the request for the old profession's recipe went out while the
-- window was switching professions). Returns whether the request was made.
-- A second result says whether a refusal is only for the moment (the window is rebuilding its list): such a
-- request can be made again shortly.
function List:Open(recipeID)
	local T = C_TradeSkillUI
	if not (recipeID and T and T.OpenRecipe) then return false, false end
	if InOpenProfession(recipeID) == false then return false, false end
	if T.IsDataSourceChanging and T.IsDataSourceChanging() then return false, true end -- the window is switching
	if not InBlizzardList(recipeID) then return false, true end
	CP:Debug("recipe list: asking the game for recipe %s at %.2f", tostring(recipeID), GetTime and GetTime() or 0)
	pcall(T.OpenRecipe, recipeID)
	return true
end

-- Requests that could not be made yet (a click while the window was rebuilding, the first request after the
-- window opened) are made as soon as the game takes them, for a few seconds at most.
local PUMP_STEP, PUMP_SECONDS, WANTED_SECONDS = 0.25, 12, 3

function List:Pump()
	local now = GetTime and GetTime() or 0
	local w = self.wanted
	if w then
		local ok, later = self:Open(w.id)
		if ok then
			self.wanted = nil
		elseif not later or now - w.at > WANTED_SECONDS then
			-- it will not happen: the highlight goes back to the recipe the form shows
			self.wanted = nil
			if self.pending == w.id then self.pending = nil end
			self:Draw()
		end
	end
	self:Settle()
	if (not self.wanted and not self.warm) or now - (self.pumpAt or now) > PUMP_SECONDS then
		self.warm = nil
		if self.pump then self.pump:Cancel() end
		self.pump = nil
	end
end

function List:StartPump()
	self.pumpAt = GetTime and GetTime() or 0
	if self.pump or not (C_Timer and C_Timer.NewTicker) then return end
	self.pump = C_Timer.NewTicker(PUMP_STEP, function() List:Pump() end)
end

-- A click: the default UI handles the game's answer and selects the recipe.
function List:Select(recipeID)
	if not recipeID then return end
	local ok, later = self:Open(recipeID)
	if not ok and not later then return false end
	self.pending = recipeID -- highlighted at once; the form's own selection takes over when it arrives
	self.pendingAt = GetTime and GetTime() or 0
	if ok then
		self.wanted = nil
	else
		-- the window is busy rebuilding: the click is not lost, the request follows in a moment
		self.wanted = { id = recipeID, at = self.pendingAt }
		self:StartPump()
	end
	self:Draw()
	return true
end

-- Keeps the form on a recipe our list shows. The default UI selects the first recipe of ITS list when the
-- window opens; with "Profitable only" that one may be hidden here, and the form would show a recipe the list
-- does not have. Then the first recipe of our list is opened instead (once per such recipe, so a request the
-- game does not answer is not repeated). Also, right after the window opened, the profession's line is chosen
-- (see Prime), so the first click does not have to wait.
function List:Settle()
	if not (self.frame and self.frame:IsShown()) or self.pending or self.wanted then return end
	local selected = self:SelectedRecipe()
	if not selected then return end
	if not (self.recipeSet and self.recipeSet[selected]) then
		-- not while the window is switching: then both the form's recipe and our list may be the old ones
		if self.firstRecipe and self.autoFor ~= selected and self:Select(self.firstRecipe) then
			self.autoFor = selected
			self.warm = nil
		end
		return
	end
	self.autoFor = nil
	-- `priming`: the game may rebuild the window while the line is being chosen, which leads back here
	if self.warm and not self.priming then
		self.priming = true
		local done = self:Prime(selected)
		self.priming = nil
		if done then self.warm = nil end
	end
end

-- Settle on the next frame, never from inside the default UI's own rebuild: what Settle asks the game for makes
-- the default UI rebuild its window, and from inside a rebuild that would start the next one before the first
-- has finished (seen as "C stack overflow" when switching professions).
function List:SettleSoon()
	if self.settleQueued then return end
	if not (C_Timer and C_Timer.After) then return self:Settle() end
	self.settleQueued = true
	C_Timer.After(0, function()
		List.settleQueued = nil
		List:Settle()
	end)
end

-- Makes the first click after the window opened as fast as the later ones.
-- On this client the window opens on the profession itself (skill line 197 for Tailoring) with no "child"
-- line chosen, while the game answers OpenRecipe with the recipe's child line (2948). The default UI then
-- finds the two do not match, treats the answer as one for another profession and keeps it until the next
-- recipe list update, which can be ten seconds away; handling that answer is also what finally chooses the
-- child line, so every later answer is acted on at once. Choosing the line here, with the game's own function
-- and as soon as the window is ready, skips that wait. Returns false while it cannot be done yet.
List.childLine = {} -- base profession -> child line, as the game's answers gave it (this session)

function List:Prime(recipeID)
	local T = C_TradeSkillUI
	if not (T and T.SetProfessionChildSkillLineID and T.GetProfessionChildSkillLineID and T.GetBaseProfessionInfo) then return true end
	if T.IsDataSourceChanging and T.IsDataSourceChanging() then return false end
	local okb, base = pcall(T.GetBaseProfessionInfo)
	local baseID = okb and type(base) == "table" and base.professionID or nil
	if not baseID or baseID == 0 then return false end
	local okc, current = pcall(T.GetProfessionChildSkillLineID)
	if okc and current and current ~= 0 then return true end -- a line is chosen already

	local line
	-- the line of the recipe on screen, when it is a child of the open profession
	if recipeID and T.GetTradeSkillLineForRecipe then
		local ok, l, _, parent = pcall(T.GetTradeSkillLineForRecipe, recipeID)
		if ok and l and l ~= 0 and l ~= baseID and parent == baseID then line = l end
	end
	-- or the profession's only child line
	if not line and T.GetChildProfessionInfos then
		local ok, infos = pcall(T.GetChildProfessionInfos)
		if ok and type(infos) == "table" and #infos == 1 and type(infos[1]) == "table" then line = infos[1].professionID end
	end
	-- or what the game answered earlier this session
	line = line or self.childLine[baseID]
	if not line or line == 0 or line == baseID then
		CP:Debug("recipe list: no child line known for profession %s, the first click will take its time", tostring(baseID))
		return true
	end
	CP:Debug("recipe list: choosing child line %s of profession %s", tostring(line), tostring(baseID))
	pcall(T.SetProfessionChildSkillLineID, line)
	return true
end

-- Selected in our list: the recipe the form shows, or the one just clicked until the form follows.
function List:IsSelected(recipeID)
	local selected = self:SelectedRecipe()
	-- a click that the game never answers must not hide the real selection for good
	if self.pending and (selected == self.pending or (GetTime and GetTime() - (self.pendingAt or 0) > PENDING_SECONDS)) then
		self.pending = nil
	end
	return recipeID ~= nil and recipeID == (self.pending or selected)
end

function List:RowClicked(row, button)
	local r = row.cpRow
	if not r then return end
	if r.kind == "category" then
		self.collapsed[r.key] = not r.collapsed
		self:Refresh()
	elseif r.kind == "recipe" then
		-- Shift-click: link to chat, like the default list
		if type(IsModifiedClick) == "function" and IsModifiedClick("CHATLINK") and C_TradeSkillUI and C_TradeSkillUI.GetRecipeLink then
			local ok, link = pcall(C_TradeSkillUI.GetRecipeLink, r.recipeID)
			if ok and link and type(ChatEdit_InsertLink) == "function" and ChatEdit_InsertLink(link) then return end
		end
		self:Select(r.recipeID)
		ClickSound()
	end
end

local function CreateRow(parent, index)
	local row = CreateFrame("Button", nil, parent)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_H)
	row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
	Call(row, "RegisterForClicks", "LeftButtonUp")

	row.Selected = row:CreateTexture(nil, "BACKGROUND")
	row.Selected:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
	row.Selected:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
	row.Selected:SetColorTexture(1, 0.82, 0, 0.18)
	row.Hover = row:CreateTexture(nil, "BACKGROUND")
	row.Hover:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
	row.Hover:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
	row.Hover:SetColorTexture(1, 1, 1, 0.08)
	row.Hover:Hide()
	row.Line = row:CreateTexture(nil, "ARTWORK")
	row.Line:SetHeight(1)
	row.Line:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.Line:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.Line:SetColorTexture(1, 1, 1, 0.15)
	row.Skill = row:CreateTexture(nil, "ARTWORK")
	row.Skill:SetSize(14, 14)
	row.Skill:SetPoint("LEFT", row, "LEFT", 3, 0)

	row.Label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.Label:SetJustifyH("LEFT")
	Call(row.Label, "SetWordWrap", false)
	row.Count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	row.Count:SetPoint("LEFT", row.Label, "RIGHT", 0, 0)
	row.Tag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.Tag:SetJustifyH("RIGHT")
	row.Tag:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	Call(row.Tag, "SetWordWrap", false)

	row:SetScript("OnClick", function(self, button) List:RowClicked(self, button) end)
	row:SetScript("OnEnter", function(self)
		local r = self.cpRow
		if not r or r.kind == "divider" then return end
		self.Hover:Show()
		-- a name that does not fit is shown in full
		if r.kind == "recipe" and self.cpTruncated and GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(r.info.name, 1, 1, 1)
			GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function(self)
		self.Hover:Hide()
		if GameTooltip_Hide then GameTooltip_Hide() end
	end)
	return row
end

function List:Ensure()
	if self.frame then return self.frame end
	local _, list, scrollBox = Blizzard()
	if not scrollBox then return nil end
	local f = CreateFrame("Frame", "CraftProfitList", list)
	f:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", 0, 0)
	f:SetPoint("BOTTOMRIGHT", scrollBox, "BOTTOMRIGHT", 0, 0)
	f:EnableMouse(true) -- clicks must not reach Blizzard's rows underneath
	Call(f, "EnableMouseWheel", true)
	f:SetScript("OnMouseWheel", function(_, delta) List:Scroll(-delta * WHEEL_ROWS) end)
	f:SetScript("OnSizeChanged", function() List:Draw() end)
	f.Rows = {}

	f.Empty = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.Empty:SetPoint("TOP", f, "TOP", 0, -40)
	f.Empty:SetWidth(220)
	f.Empty:SetJustifyH("CENTER")
	Call(f.Empty, "SetWordWrap", true)
	f.Empty:Hide()

	-- our own scroll bar in the place of Blizzard's
	local ok, bar = pcall(CreateFrame, "Slider", nil, f)
	if ok and bar and type(bar.SetMinMaxValues) == "function" then
		bar:SetWidth(8)
		bar:SetPoint("TOPLEFT", f, "TOPRIGHT", 6, 0)
		bar:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 6, 0)
		Call(bar, "SetOrientation", "VERTICAL")
		Call(bar, "SetValueStep", 1)
		Call(bar, "SetObeyStepOnDrag", true)
		local track = bar:CreateTexture(nil, "BACKGROUND")
		track:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
		track:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
		track:SetColorTexture(0, 0, 0, 0.35)
		local thumb = bar:CreateTexture(nil, "ARTWORK")
		thumb:SetSize(8, 40)
		thumb:SetColorTexture(0.6, 0.6, 0.6, 0.8)
		Call(bar, "SetThumbTexture", thumb)
		bar:SetScript("OnValueChanged", function(_, value)
			if List.settingBar then return end
			List.offset = math.floor((value or 0) + 0.5)
			List:Draw()
		end)
		f.Bar = bar
	end
	self.frame = f
	return f
end

-- Blizzard's list and scroll bar stay where they are, drawn invisible while ours is shown. Alpha is a widget
-- setting, not a value the default UI's code reads.
function List:Cover(covered)
	local _, list, scrollBox = Blizzard()
	if not scrollBox then return end
	local alpha = covered and 0 or 1
	Call(scrollBox, "SetAlpha", alpha)
	Call(list.ScrollBar, "SetAlpha", alpha)
	self.covered = covered and true or false
end

function List:VisibleRows()
	local f = self.frame
	local h = f and f:GetHeight() or 0
	return math.max(1, math.floor(h / ROW_H))
end

function List:Scroll(by)
	self.offset = self.offset + by
	self:Draw()
end

local function DrawRow(row, r, selected)
	row.cpRow = r
	row.cpTruncated = false
	row.Selected:Hide()
	row.Line:Hide()
	row.Skill:Hide()
	row.Count:Hide()
	row.Tag:Hide()
	row.Label:Hide()
	row.Label:ClearAllPoints()
	if r.kind == "divider" then return end

	local indent = math.max(0, (r.depth or 0) - (r.kind == "recipe" and 1 or 0)) * 8
	if r.kind == "category" then
		row.Label:SetPoint("LEFT", row, "LEFT", 6 + indent, 0)
		row.Label:SetText((r.collapsed and "+ " or "- ") .. tostring(r.name))
		if r.unlearned then
			row.Label:SetTextColor(Color("DISABLED_FONT_COLOR", 0.5, 0.5, 0.5))
		else
			row.Label:SetTextColor(Color("NORMAL_FONT_COLOR", 1, 0.82, 0))
		end
		row.Label:SetWidth(math.max(30, row:GetWidth() - 12 - indent))
		row.Label:Show()
		return
	end

	local info = r.info
	row.Label:SetPoint("LEFT", row, "LEFT", LABEL_X + indent, 0)
	row.Label:SetText(info.name or "?")
	if info.learned == false then
		row.Label:SetTextColor(Color("DISABLED_FONT_COLOR", 0.5, 0.5, 0.5))
	else
		row.Label:SetTextColor(Color("PROFESSION_RECIPE_COLOR", 0.88, 0.73, 0.51))
	end
	row.Label:Show()

	-- skill-up arrow, as in the default list
	local diff = Enum and Enum.TradeskillRelativeDifficulty
	if info.canSkillUp and diff and info.relativeDifficulty then
		local atlas = (info.relativeDifficulty == diff.Optimal and SKILL_ATLAS[1]) or (info.relativeDifficulty == diff.Medium and SKILL_ATLAS[2])
			or (info.relativeDifficulty == diff.Easy and SKILL_ATLAS[3]) or nil
		if atlas and Call(row.Skill, "SetAtlas", atlas) then row.Skill:Show() end
	end

	-- how many you can craft
	local countWidth = 0
	if C_TradeSkillUI and C_TradeSkillUI.GetCraftableCount then
		local ok, count = pcall(C_TradeSkillUI.GetCraftableCount, r.recipeID)
		if ok and type(count) == "number" and count > 0 then
			row.Count:SetText(string.format(" [%d] ", count))
			row.Count:SetTextColor(row.Label:GetTextColor())
			row.Count:Show()
			countWidth = row.Count:GetStringWidth() or 0
		end
	end

	-- the profit tag, the same one the default rows get
	local tagWidth = 0
	if CP.settings.showRowTags then
		local eco = UI:GetEco(r.recipeID)
		local net, margin = UI:DisplayNet(eco)
		if not (eco and not eco.error and not eco.outputItemID and net == nil) then
			row.Tag:SetText(UI:TagText(net, margin))
			row.Tag:Show()
			tagWidth = (row.Tag:GetStringWidth() or 0) + 10
		end
	end

	local available = math.max(30, row:GetWidth() - LABEL_X - indent - countWidth - tagWidth - 4)
	local wanted = row.Label:GetStringWidth() or available
	row.cpTruncated = wanted > available
	row.Label:SetWidth(math.min(wanted, available))
	if selected then row.Selected:Show() end
end

-- Why the list is empty. "Profitable only" with no price known for any recipe hides them all: that is a missing
-- Auction House scan, not a profession without profit, and the text says how to get prices.
List.EMPTY_NO_PRICES = "No prices yet, so no recipe can be shown as profitable.\n\nScan the Auction House (the CraftProfit Scan button there, or /cf scan), or turn off Profitable only (/cf profit)."
List.EMPTY_NO_PROFIT = "No recipe makes a profit at the current prices.\n\nTurn off Profitable only (/cf profit) to see them all."

function List:EmptyText()
	if #self.rows > 0 then return nil end
	if CP.settings.profitableOnly and (self.priced or 0) == 0 then return self.EMPTY_NO_PRICES end
	return self.EMPTY_NO_PROFIT
end

function List:ShowEmpty()
	local f = self.frame
	if not f then return end
	local text = self:EmptyText()
	if text then f.Empty:SetText(text) end
	f.Empty:SetShown(text ~= nil)
end

function List:Draw()
	local f = self.frame
	if not f or not f:IsShown() then return end
	if self.native then
		-- Blizzard's scroll box draws the rows; only the selection can have changed
		for _, row in ipairs(f.Rows) do row:Hide() end
		if f.Bar then f.Bar:Hide() end
		self:ShowEmpty()
		self:NativeSelection()
		return
	end
	local rows, visible = self.rows, self:VisibleRows()
	local maxOffset = math.max(0, #rows - visible)
	if self.offset > maxOffset then self.offset = maxOffset end
	if self.offset < 0 then self.offset = 0 end

	-- the form's own selection is the truth; a click is shown until it arrives
	for i = 1, visible do
		local row = f.Rows[i]
		if not row then
			row = CreateRow(f, i)
			f.Rows[i] = row
		end
		local r = rows[self.offset + i]
		if r then
			DrawRow(row, r, r.kind == "recipe" and self:IsSelected(r.recipeID))
			if r.kind == "divider" then row.Line:Show() end
			row:Show()
		else
			row.cpRow = nil
			row:Hide()
		end
	end
	for i = visible + 1, #f.Rows do f.Rows[i]:Hide() end
	self:ShowEmpty()

	if f.Bar then
		self.settingBar = true
		f.Bar:SetMinMaxValues(0, maxOffset)
		Call(f.Bar, "SetValue", self.offset)
		f.Bar:SetShown(maxOffset > 0)
		self.settingBar = nil
	end
end

---------------------------------------------------------------------------
-- Native view: Blizzard's scroll box, scroll bar and row templates, in instances of our own
---------------------------------------------------------------------------
-- The same building blocks the default recipe list is made of (ProfessionsRecipeListMixin:OnLoad), so the
-- list looks and behaves like it: header art and rank bars, fonts, spacing, hover and selection art, the
-- scroll bar. The scroll box, its view, its data provider and every row are created here and belong to
-- CraftProfit; nothing of the default list is shared but the recipe and category info tables, which are read.
-- Without these pieces (another client, the test harness) the plain rows above are drawn instead.

local function NativeAvailable()
	return type(CreateScrollBoxListTreeListView) == "function" and type(CreateTreeDataProvider) == "function"
		and type(ScrollUtil) == "table" and type(ScrollUtil.InitScrollBoxListWithScrollBar) == "function"
		and type(ProfessionsRecipeListRecipeMixin) == "table" and type(ProfessionsRecipeListCategoryMixin) == "table"
end

local function RecipeClicked(button, buttonName, info)
	if buttonName == "LeftButton" then
		if type(IsModifiedClick) == "function" and IsModifiedClick() then
			-- Shift-click links, the track modifier tracks: as in the default list
			local ok, link = pcall(C_TradeSkillUI.GetRecipeLink, info.recipeID)
			local handled = ok and link and type(HandleModifiedItemClick) == "function" and HandleModifiedItemClick(link)
			if not handled and IsModifiedClick("RECIPEWATCHTOGGLE") and C_TradeSkillUI.IsRecipeTracked and C_TradeSkillUI.SetRecipeTracked then
				local ok2, tracked = pcall(C_TradeSkillUI.IsRecipeTracked, info.recipeID, false)
				if ok2 then pcall(C_TradeSkillUI.SetRecipeTracked, info.recipeID, not tracked, false) end
			end
		else
			List:Select(info.recipeID)
		end
	elseif buttonName == "RightButton" then
		-- favourite / unfavourite, through the game's own function
		if info.learned and type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) == "function"
			and C_TradeSkillUI.IsRecipeFavorite and C_TradeSkillUI.SetRecipeFavorite then
			pcall(MenuUtil.CreateContextMenu, button, function(_, rootDescription)
				local recipeID = info.recipeID
				if C_TradeSkillUI.IsRecipeFavorite(recipeID) then
					rootDescription:CreateButton(BATTLE_PET_UNFAVORITE or "Unfavorite", function() C_TradeSkillUI.SetRecipeFavorite(recipeID, false) end)
				else
					rootDescription:CreateButton(BATTLE_PET_FAVORITE or "Favorite", function() C_TradeSkillUI.SetRecipeFavorite(recipeID, true) end)
				end
			end)
		end
	end
	ClickSound()
end

function List:EnsureNative()
	if self.native then return true end
	if self.nativeFailed or not NativeAvailable() then return false end
	local f = self.frame
	local ok, err = pcall(function()
		local box = CreateFrame("Frame", "CraftProfitListScrollBox", f, "WowScrollBoxList")
		box:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
		box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
		local bar = CreateFrame("EventFrame", "CraftProfitListScrollBar", f, "MinimalScrollBar")
		bar:SetPoint("TOPLEFT", box, "TOPRIGHT", 0, 0)
		bar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 0, 0)

		-- indent, padding and spacing of the default list
		local view = CreateScrollBoxListTreeListView(10, 5, 5, 0, 5, 1)
		view:SetElementFactory(function(factory, node)
			local data = node:GetData()
			if data.categoryInfo then
				factory("ProfessionsRecipeListCategoryTemplate", function(button, node)
					button:Init(node)
					button:SetScript("OnClick", function(button)
						node:ToggleCollapsed()
						button:UpdateCollapsedState(node:IsCollapsed())
						List.collapsed[data.cpKey] = node:IsCollapsed() and true or false
						List.rows = Flatten(List:MarkCollapsed(List.tree), {})
						List.sig = List:Sig()
					end)
					button:SetScript("OnEnter", function() ProfessionsRecipeListCategoryMixin.OnEnter(button) end)
				end)
			elseif data.recipeInfo then
				factory("ProfessionsRecipeListRecipeTemplate", function(button, node)
					button:Init(node, false)
					button:SetSelected(List:IsSelected(data.recipeInfo.recipeID))
					UI:UpdateRow(button, node) -- the profit tag, as on the default rows
					button:SetScript("OnClick", function(button, buttonName) RecipeClicked(button, buttonName, data.recipeInfo) end)
					-- the default hover, without announcing it to the rest of the UI
					button:SetScript("OnEnter", function()
						if HIGHLIGHT_FONT_COLOR then button:SetLabelFontColors(HIGHLIGHT_FONT_COLOR) end
						if button.Label:IsTruncated() then
							GameTooltip:SetOwner(button.Label, "ANCHOR_RIGHT")
							GameTooltip:AddLine(data.recipeInfo.name, 1, 1, 1)
							GameTooltip:Show()
						end
					end)
				end)
			elseif data.isDivider then
				factory("ProfessionsRecipeListDividerTemplate")
			else
				factory("Frame")
			end
		end)
		view:SetElementExtentCalculator(function(_, node)
			local data = node:GetData()
			if data.recipeInfo then return 20 end
			if data.categoryInfo then return 25 end
			if data.dividerHeight then return data.dividerHeight end
			if data.topPadding then return 1 end
			if data.bottomPadding then return 10 end
			return 1
		end)
		ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
		self.box, self.bar = box, bar
	end)
	if not ok then
		CP:Print("recipe list: could not use the default list look, showing plain rows instead (%s)", tostring(err))
		self.nativeFailed = true
		if self.box then self.box:Hide() end
		if self.bar then self.bar:Hide() end
		self.box, self.bar = nil, nil
		return false
	end
	self.native = true
	return true
end

-- Writes the collapse state the player set here back into the tree items (after a header click).
function List:MarkCollapsed(items)
	for _, it in ipairs(items or {}) do
		if it.kind == "category" then
			local own = self.collapsed[it.key]
			if own ~= nil then it.collapsed = own end
			self:MarkCollapsed(it.children)
		end
	end
	return items or {}
end

-- What the rows are, as text: the same text means the same rows in the same order.
local function Signature(items, out)
	for _, it in ipairs(items) do
		if it.kind == "category" then
			out[#out + 1] = "c" .. tostring(it.key) .. (it.collapsed and "-" or "+")
			Signature(it.children, out)
			out[#out + 1] = "."
		elseif it.kind == "recipe" then
			out[#out + 1] = "r" .. tostring(it.recipeID)
		else
			out[#out + 1] = it.kind == "divider" and "d" or "p"
		end
	end
	return out
end

function List:Sig()
	return table.concat(Signature(self.tree or {}, {}))
end

-- Same rows as before: the frames stay as they are, only what they show is brought up to date (craftable
-- counts, profit tags, selection). Handing the scroll box a new provider would build every row again, and a
-- click whose press and release fall on either side of that is lost. The default UI rebuilds its own list on
-- every selection, so without this each click would rebuild ours too.
function List:NativeUpdateRows()
	if not (self.box and type(self.box.ForEachFrame) == "function") then return end
	-- Blizzard's rebuilt list carries fresh recipe info (learned, skill-ups): our nodes take it over
	local fresh = {}
	local function Collect(items)
		for _, it in ipairs(items) do
			if it.kind == "recipe" then fresh[it.recipeID] = it.info elseif it.kind == "category" then Collect(it.children) end
		end
	end
	Collect(self.tree or {})
	local function Renew(node)
		for _, child in ipairs(Children(node)) do
			local d = NodeData(child)
			if d and d.recipeInfo and fresh[d.recipeInfo.recipeID] then d.recipeInfo = fresh[d.recipeInfo.recipeID] end
			Renew(child)
		end
	end
	pcall(function()
		local dp = type(self.box.GetDataProvider) == "function" and self.box:GetDataProvider() or self.box.dp
		if dp and type(dp.GetRootNode) == "function" then Renew(dp:GetRootNode()) end
	end)
	pcall(self.box.ForEachFrame, self.box, function(frame)
		local node = type(frame.GetElementData) == "function" and frame:GetElementData() or nil
		local data = node and NodeData(node)
		if data and data.recipeInfo then
			-- the row's own setup again, on the same frame: name colour, skill-up arrow, craftable count
			if type(frame.Init) == "function" then pcall(frame.Init, frame, node, false) end
			UI:UpdateRow(frame, node)
			if type(frame.SetSelected) == "function" then frame:SetSelected(List:IsSelected(data.recipeInfo.recipeID)) end
		end
	end)
end

-- Fills a tree data provider of our own with the items and hands it to our scroll box.
function List:Populate()
	local sig = self:Sig()
	if sig == self.sig then
		self:NativeUpdateRows()
		return
	end
	local dp = CreateTreeDataProvider()
	local function Add(parent, items)
		for _, it in ipairs(items) do
			local d = it.data or {}
			if it.kind == "recipe" then
				parent:Insert({ recipeInfo = it.info, order = d.order })
			elseif it.kind == "category" then
				local node = parent:Insert({ categoryInfo = d.categoryInfo, cpKey = it.key })
				Add(node, it.children)
				node:SetCollapsed(it.collapsed and true or false, false, true)
			elseif it.kind == "divider" then
				parent:Insert({ isDivider = true, dividerHeight = d.dividerHeight })
			elseif it.kind == "pad" then
				parent:Insert({ topPadding = d.topPadding, bottomPadding = d.bottomPadding, order = d.order })
			end
		end
	end
	Add(dp:GetRootNode(), self.tree or {})
	local retain = ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition
	self.box:SetDataProvider(dp, retain)
	self.sig = sig
end

-- The selection moved: only the rows on screen need to know.
function List:NativeSelection()
	if not (self.native and self.box and type(self.box.ForEachFrame) == "function") then return end
	pcall(self.box.ForEachFrame, self.box, function(frame)
		local node = type(frame.GetElementData) == "function" and frame:GetElementData() or nil
		local data = node and NodeData(node)
		if data and data.recipeInfo and type(frame.SetSelected) == "function" then
			frame:SetSelected(List:IsSelected(data.recipeInfo.recipeID))
		end
	end)
end

-- Rebuilds our rows from Blizzard's list and shows or hides our frame. `dataProvider` is the list Blizzard
-- just set (from the SetDataProvider hook); without it the one on screen is read.
function List:Refresh(dataProvider)
	local _, _, scrollBox = Blizzard()
	if not scrollBox then return false end
	if not dataProvider and type(scrollBox.GetDataProvider) == "function" then dataProvider = scrollBox:GetDataProvider() end

	-- off, or Blizzard has nothing to list (its own "no results" text shows): Blizzard's list as it is
	local empty = not dataProvider or (type(dataProvider.IsEmpty) == "function" and dataProvider:IsEmpty())
	if not self:Active() or empty then
		self.rows = {}
		if self.frame then self.frame:Hide() end
		if self.covered then self:Cover(false) end
		return false
	end

	local ok, rows = pcall(self.Build, self, dataProvider)
	if not ok then
		CP:Debug("profit list failed: %s", tostring(rows))
		self.rows = {}
		if self.frame then self.frame:Hide() end
		if self.covered then self:Cover(false) end
		return false
	end
	self.rows = rows
	local f = self:Ensure()
	if not f then return false end
	-- above Blizzard's rows, whatever level they were given
	Call(f, "SetFrameLevel", (scrollBox:GetFrameLevel() or 1) + 30)
	self:Cover(true)
	f:Show()
	if self:EnsureNative() then
		local ok2, err = pcall(self.Populate, self)
		if not ok2 then
			-- Blizzard's pieces did not take our data: the plain rows from here on
			CP:Print("recipe list: could not use the default list look, showing plain rows instead (%s)", tostring(err))
			self.native, self.nativeFailed = false, true
			if self.box then self.box:Hide() end
			if self.bar then self.bar:Hide() end
		end
	end
	self:Draw()
	self:SettleSoon()
	return true
end

-- craftable counts change with the bags
CP:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() if List.frame and List.frame:IsShown() then List:Refresh() end end)
CP:RegisterEvent("BAG_UPDATE_DELAYED", function()
	if not (List.frame and List.frame:IsShown()) then return end
	if List.native then List:Refresh() else List:Draw() end
end)
CP:On("FORM_INIT", function()
	if not (List.frame and List.frame:IsShown()) then return end
	List:Draw()
	List:SettleSoon()
end)
-- The window opened. Nothing else may happen before the first click (the list is usually built before this
-- event), so the first request is made from here, as soon as the window is ready to take it.
CP:RegisterEvent("TRADE_SKILL_SHOW", function()
	List.warm = true
	List:StartPump()
end)

-- /cf debug: when the game answers a request and when the window gets its next list update. The first answer
-- after the window opened is acted on late by the default UI (it waits for a list update); these lines show
-- which ids it compared, to find out why.
local function DebugState(what, ...)
	if not (CP.settings and CP.settings.debug) then return end
	local T = C_TradeSkillUI
	local function Try(fn, field)
		if type(fn) ~= "function" then return "?" end
		local ok, v = pcall(fn)
		if not ok then return "?" end
		if field then v = type(v) == "table" and v[field] or nil end
		return tostring(v)
	end
	local args = {}
	for i = 1, select("#", ...) do args[i] = tostring((select(i, ...))) end
	CP:Debug("recipe list: %s(%s) at %.2f | child line %s, base %s, child info %s, changing %s", what, table.concat(args, ", "),
		GetTime and GetTime() or 0, Try(T and T.GetProfessionChildSkillLineID), Try(T and T.GetBaseProfessionInfo, "professionID"),
		Try(T and T.GetChildProfessionInfo, "professionID"), Try(T and T.IsDataSourceChanging))
end
CP:RegisterEvent("OPEN_RECIPE_RESPONSE", function(_, recipeID, professionLine, childLine)
	if professionLine and childLine and childLine ~= 0 then List.childLine[professionLine] = childLine end
	DebugState("OPEN_RECIPE_RESPONSE", recipeID, professionLine, childLine)
end)
CP:RegisterEvent("TRADE_SKILL_LIST_UPDATE", function() DebugState("TRADE_SKILL_LIST_UPDATE") end)
CP:RegisterEvent("TRADE_SKILL_SHOW", function() DebugState("TRADE_SKILL_SHOW") end)
