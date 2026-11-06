local _, ns = ...

local BACKDROP = BackdropTemplateMixin and "BackdropTemplate" or nil
local ROW_HEIGHT = 46
local VISIBLE_ROWS = 9
local WIDTH, HEIGHT = 820, 540
local LIST_WIDTH = 310

local main, beacon
local rows = {}
local scrollOffset = 0
local selectedId

local function setBackdrop(f, bg, border, edge, inset)
	if not f.SetBackdrop then return end
	f:SetBackdrop({
		bgFile = bg,
		edgeFile = border,
		tile = true,
		tileSize = 32,
		edgeSize = edge or 16,
		insets = { left = inset or 4, right = inset or 4, top = inset or 4, bottom = inset or 4 },
	})
end

local function font(parent, template, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlight")
	fs:SetJustifyH(justify or "LEFT")
	if fs.SetWordWrap then fs:SetWordWrap(true) end
	return fs
end

local function button(parent, text, width, onClick)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width or 120, 24)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local function tooltip(widget, title, body)
	widget:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 0.82, 0)
		if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
		GameTooltip:Show()
	end)
	widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---------------------------------------------------------------------------
-- Session rows: unit frames with a cast bar for thinking and a mana bar for context.

local function createRow(parent, i)
	local row = CreateFrame("Button", nil, parent, BACKDROP)
	row:SetSize(LIST_WIDTH - 12, ROW_HEIGHT - 4)
	row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_HEIGHT)
	setBackdrop(row, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
	row:SetBackdropColor(0.08, 0.08, 0.1, 0.9)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(30, 30)
	row.icon:SetPoint("LEFT", 6, 0)

	row.name = font(row, "GameFontNormal")
	row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 2)
	row.name:SetPoint("RIGHT", -8, 0)
	row.name:SetHeight(14)
	if row.name.SetWordWrap then row.name:SetWordWrap(false) end

	row.sub = font(row, "GameFontHighlightSmall")
	row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
	row.sub:SetPoint("RIGHT", -8, 0)
	row.sub:SetHeight(12)
	if row.sub.SetWordWrap then row.sub:SetWordWrap(false) end

	row.bar = CreateFrame("StatusBar", nil, row)
	row.bar:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, -2)
	row.bar:SetPoint("RIGHT", -8, 0)
	row.bar:SetHeight(5)
	row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	row.bar:SetMinMaxValues(0, 1)
	row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
	row.bar.bg:SetAllPoints()
	row.bar.bg:SetColorTexture(0, 0, 0, 0.6)

	row.glow = row:CreateTexture(nil, "BACKGROUND")
	row.glow:SetPoint("TOPLEFT", 2, -2)
	row.glow:SetPoint("BOTTOMRIGHT", -2, 2)
	row.glow:SetColorTexture(1, 0.82, 0, 0.18)
	row.glow:Hide()

	row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
	row.highlight:SetPoint("TOPLEFT", 2, -2)
	row.highlight:SetPoint("BOTTOMRIGHT", -2, 2)
	row.highlight:SetColorTexture(1, 1, 1, 0.08)

	row.index = font(row, "GameFontDisableSmall", "RIGHT")
	row.index:SetPoint("TOPRIGHT", -6, -4)

	row.skull = row:CreateTexture(nil, "OVERLAY")
	row.skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
	row.skull:SetSize(16, 16)
	row.skull:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 6, -4)
	row.skull:Hide()

	row:SetScript("OnClick", function(self)
		selectedId = self.sessionId
		ns.PlaySound("IG_MAINMENU_OPTION_CHECKBOX_ON")
		ns.Refresh()
	end)

	row:SetScript("OnUpdate", function(self, elapsed)
		if self.status == "busy" then
			-- Fake a channelled cast: "Thinking..." sweeping forever.
			self.cast = ((self.cast or 0) + elapsed / 2.5) % 1
			self.bar:SetValue(self.cast)
		elseif self.status == "input" then
			self.pulse = (self.pulse or 0) + elapsed * 3
			self.glow:SetAlpha(0.5 + 0.5 * math.sin(self.pulse))
		end
	end)
	return row
end

local function updateRow(row, s, index)
	if not s then
		row:Hide()
		return
	end
	row:Show()
	local meta = ns.STATUS[s.status] or ns.STATUS.idle
	row.sessionId = s.id
	row.status = s.status
	row.icon:SetTexture(meta.icon)
	row.icon:SetDesaturated(s.status == "idle" and not (s.lastFinishedAt and time() - s.lastFinishedAt < 3600))
	row.name:SetText(s.name)
	row.sub:SetText(ns.StatusLabel(s))
	row.sub:SetTextColor(meta.color[1], meta.color[2], meta.color[3])
	row.index:SetText(index)
	if s.status == "busy" then
		row.bar:SetStatusBarColor(1, 0.7, 0)
	else
		row.bar:SetStatusBarColor(0.2, 0.45, 1)
		row.bar:SetValue(s.context or 0)
	end
	row.glow:SetShown(s.status == "input")
	row.skull:SetShown(ns.BossForSession and ns.BossForSession(s.id) ~= nil)
	if s.id == selectedId then
		row:SetBackdropBorderColor(1, 0.82, 0, 1)
	else
		row:SetBackdropBorderColor(0.4, 0.4, 0.45, 1)
	end
	local pending = #ns.PendingOrders(s.id)
	if pending > 0 then
		row.index:SetText("|TInterface\\Icons\\INV_Letter_15:12|t " .. pending .. "  " .. index)
	end
end

-- ---------------------------------------------------------------------------
-- Detail panel: field report, quest dialog and orders.

local detail = {}

local function buildDetail(parent)
	local panel = CreateFrame("Frame", nil, parent, BACKDROP)
	panel:SetPoint("TOPLEFT", LIST_WIDTH + 8, -92)
	panel:SetPoint("BOTTOMRIGHT", -14, 14)
	setBackdrop(panel, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 4)
	panel:SetBackdropColor(0.12, 0.09, 0.05, 0.92)
	panel:SetBackdropBorderColor(0.7, 0.55, 0.3, 1)
	detail.panel = panel

	detail.icon = panel:CreateTexture(nil, "ARTWORK")
	detail.icon:SetSize(40, 40)
	detail.icon:SetPoint("TOPLEFT", 12, -12)

	detail.title = font(panel, "GameFontNormalLarge")
	detail.title:SetPoint("TOPLEFT", detail.icon, "TOPRIGHT", 10, -2)
	detail.title:SetPoint("RIGHT", -12, 0)
	if detail.title.SetWordWrap then detail.title:SetWordWrap(false) end

	detail.meta = font(panel, "GameFontDisableSmall")
	detail.meta:SetPoint("TOPLEFT", detail.title, "BOTTOMLEFT", 0, -4)
	detail.meta:SetPoint("RIGHT", -12, 0)

	detail.status = font(panel, "GameFontHighlightSmall")
	detail.status:SetPoint("TOPLEFT", detail.meta, "BOTTOMLEFT", 0, -3)

	local header = font(panel, "GameFontNormal")
	header:SetPoint("TOPLEFT", 14, -70)
	header:SetText("Field report")
	detail.reportHeader = header

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
	scroll:SetPoint("RIGHT", -34, 0)
	scroll:SetHeight(150)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(400, 150)
	scroll:SetScrollChild(content)
	detail.report = font(content, "QuestFont")
	detail.report:SetPoint("TOPLEFT")
	detail.report:SetWidth(400)
	detail.report:SetTextColor(0.95, 0.9, 0.75)
	detail.scroll = scroll
	detail.content = content

	-- Quest dialog
	local quest = CreateFrame("Frame", nil, panel, BACKDROP)
	quest:SetPoint("TOPLEFT", scroll, "BOTTOMLEFT", -4, -10)
	quest:SetPoint("RIGHT", -12, 0)
	quest:SetHeight(150)
	setBackdrop(quest, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
	quest:SetBackdropColor(0.25, 0.18, 0.02, 0.9)
	quest:SetBackdropBorderColor(1, 0.82, 0, 1)
	detail.quest = quest

	local bang = quest:CreateTexture(nil, "ARTWORK")
	bang:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
	bang:SetSize(18, 18)
	bang:SetPoint("TOPLEFT", 8, -8)
	detail.questText = font(quest, "GameFontHighlight")
	detail.questText:SetPoint("TOPLEFT", bang, "TOPRIGHT", 6, 0)
	detail.questText:SetPoint("RIGHT", -10, 0)

	detail.choices = {}
	for i = 1, 6 do
		local choice = CreateFrame("Button", nil, quest)
		choice:SetHeight(18)
		choice:SetPoint("LEFT", 14, 0)
		choice:SetPoint("RIGHT", -10, 0)
		choice.icon = choice:CreateTexture(nil, "ARTWORK")
		choice.icon:SetTexture("Interface\\GossipFrame\\GossipGossipIcon")
		choice.icon:SetSize(14, 14)
		choice.icon:SetPoint("LEFT")
		choice.text = font(choice, "GameFontNormal")
		choice.text:SetPoint("LEFT", choice.icon, "RIGHT", 6, 0)
		choice.text:SetPoint("RIGHT")
		choice.text:SetHeight(18)
		if choice.text.SetWordWrap then choice.text:SetWordWrap(false) end
		choice:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		choice:SetScript("OnClick", function(self)
			local s = ns.FindSession(selectedId)
			if s and s.question then
				ns.Answer(s.id, s.question.requestId, self.raw)
				PlaySound(SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
			end
		end)
		detail.choices[i] = choice
	end

	-- Orders
	local box = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
	box:SetAutoFocus(false)
	box:SetMaxLetters(1000)
	box:SetHeight(24)
	box:SetPoint("BOTTOMLEFT", 20, 48)
	box:SetPoint("RIGHT", -16, 0)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	box:SetScript("OnEnterPressed", function(self)
		if detail.submit then detail.submit("enqueue") end
		self:ClearFocus()
	end)
	detail.box = box
	detail.placeholder = font(box, "GameFontDisable")
	detail.placeholder:SetPoint("LEFT", 2, 0)
	box:SetScript("OnTextChanged", function(self)
		detail.placeholder:SetShown(self:GetText() == "")
	end)

	detail.submit = function(mode)
		local s = ns.FindSession(selectedId)
		if not s then return end
		local text = box:GetText()
		local ok
		if s.question and s.question.freeform ~= false and mode ~= "force-message" then
			ok = ns.Answer(s.id, s.question.requestId, text)
		else
			ok = ns.QueueMessage(s.id, text, mode)
		end
		if ok then box:SetText("") end
	end

	detail.queue = button(panel, "Queue orders", 130, function() detail.submit("enqueue") end)
	detail.queue:SetPoint("BOTTOMLEFT", 14, 16)
	tooltip(detail.queue, "Queue orders", "Delivered after the mission finishes what it's doing.")

	detail.priority = button(panel, "Priority orders", 130, function() detail.submit("immediate") end)
	detail.priority:SetPoint("LEFT", detail.queue, "RIGHT", 6, 0)
	tooltip(detail.priority, "Priority orders", "Jumps the queue: the mission reads it at its next turn.")

	detail.couriers = font(panel, "GameFontHighlightSmall", "RIGHT")
	detail.couriers:SetPoint("BOTTOMRIGHT", -14, 22)
	detail.couriers:SetPoint("LEFT", detail.priority, "RIGHT", 8, 0)

	detail.empty = font(panel, "GameFontDisableLarge", "CENTER")
	detail.empty:SetPoint("CENTER")
	detail.empty:SetText("Select a mission")
end

local function updateDetail()
	local s = ns.FindSession(selectedId)
	local showing = s ~= nil
	for _, w in ipairs({
		detail.icon, detail.title, detail.meta, detail.status, detail.reportHeader, detail.scroll,
		detail.box, detail.queue, detail.priority, detail.couriers,
	}) do
		w:SetShown(showing)
	end
	detail.empty:SetShown(not showing)
	if not showing then
		detail.quest:Hide()
		return
	end
	local meta = ns.STATUS[s.status] or ns.STATUS.idle
	detail.icon:SetTexture(meta.icon)
	detail.title:SetText(s.name)
	local parts = {}
	if s.project and s.project ~= "" then table.insert(parts, s.project) end
	if s.branch and s.branch ~= "" then table.insert(parts, s.branch) end
	if s.model then table.insert(parts, s.model) end
	if s.context then table.insert(parts, string.format("%d%% mana used", math.floor(s.context * 100))) end
	detail.meta:SetText(table.concat(parts, "  |cff555555*|r  "))
	detail.status:SetText(ns.StatusLabel(s))
	detail.status:SetTextColor(meta.color[1], meta.color[2], meta.color[3])

	local width = detail.scroll:GetWidth()
	if width and width > 50 then
		detail.content:SetWidth(width)
		detail.report:SetWidth(width - 4)
	end
	local report = s.lastMessage
	if not report or report == "" then report = "|cff888888No word from this mission yet.|r" end
	detail.report:SetText(report)
	detail.content:SetHeight(math.max(150, detail.report:GetStringHeight() + 8))

	local q = s.question
	detail.scroll:SetHeight(q and 90 or 220)
	if q then
		detail.quest:Show()
		detail.questText:SetText(q.text)
		local y = -14 - math.max(18, detail.questText:GetStringHeight())
		local raw = q.rawChoices or q.choices or {}
		for i, choice in ipairs(detail.choices) do
			local label = q.choices and q.choices[i]
			if label then
				choice:Show()
				choice:ClearAllPoints()
				choice:SetPoint("TOPLEFT", 14, y)
				choice:SetPoint("RIGHT", -10, 0)
				choice.text:SetText(label)
				choice.raw = raw[i] or label
				y = y - 20
			else
				choice:Hide()
			end
		end
		detail.quest:SetHeight(-y + 8)
		local pendingAnswer
		for _, order in ipairs(ns.PendingOrders(s.id)) do
			if order.kind == "answer" and order.requestId == q.requestId then pendingAnswer = order.text end
		end
		if pendingAnswer then
			detail.questText:SetText(q.text .. "\n|cff7ee787Your answer is sealed: " .. pendingAnswer .. "|r")
		end
		detail.placeholder:SetText(q.freeform ~= false and "Write your own answer..." or "Pick a choice above")
	else
		detail.quest:Hide()
		detail.placeholder:SetText("Orders for this mission...")
	end
	detail.placeholder:SetShown(detail.box:GetText() == "")

	local pending = #ns.PendingOrders(s.id)
	if pending > 0 then
		detail.couriers:SetText(string.format(
			"|TInterface\\Icons\\INV_Letter_15:14|t %d courier%s waiting. Hearth to send.",
			pending, pending == 1 and "" or "s"
		))
	else
		detail.couriers:SetText("")
	end
end

-- ---------------------------------------------------------------------------

local header = {}

local function updateHeader()
	local inbox = ns.inbox
	local counts = { busy = 0, input = 0, idle = 0, error = 0, interrupted = 0 }
	for _, s in ipairs(ns.Sessions()) do counts[s.status] = (counts[s.status] or 0) + 1 end
	if inbox then
		local health = inbox.connected == false and "|cffff4040app offline|r"
			or (time() - (inbox.generatedAt or 0) > 120 and "|cffff8040report is stale|r")
			or "|cff7ee787companion online|r"
		header.sub:SetText(string.format(
			"Commander |cffffd100%s|r   |cff888888Scouted %s ago, %s|r",
			inbox.commander or "?", ns.FormatAgo(inbox.generatedAt), health
		))
	else
		header.sub:SetText("|cffff8040No reports yet.|r Run the companion, then Hearth.")
	end
	header.counts:SetText(string.format(
		"|T%s:14|t |cffffd100%d|r awaiting   |T%s:14|t |cff59bfff%d|r on mission   |T%s:14|t |cff99d980%d|r at camp",
		ns.STATUS.input.icon, counts.input, ns.STATUS.busy.icon, counts.busy, ns.STATUS.idle.icon, counts.idle
	))
	local outbox = #ns.db.outbox
	header.hearthCount:SetText(outbox > 0 and outbox or "")
	if header.hearthGlow then header.hearthGlow:SetShown(outbox > 0) end
end

local function updateList()
	local sessions = ns.Sessions()
	local maxOffset = math.max(0, #sessions - VISIBLE_ROWS)
	scrollOffset = math.min(math.max(scrollOffset, 0), maxOffset)
	for i, row in ipairs(rows) do
		local index = i + scrollOffset
		updateRow(row, sessions[index], index)
	end
	main.listEmpty:SetShown(#sessions == 0)
end

function ns.Refresh()
	if not main or not main:IsShown() then
		if ns.UpdateBeacon then ns.UpdateBeacon() end
		return
	end
	if not selectedId or not ns.FindSession(selectedId) then
		local first = ns.Sessions()[1]
		selectedId = first and first.id
	end
	updateHeader()
	local view = ns.currentView
	if view and view.refresh then
		view.refresh()
	else
		updateList()
		updateDetail()
	end
	ns.UpdateBeacon()
end

-- Extra panels (raid, loot, achievements) fill the body below the header.
function ns.AddView(name, build, refresh)
	local frame = CreateFrame("Frame", nil, main)
	frame:SetPoint("TOPLEFT", 12, -92)
	frame:SetPoint("BOTTOMRIGHT", -14, 14)
	frame:Hide()
	build(frame)
	table.insert(ns.views, { name = name, frame = frame, refresh = refresh })
end

function ns.SelectView(name)
	for _, view in ipairs(ns.views) do
		local active = view.name == name
		view.frame:SetShown(active)
		if active then ns.currentView = view end
		if view.tab then
			if active then view.tab:LockHighlight() else view.tab:UnlockHighlight() end
			view.tab:SetAlpha(active and 1 or 0.75)
		end
	end
	ns.Refresh()
end

local function buildTabs()
	local previous
	for i = #ns.views, 1, -1 do
		local view = ns.views[i]
		local tab = button(main, view.name, 104, function()
			ns.PlaySound("IG_CHARACTER_INFO_TAB")
			ns.SelectView(view.name)
		end)
		tab:SetHeight(22)
		if previous then
			tab:SetPoint("RIGHT", previous, "LEFT", -4, 0)
		else
			tab:SetPoint("TOPRIGHT", -16, -66)
		end
		view.tab = tab
		previous = tab
	end
	ns.SelectView("Missions")
end

function ns.Show(sessionId)
	if sessionId then
		selectedId = sessionId
		local _, index = ns.FindSession(sessionId)
		if index then scrollOffset = math.max(0, index - VISIBLE_ROWS) end
	end
	main:Show()
	if sessionId or not ns.currentView then
		ns.SelectView("Missions")
	else
		ns.Refresh()
	end
end

-- Pre-fills orders for a mission and jumps to it.
function ns.Draft(sessionId, text)
	ns.Show(sessionId)
	detail.box:SetText(text)
	detail.box:SetFocus()
end

function ns.Toggle()
	if main:IsShown() then main:Hide() else ns.Show() end
end

local function buildMain()
	main = CreateFrame("Frame", "CopilotMissionTableFrame", UIParent, BACKDROP)
	main:SetSize(WIDTH, HEIGHT)
	main:SetPoint("CENTER")
	main:SetFrameStrata("HIGH")
	main:SetToplevel(true)
	main:SetMovable(true)
	main:EnableMouse(true)
	main:RegisterForDrag("LeftButton")
	main:SetScript("OnDragStart", main.StartMoving)
	main:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db.pos = { point, relPoint, x, y }
	end)
	if ns.db.pos then
		main:ClearAllPoints()
		main:SetPoint(ns.db.pos[1], UIParent, ns.db.pos[2], ns.db.pos[3], ns.db.pos[4])
	end
	setBackdrop(main, "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", "Interface\\DialogFrame\\UI-DialogBox-Border", 32, 11)
	main:Hide()
	table.insert(UISpecialFrames, "CopilotMissionTableFrame")
	main:SetScript("OnShow", function() ns.PlaySound("IG_CHARACTER_INFO_OPEN") end)
	main:SetScript("OnHide", function() ns.PlaySound("IG_CHARACTER_INFO_CLOSE") end)

	local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local crest = main:CreateTexture(nil, "ARTWORK")
	crest:SetTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
	crest:SetSize(44, 44)
	crest:SetPoint("TOPLEFT", 18, -16)

	local title = font(main, "GameFontNormalHuge")
	title:SetPoint("TOPLEFT", crest, "TOPRIGHT", 10, 0)
	title:SetText("Copilot Mission Table")

	header.sub = font(main, "GameFontHighlightSmall")
	header.sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

	header.counts = font(main, "GameFontHighlightSmall")
	header.counts:SetPoint("TOPLEFT", crest, "BOTTOMLEFT", 2, -12)

	-- Hearthstone: the one big button. /reload sends couriers and fetches reports.
	local hearth = CreateFrame("Button", nil, main)
	hearth:SetSize(44, 44)
	hearth:SetPoint("TOPRIGHT", -44, -18)
	hearth:SetNormalTexture("Interface\\Icons\\INV_Misc_Rune_01")
	hearth:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	hearth:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	hearth:SetScript("OnClick", ns.Sync)
	tooltip(hearth, "Hearth to HQ", "Reloads your UI to dispatch waiting couriers and fetch fresh field reports. (/cmt sync)")
	header.hearthCount = font(hearth, "NumberFontNormalLarge", "RIGHT")
	header.hearthCount:SetPoint("BOTTOMRIGHT", -2, 2)
	header.hearthGlow = hearth:CreateTexture(nil, "OVERLAY")
	header.hearthGlow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	header.hearthGlow:SetBlendMode("ADD")
	header.hearthGlow:SetSize(80, 80)
	header.hearthGlow:SetPoint("CENTER")
	header.hearthGlow:SetVertexColor(0.5, 1, 0.6)
	local hearthLabel = font(main, "GameFontNormalSmall", "RIGHT")
	hearthLabel:SetPoint("RIGHT", hearth, "LEFT", -8, 0)
	hearthLabel:SetText("Hearth")
	hearth:SetScript("OnUpdate", function(_, elapsed)
		if header.hearthGlow:IsShown() then
			header.hearthT = (header.hearthT or 0) + elapsed * 4
			header.hearthGlow:SetAlpha(0.55 + 0.45 * math.sin(header.hearthT))
		end
	end)

	local missions = CreateFrame("Frame", nil, main)
	missions:SetAllPoints(main)
	ns.views = { { name = "Missions", frame = missions } }

	local list = CreateFrame("Frame", nil, missions, BACKDROP)
	list:SetPoint("TOPLEFT", 12, -92)
	list:SetPoint("BOTTOMLEFT", 12, 14)
	list:SetWidth(LIST_WIDTH)
	setBackdrop(list, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 4)
	list:SetBackdropColor(0.03, 0.03, 0.05, 0.85)
	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function(_, delta)
		scrollOffset = scrollOffset - delta
		ns.Refresh()
	end)
	for i = 1, VISIBLE_ROWS do rows[i] = createRow(list, i) end
	main.listEmpty = font(list, "GameFontDisable", "CENTER")
	main.listEmpty:SetPoint("CENTER")
	main.listEmpty:SetText("No missions reported.")

	buildDetail(missions)

	-- Tick timers ("on mission for 3m") while open.
	local acc = 0
	main:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + elapsed
		if acc > 5 then
			acc = 0
			updateHeader()
			for i, row in ipairs(rows) do
				local s = ns.Sessions()[i + scrollOffset]
				if s and row:IsShown() then row.sub:SetText(ns.StatusLabel(s)) end
			end
		end
	end)
end

-- A draggable beacon on screen: count of missions needing you, glowing when it matters.
local function buildBeacon()
	beacon = CreateFrame("Button", "CopilotMissionTableBeacon", UIParent)
	beacon:SetSize(40, 40)
	beacon:SetPoint("TOPRIGHT", -220, -30)
	beacon:SetFrameStrata("MEDIUM")
	beacon:SetMovable(true)
	beacon:RegisterForDrag("LeftButton")
	beacon:SetClampedToScreen(true)
	beacon:SetScript("OnDragStart", beacon.StartMoving)
	beacon:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db.beaconPos = { point, relPoint, x, y }
	end)
	if ns.db.beaconPos then
		beacon:ClearAllPoints()
		beacon:SetPoint(ns.db.beaconPos[1], UIParent, ns.db.beaconPos[2], ns.db.beaconPos[3], ns.db.beaconPos[4])
	end
	beacon:SetNormalTexture("Interface\\Icons\\INV_Misc_Spyglass_03")
	beacon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	beacon.border = beacon:CreateTexture(nil, "OVERLAY")
	beacon.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
	beacon.border:SetBlendMode("ADD")
	beacon.border:SetSize(76, 76)
	beacon.border:SetPoint("CENTER")
	beacon.badge = font(beacon, "NumberFontNormalLarge", "RIGHT")
	beacon.badge:SetPoint("BOTTOMRIGHT", -1, 2)
	beacon.bang = beacon:CreateTexture(nil, "OVERLAY")
	beacon.bang:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
	beacon.bang:SetSize(20, 20)
	beacon.bang:SetPoint("BOTTOM", beacon, "TOP", 0, -4)
	beacon:SetScript("OnClick", function() ns.Toggle() end)
	beacon:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("Copilot Mission Table", 0.49, 0.9, 0.53)
		for i, s in ipairs(ns.Sessions()) do
			if i > 12 then break end
			local meta = ns.STATUS[s.status] or ns.STATUS.idle
			GameTooltip:AddDoubleLine(
				string.format("|T%s:14|t %s", meta.icon, s.name),
				ns.StatusLabel(s),
				1, 1, 1, meta.color[1], meta.color[2], meta.color[3]
			)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click to open. Drag to move.", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	beacon:SetScript("OnLeave", function() GameTooltip:Hide() end)
	beacon:SetScript("OnUpdate", function(self, elapsed)
		if self.border:IsShown() then
			self.t = (self.t or 0) + elapsed * 3
			self.border:SetAlpha(0.5 + 0.5 * math.sin(self.t))
			self.bang:SetPoint("BOTTOM", self, "TOP", 0, -4 + 3 * math.abs(math.sin(self.t / 1.5)))
		end
	end)
end

function ns.UpdateBeacon()
	if not beacon then return end
	local waiting, busy = 0, 0
	for _, s in ipairs(ns.Sessions()) do
		if s.status == "input" or s.status == "error" then waiting = waiting + 1 end
		if s.status == "busy" then busy = busy + 1 end
	end
	beacon.badge:SetText(waiting > 0 and waiting or (busy > 0 and "|cff59bfff" .. busy .. "|r" or ""))
	beacon.border:SetShown(waiting > 0)
	beacon.bang:SetShown(waiting > 0)
	if waiting > 0 then
		beacon.border:SetVertexColor(1, 0.82, 0)
	end
end

function ns.BuildUI()
	ns.ui = { font = font, button = button, setBackdrop = setBackdrop, tooltip = tooltip, BACKDROP = BACKDROP }
	buildMain()
	buildBeacon()
	if ns.BuildFun then ns.BuildFun() end
	buildTabs()
	ns.UpdateBeacon()
end
