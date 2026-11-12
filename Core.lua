-- CraftProfit :: Core
-- Namespace, saved variables, event dispatch, pub/sub, formatting helpers, slash commands.

local ADDON_NAME, CP = ...
_G.CraftProfit = CP

CP.name = ADDON_NAME
CP.CALLER_ID = ADDON_NAME -- identifier passed to third-party APIs (Auctionator)
-- Filled in at PLAYER_LOGIN (end of this file): on build 69977 asking the client for our own TOC metadata
-- while the addon is still loading keeps it from handing back our SavedVariables.
CP.version = "dev"
CP.DB_VERSION = 1

CP.defaults = {
	source = "auto",              -- auto | craftprofit | auctionator | tsm
	ahCut = 0.05,                 -- auction house cut on sale (retail value; confirm for Forever)
	saleBasis = "min",            -- own scan only: min (lowest buyout) | market (depth value, else median of recent scans)
	depthScan = true,             -- after a full scan, read the listings of learned recipes' reagents and outputs
	useVendorWhenCheaper = true,  -- reagent cost = min(AH, vendor buy price)
	showRowTags = true,
	rowTag = "profit",            -- what the recipe-row tag shows: profit | margin | both
	netBasis = "ah",              -- which net the tags, sort and panel lead with: ah | vendor
	trainerTags = true,           -- profit tags in the profession trainer window
	showReagentPrices = true,
	showPanel = true,
	sortByProfit = false,
	craftIntermediates = false,   -- price reagents you can craft (learned recipe) at their own craft cost
	craftOnlyWhenCheaper = true,  -- ...but only when that beats the buy price
	scanButton = true,
	tsmSale = "DBMarket",
	tsmCost = "min(DBMarket, VendorBuy)",
	tsmSoldPerDay = "DBRegionSoldPerDay",
	tooltip = true,               -- CraftProfit block (auction price, scan status) in item tooltips
	debug = false,
}

CP.COLORS = {
	gold   = "ffd100",
	body   = "e8dcc8",
	label  = "c8b78a",
	muted  = "8a7d64",
	gray   = "9d9d9d",
	profit = "4cd137",
	loss   = "ff5b4b",
	high   = "ff9933",                -- price verdict "high" (cheap uses profit)
}

---------------------------------------------------------------------------
-- Output helpers
---------------------------------------------------------------------------

function CP:Print(msg, ...)
	if select("#", ...) > 0 then msg = string.format(msg, ...) end
	(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cffffd100CraftProfit:|r " .. tostring(msg))
end

function CP:Debug(msg, ...)
	if self.settings and self.settings.debug then
		if select("#", ...) > 0 then msg = string.format(msg, ...) end
		(DEFAULT_CHAT_FRAME or ChatFrame1):AddMessage("|cff8a7d64CraftProfit[dbg]:|r " .. tostring(msg))
	end
end

function CP:Color(hex, text)
	return "|cff" .. hex .. tostring(text) .. "|r"
end

---------------------------------------------------------------------------
-- Pub/sub between modules
---------------------------------------------------------------------------

local listeners = {}

function CP:On(event, fn)
	listeners[event] = listeners[event] or {}
	table.insert(listeners[event], fn)
end

function CP:Fire(event, ...)
	local list = listeners[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, ...)
		if not ok then
			CP:Debug("listener for %s failed: %s", event, tostring(err))
		end
	end
end

---------------------------------------------------------------------------
-- Game events
---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

function CP:RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
		if not ok then
			CP:Debug("cannot register event %s: %s", event, tostring(err))
		end
	end
	table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, event, ...)
		if not ok then
			geterrorhandler()(err)
		end
	end
end)

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local function ApplyDefaults(tbl, defaults)
	for k, v in pairs(defaults) do
		if tbl[k] == nil then tbl[k] = v end
	end
	-- netBasis briefly had a third value ("best") in a test build
	if tbl.netBasis ~= nil and tbl.netBasis ~= "ah" and tbl.netBasis ~= "vendor" then tbl.netBasis = "ah" end
end

local function InitDB()
	-- What the client handed us from disk, before we touch it (shown by /cf status to diagnose data loss).
	-- Two copies are declared: account-wide CraftProfitDB and per-character CraftProfitCharDB (the client
	-- stores them in different folders; whichever comes back is used).
	if CraftProfitDB == nil and CraftProfitCharDB ~= nil then
		CraftProfitDB = CraftProfitCharDB
		CP.loadedFrom = "per-character file"
	elseif CraftProfitDB ~= nil then
		CP.loadedFrom = "account file"
	end
	if not CP.loadInfo then
		local info = { hadDB = CraftProfitDB ~= nil, realms = {}, prices = 0, ladders = 0, from = CP.loadedFrom }
		if type(CraftProfitDB) == "table" and type(CraftProfitDB.realms) == "table" then
			for key, realm in pairs(CraftProfitDB.realms) do
				local n, l = 0, 0
				for _ in pairs(realm.prices or {}) do n = n + 1 end
				for _ in pairs(realm.ladders or {}) do l = l + 1 end
				info.realms[key] = n
				info.prices = info.prices + n
				info.ladders = info.ladders + l
			end
		end
		CP.loadInfo = info
	end
	-- Do NOT create the global here when the client has not set it: on this client the saved file is loaded
	-- after ADDON_LOADED and an already-set global appears to make it skip the file. The watcher below
	-- assigns the global at logout (in time for the save) or adopts the client's table when it shows up.
	local db = CraftProfitDB or {}
	if CP:IsPacked(db) then
		db = CP:UnpackDB(db)
		CraftProfitDB = db -- the loader has run; from here on the live table is the global
		if CP.loadInfo then
			CP.loadInfo.prices, CP.loadInfo.realms = 0, {}
			for key, realm in pairs(db.realms) do
				local n = 0
				for _ in pairs(realm.prices) do n = n + 1 end
				CP.loadInfo.realms[key] = n
				CP.loadInfo.prices = CP.loadInfo.prices + n
			end
		end
	end
	db.version = db.version or CP.DB_VERSION
	db.settings = db.settings or {}
	db.vendor = db.vendor or {}     -- itemID -> vendor buy price per unit (copper)
	db.recipeCache = db.recipeCache or {} -- recipeID -> compact schematic, so costs work before a profession is opened
	db.learned = db.learned or {}   -- charKey -> { recipeID = true } learned recipes seen on that character
	db.realms = db.realms or {}     -- realmKey -> { prices, history, ladders, mv, purchases, lastScan }
	ApplyDefaults(db.settings, CP.defaults)
	CP.db = db
	CP.settings = db.settings
	local pack = function(live) return CP:PackDB(live) end
	CP:WatchSavedVariable("CraftProfitDB", db, function(...) return CP.AdoptDB(...) end, pack, "CraftProfit")
	CP:WatchSavedVariable("CraftProfitCharDB", db, function(...) return CP.AdoptDB(...) end, pack, "CraftProfit")
end

function CP:GetCharKey()
	local name = (UnitName and UnitName("player")) or "char"
	return name .. "-" .. self:GetRealmKey()
end

-- Realm bucket key. GetNormalizedRealmName() can be nil early after login; then the plain realm name with
-- spaces removed gives the same key ("Classic Beta PvP" -> "ClassicBetaPvP"), and the first good answer is
-- kept so the key cannot change within a session.
local realmKeyCache
function CP:GetRealmKey()
	if realmKeyCache then return realmKeyCache end
	local name = GetNormalizedRealmName and GetNormalizedRealmName()
	if not name or name == "" then
		local plain = GetRealmName and GetRealmName()
		if plain and plain ~= "" then name = plain:gsub("[%s%-']", "") end
	end
	if not name or name == "" then return "Unknown" end
	realmKeyCache = name
	return name
end

function CP:GetRealmDB()
	local key = self:GetRealmKey()
	local realm = self.db.realms[key]
	if not realm then
		realm = { prices = {}, history = {}, lastScan = 0 }
		self.db.realms[key] = realm
	end
	realm.prices = realm.prices or {}
	realm.history = realm.history or {}
	realm.mv = realm.mv or {}
	realm.daily = realm.daily or {}
	realm.lastScan = realm.lastScan or 0
	return realm
end

CP.touched = {} -- settings changed this session (kept when a late-loaded database is adopted)

function CP:SetSetting(key, value)
	self.settings[key] = value
	self.touched[key] = true
	self:Fire("SETTINGS_CHANGED", key, value)
end

---------------------------------------------------------------------------
-- Late SavedVariables (WoW Forever beta)
---------------------------------------------------------------------------
-- On this client the saved table is not always in place when ADDON_LOADED fires: it can be assigned to the
-- global later (observed: saved data appearing after login) or, for some addons, seemingly not at
-- all. If we simply created a fresh table at load, the client keeps writing the *old* global back and
-- everything recorded this session is lost. So every addon registers its global here; we poll for the
-- client swapping it, and when that happens the session's data is merged into the loaded table and the
-- addon switches over. PLAYER_LOGOUT is the last chance before the client writes the file.

local svWatchers = {}

-- onAdopt(loaded, provisional, reason) must merge provisional into loaded and repoint the addon at loaded.
-- pack(live) (optional) returns the table to hand the client at logout (the compact form).
-- group: watchers of the same addon (account-wide and per-character copies of the same data) share a
-- group; the first copy the client hands back is adopted, a later duplicate is ignored.
local svGroups = {}
function CP:WatchSavedVariable(name, current, onAdopt, pack, group)
	svWatchers[name] = { current = current, onAdopt = onAdopt, pack = pack, group = group or name, adopted = 0 }
	svGroups[group or name] = svGroups[group or name] or { adopted = false }
	-- the addon started from a saved table the client had already set: that IS the saved data. Adopting the
	-- vault copy (or a sibling file) on top would merge the same records into themselves, and additive
	-- merges would then double on every login.
	if current ~= nil and _G[name] == current then
		svGroups[group or name].adopted = true
		svWatchers[name].adoptedAt = "present at load"
	end
end

-- Console vault. Build 69977 never opens per-account or per-character SavedVariables files at load (ETW file
-- trace, 2026-09-24): only the machine-wide WTF\SavedVariables\Blizzard_Console.lua is read back. So every
-- watched group also keeps a copy at Blizzard_Console_SavedVars.AddOnVault[group], written at logout and
-- adopted like a late-loaded file when it shows up. Only CraftProfit's own groups are read or written.
local VAULT_KEY = "AddOnVault"
function CP:GetVault(create)
	local console = _G.Blizzard_Console_SavedVars
	if type(console) ~= "table" then return nil end
	local vault = console[VAULT_KEY]
	if type(vault) ~= "table" then
		if not create then return nil end
		vault = {}
		console[VAULT_KEY] = vault
	end
	return vault
end

function CP:GroupAdopted(group)
	local g = svGroups[group]
	return g and g.adopted or false
end

local function CheckVault(reason)
	local vault = CP:GetVault(false)
	if not vault then return end
	for groupName, group in pairs(svGroups) do
		local copy = vault[groupName]
		if type(copy) == "table" and not group.adopted and not group.vaultTried then
			group.vaultTried = true
			local w
			for _, x in pairs(svWatchers) do if x.group == groupName then w = x break end end
			if w then
				local ok, live = pcall(w.onAdopt, copy, w.current, "console vault")
				if ok then
					if type(live) ~= "table" then live = copy end
					group.adopted = true
					for _, w2 in pairs(svWatchers) do
						if w2.group == groupName then
							w2.current = live
							w2.adopted = w2.adopted + 1
							w2.adoptedAt = reason .. " via console vault"
						end
					end
				else
					CP:Print("could not adopt %s's saved data from the console vault (%s): %s", groupName, tostring(reason), tostring(live))
				end
			end
		end
	end
end

local function WriteVault()
	local vault = CP:GetVault(true)
	if not vault then return end
	for groupName in pairs(svGroups) do
		for _, w in pairs(svWatchers) do
			if w.group == groupName then
				vault[groupName] = w.lastPacked or w.current
				break
			end
		end
	end
end

function CP:CheckSavedVariables(reason)
	if reason ~= "logout" then CheckVault(reason) end
	for name, w in pairs(svWatchers) do
		local g = _G[name]
		local group = svGroups[w.group]
		if reason == "logout" then
			-- the client writes the files right after this: hand it the (compact) table to save
			local ok, packed = true, w.current
			if w.pack then ok, packed = pcall(w.pack, w.current) end
			_G[name] = (ok and packed) or w.current
			w.assign = true
			w.lastPacked = _G[name]
		elseif g == nil then
			-- leave the global unset while the client may still load the file into it
			if w.assign then _G[name] = w.current end
		elseif g ~= w.current and g ~= w.lastPacked then
			if group.adopted then
				-- the sibling copy already arrived and was merged; this one is the same data
				_G[name] = w.current
			else
				local ok, err = pcall(w.onAdopt, g, w.current, reason)
				if ok then
					local live = _G[name] -- the adopter may have replaced the global (unpacked form)
					w.adopted = w.adopted + 1
					w.adoptedAt = reason .. " via " .. name
					group.adopted = true
					for _, w2 in pairs(svWatchers) do
						if w2.group == w.group then w2.current = live end
					end
				else
					CP:Print("could not adopt the saved %s (%s); keeping this session's data. %s", name, tostring(reason), tostring(err))
					_G[name] = w.current
				end
			end
		end
	end
	if reason == "logout" then WriteVault() end
end

-- Forget that a group already adopted a copy (used by the test harness to simulate a new session).
function CP:ResetSavedVariableGroups()
	for _, g in pairs(svGroups) do g.adopted = false end
end

-- After another addon restored our table from its own backup, treat that table as the current one.
function CP:ResetSavedVariableWatch(name, current)
	local w = svWatchers[name]
	if w then
		w.current = current
		w.restoredFromBackup = true
	end
end

function CP:SavedVariableStatus(name)
	local w = svWatchers[name]
	if not w then return "not watched" end
	for _, w2 in pairs(svWatchers) do
		if w2.group == w.group and w2.adopted > 0 then
			return string.format("saved data arrived late and was adopted (%s)", tostring(w2.adoptedAt))
		end
	end
	if w.restoredFromBackup then return "restored from a companion addon's backup copy" end
	return "no late saved data seen" .. (_G[name] == nil and " (global left unset for the client to fill; assigned at logout)" or "")
end

local svTicker
local function StartSavedVariableWatch()
	CP:CheckSavedVariables("login")
	if svTicker or not (C_Timer and C_Timer.NewTicker) then return end
	local polls = 0
	svTicker = C_Timer.NewTicker(1, function()
		polls = polls + 1
		CP:CheckSavedVariables("poll " .. polls .. "s")
		if polls >= 300 and svTicker then
			svTicker:Cancel()
			svTicker = nil
		end
	end)
end
CP:RegisterEvent("PLAYER_ENTERING_WORLD", function() CP:CheckSavedVariables("entering world") end)
CP:RegisterEvent("PLAYER_LOGOUT", function()
	CP:CheckSavedVariables("logout")
end)
CP:RegisterEvent("ADDON_LOADED", function(_, name) if name ~= ADDON_NAME then CP:CheckSavedVariables("addon " .. tostring(name)) end end)

---------------------------------------------------------------------------
-- Compact on-disk format
---------------------------------------------------------------------------
-- Every saved file that came back on this client was small (a few KB); every one that did not was large
-- (150-250 KB), so the database is written in a compact form at logout: numbers in base 36, a few hundred
-- entries per string, and only items whose price was actually used this session or last (recipe outputs,
-- reagents, materials, ladders). Loading accepts both the compact and the plain form.

local PACK_VERSION = 2
local PACK_CHUNK = 150
local PACK_HISTORY, PACK_TIERS, PACK_PURCHASES, PACK_LADDER_AGE = 3, 20, 5, 86400
local PACK_MV_AGE = 14 * 86400 -- depth values older than this are dropped (Scanner.MV_TTL)
local PACK_DAILY_DAYS = 14      -- price history days kept (Scanner.DAILY_DAYS)
local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"

local function Enc(n)
	n = math.floor((tonumber(n) or 0) + 0.5)
	if n <= 0 then return "0" end
	local s = ""
	while n > 0 do
		local d = n % 36
		s = B36:sub(d + 1, d + 1) .. s
		n = math.floor(n / 36)
	end
	return s
end

local function Dec(s)
	if not s or s == "" then return 0 end
	return tonumber(s, 36) or 0
end
CP.Enc, CP.Dec = Enc, Dec -- shared with Share.lua

local function Chunks(list)
	local chunks, buf = {}, {}
	for _, s in ipairs(list) do
		buf[#buf + 1] = s
		if #buf >= PACK_CHUNK then
			chunks[#chunks + 1] = table.concat(buf, ";")
			buf = {}
		end
	end
	if #buf > 0 then chunks[#chunks + 1] = table.concat(buf, ";") end
	return chunks
end

local function Each(chunks, fn)
	for _, chunk in ipairs(chunks or {}) do
		for entry in string.gmatch(chunk, "[^;]+") do fn(entry) end
	end
end

-- Items worth keeping across sessions: anything whose price was looked up (recipes, reagents, materials),
-- anything with a ladder or a purchase, and everything that came back from disk.
CP.touchedItems = {}
function CP:Touch(itemID)
	if itemID then self.touchedItems[itemID] = true end
end

function CP:PackDB(db)
	db = db or self.db
	local now = time()
	local keep = self.touchedItems
	local out = { packed = PACK_VERSION, packedAt = now, version = db.version, settings = db.settings, realms = {}, learned = {},
		shareImported = db.shareImported, shopping = db.shopping, shoppingMail = db.shoppingMail }
	local v = {}
	for id, price in pairs(db.vendor or {}) do v[#v + 1] = Enc(id) .. "." .. Enc(price) end
	out.vendor = Chunks(v)
	for char, set in pairs(db.learned or {}) do
		local ids = {}
		for id in pairs(set) do ids[#ids + 1] = Enc(id) end
		out.learned[char] = table.concat(ids, ",")
	end
	local rc = {}
	for rid, c in pairs(db.recipeCache or {}) do
		local slots = {}
		for _, slot in ipairs(c.r or {}) do
			local parts = {}
			for i = 1, #slot do parts[#parts + 1] = Enc(slot[i]) end
			slots[#slots + 1] = table.concat(parts, ".")
		end
		rc[#rc + 1] = table.concat({ Enc(rid), Enc(c.o or 0), Enc(c.qmin or 1), Enc(c.qmax or c.qmin or 1), table.concat(slots, "|") }, ":")
	end
	out.recipeCache = Chunks(rc)
	for key, realm in pairs(db.realms or {}) do
		local p, h, l, pu, mv, dl = {}, {}, {}, {}, {}, {}
		for id, rec in pairs(realm.prices or {}) do
			if keep[id] then
				p[#p + 1] = table.concat({ Enc(id), Enc(rec[1]), Enc(rec[2] or 0), Enc(math.max(0, now - (rec[3] or now)) / 60) }, ".")
			end
		end
		for id, samples in pairs(realm.history or {}) do
			if keep[id] and #samples > 0 then
				local s = {}
				for i = math.max(1, #samples - PACK_HISTORY + 1), #samples do
					local x = samples[i]
					s[#s + 1] = Enc(math.max(0, now - (x[1] or now)) / 60) .. "." .. Enc(x[2] or 0) .. "." .. Enc(x[3] or 0)
				end
				h[#h + 1] = Enc(id) .. ":" .. table.concat(s, "|")
			end
		end
		for id, ladder in pairs(realm.ladders or {}) do
			if keep[id] and (now - (ladder.t or 0)) < PACK_LADDER_AGE and ladder.tiers then
				local tiers = {}
				for i = 1, math.min(#ladder.tiers, PACK_TIERS) do
					tiers[#tiers + 1] = Enc(ladder.tiers[i][1]) .. "." .. Enc(ladder.tiers[i][2])
				end
				l[#l + 1] = table.concat({ Enc(id), Enc(math.max(0, now - (ladder.t or now)) / 60), ladder.full and "1" or "0", table.concat(tiers, "|") }, ":")
			end
		end
		for id, d in pairs(realm.mv or {}) do
			local age = now - (d[3] or now)
			if keep[id] and age < PACK_MV_AGE then
				mv[#mv + 1] = table.concat({ Enc(id), Enc(d[1]), Enc(d[2] or 0), Enc(math.max(0, age) / 60) }, ".")
			end
		end
		local firstDay = math.floor(now / 86400) - PACK_DAILY_DAYS
		for id, list in pairs(realm.daily or {}) do
			if keep[id] then
				local s = {}
				for _, e in ipairs(list) do
					if e[1] > firstDay then s[#s + 1] = Enc(e[1]) .. "." .. Enc(e[2]) .. "." .. Enc(e[3] or 1) end
				end
				if #s > 0 then dl[#dl + 1] = Enc(id) .. ":" .. table.concat(s, "|") end
			end
		end
		for id, list in pairs(realm.purchases or {}) do
			local s = {}
			for i = math.max(1, #list - PACK_PURCHASES + 1), #list do
				local x = list[i]
				s[#s + 1] = Enc(math.max(0, now - (x[1] or now)) / 60) .. "." .. Enc(x[2] or 0) .. "." .. Enc(x[3] or 0)
			end
			if #s > 0 then pu[#pu + 1] = Enc(id) .. ":" .. table.concat(s, "|") end
		end
		out.realms[key] = { lastScan = realm.lastScan or 0, prices = Chunks(p), history = Chunks(h), ladders = Chunks(l), purchases = Chunks(pu), mv = Chunks(mv), daily = Chunks(dl) }
	end
	return out
end

function CP:IsPacked(tbl)
	return type(tbl) == "table" and tbl.packed == PACK_VERSION
end

function CP:UnpackDB(p)
	if not self:IsPacked(p) then return p end
	local base = p.packedAt or time()
	local db = { version = p.version, settings = p.settings or {}, vendor = {}, learned = {}, recipeCache = {}, realms = {},
		shareImported = p.shareImported, shopping = p.shopping, shoppingMail = p.shoppingMail }
	Each(p.vendor, function(e)
		local id, price = e:match("^(%w+)%.(%w+)$")
		if id then db.vendor[Dec(id)] = Dec(price) end
	end)
	for char, s in pairs(p.learned or {}) do
		db.learned[char] = {}
		for id in string.gmatch(s, "[^,]+") do db.learned[char][Dec(id)] = true end
	end
	Each(p.recipeCache, function(e)
		local rid, o, qmin, qmax, slots = e:match("^(%w+):(%w+):(%w+):(%w+):(.*)$")
		if rid then
			local c = { o = Dec(o) > 0 and Dec(o) or nil, qmin = Dec(qmin), qmax = Dec(qmax), r = {} }
			for slot in string.gmatch(slots, "[^|]+") do
				local entry = {}
				for f in string.gmatch(slot, "[^.]+") do entry[#entry + 1] = Dec(f) end
				if #entry >= 1 then c.r[#c.r + 1] = entry end
			end
			db.recipeCache[Dec(rid)] = c
		end
	end)
	for key, r in pairs(p.realms or {}) do
		local realm = { lastScan = r.lastScan or 0, prices = {}, history = {}, ladders = {}, purchases = {}, mv = {}, daily = {} }
		Each(r.prices, function(e)
			local id, price, qty, dt = e:match("^(%w+)%.(%w+)%.(%w+)%.(%w+)$")
			if id then
				realm.prices[Dec(id)] = { Dec(price), Dec(qty), base - Dec(dt) * 60 }
				self.touchedItems[Dec(id)] = true
			end
		end)
		Each(r.history, function(e)
			local id, rest = e:match("^(%w+):(.*)$")
			if id then
				local list = {}
				for s in string.gmatch(rest, "[^|]+") do
					local dt, price, qty = s:match("^(%w+)%.(%w+)%.(%w+)$")
					if dt then list[#list + 1] = { base - Dec(dt) * 60, Dec(price), Dec(qty) } end
				end
				realm.history[Dec(id)] = list
			end
		end)
		Each(r.ladders, function(e)
			local id, dt, full, tiers = e:match("^(%w+):(%w+):(%w+):(.*)$")
			if id then
				local ladder = { t = base - Dec(dt) * 60, full = (full == "1"), tiers = {}, total = 0 }
				for s in string.gmatch(tiers, "[^|]+") do
					local price, qty = s:match("^(%w+)%.(%w+)$")
					if price then
						ladder.tiers[#ladder.tiers + 1] = { Dec(price), Dec(qty) }
						ladder.total = ladder.total + Dec(qty)
					end
				end
				realm.ladders[Dec(id)] = ladder
			end
		end)
		Each(r.mv, function(e)
			local id, mv, units, dt = e:match("^(%w+)%.(%w+)%.(%w+)%.(%w+)$")
			if id then realm.mv[Dec(id)] = { Dec(mv), Dec(units), base - Dec(dt) * 60 } end
		end)
		Each(r.daily, function(e)
			local id, rest = e:match("^(%w+):(.*)$")
			if id then
				local list = {}
				for s in string.gmatch(rest, "[^|]+") do
					local day, mv, n = s:match("^(%w+)%.(%w+)%.(%w+)$")
					if day then list[#list + 1] = { Dec(day), Dec(mv), Dec(n) } end
				end
				realm.daily[Dec(id)] = list
			end
		end)
		Each(r.purchases, function(e)
			local id, rest = e:match("^(%w+):(.*)$")
			if id then
				local list = {}
				for s in string.gmatch(rest, "[^|]+") do
					local dt, qty, unit = s:match("^(%w+)%.(%w+)%.(%w+)$")
					if dt then list[#list + 1] = { base - Dec(dt) * 60, Dec(qty), Dec(unit) } end
				end
				realm.purchases[Dec(id)] = list
			end
		end)
		db.realms[key] = realm
	end
	return db
end

-- Merge helpers (also usable by companion addons).
CP.Merge = {}
-- union: keys missing in `into` are copied from `from`; when preferFrom, `from` wins on conflicts
function CP.Merge.Union(into, from, preferFrom)
	for k, v in pairs(from or {}) do
		if into[k] == nil or preferFrom then into[k] = v end
	end
	return into
end
-- settings: loaded values win except for keys the user changed this session
function CP.Merge.Settings(into, from, touched)
	for k, v in pairs(from or {}) do
		if into[k] == nil or (touched and touched[k]) then into[k] = v end
	end
	return into
end
-- day lists { {day, value, reads}, ... }: one entry per day, the one with more reads wins (idempotent),
-- sorted, at most `days` days up to the newest
function CP.Merge.Days(into, from, days)
	local byDay = {}
	for _, list in ipairs({ into or {}, from or {} }) do
		for _, e in ipairs(list) do
			local old = byDay[e[1]]
			if not old or (e[3] or 1) > (old[3] or 1) then byDay[e[1]] = e end
		end
	end
	local out = {}
	for _, e in pairs(byDay) do out[#out + 1] = e end
	table.sort(out, function(a, b) return a[1] < b[1] end)
	local newest = out[#out] and out[#out][1]
	while out[1] and days and out[1][1] <= newest - days do table.remove(out, 1) end
	return out
end
-- list append with a cap (oldest first)
function CP.Merge.Append(into, from, max)
	for _, v in ipairs(from or {}) do table.insert(into, v) end
	while max and #into > max do table.remove(into, 1) end
	return into
end

-- CraftProfit's own merge: prices/ladders/depth values newest wins, daily price history by day, histories and
-- purchases append, the rest unions.
local function AdoptCraftProfitDB(loaded, provisional, reason)
	local M = CP.Merge
	if CP:IsPacked(loaded) then
		loaded = CP:UnpackDB(loaded)
		if not tostring(reason):find("backup", 1, true) and reason ~= "console vault" then
			-- put the unpacked table into whichever global the copy came from
			if reason:find("CraftProfitCharDB") then _G.CraftProfitCharDB = loaded else _G.CraftProfitDB = loaded end
		end
	end
	loaded.settings = M.Settings(loaded.settings or {}, provisional.settings, CP.touched)
	loaded.vendor = M.Union(loaded.vendor or {}, provisional.vendor, true)
	loaded.recipeCache = M.Union(loaded.recipeCache or {}, provisional.recipeCache, true)
	loaded.learned = loaded.learned or {}
	for char, set in pairs(provisional.learned or {}) do
		loaded.learned[char] = M.Union(loaded.learned[char] or {}, set)
	end
	loaded.realms = loaded.realms or {}
	for key, realm in pairs(provisional.realms or {}) do
		local into = loaded.realms[key]
		if not into then
			loaded.realms[key] = realm
		else
			into.prices = into.prices or {}
			for itemID, rec in pairs(realm.prices or {}) do
				local old = into.prices[itemID]
				if not old or (rec[3] or 0) >= (old[3] or 0) then into.prices[itemID] = rec end
			end
			into.history = into.history or {}
			for itemID, samples in pairs(realm.history or {}) do
				into.history[itemID] = M.Append(into.history[itemID] or {}, samples, 30)
			end
			into.ladders = into.ladders or {}
			for itemID, ladder in pairs(realm.ladders or {}) do
				local old = into.ladders[itemID]
				if not old or (ladder.t or 0) >= (old.t or 0) then into.ladders[itemID] = ladder end
			end
			into.mv = into.mv or {}
			for itemID, d in pairs(realm.mv or {}) do
				local old = into.mv[itemID]
				if not old or (d[3] or 0) >= (old[3] or 0) then into.mv[itemID] = d end
			end
			into.daily = into.daily or {}
			for itemID, list in pairs(realm.daily or {}) do
				into.daily[itemID] = M.Days(into.daily[itemID], list, PACK_DAILY_DAYS)
			end
			into.purchases = into.purchases or {}
			for itemID, list in pairs(realm.purchases or {}) do
				into.purchases[itemID] = M.Append(into.purchases[itemID] or {}, list, 20)
			end
			into.lastScan = math.max(into.lastScan or 0, realm.lastScan or 0)
		end
	end
	loaded.version = loaded.version or provisional.version
	loaded.shareImported = loaded.shareImported or provisional.shareImported -- old CVar cache already merged (Share.lua)
	-- shopping list (Shopping.lua): recipes added this session before the saved copy arrived are kept
	loaded.shopping = loaded.shopping or {}
	for recipeID, e in pairs(provisional.shopping or {}) do
		if not loaded.shopping[recipeID] then loaded.shopping[recipeID] = e end
	end
	loaded.shoppingMail = loaded.shoppingMail or {}
	for char, items in pairs(provisional.shoppingMail or {}) do
		loaded.shoppingMail[char] = loaded.shoppingMail[char] or {}
		for itemID, n in pairs(items) do
			loaded.shoppingMail[char][itemID] = math.max(n, loaded.shoppingMail[char][itemID] or 0)
		end
	end
	CP.db = loaded
	CP.settings = loaded.settings
	ApplyDefaults(CP.settings, CP.defaults)
	if CP.Calc then
		CP.Calc:Invalidate()
		if CP.Calc.RestoreCrafts then CP.Calc:RestoreCrafts() end
	end
	local n = 0
	for _ in pairs((loaded.realms[CP:GetRealmKey()] or {}).prices or {}) do n = n + 1 end
	if tostring(reason):find("backup", 1, true) then
		CP:Print("the client did not hand back CraftProfit's saved data; restored it from a backup copy: %d prices on %s.", n, CP:GetRealmKey())
	elseif reason == "console vault" then
		CP:Print("saved data loaded from the console vault: %d prices on %s.", n, CP:GetRealmKey())
	else
		CP:Print("saved data arrived after login (%s) and was merged with this session: %d prices on %s.", tostring(reason), n, CP:GetRealmKey())
	end
	CP:Fire("PRICES_UPDATED", "adopt")
	CP:Fire("VENDOR_UPDATED")
	CP:Fire("SETTINGS_CHANGED")
	CP:Fire("DB_ADOPTED")
	return loaded
end
CP.AdoptDB = AdoptCraftProfitDB

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

local COIN = {
	g = "|TInterface\\MoneyFrame\\UI-GoldIcon:%d:%d:2:0|t",
	s = "|TInterface\\MoneyFrame\\UI-SilverIcon:%d:%d:2:0|t",
	c = "|TInterface\\MoneyFrame\\UI-CopperIcon:%d:%d:2:0|t",
}

-- opts.compact: drop copper when >= 1g, drop silver when >= 100g
-- opts.sign: prefix "+" for positive values ("-" is always shown for negatives)
-- opts.size: icon size in px (0 = font height)
function CP:FormatMoney(copper, opts)
	opts = opts or {}
	copper = tonumber(copper) or 0
	local size = opts.size or 0
	local negative = copper < 0
	local value = math.floor(math.abs(copper) + 0.5)
	local g = math.floor(value / 10000)
	local s = math.floor((value % 10000) / 100)
	local c = value % 100

	local parts = {}
	if g > 0 then
		table.insert(parts, g .. string.format(COIN.g, size, size))
		if s > 0 and not (opts.compact and g >= 100) then
			table.insert(parts, s .. string.format(COIN.s, size, size))
		end
		if c > 0 and not opts.compact then
			table.insert(parts, c .. string.format(COIN.c, size, size))
		end
	else
		if s > 0 then table.insert(parts, s .. string.format(COIN.s, size, size)) end
		if c > 0 or #parts == 0 then table.insert(parts, c .. string.format(COIN.c, size, size)) end
	end

	local text = table.concat(parts, " ")
	if negative then
		text = "-" .. text
	elseif opts.sign and value > 0 then
		text = "+" .. text
	end
	return text
end

-- One denomination only, for tight spaces: +128g, +12.4g, +79s, -35s, +95c.
function CP:FormatMoneyShort(copper, opts)
	opts = opts or {}
	copper = tonumber(copper) or 0
	local size = opts.size or 0
	local negative = copper < 0
	local value = math.abs(copper)
	local text
	if value >= 1000000 then
		text = string.format("%d", math.floor(value / 10000 + 0.5)) .. string.format(COIN.g, size, size)
	elseif value >= 10000 then
		local g = string.format("%.1f", value / 10000):gsub("%.0$", "")
		text = g .. string.format(COIN.g, size, size)
	elseif value >= 100 then
		text = string.format("%d", math.floor(value / 100 + 0.5)) .. string.format(COIN.s, size, size)
	else
		text = string.format("%d", math.floor(value + 0.5)) .. string.format(COIN.c, size, size)
	end
	if negative then
		text = "-" .. text
	elseif opts.sign and value > 0 then
		text = "+" .. text
	end
	return text
end

-- Margin as a percentage string, capped so absurd ratios cannot blow up a layout.
function CP:FormatMargin(margin, sign)
	if not margin then return nil end
	local pct = math.floor(margin * 100 + 0.5)
	if pct > 999 then return "999%+" end
	if pct < -999 then return "-999%" end
	if sign and pct > 0 then return "+" .. pct .. "%" end
	return pct .. "%"
end

function CP:FormatAge(seconds)
	if not seconds then return "never" end
	seconds = math.max(0, math.floor(seconds))
	if seconds < 60 then return "just now" end
	if seconds < 3600 then return string.format("%d min ago", math.floor(seconds / 60)) end
	if seconds < 86400 then return string.format("%d h ago", math.floor(seconds / 3600)) end
	return string.format("%d d ago", math.floor(seconds / 86400))
end

-- Price verdict (Scanner:GetVerdict) as short colored text: "cheap -12%", "normal +3%", "high +18%".
function CP:FormatVerdict(v)
	if not v then return "" end
	local pct = math.floor(math.abs(v.pct) * 100 + 0.5) * (v.pct < 0 and -1 or 1)
	local text = string.format("%s %s%d%%", v.verdict, pct >= 0 and "+" or "", pct)
	if v.verdict == "cheap" then return self:Color(self.COLORS.profit, text) end
	if v.verdict == "high" then return self:Color(self.COLORS.high, text) end
	return self:Color(self.COLORS.body, text)
end

-- Color for a price judged by a verdict (nil verdict or "normal": the given default).
function CP:VerdictColor(v, default)
	if v and v.verdict == "cheap" then return self.COLORS.profit end
	if v and v.verdict == "high" then return self.COLORS.high end
	return default
end

function CP:ItemIDFromLink(link)
	if type(link) ~= "string" then return nil end
	local id = link:match("item:(%d+)")
	return id and tonumber(id) or nil
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function PrintStatus()
	CP:Print("v%s on %s (interface %s)", CP.version, CP:GetRealmKey(),
		tostring(select(4, GetBuildInfo())))
	local li = CP.loadInfo
	if li then
		local parts = {}
		for key, n in pairs(li.realms) do table.insert(parts, key .. "=" .. n) end
		table.sort(parts)
		CP:Print("Loaded from disk at login: %s (%d prices, %d ladders; realms: %s). Current realm key: %s. Since: %s.",
			li.hadDB and ("saved data found in the " .. tostring(li.from)) or "NO SAVED DATA (fresh database)", li.prices, li.ladders,
			#parts > 0 and table.concat(parts, ", ") or "none", CP:GetRealmKey(), CP:SavedVariableStatus("CraftProfitDB"))
	end
	local active, reason = CP.Sources:Resolve()
	CP:Print("Setting: %s | active source: %s", CP.settings.source,
		active and active.name or ("none (" .. tostring(reason) .. ")"))
	for _, def in ipairs(CP.Sources.list) do
		local avail = def:IsAvailable()
		CP:Print("  %s [%s] %s", def.key, def.name,
			avail and (def:HasData() and "available, has data" or "available, no data yet") or "not installed")
	end
	local realm = CP:GetRealmDB()
	local n = 0
	for _ in pairs(realm.prices) do n = n + 1 end
	local v = 0
	for _ in pairs(CP.db.vendor) do v = v + 1 end
	local ladders, purchases = 0, 0
	for _ in pairs(realm.ladders or {}) do ladders = ladders + 1 end
	for _, list in pairs(realm.purchases or {}) do purchases = purchases + #list end
	CP:Print("Own scan: %d items, last scan %s. Price ladders: %d items. Purchases recorded: %d. Vendor prices learned: %d.", n,
		realm.lastScan > 0 and CP:FormatAge(time() - realm.lastScan) or "never", ladders, purchases, v)
	local depth, histItems, histDays = 0, 0, 0
	for _ in pairs(realm.mv or {}) do depth = depth + 1 end
	for _, list in pairs(realm.daily or {}) do
		histItems = histItems + 1
		histDays = math.max(histDays, #list)
	end
	local ld = CP.Scanner and CP.Scanner.lastDepth
	CP:Print("Depth values: %d items; price history: %d items, up to %d days (a verdict needs %d). Depth scan after a full scan: %s.%s",
		depth, histItems, histDays, CP.Scanner and CP.Scanner.NORMAL_MIN_DAYS or 3, CP.settings.depthScan and "on" or "off",
		ld and string.format(" Last depth scan %s: %d of %d items in %.0fs%s.", CP:FormatAge(time() - ld.at), ld.done, ld.total,
			ld.elapsed, ld.reason and (" (" .. ld.reason .. ")") or "") or "")
	if CP.Share then CP:Print(CP.Share:Status()) end
	local crafts = 0
	for _ in pairs(CP.crafts or {}) do crafts = crafts + 1 end
	CP:Print("AH cut %d%%, sale basis %s, net shown %s, sort by profit %s, craft intermediates %s (%d craftable items known), trainer tags %s.",
		math.floor(CP.settings.ahCut * 100 + 0.5), CP.settings.saleBasis, CP.settings.netBasis or "ah",
		CP.settings.sortByProfit and "on" or "off", CP.settings.craftIntermediates and "on" or "off", crafts,
		CP.settings.trainerTags and "on" or "off")
end

local function PrintHelp()
	CP:Print("commands:")
	CP:Print("  /cf status - sources, scan data, settings")
	CP:Print("  /cf scan - scan the Auction House (AH must be open)")
	CP:Print("  /cf depth [on|off] - read your reagents' and outputs' listings now (on/off: after every full scan)")
	CP:Print("  /cf source auto|craftprofit|auctionator|tsm")
	CP:Print("  /cf sort - toggle sort recipes by profit")
	CP:Print("  /cf tag profit|margin|both - what the recipe rows show")
	CP:Print("  /cf net ah|vendor - show profit for selling on the AH or to a vendor")
	CP:Print("  /cf trainer - toggle profit tags in the profession trainer window (/cf trainer check lists what each service matched)")
	CP:Print("  /cf craft - toggle pricing craftable reagents at their own craft cost")
	CP:Print("  /cf cut <percent> - auction house cut used for net profit")
	CP:Print("  /cf basis min|market - sale price basis for own scans (market = depth value)")
	CP:Print("  /cf options - open the settings panel")
	CP:Print("  /cf tooltip - toggle the CraftProfit block in item tooltips")
	CP:Print("  /cf shop [clear] - show (or empty) the AH shopping list; add recipes with Shop in the profit panel")
	CP:Print("  /cf share [import] - state of the old cross-character cache (import: merge what it still holds again)")
	CP:Print("  /cf debug - toggle debug output")
	CP:Print("  /cf reset confirm - wipe scan data and settings")
end

local function HandleSlash(input)
	input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local cmd, rest = input:match("^(%S+)%s*(.*)$")
	cmd = cmd and cmd:lower() or ""

	if cmd == "" or cmd == "help" then
		PrintHelp()
	elseif cmd == "status" then
		PrintStatus()
	elseif cmd == "scan" then
		CP.Scanner:Start()
	elseif cmd == "depth" then
		local arg = rest:lower()
		if arg == "on" or arg == "off" then
			CP:SetSetting("depthScan", arg == "on")
			CP:Print("depth scan after a full scan %s", arg)
		elseif CP.Scanner.depthJob then
			CP.Scanner:StopDepth()
		else
			CP.Scanner:StartDepth()
		end
	elseif cmd == "source" then
		local key = rest:lower()
		if key == "auto" or CP.Sources:Get(key) then
			CP:SetSetting("source", key)
			local active = CP.Sources:Resolve()
			CP:Print("price source set to %s (active: %s)", key, active and active.name or "none")
		else
			CP:Print("unknown source '%s'. Use auto, craftprofit, auctionator or tsm.", rest)
		end
	elseif cmd == "sort" then
		CP.UI:SetSortByProfit(not CP.settings.sortByProfit)
		CP:Print("sort by profit %s", CP.settings.sortByProfit and "on" or "off")
	elseif cmd == "tag" then
		local mode = rest:lower()
		if mode == "profit" or mode == "margin" or mode == "both" then
			CP:SetSetting("rowTag", mode)
			CP:Print("recipe rows now show %s", mode)
		else
			CP:Print("usage: /cf tag profit|margin|both")
		end
	elseif cmd == "net" then
		local basis = rest:lower()
		if basis == "ah" or basis == "vendor" then
			CP:SetSetting("netBasis", basis)
			CP:Print("profit now shown %s", basis == "ah" and "for selling on the Auction House" or "for selling to a vendor")
		else
			CP:Print("usage: /cf net ah|vendor (now %s)", tostring(CP.settings.netBasis))
		end
	elseif cmd == "trainer" then
		if rest:lower() == "check" then
			if CP.Trainer then CP.Trainer:Report() end
		else
			CP:SetSetting("trainerTags", not CP.settings.trainerTags)
			CP:Print("trainer profit tags %s", CP.settings.trainerTags and "on" or "off")
		end
	elseif cmd == "craft" then
		CP:SetSetting("craftIntermediates", not CP.settings.craftIntermediates)
		local n = 0
		for _ in pairs(CP.crafts or {}) do n = n + 1 end
		CP:Print("craft intermediates %s (%d craftable items known this session)",
			CP.settings.craftIntermediates and "on" or "off", n)
	elseif cmd == "cut" then
		local pct = tonumber(rest)
		if pct and pct >= 0 and pct <= 50 then
			CP:SetSetting("ahCut", pct / 100)
			CP:Print("auction house cut set to %d%%", pct)
		else
			CP:Print("usage: /cf cut <0-50>")
		end
	elseif cmd == "basis" then
		local basis = rest:lower()
		if basis == "min" or basis == "market" then
			CP:SetSetting("saleBasis", basis)
			CP:Print("sale price basis set to %s", basis)
		else
			CP:Print("usage: /cf basis min|market")
		end
	elseif cmd == "demo" then
		CP.Demo:Command(rest)
	elseif cmd == "options" or cmd == "config" then
		CP.Options:Open()
	elseif cmd == "share" then
		if CP.Share then
			local sub = rest:lower()
			if sub == "import" or sub == "pull" then CP.Share:Import("manual", true) end
			CP:Print(CP.Share:Status())
		end
	elseif cmd == "shop" and CP.Shopping then
		local shop = CP.Shopping
		if rest:lower() == "clear" then
			shop:Clear()
			CP:Print("Shopping list cleared.")
		elseif shop:IsEmpty() then
			CP:Print("The shopping list is empty. Select a recipe and click Shop in the profit panel.")
		else
			for _, r in ipairs(shop:Recipes()) do CP:Print("  %dx %s", r.n, r.name) end
			for _, it in ipairs(shop:Items()) do
				CP:Print("    %s  %d / %d%s", it.name, it.have + it.mail, it.need, it.missing == 0 and "  done" or (it.vendor and "  (vendor)" or ""))
			end
		end
	elseif cmd == "tooltip" then
		CP:SetSetting("tooltip", not CP.settings.tooltip)
		CP:Print("item tooltip block %s", CP.settings.tooltip and "on" or "off")
	elseif cmd == "debug" then
		CP:SetSetting("debug", not CP.settings.debug)
		CP:Print("debug %s", CP.settings.debug and "on" or "off")
	elseif cmd == "reset" then
		if rest:lower() == "confirm" then
			wipe(CP.db.realms)
			wipe(CP.db.vendor)
			wipe(CP.db.settings)
			ApplyDefaults(CP.db.settings, CP.defaults)
			wipe(CP.touched)
			wipe(CP.touchedItems)
			-- empty the old CVar cache too, so nothing of the wiped data is left behind
			if CP.Share and CP.Share.Clear then CP.Share:Clear() end
			if CP.Calc then CP.Calc:Invalidate() end
			CP:Fire("PRICES_UPDATED", "reset")
			CP:Fire("SETTINGS_CHANGED")
			CP:Print("database and settings reset.")
		else
			CP:Print("this wipes all scan data and settings. Type /cf reset confirm to proceed.")
		end
	else
		CP:Print("unknown command '%s'", cmd)
		PrintHelp()
	end
end

SLASH_CRAFTPROFIT1 = "/craftprofit"
SLASH_CRAFTPROFIT2 = "/cf"
SLASH_CRAFTPROFIT3 = "/cp" -- the old name, kept so existing macros keep working
SlashCmdList["CRAFTPROFIT"] = HandleSlash

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

CP:RegisterEvent("ADDON_LOADED", function(_, name)
	if name ~= ADDON_NAME then return end
	InitDB()
	CP:Debug("loaded v%s", CP.version)
end)

CP:RegisterEvent("PLAYER_LOGIN", function()
	if not CP.db then InitDB() end
	-- the console vault can show up a little after login: only complain if nothing arrived by then
	local function ReportLoad()
		local li = CP.loadInfo
		if li and not li.hadDB and not CP:GroupAdopted("CraftProfit") then
			CP:Print("no saved data yet. Open the Auction House and click CraftProfit Scan to get prices (/cf for commands).")
		elseif li and li.hadDB and li.prices == 0 then
			CP:Print("saved data loaded but it holds no prices yet (run a scan in the Auction House).")
		end
	end
	if C_Timer and C_Timer.After then C_Timer.After(10, ReportLoad) else ReportLoad() end
	CP.Sources:Init()
	if CP.Calc and CP.Calc.RestoreCrafts then CP.Calc:RestoreCrafts() end
	StartSavedVariableWatch()
	CP:Fire("READY")
end)

CP:RegisterEvent("PLAYER_LOGIN", function()
	if C_AddOns and C_AddOns.GetAddOnMetadata then CP.version = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or CP.version end
end)
