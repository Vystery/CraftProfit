-- CraftProfit :: Share
-- Account-wide price cache carried in registered CVars, so a scan on one character is visible on every
-- other character of the account. Why: on the WoW Forever beta the account-wide SavedVariables file is not
-- reliably handed back to addons, and a character that starts empty then overwrites the account file with an
-- empty database at logout.
-- CVars registered with C_CVar.RegisterCVar live for the whole client process (character switches
-- included) and are written to WTF/Config.wtf at exit, which gives us an account-wide channel that does
-- not go through the SavedVariables loader.
--
-- Payload: one string, base-36 numbers, split over CraftProfitShare1..N (chunk size adapts if the client
-- truncates CVar values), plus CraftProfitShareMeta = "version|chunks|length|writtenAt|by".
--   V:<id.price;...>                              learned vendor prices
--   R:<realmKey>:<lastScan>:<id.price.qty[.age];...>  one section per realm, current realm first; age =
--                                                 minutes the price is older than lastScan (omitted when 0)
-- Pull merges shared prices whose scan is newer than the local record; Push writes the whole realm price
-- table (not only the "touched" items the SavedVariables pack keeps) within the size budget.

local _, CP = ...
local Share = { chunkSize = 1000, maxChunks = 24, minChunk = 200, status = "not initialised" }
CP.Share = Share

local PREFIX = "CraftProfitShare"
local META = PREFIX .. "Meta"
local VERSION = 1

local function Available()
	return C_CVar ~= nil and type(C_CVar.RegisterCVar) == "function"
		and type(C_CVar.SetCVar) == "function" and type(C_CVar.GetCVar) == "function"
end
Share.Available = Available

local registered = false
function Share:Register()
	if registered or not Available() then return registered end
	pcall(C_CVar.RegisterCVar, META, "")
	for i = 1, self.maxChunks do pcall(C_CVar.RegisterCVar, PREFIX .. i, "") end
	registered = true
	return true
end

local function Get(name)
	local ok, v = pcall(C_CVar.GetCVar, name)
	if ok and type(v) == "string" then return v end
	return nil
end

local function Set(name, value)
	local ok = pcall(C_CVar.SetCVar, name, value)
	return ok
end

local function Clean(name)
	return (tostring(name or ""):gsub("[^%w]", ""))
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

-- Returns the payload string and { prices, realms, dropped }.
function Share:Encode(db, budget)
	db = db or CP.db
	local Enc = CP.Enc
	budget = budget or (self.chunkSize * self.maxChunks)
	local now = time()
	local parts = { tostring(VERSION), Enc(now), Clean(UnitName and UnitName("player") or "") }
	local total = #table.concat(parts, "|")
	local stats = { prices = 0, realms = 0, dropped = 0 }

	local v = {}
	for id, price in pairs(db.vendor or {}) do v[#v + 1] = Enc(id) .. "." .. Enc(price) end
	if #v > 0 then
		local section = "V:" .. table.concat(v, ";")
		if total + #section + 1 <= budget then
			parts[#parts + 1] = section
			total = total + #section + 1
		end
	end

	-- current realm first, then the others
	local keys = {}
	local current = CP:GetRealmKey()
	if db.realms and db.realms[current] then keys[1] = current end
	for key in pairs(db.realms or {}) do
		if key ~= current then keys[#keys + 1] = key end
	end
	local keep = CP.touchedItems or {}
	for _, key in ipairs(keys) do
		local realm = db.realms[key]
		local ids = {}
		for id in pairs(realm.prices or {}) do ids[#ids + 1] = id end
		-- touched items first (the ones recipes and companions asked for), then the rest, stable order
		table.sort(ids, function(a, b)
			local ta, tb = keep[a] and 1 or 0, keep[b] and 1 or 0
			if ta ~= tb then return ta > tb end
			return a < b
		end)
		local head = "R:" .. key .. ":" .. Enc(realm.lastScan or 0) .. ":"
		local entries = {}
		local used = total + #head + 1
		for _, id in ipairs(ids) do
			local rec = realm.prices[id]
			local e = Enc(id) .. "." .. Enc(rec[1] or 0) .. "." .. Enc(rec[2] or 0)
			local age = math.floor(((realm.lastScan or 0) - (rec[3] or realm.lastScan or 0)) / 60)
			if age > 0 then e = e .. "." .. Enc(age) end
			if used + #e + 1 > budget then
				stats.dropped = stats.dropped + 1
			else
				entries[#entries + 1] = e
				used = used + #e + 1
			end
		end
		if #entries > 0 or (realm.lastScan or 0) > 0 then
			parts[#parts + 1] = head .. table.concat(entries, ";")
			total = used
			stats.prices = stats.prices + #entries
			stats.realms = stats.realms + 1
		end
	end
	return table.concat(parts, "|"), stats
end

-- Returns { writtenAt, by, vendor = { id = price }, realms = { key = { lastScan, prices = { id = { price, qty, t } } } } }
function Share:Decode(s)
	if type(s) ~= "string" or s == "" then return nil, "empty" end
	local Dec = CP.Dec
	local out = { vendor = {}, realms = {} }
	local i = 0
	for section in string.gmatch(s, "[^|]+") do
		i = i + 1
		if i == 1 then
			if tonumber(section) ~= VERSION then return nil, "version " .. tostring(section) end
		elseif i == 2 then
			out.writtenAt = Dec(section)
		elseif i == 3 then
			out.by = section
		elseif section:sub(1, 2) == "V:" then
			for e in string.gmatch(section:sub(3), "[^;]+") do
				local id, price = e:match("^(%w+)%.(%w+)$")
				if id then out.vendor[Dec(id)] = Dec(price) end
			end
		elseif section:sub(1, 2) == "R:" then
			local key, lastScan, rest = section:match("^R:([^:]+):(%w*):(.*)$")
			if key then
				local realm = { lastScan = Dec(lastScan), prices = {} }
				for e in string.gmatch(rest, "[^;]+") do
					local id, price, qty, age = e:match("^(%w+)%.(%w+)%.(%w+)%.?(%w*)$")
					if id then realm.prices[Dec(id)] = { Dec(price), Dec(qty), realm.lastScan - Dec(age) * 60 } end
				end
				out.realms[key] = realm
			end
		end
	end
	if i < 3 then return nil, "malformed" end
	return out
end

---------------------------------------------------------------------------
-- Push / pull
---------------------------------------------------------------------------

-- Writes the shared cache. Returns prices written (or nil) and an info table.
function Share:Push(reason)
	if not Available() then
		self.status = "unavailable (C_CVar.RegisterCVar / SetCVar / GetCVar missing)"
		return nil, { ok = false, reason = self.status }
	end
	self:Register()
	local attempts = 0
	while true do
		attempts = attempts + 1
		local payload, stats = self:Encode(CP.db, self.chunkSize * self.maxChunks)
		local chunks = {}
		for pos = 1, #payload, self.chunkSize do
			chunks[#chunks + 1] = payload:sub(pos, pos + self.chunkSize - 1)
		end
		local ok = true
		for i, chunk in ipairs(chunks) do
			if not Set(PREFIX .. i, chunk) or Get(PREFIX .. i) ~= chunk then
				ok = false
				break
			end
		end
		if ok then
			for i = #chunks + 1, self.maxChunks do
				if (Get(PREFIX .. i) or "") ~= "" then Set(PREFIX .. i, "") end
			end
			local meta = table.concat({ VERSION, #chunks, #payload, CP.Enc(time()), Clean(UnitName and UnitName("player") or "") }, "|")
			Set(META, meta)
			self.lastPush = { at = time(), reason = reason, chunks = #chunks, length = #payload, prices = stats.prices,
				realms = stats.realms, dropped = stats.dropped, chunkSize = self.chunkSize, ok = true }
			self.status = string.format("pushed %d prices (%d realm%s) in %d chunk%s, %.1f KB%s", stats.prices, stats.realms,
				stats.realms == 1 and "" or "s", #chunks, #chunks == 1 and "" or "s", #payload / 1024,
				stats.dropped > 0 and string.format(", %d dropped for size", stats.dropped) or "")
			CP:Debug("share push (%s): %s", tostring(reason), self.status)
			return stats.prices, self.lastPush
		end
		-- the client truncated or refused the value: try smaller chunks
		if self.chunkSize <= self.minChunk or attempts >= 8 then
			self.lastPush = { at = time(), reason = reason, ok = false, chunkSize = self.chunkSize }
			self.status = string.format("push FAILED: CVar values do not round-trip even at %d characters", self.chunkSize)
			CP:Print("shared price cache could not be written (%s).", self.status)
			return nil, self.lastPush
		end
		self.chunkSize = math.max(self.minChunk, math.floor(self.chunkSize / 2))
	end
end

-- Reads the shared cache and merges newer prices into the database. Returns the number of prices merged.
function Share:Pull(reason)
	if not Available() then
		self.status = "unavailable (C_CVar.RegisterCVar / SetCVar / GetCVar missing)"
		return 0
	end
	self:Register()
	local meta = Get(META)
	if not meta or meta == "" then
		self.lastPull = { at = time(), reason = reason, found = false }
		if not self.lastPush then self.status = "no shared data yet (scan on any character to fill it)" end
		return 0
	end
	local version, n, len = meta:match("^(%d+)|(%d+)|(%d+)")
	if tonumber(version) ~= VERSION then
		self.status = "shared data has version " .. tostring(version) .. "; ignored"
		return 0
	end
	n, len = tonumber(n) or 0, tonumber(len) or 0
	local buf = {}
	for i = 1, n do buf[i] = Get(PREFIX .. i) or "" end
	local payload = table.concat(buf)
	if #payload ~= len then
		self.status = string.format("shared data incomplete (%d of %d characters); ignored", #payload, len)
		self.lastPull = { at = time(), reason = reason, found = true, ok = false }
		return 0
	end
	local data, err = self:Decode(payload)
	if not data then
		self.status = "shared data unreadable (" .. tostring(err) .. ")"
		self.lastPull = { at = time(), reason = reason, found = true, ok = false }
		return 0
	end

	local db = CP.db
	db.vendor = db.vendor or {}
	local merged, vendorAdded = 0, 0
	for id, price in pairs(data.vendor) do
		if db.vendor[id] == nil then
			db.vendor[id] = price
			vendorAdded = vendorAdded + 1
		end
	end
	db.realms = db.realms or {}
	for key, r in pairs(data.realms) do
		local into = db.realms[key]
		if not into then
			into = { prices = {}, history = {}, lastScan = 0 }
			db.realms[key] = into
		end
		into.prices = into.prices or {}
		for id, rec in pairs(r.prices) do
			local old = into.prices[id]
			if not old or rec[3] > (old[3] or 0) then
				into.prices[id] = { rec[1], rec[2], rec[3] }
				merged = merged + 1
			end
		end
		into.lastScan = math.max(into.lastScan or 0, r.lastScan or 0)
	end
	local realm = data.realms[CP:GetRealmKey()]
	local count = 0
	if realm then for _ in pairs(realm.prices) do count = count + 1 end end
	self.lastPull = { at = time(), reason = reason, found = true, ok = true, merged = merged, vendor = vendorAdded,
		writtenAt = data.writtenAt, by = data.by, count = count }
	self.status = string.format("shared data holds %d prices for %s, written %s%s; %d merged", count, CP:GetRealmKey(),
		CP:FormatAge(time() - (data.writtenAt or time())), data.by ~= "" and (" by " .. data.by) or "", merged)
	CP:Debug("share pull (%s): %s", tostring(reason), self.status)
	if merged > 0 then
		if CP.Calc then CP.Calc:Invalidate() end
		CP:Fire("PRICES_UPDATED", "share")
	end
	if vendorAdded > 0 then CP:Fire("VENDOR_UPDATED") end
	return merged
end

-- Empties the shared cache (used by /cf reset so the wiped prices do not come back at the next pull).
function Share:Clear()
	if not Available() then return end
	self:Register()
	Set(META, "")
	for i = 1, self.maxChunks do Set(PREFIX .. i, "") end
	self.lastPush = nil
	self.status = "cleared"
end

function Share:Status()
	if not Available() then return "Shared price cache: unavailable on this client (C_CVar.RegisterCVar missing)." end
	local s = "Shared price cache (account-wide CVars): " .. tostring(self.status) .. "."
	if self.lastPush and self.lastPush.ok then
		s = s .. string.format(" Last push %s (%s).", CP:FormatAge(time() - self.lastPush.at), tostring(self.lastPush.reason))
	end
	return s
end

function Share:OnLogout()
	if not Available() then return end
	pcall(self.Pull, self, "logout")
	pcall(self.Push, self, "logout")
end

CP:On("READY", function()
	Share:Register()
	Share:Pull("login")
end)
CP:On("DB_ADOPTED", function() Share:Pull("adopted") end)
CP:On("SCAN_FINISHED", function() Share:Push("scan") end)
