local ADDON_NAME, ns = ...

ns.STATUS = {
	input = {
		label = "Awaiting orders!",
		color = { 1, 0.82, 0 },
		icon = "Interface\\GossipFrame\\AvailableQuestIcon",
		rank = 0,
	},
	error = {
		label = "Wiped",
		color = { 1, 0.25, 0.25 },
		icon = "Interface\\RaidFrame\\ReadyCheck-NotReady",
		rank = 1,
	},
	busy = {
		label = "On mission",
		color = { 0.35, 0.75, 1 },
		icon = "Interface\\Icons\\Spell_Holy_BorrowedTime",
		rank = 2,
	},
	interrupted = {
		label = "Interrupted",
		color = { 1, 0.5, 0.15 },
		icon = "Interface\\RaidFrame\\ReadyCheck-Waiting",
		rank = 3,
	},
	idle = {
		label = "Resting at camp",
		color = { 0.6, 0.85, 0.5 },
		icon = "Interface\\RaidFrame\\ReadyCheck-Ready",
		rank = 4,
	},
}

local PREFIX = "|cff7ee787[Copilot]|r "
local QUIPS = {
	"Work work.",
	"Ready to work!",
	"Something need doing?",
	"Zug zug.",
	"More work?",
	"Job's done!",
}

function ns.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end

function ns.PlaySound(name)
	if not ns.db.settings.sound then return end
	if SOUNDKIT and SOUNDKIT[name] then
		PlaySound(SOUNDKIT[name], "Master")
	end
end

function ns.FormatAgo(seconds)
	if not seconds then return "never" end
	local delta = math.max(0, time() - seconds)
	if delta < 60 then return delta .. "s" end
	if delta < 3600 then return math.floor(delta / 60) .. "m" end
	if delta < 86400 then return math.floor(delta / 3600) .. "h" end
	return math.floor(delta / 86400) .. "d"
end

function ns.StatusLabel(s)
	if s.status == "busy" and s.busySince then
		return "On mission for " .. ns.FormatAgo(s.busySince)
	end
	if s.status == "input" and s.permission and not s.question then
		return "Needs your permission (answer in the app)"
	end
	if s.status == "idle" and s.lastFinishedAt and time() - s.lastFinishedAt < 3600 then
		return "Mission complete " .. ns.FormatAgo(s.lastFinishedAt) .. " ago"
	end
	return (ns.STATUS[s.status] or ns.STATUS.idle).label
end

function ns.Sessions()
	return ns.inbox and ns.inbox.sessions or {}
end

function ns.FindSession(id)
	for i, s in ipairs(ns.Sessions()) do
		if s.id == id then return s, i end
	end
end

function ns.PendingOrders(sessionId)
	local list = {}
	for _, order in ipairs(ns.db.outbox) do
		if not sessionId or order.sessionId == sessionId then
			table.insert(list, order)
		end
	end
	return list
end

local orderCounter = 0
local function addOrder(order)
	orderCounter = orderCounter + 1
	order.id = string.format("%d-%d-%d", time(), math.random(100000, 999999), orderCounter)
	order.createdAt = time()
	table.insert(ns.db.outbox, order)
	ns.PlaySound("IG_QUEST_LIST_SELECT")
	if ns.Refresh then ns.Refresh() end
end

function ns.QueueMessage(sessionId, text, mode)
	text = text and strtrim(text) or ""
	if text == "" then return false end
	local s = ns.FindSession(sessionId)
	addOrder({ sessionId = sessionId, kind = "message", text = text, mode = mode or "enqueue" })
	ns.Print(string.format(
		"Courier saddled for |cffffd100%s|r. Hearth (/reload) to dispatch.",
		s and s.name or "mission"
	))
	return true
end

function ns.Answer(sessionId, requestId, text)
	text = text and strtrim(text) or ""
	if text == "" then return false end
	for _, order in ipairs(ns.db.outbox) do
		if order.kind == "answer" and order.requestId == requestId then
			order.text = text
			ns.Print("Answer updated. Hearth (/reload) to dispatch.")
			if ns.Refresh then ns.Refresh() end
			return true
		end
	end
	addOrder({ sessionId = sessionId, kind = "answer", requestId = requestId, text = text })
	ns.Print("Answer sealed: |cffffffff" .. text .. "|r. Hearth (/reload) to dispatch.")
	return true
end

function ns.CancelOrder(id)
	for i, order in ipairs(ns.db.outbox) do
		if order.id == id then
			table.remove(ns.db.outbox, i)
			break
		end
	end
	if ns.Refresh then ns.Refresh() end
end

function ns.Sync()
	ReloadUI()
end

-- Reconcile the outbox with the companion's receipts, then work out what changed
-- since the last time we looked so we can make some noise about it.
local function reconcile()
	local inbox = ns.inbox
	if not inbox then return {} end
	local keep = {}
	ns.failedOrders = {}
	for _, order in ipairs(ns.db.outbox) do
		if inbox.acked and inbox.acked[order.id] then
			-- delivered
		elseif inbox.failed and inbox.failed[order.id] then
			order.error = inbox.failed[order.id]
			table.insert(ns.failedOrders, order)
		else
			table.insert(keep, order)
		end
	end
	ns.db.outbox = keep

	local events = { completed = {}, questions = {}, wiped = {} }
	local last = ns.db.lastStatus or {}
	local now = {}
	for _, s in ipairs(inbox.sessions or {}) do
		local before = last[s.id]
		now[s.id] = { status = s.status, requestId = s.question and s.question.requestId }
		if before then
			if before.status == "busy" and s.status == "idle" then
				table.insert(events.completed, s)
			end
			if s.status == "error" and before.status ~= "error" then
				table.insert(events.wiped, s)
			end
		end
		if s.question and (not before or before.requestId ~= s.question.requestId) then
			table.insert(events.questions, s)
		end
	end
	ns.db.lastStatus = now
	return events
end

local function announce(events)
	local inbox = ns.inbox
	if not inbox then
		ns.Print("No reports yet. Start the companion: |cffffffffnode companion/companion.mjs|r, then /reload.")
		return
	end
	local counts = { busy = 0, input = 0, idle = 0, error = 0, interrupted = 0 }
	for _, s in ipairs(inbox.sessions or {}) do
		counts[s.status] = (counts[s.status] or 0) + 1
	end
	local stale = inbox.generatedAt and (time() - inbox.generatedAt > 120)
	ns.Print(string.format(
		"Welcome back, Commander |cffffd100%s|r. |cff59bfff%d|r on mission, |cffffd100%d|r awaiting orders, |cff99d980%d|r at camp.%s",
		inbox.commander or "?",
		counts.busy, counts.input, counts.idle,
		stale and " |cffff8040(Report is " .. ns.FormatAgo(inbox.generatedAt) .. " old: is the companion running?)|r" or ""
	))
	if inbox.connected == false then
		ns.Print("|cffff4040The companion can't reach the Copilot app.|r Is it open?")
	end
	for _, s in ipairs(events.completed) do
		ns.Print(string.format("|cff99d980Mission complete:|r %s. %s", s.name, QUIPS[math.random(#QUIPS)]))
	end
	for _, s in ipairs(events.wiped) do
		ns.Print(string.format("|cffff4040%s wiped.|r Check the field report.", s.name))
	end
	for _, order in ipairs(ns.failedOrders or {}) do
		ns.Print(string.format("|cffff4040Courier lost:|r %s (%s)", order.text, order.error or "unknown"))
	end
	if #events.questions > 0 and ns.db.settings.announce then
		local s = events.questions[1]
		local msg = string.format("%s needs your orders!", s.name)
		if #events.questions > 1 then
			msg = string.format("%d missions need your orders!", #events.questions)
		end
		if RaidNotice_AddMessage and RaidWarningFrame then
			RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
		end
		ns.PlaySound("RAID_WARNING")
	elseif #events.completed > 0 then
		ns.PlaySound("IG_QUEST_LIST_COMPLETE")
	end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		CopilotMissionTableDB = CopilotMissionTableDB or {}
		local db = CopilotMissionTableDB
		db.outbox = db.outbox or {}
		db.lastStatus = db.lastStatus or {}
		db.settings = db.settings or {}
		if db.settings.sound == nil then db.settings.sound = true end
		if db.settings.announce == nil then db.settings.announce = true end
		if db.settings.openOnQuest == nil then db.settings.openOnQuest = true end
		ns.db = db
		ns.inbox = CopilotMissionTable_Inbox
		ns.events = reconcile()
		if ns.BuildUI then ns.BuildUI() end
	elseif event == "PLAYER_ENTERING_WORLD" and ns.db and not ns.announced then
		ns.announced = true
		C_Timer.After(2, function()
			announce(ns.events or {})
			if ns.db.settings.openOnQuest and ns.events and #(ns.events.questions or {}) > 0 and ns.Show then
				ns.Show(ns.events.questions[1].id)
			end
		end)
	end
end)

local function printHelp()
	ns.Print("Commands:")
	print("  |cffffd100/cmt|r  open the mission table")
	print("  |cffffd100/cmt list|r  roll call of every mission")
	print("  |cffffd100/cmt <n> <orders>|r  queue orders for mission n")
	print("  |cffffd100/cmt <n>! <orders>|r  priority orders (delivered at the next turn)")
	print("  |cffffd100/cmt answer <n> <text or choice #>|r  answer a mission's question")
	print("  |cffffd100/cmt sync|r  hearth: /reload to dispatch couriers and fetch reports")
	print("  |cffffd100/cmt sound|r / |cffffd100/cmt announce|r  toggle alerts")
end

SLASH_COPILOTMISSIONTABLE1 = "/cmt"
SLASH_COPILOTMISSIONTABLE2 = "/copilot"
SlashCmdList.COPILOTMISSIONTABLE = function(input)
	input = strtrim(input or "")
	local lower = input:lower()
	if input == "" then
		if ns.Toggle then ns.Toggle() end
	elseif lower == "help" then
		printHelp()
	elseif lower == "sync" or lower == "hearth" then
		ns.Sync()
	elseif lower == "sound" or lower == "announce" then
		ns.db.settings[lower] = not ns.db.settings[lower]
		ns.Print(lower .. " " .. (ns.db.settings[lower] and "on" or "off"))
	elseif lower == "list" then
		for i, s in ipairs(ns.Sessions()) do
			local meta = ns.STATUS[s.status] or ns.STATUS.idle
			print(string.format("  |cffffd100%d.|r |T%s:14|t %s |cff888888(%s)|r", i, meta.icon, s.name, ns.StatusLabel(s)))
		end
	else
		local n, answer = input:match("^[Aa]nswer%s+(%d+)%s+(.+)$")
		if n then
			local s = ns.Sessions()[tonumber(n)]
			if not (s and s.question) then
				ns.Print("That mission isn't asking anything.")
				return
			end
			local choice = tonumber(answer)
			local raw = s.question.rawChoices or s.question.choices or {}
			ns.Answer(s.id, s.question.requestId, choice and raw[choice] or answer)
			return
		end
		local index, bang, text = input:match("^(%d+)(!?)%s+(.+)$")
		local s = index and ns.Sessions()[tonumber(index)]
		if s then
			ns.QueueMessage(s.id, text, bang == "!" and "immediate" or "enqueue")
		else
			printHelp()
		end
	end
end
