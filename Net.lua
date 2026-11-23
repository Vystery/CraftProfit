-- CraftProfit :: Net
-- Hidden addon messages between players who run CraftProfit. Two uses:
--   * Version notice: every copy tells its guild and group which version it is. Hearing a higher one prints
--     "CraftProfit X is out" once per session. Addons cannot reach the internet; this is how the news travels.
--   * Blocked-action reports: when the game blocks an action and names CraftProfit, the record (what
--     /cf blocked shows: time, function, version, what was on screen, the call stack, and which values of the
--     game's windows count as addon-written) is kept in the saved data and handed to the author's character
--     when it is online. Other players' copies carry it too: a report is passed on to guild and group members
--     who do not have it, so it can reach the author through whoever meets them first. When the author's copy
--     confirms a report, it is deleted. Nothing else is stored or sent, the player is told in chat when a
--     report is made, and /cf report (or the options) turns all of it off: sending, carrying and passing on.
--
-- Messages, all plain text under one prefix:
--   V <version>                     version, to guild / group
--   O <id> <id> ...                 offer: "I hold these reports" (whisper to the author, or guild / group)
--   W <id> <id> ...                 want: "send me these" (whisper, answers an offer)
--   B<id>:<i>/<n>:<part>            a report's text in parts (whisper, answers a want)
--   A <id> <id> ...                 received, from the author only: delete these

local ADDON_NAME, CP = ...
local Net = { PREFIX = "CraftProfit" }
CP.Net = Net

-- The author's characters: reports are handed to these. `ruleset` (CP:GetRuleset) keeps copies on other
-- rulesets, where that character does not exist, from trying. Empty list = reports go nowhere.
Net.AUTHORS = {
	{ name = "Vystery Priesty", ruleset = "PvP" },
}

local PART = 200             -- text per message (the game allows 255 bytes including the header)
local LINE_BREAK = " ## "    -- line separator inside a report (addon messages are single lines)
local MAX_TEXT = 3200        -- a report: record, stack and taint summary
local MAX_PARTS = 20
local ANNOUNCE_GAP = 300     -- seconds between two version announcements on the same channel
local OFFER_GAP = 900        -- seconds between two offers to the same place
local KEEP_SECONDS = 14 * 86400
local HELD_MAX = 20          -- reports one copy carries (its own and other players')
local MAX_HOPS = 3           -- how many players a report may pass through
local SERVE_MAX = 3          -- how many players one copy passes a given report on to per session
local REPORTS_PER_DAY = 5    -- own reports: a player with the same error all evening does not send hundreds
local DONE_MAX = 200         -- delivered ids remembered, so a delivered report is not picked up again
local INBOX_MAX = 100        -- the author's side
local SEND_STEP = 0.3        -- seconds between two messages: well under the game's limit for addon messages
local QUEUE_MAX = 150
local QUIET_SECONDS = 5      -- how long "no player named <author>" is kept out of the chat after an offer

local function Now() return time and time() or 0 end
local function Clock() return GetTime and GetTime() or 0 end

-- WoW Forever characters have a first name and a surname ("Guld Göran"): UnitName returns them as two values
-- and chat events give them joined by the client's separator. There is no realm suffix on names there.
-- Other clients: one name, and "-Realm" on names from other realms, which is cut off.
local function SurnameSeparator()
	local c = Constants and Constants.CharacterNameSeparatorConsts
	return c and c.CHARACTERNAME_SURNAME_SEPARATOR or nil
end

local function ShortName(name)
	if type(name) ~= "string" then return nil end
	if SurnameSeparator() then return name end
	return (name:match("^([^%-]+)")) or name
end

-- This character's name the way chat events give it: with the surname where the client has one.
local function Me()
	local ok, name, surname = pcall(function() return (UnitNameUnmodified or UnitName)("player") end)
	if not ok or type(name) ~= "string" then return nil end
	local sep = SurnameSeparator()
	if sep and type(surname) == "string" and surname ~= "" then return name .. sep .. surname end
	return name
end

-- Authors this copy can reach: all of them, minus those on another ruleset than this character's.
function Net:Authors()
	local ruleset = CP.GetRuleset and CP:GetRuleset() or nil
	local out = {}
	for _, a in ipairs(self.AUTHORS) do
		if not (a.ruleset and ruleset and a.ruleset ~= ruleset) then out[#out + 1] = a.name end
	end
	return out
end

function Net:IsAuthor(name)
	name = ShortName(name or Me())
	if not name then return false end
	for _, a in ipairs(self:Authors()) do
		if a == name then return true end
	end
	return false
end

function Net:Enabled()
	return CP.settings ~= nil and CP.settings.sendReports ~= false
end

---------------------------------------------------------------------------
-- Sending, one message at a time
---------------------------------------------------------------------------

local function SendNow(text, channel, target)
	if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
		CP:Debug("net: this client has no SendAddonMessage")
		return false
	end
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, Net.PREFIX, text, channel, target)
	CP:Debug("net: sent '%s' on %s%s -> %s %s", tostring(text):sub(1, 40), tostring(channel), target and (" to '" .. tostring(target) .. "'") or "",
		ok and "ok" or "error", tostring(result))
	return ok
end

-- Everything but the one-line version message goes through this queue, so a report in many parts never
-- reaches the game's limit for addon messages.
function Net:Send(text, channel, target)
	self.queue = self.queue or {}
	if #self.queue >= QUEUE_MAX then return false end
	self.queue[#self.queue + 1] = { text, channel, target }
	if not self.sender and C_Timer and C_Timer.NewTicker then
		self.sender = C_Timer.NewTicker(SEND_STEP, function() Net:Pump() end)
	elseif not (C_Timer and C_Timer.NewTicker) then
		self:Pump(true)
	end
	return true
end

function Net:Pump(all)
	local q = self.queue
	repeat
		local m = q and table.remove(q, 1)
		if m then SendNow(m[1], m[2], m[3]) end
	until not all or not q or #q == 0
	if (not q or #q == 0) and self.sender then
		self.sender:Cancel()
		self.sender = nil
	end
end

---------------------------------------------------------------------------
-- Version notice
---------------------------------------------------------------------------

-- "0.5.13" -> { 0, 5, 13 }; nil for anything that is not a plain release number (a test build tells nobody).
function Net:ParseVersion(v)
	if type(v) ~= "string" then return nil end
	local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)$")
	if not a then return nil end
	a, b, c = tonumber(a), tonumber(b), tonumber(c)
	if a > 99 or b > 999 or c > 9999 then return nil end
	return { a, b, c }
end

function Net:IsNewer(theirs, mine)
	local t, m = self:ParseVersion(theirs), self:ParseVersion(mine)
	if not t or not m then return false end
	for i = 1, 3 do
		if t[i] ~= m[i] then return t[i] > m[i] end
	end
	return false
end

local function GroupChannels()
	local out = {}
	if IsInGuild and IsInGuild() then out[#out + 1] = "GUILD" end
	if IsInRaid and IsInRaid() then
		out[#out + 1] = "RAID"
	elseif IsInGroup and IsInGroup() then
		out[#out + 1] = "PARTY"
	end
	return out
end

function Net:Announce(channel)
	if not self:ParseVersion(CP.version) then return false end
	self.announced = self.announced or {}
	local now = Clock()
	if self.announced[channel] and now - self.announced[channel] < ANNOUNCE_GAP then return false end
	self.announced[channel] = now
	return SendNow("V " .. CP.version, channel)
end

function Net:AnnounceAll()
	for _, channel in ipairs(GroupChannels()) do self:Announce(channel) end
end

function Net:OnVersion(theirs, channel)
	if not self:ParseVersion(theirs) then return end
	if self:IsNewer(theirs, CP.version) then
		-- once per session, and again only for an even newer one
		if CP.settings and CP.settings.versionNotice ~= false and (not self.told or self:IsNewer(theirs, self.told)) then
			self.told = theirs
			CP:Print("CraftProfit %s is out (you have %s). Update through CurseForge.", theirs, tostring(CP.version))
		end
	elseif self:IsNewer(CP.version, theirs) and (channel == "GUILD" or channel == "PARTY" or channel == "RAID") then
		-- they are behind: say ours where they said theirs, so they hear it without waiting for our next login
		self:Announce(channel)
	end
end

---------------------------------------------------------------------------
-- Reports: what a copy carries
---------------------------------------------------------------------------

-- db.relay = { seq, log = { times of own reports }, list = { { id, from, t, text, hops } }, done = { [id] = t } }
local function Relay()
	local db = CP.db
	if not db then return nil end
	db.relay = db.relay or {}
	local r = db.relay
	r.list, r.done, r.log = r.list or {}, r.done or {}, r.log or {}
	return r
end

local function Find(relay, id)
	for i, r in ipairs(relay.list) do
		if r.id == id then return r, i end
	end
end

-- Old reports and old delivery notes go; the list stays within what one copy carries.
function Net:Prune()
	local relay = Relay()
	if not relay then return end
	local now = Now()
	for i = #relay.list, 1, -1 do
		if now - (relay.list[i].t or now) > KEEP_SECONDS then table.remove(relay.list, i) end
	end
	while #relay.list > HELD_MAX do table.remove(relay.list, 1) end
	local n, oldest, oldestT = 0, nil, nil
	for id, t in pairs(relay.done) do
		n = n + 1
		if not oldestT or t < oldestT then oldest, oldestT = id, t end
	end
	if n > DONE_MAX and oldest then relay.done[oldest] = nil end
end

-- 8 hex digits from the reporter, the time and a counter: the same report has the same id on every copy.
local function MakeId(name, t, seq)
	local h = 5381
	local s = tostring(name) .. "|" .. tostring(t) .. "|" .. tostring(seq)
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return string.format("%08x", h)
end

local function OneLine(text)
	return (text:gsub("[%c]+", function(c) return c:find("\n", 1, true) and LINE_BREAK or " " end))
end

-- The record as text, as /cf blocked shows it, with the taint summary taken when it happened.
local function ReportText(rec)
	local text = CP.Blocked and CP.Blocked:Line(rec) or tostring(rec.fn)
	if type(rec.stack) == "string" and rec.stack ~= "" then text = text .. "\n" .. rec.stack end
	if type(rec.taint) == "string" and rec.taint ~= "" then text = text .. "\n" .. rec.taint end
	if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) .. "..." end
	return text
end

-- Called by Blocked.lua for every record. Returns true when a report was made.
function Net:QueueReport(rec)
	if #self:Authors() == 0 or self:IsAuthor() or not self:Enabled() then return false end
	local relay = Relay()
	if not relay then return false end
	local now = Now()
	-- the same block again (same function, same stack) is one report per session
	local sig = tostring(rec.fn) .. "|" .. tostring(rec.stack)
	self.sentSigs = self.sentSigs or {}
	if self.sentSigs[sig] then return false end
	local today = 0
	for _, t in ipairs(relay.log) do
		if now - t < 86400 then today = today + 1 end
	end
	if today >= REPORTS_PER_DAY then return false end
	self.sentSigs[sig] = true
	relay.log[#relay.log + 1] = now
	while #relay.log > REPORTS_PER_DAY * 2 do table.remove(relay.log, 1) end
	relay.seq = (relay.seq or 0) % 9999 + 1
	local me = Me() or "?"
	relay.list[#relay.list + 1] = { id = MakeId(me, now, relay.seq), from = me, t = now, text = ReportText(rec), hops = 0 }
	self:Prune()
	self.offered = nil -- a new report is offered at once
	self:OfferAll()
	return true
end

---------------------------------------------------------------------------
-- Reports: offer, want, body, received
---------------------------------------------------------------------------

local function Ids(text)
	local ids = {}
	for id in text:gmatch("%x%x%x%x%x%x%x%x") do
		ids[#ids + 1] = id
		if #ids >= HELD_MAX then break end
	end
	return ids
end

-- "I hold these": to the author's characters by whisper, and to guild and group so other copies can carry them.
function Net:OfferAll()
	if not self:Enabled() or self:IsAuthor() then return end
	local relay = Relay()
	if not relay then return end
	self:Prune()
	if #relay.list == 0 then return end
	local ids, passable = {}, {}
	for _, r in ipairs(relay.list) do
		ids[#ids + 1] = r.id
		if (r.hops or 0) < MAX_HOPS then passable[#passable + 1] = r.id end
	end
	self.offered = self.offered or {}
	local now = Clock()
	local function Due(key)
		if self.offered[key] and now - self.offered[key] < OFFER_GAP then return false end
		self.offered[key] = now
		return true
	end
	for _, author in ipairs(self:Authors()) do
		-- without the chat filter every attempt would show "no player named ...": then once per session
		if (self.filtered or not self.offered["@" .. author]) and Due("@" .. author) then
			self.quietUntil = now + QUIET_SECONDS + SEND_STEP * (self.queue and #self.queue or 0)
			self:Send("O " .. table.concat(ids, " "), "WHISPER", author)
		end
	end
	if #passable > 0 then
		for _, channel in ipairs(GroupChannels()) do
			if Due(channel) then self:Send("O " .. table.concat(passable, " "), channel) end
		end
	end
end

function Net:OnOffer(sender, ids)
	if not self:Enabled() then return end
	local want, have = {}, {}
	if self:IsAuthor() then
		local got = CP.db and CP.db.reportIds or {}
		for _, id in ipairs(ids) do
			if got[id] then have[#have + 1] = id else want[#want + 1] = id end
		end
	else
		local relay = Relay()
		if not relay then return end
		self:Prune()
		local room = HELD_MAX - #relay.list
		for _, id in ipairs(ids) do
			if room <= 0 then break end
			if not relay.done[id] and not Find(relay, id) then
				want[#want + 1] = id
				room = room - 1
			end
		end
	end
	if #have > 0 then self:Send("A " .. table.concat(have, " "), "WHISPER", sender) end
	if #want > 0 then self:Send("W " .. table.concat(want, " "), "WHISPER", sender) end
end

function Net:OnWant(sender, ids)
	if not self:Enabled() then return end
	local relay = Relay()
	if not relay then return end
	local toAuthor = self:IsAuthor(sender)
	self.served = self.served or {}
	for _, id in ipairs(ids) do
		local r = Find(relay, id)
		if r and (toAuthor or ((r.hops or 0) < MAX_HOPS and (self.served[id] or 0) < SERVE_MAX)) then
			if not toAuthor then self.served[id] = (self.served[id] or 0) + 1 end
			-- first line: who reported it, when, and how many players it has passed through
			local body = OneLine(string.format("%s;%d;%d\n%s", tostring(r.from), r.t or 0, r.hops or 0, r.text))
			local parts = math.min(MAX_PARTS, math.max(1, math.ceil(#body / PART)))
			for p = 1, parts do
				self:Send(string.format("B%s:%d/%d:%s", id, p, parts, body:sub((p - 1) * PART + 1, p * PART)), "WHISPER", sender)
			end
		end
	end
end

function Net:OnBodyPart(sender, id, index, count, part)
	if not self:Enabled() then return end
	index, count = tonumber(index), tonumber(count)
	if not index or not count or count < 1 or count > MAX_PARTS or index < 1 or index > count then return end
	self.incoming = self.incoming or {}
	local key = sender .. ":" .. id
	local inc = self.incoming[key]
	if not inc or inc.count ~= count then
		inc = { count = count, parts = {}, got = 0 }
		self.incoming[key] = inc
	end
	if not inc.parts[index] then
		inc.parts[index] = part
		inc.got = inc.got + 1
	end
	if inc.got < count then return end
	self.incoming[key] = nil

	local body = table.concat(inc.parts)
	local head, rest = body:match("^(.-)" .. LINE_BREAK:gsub("%p", "%%%0") .. "(.*)$")
	local from, t, hops = (head or ""):match("^(.-);(%d+);(%d+)$")
	if not from or from == "" then return end
	local text = rest:gsub(LINE_BREAK:gsub("%p", "%%%0"), "\n")
	t, hops = tonumber(t), tonumber(hops)

	if self:IsAuthor() then
		self:Send("A " .. id, "WHISPER", sender) -- received: every copy that offers it from now on is told so
		local db = CP.db
		if not db then return end
		db.reportIds = db.reportIds or {}
		if db.reportIds[id] then return end
		db.reportIds[id] = Now()
		db.reports = db.reports or {}
		table.insert(db.reports, { id = id, from = from, via = (sender ~= from) and sender or nil, t = t, got = Now(), text = (text:gsub("|", "||")) })
		while #db.reports > INBOX_MAX do table.remove(db.reports, 1) end
		CP:Print("blocked-action report from %s%s: %s  (/cf reports)", from, sender ~= from and (" (carried by " .. sender .. ")") or "",
			(text:match("^[^\n]*") or ""):sub(1, 110))
	else
		-- carry it for the author
		local relay = Relay()
		if not relay or relay.done[id] or Find(relay, id) or from == Me() then return end
		if #relay.list >= HELD_MAX then return end
		relay.list[#relay.list + 1] = { id = id, from = from, t = t, text = text, hops = hops + 1 }
	end
end

-- The author's own copy holds reports it once picked up as a carrier (on another character of the account, the
-- saved data is shared): those have arrived by being here.
function Net:AdoptCarried()
	local db = CP.db
	if not (db and db.relay and db.relay.list and #db.relay.list > 0 and self:IsAuthor()) then return end
	db.reportIds, db.reports = db.reportIds or {}, db.reports or {}
	for _, r in ipairs(db.relay.list) do
		if not db.reportIds[r.id] then
			db.reportIds[r.id] = Now()
			table.insert(db.reports, { id = r.id, from = r.from, t = r.t, got = Now(), text = (tostring(r.text):gsub("|", "||")) })
			CP:Print("blocked-action report from %s: %s  (/cf reports)", tostring(r.from), (tostring(r.text):match("^[^\n]*") or ""):sub(1, 110))
		end
	end
	db.relay.list = {}
	while #db.reports > INBOX_MAX do table.remove(db.reports, 1) end
end

-- From the author: these arrived. They are deleted here and never picked up again.
function Net:OnReceived(ids)
	local relay = Relay()
	if not relay then return end
	local now = Now()
	for _, id in ipairs(ids) do
		local _, i = Find(relay, id)
		if i then table.remove(relay.list, i) end
		relay.done[id] = now
	end
	self:Prune()
end

-- A whisper to a character that is not online makes the game say so in chat. Right after an offer, that one
-- line for an author's name is kept out of the chat; every other system message passes.
local function NotFoundFilter(_, _, msg)
	if not Net.quietUntil or Clock() > Net.quietUntil then return false end
	if type(msg) ~= "string" or type(ERR_CHAT_PLAYER_NOT_FOUND_S) ~= "string" then return false end
	for _, a in ipairs(Net.AUTHORS) do
		if msg == ERR_CHAT_PLAYER_NOT_FOUND_S:format(a.name) then return true end
	end
	return false
end
Net.NotFoundFilter = NotFoundFilter

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

-- /cf reports [clear]: what arrived (the author's characters only have any).
function Net:ReportsCommand(rest)
	local db = CP.db
	local list = db and db.reports or {}
	if (rest or ""):lower() == "clear" then
		if db then db.reports = nil end -- the ids stay, so a cleared report is not accepted a second time
		CP:Print("reports cleared.")
		return
	end
	if #list == 0 then
		CP:Print("no reports received.")
		return
	end
	local out = {}
	for _, r in ipairs(list) do
		out[#out + 1] = string.format("from %s%s, happened %s, received %s\n%s", tostring(r.from), r.via and (" (carried by " .. r.via .. ")") or "",
			date and date("%Y-%m-%d %H:%M", r.t) or tostring(r.t), date and date("%Y-%m-%d %H:%M", r.got) or tostring(r.got), tostring(r.text))
	end
	CP:Print("%d report%s received. /cf reports clear empties the list.", #list, #list == 1 and "" or "s")
	if CP.Blocked and CP.Blocked.ShowCopy then pcall(CP.Blocked.ShowCopy, CP.Blocked, table.concat(out, "\n\n")) end
end

-- /cf report: turn sending, carrying and passing on reports on or off. Off also drops what is carried.
function Net:ToggleReports()
	CP:SetSetting("sendReports", not self:Enabled())
	if not self:Enabled() and CP.db then CP.db.relay = nil end
	local relay = self:Enabled() and Relay() or nil
	CP:Print("blocked-action reports to the author: %s%s", self:Enabled() and "on" or "off",
		relay and string.format(" (%d waiting)", #relay.list) or "")
end

-- /cf report            on / off
-- /cf report status     what this copy holds and whom it can reach
-- /cf report test       makes a report marked as a test, to try the way to the author
function Net:ReportCommand(rest)
	rest = (rest or ""):lower()
	if rest == "status" then
		local relay = self:Enabled() and Relay() or nil
		local authors = self:Authors()
		CP:Print("reports: %s; %d waiting here; author reachable from this character: %s%s", self:Enabled() and "on" or "off",
			relay and #relay.list or 0, #authors > 0 and table.concat(authors, ", ") or "no (other ruleset)",
			self:IsAuthor() and "; this character is the author" or "")
		CP:Print("  this character: '%s', ruleset %s, 'no player' line hidden: %s, received here: %d", tostring(Me()),
			tostring(CP.GetRuleset and CP:GetRuleset() or nil), self.filtered and "yes" or "no", CP.db and CP.db.reports and #CP.db.reports or 0)
		for _, r in ipairs(relay and relay.list or {}) do
			CP:Print("  %s from %s, passed through %d player%s: %s", r.id, tostring(r.from), r.hops or 0, (r.hops or 0) == 1 and "" or "s",
				(tostring(r.text):match("^[^\n]*") or ""):sub(1, 80))
		end
		return
	elseif rest == "test" then
		local rec = CP.Blocked and CP.Blocked:Context() or {}
		rec.t, rec.kind, rec.fn, rec.version = Now(), "test", "TEST()", CP.version
		local okb, build = pcall(function() return (select(4, GetBuildInfo())) end)
		rec.build = okb and build or nil
		rec.stack = "(test report made with /cf report test at " .. tostring(Now()) .. ")"
		if self:QueueReport(rec) then
			CP:Print("test report made. /cf report status shows it until the author has it.")
		else
			CP:Print("no test report made: reports are off, this character is the author, the author plays another ruleset, or today's limit is reached.")
		end
		return
	end
	return self:ToggleReports()
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function Net:OnMessage(prefix, text, channel, sender)
	if prefix ~= self.PREFIX or type(text) ~= "string" then return end
	CP:Debug("net: got '%s' on %s from '%s' (I am '%s')", text:sub(1, 40), tostring(channel), tostring(sender), tostring(Me()))
	sender = ShortName(sender)
	if not sender or sender == Me() then return end
	local version = text:match("^V (%S+)$")
	if version then return self:OnVersion(version, channel) end
	local offer = text:match("^O (.+)$")
	if offer then return self:OnOffer(sender, Ids(offer)) end
	if channel ~= "WHISPER" then return end
	local want = text:match("^W (.+)$")
	if want then return self:OnWant(sender, Ids(want)) end
	local id, index, count, part = text:match("^B(%x%x%x%x%x%x%x%x):(%d+)/(%d+):(.*)$")
	if id then return self:OnBodyPart(sender, id, index, count, part) end
	local received = text:match("^A (.+)$")
	if received and self:IsAuthor(sender) then return self:OnReceived(Ids(received)) end
end

CP:RegisterEvent("CHAT_MSG_ADDON", function(_, prefix, text, channel, sender) Net:OnMessage(prefix, text, channel, sender) end)
CP:RegisterEvent("GROUP_ROSTER_UPDATE", function()
	Net:AnnounceAll()
	Net:OfferAll()
end)
CP:RegisterEvent("PLAYER_LOGIN", function()
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, Net.PREFIX) end
	if type(ChatFrame_AddMessageEventFilter) == "function" and #Net.AUTHORS > 0 then
		Net.filtered = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", NotFoundFilter)
	end
	-- a little after login: the guild roster and the saved data are there by then
	if C_Timer and C_Timer.After then
		C_Timer.After(15, function()
			Net:AdoptCarried()
			Net:AnnounceAll()
			Net:OfferAll()
			if C_Timer.NewTicker then C_Timer.NewTicker(OFFER_GAP + 5, function() Net:OfferAll() end) end
		end)
	end
end)
