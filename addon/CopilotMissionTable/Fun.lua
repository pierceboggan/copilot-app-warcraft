local _, ns = ...

local ICON = "Interface\\Icons\\"

-- ---------------------------------------------------------------------------
-- Toasts: achievement, loot and boss-kill pop-ups, one at a time.

local toast
local toastQueue = {}

local function playFirst(...)
	for i = 1, select("#", ...) do
		local name = select(i, ...)
		if SOUNDKIT and SOUNDKIT[name] then
			ns.PlaySound(name)
			return
		end
	end
end

local function nextToast()
	local t = table.remove(toastQueue, 1)
	if not t then
		toast:Hide()
		toast.active = false
		return
	end
	toast.active = true
	toast.elapsed = 0
	toast.icon:SetTexture(t.icon)
	toast.label:SetText(t.label)
	toast.title:SetText(t.title)
	toast.title:SetTextColor(t.color[1], t.color[2], t.color[3])
	toast.points:SetText(t.points or "")
	toast.shield:SetShown(t.points ~= nil)
	toast:SetBackdropBorderColor(t.color[1], t.color[2], t.color[3], 1)
	toast:SetAlpha(0)
	toast:Show()
	if t.sound then playFirst(unpack(t.sound)) end
end

function ns.Toast(t)
	table.insert(toastQueue, t)
	if toast and not toast.active then nextToast() end
end

local function buildToast()
	local ui = ns.ui
	toast = CreateFrame("Frame", "CopilotMissionTableToast", UIParent, ui.BACKDROP)
	toast:SetSize(340, 74)
	toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
	toast:SetFrameStrata("DIALOG")
	ui.setBackdrop(toast, "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", "Interface\\Tooltips\\UI-Tooltip-Border", 16, 4)
	toast:Hide()

	toast.icon = toast:CreateTexture(nil, "ARTWORK")
	toast.icon:SetSize(50, 50)
	toast.icon:SetPoint("LEFT", 12, 0)

	toast.label = ui.font(toast, "GameFontNormalSmall")
	toast.label:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 12, -4)
	toast.title = ui.font(toast, "GameFontHighlightLarge")
	toast.title:SetPoint("TOPLEFT", toast.label, "BOTTOMLEFT", 0, -4)
	toast.title:SetPoint("RIGHT", -52, 0)
	toast.title:SetHeight(32)

	toast.shield = toast:CreateTexture(nil, "ARTWORK")
	toast.shield:SetTexture(ICON .. "INV_Shield_06")
	toast.shield:SetSize(34, 34)
	toast.shield:SetPoint("RIGHT", -12, 0)
	toast.points = ui.font(toast, "GameFontNormalLarge", "CENTER")
	toast.points:SetPoint("CENTER", toast.shield)

	toast:SetScript("OnUpdate", function(self, elapsed)
		self.elapsed = self.elapsed + elapsed
		local e = self.elapsed
		if e < 0.3 then
			self:SetAlpha(e / 0.3)
		elseif e < 4.5 then
			self:SetAlpha(1)
		elseif e < 5.3 then
			self:SetAlpha(1 - (e - 4.5) / 0.8)
		else
			nextToast()
		end
	end)
	toast:SetScript("OnMouseDown", nextToast)
	if #toastQueue > 0 then nextToast() end
end

-- ---------------------------------------------------------------------------
-- Loot: merged PRs become items.

local QUALITY = {
	{ name = "Poor", min = 0, hex = "9d9d9d", rgb = { 0.62, 0.62, 0.62 } },
	{ name = "Common", min = 8, hex = "ffffff", rgb = { 1, 1, 1 } },
	{ name = "Uncommon", min = 50, hex = "1eff00", rgb = { 0.12, 1, 0 } },
	{ name = "Rare", min = 200, hex = "0070dd", rgb = { 0, 0.44, 0.87 } },
	{ name = "Epic", min = 800, hex = "a335ee", rgb = { 0.64, 0.21, 0.93 } },
	{ name = "Legendary", min = 3000, hex = "ff8000", rgb = { 1, 0.5, 0 } },
}

local SLOTS = {
	{ "One-Hand Sword", "INV_Sword_04" },
	{ "Two-Hand Axe", "INV_Axe_09" },
	{ "Mace", "INV_Mace_01" },
	{ "Staff", "INV_Staff_08" },
	{ "Shield", "INV_Shield_06" },
	{ "Head", "INV_Helmet_03" },
	{ "Chest", "INV_Chest_Chain_05" },
	{ "Feet", "INV_Boots_05" },
	{ "Hands", "INV_Gauntlets_04" },
	{ "Gem", "INV_Misc_Gem_Ruby_01" },
	{ "Finger", "INV_Jewelry_Ring_03" },
	{ "Tome", "INV_Misc_Book_09" },
	{ "Wand", "INV_Wand_04" },
	{ "Bow", "INV_Weapon_Bow_07" },
	{ "Held In Off-hand", "INV_Misc_Orb_01" },
	{ "Potion", "INV_Potion_51" },
}

local FLAVOR = {
	"It worked on my machine.",
	"Forged in the fires of code review.",
	"Smells faintly of merge conflicts.",
	"LGTM.",
	"Ship it.",
	"Once belonged to a senior engineer.",
	"Tested in production.",
	"Nit: consider renaming.",
	"Approved with suggestions.",
	"Squashed, never stirred.",
}

function ns.LootQuality(item)
	local lines = (item.additions or 0) + (item.deletions or 0)
	local q = QUALITY[1]
	for _, quality in ipairs(QUALITY) do
		if lines >= quality.min then q = quality end
	end
	return q
end

function ns.LootSlot(item)
	return SLOTS[(item.seed or 0) % #SLOTS + 1]
end

function ns.LootLink(item)
	local q = ns.LootQuality(item)
	return string.format("|cff%s[%s]|r", q.hex, item.title)
end

function ns.LootList()
	local list = {}
	for _, item in pairs(ns.db.loot) do table.insert(list, item) end
	table.sort(list, function(a, b) return (a.mergedAt or 0) > (b.mergedAt or 0) end)
	return list
end

function ns.ShowLootTooltip(owner, item)
	local q = ns.LootQuality(item)
	local slot = ns.LootSlot(item)
	local adds, dels = item.additions or 0, item.deletions or 0
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:SetText(item.title, q.rgb[1], q.rgb[2], q.rgb[3], 1, true)
	GameTooltip:AddLine("Item Level " .. (100 + math.floor(math.sqrt(adds + dels) * 4)), 1, 0.82, 0)
	GameTooltip:AddLine("Bind on Merge", 1, 1, 1)
	GameTooltip:AddDoubleLine(slot[1], q.name, 1, 1, 1, q.rgb[1], q.rgb[2], q.rgb[3])
	GameTooltip:AddLine("+" .. adds .. " Stamina", 1, 1, 1)
	GameTooltip:AddLine("+" .. dels .. " Agility", 1, 1, 1)
	GameTooltip:AddLine("+" .. (item.files or 0) .. " Intellect", 1, 1, 1)
	local total = math.max(1, adds + dels)
	if dels > adds then
		GameTooltip:AddLine(string.format("Equip: Reduces technical debt by %d%%.", math.floor(dels * 100 / total)), 0.12, 1, 0, true)
	else
		GameTooltip:AddLine(string.format("Equip: Increases surface area by %d%%.", math.floor(adds * 100 / total)), 0.12, 1, 0, true)
	end
	GameTooltip:AddLine(string.format("%s #%d", item.repo or "?", item.number or 0), 0.6, 0.6, 0.6)
	if item.mergedAt then GameTooltip:AddLine("Looted " .. date("%b %d, %Y", item.mergedAt), 0.6, 0.6, 0.6) end
	GameTooltip:AddLine('"' .. FLAVOR[(item.seed or 0) % #FLAVOR + 1] .. '"', 1, 0.82, 0, true)
	GameTooltip:Show()
end

local function ingestLoot()
	local inbox = ns.inbox
	if not (inbox and inbox.loot) then return end
	local fresh = {}
	for _, item in ipairs(inbox.loot) do
		if not ns.db.loot[item.id] then
			ns.db.loot[item.id] = item
			table.insert(fresh, item)
		end
	end
	if not ns.db.lootSeeded then
		ns.db.lootSeeded = true
		if #fresh > 0 then
			ns.Print(string.format("Your bags fill with |cffffffff%d|r items from past raids. |cffffd100/cmt loot|r to inspect.", #fresh))
		end
		return
	end
	table.sort(fresh, function(a, b) return (a.mergedAt or 0) < (b.mergedAt or 0) end)
	for i, item in ipairs(fresh) do
		ns.Print("You receive loot: " .. ns.LootLink(item) .. ".")
		if i <= 3 then
			local q = ns.LootQuality(item)
			ns.Toast({
				label = "You receive loot:",
				title = item.title,
				icon = ICON .. ns.LootSlot(item)[2],
				color = q.rgb,
				sound = q.name == "Legendary" and { "UI_LEGENDARY_LOOT_TOAST", "UI_EPICLOOT_TOAST", "LOOT_WINDOW_COIN_SOUND" }
					or { "UI_EPICLOOT_TOAST", "LOOT_WINDOW_COIN_SOUND" },
			})
		end
	end
end

-- ---------------------------------------------------------------------------
-- Raid bosses: open PRs with failing CI.

function ns.Bosses()
	return ns.inbox and ns.inbox.bosses or {}
end

function ns.BossForSession(sessionId)
	for _, boss in ipairs(ns.Bosses()) do
		if boss.sessionId == sessionId then return boss end
	end
end

local function ingestKills()
	local inbox = ns.inbox
	if not (inbox and inbox.defeated) then return end
	for _, kill in ipairs(inbox.defeated) do
		if not ns.db.kills[kill.id] then
			ns.db.kills[kill.id] = { name = kill.name, at = kill.at, number = kill.number, repo = kill.repo }
			ns.Print(string.format("|cffff2020%s|r has been defeated! (PR #%d)", kill.name, kill.number or 0))
			ns.Toast({
				label = "Boss Defeated",
				title = kill.name,
				icon = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
				color = { 1, 0.25, 0.25 },
				sound = { "UI_RAID_BOSS_DEFEATED", "RAID_WARNING" },
			})
		end
	end
end

-- ---------------------------------------------------------------------------
-- Achievements

local function countLoot(pred)
	local n = 0
	for _, item in pairs(ns.db.loot) do
		if not pred or pred(item) then n = n + 1 end
	end
	return n
end

local function sumLoot(field)
	local n = 0
	for _, item in pairs(ns.db.loot) do n = n + (item[field] or 0) end
	return n
end

local function countKills()
	local n = 0
	for _ in pairs(ns.db.kills) do n = n + 1 end
	return n
end

local function stat(name) return ns.db.stats[name] or 0 end

local function sessionsWhere(pred)
	local n = 0
	for _, s in ipairs(ns.Sessions()) do
		if pred(s) then n = n + 1 end
	end
	return n
end

local function companionStat(name)
	return ns.inbox and ns.inbox.stats and ns.inbox.stats[name] or 0
end

ns.ACHIEVEMENTS = {
	{ id = "courier1", name = "Pony Express", desc = "Dispatch your first courier.", icon = "INV_Letter_15", points = 10,
		test = function() return stat("couriers") >= 1 end },
	{ id = "courier50", name = "Postmaster General", desc = "Dispatch 50 couriers.", icon = "INV_Letter_15", points = 25,
		test = function() return stat("couriers") >= 50 end },
	{ id = "leeroy", name = "Leeroy Jenkins", desc = "Send priority orders.", icon = "Ability_Warrior_Charge", points = 10,
		test = function() return stat("priority") >= 1 end },
	{ id = "answers10", name = "Quest Giver's Best Friend", desc = "Answer 10 questions from your missions.", icon = "INV_Scroll_03", points = 10,
		test = function() return stat("answers") >= 10 end },
	{ id = "hearth25", name = "Frequent Flyer", desc = "Hearth 25 times.", icon = "INV_Misc_Rune_01", points = 10,
		test = function() return stat("hearths") >= 25 end },
	{ id = "nightowl", name = "Night Owl", desc = "Dispatch a courier between midnight and 5 AM.", icon = "Spell_Nature_StarFall", points = 10,
		test = function() return stat("nightOwl") >= 1 end },
	{ id = "loot1", name = "Loot Goblin", desc = "Loot a merged pull request.", icon = "INV_Misc_Bag_10", points = 10,
		test = function() return countLoot() >= 1 end },
	{ id = "loot25", name = "Hoarder", desc = "Carry 25 items.", icon = "INV_Misc_Bag_08", points = 25,
		test = function() return countLoot() >= 25 end },
	{ id = "loot100", name = "Raider of the Lost Repo", desc = "Carry 100 items.", icon = "INV_Misc_Bag_17", points = 50,
		test = function() return countLoot() >= 100 end },
	{ id = "epic", name = "Purple Haze", desc = "Loot an epic item (800+ lines).", icon = "INV_Misc_Gem_Amethyst_02", points = 10,
		test = function() return countLoot(function(i) return ns.LootQuality(i).min >= 800 end) >= 1 end },
	{ id = "legendary", name = "Legendary!", desc = "Loot a legendary item (3,000+ lines).", icon = "INV_Hammer_Unique_Sulfuras", points = 25,
		test = function() return countLoot(function(i) return ns.LootQuality(i).name == "Legendary" end) >= 1 end },
	{ id = "janitor", name = "Ten Thousand Cuts", desc = "Delete 10,000 lines across your loot.", icon = "Ability_Warrior_Cleave", points = 25,
		test = function() return sumLoot("deletions") >= 10000 end },
	{ id = "kill1", name = "Bugslayer", desc = "Defeat a CI boss.", icon = "INV_Misc_Bone_HumanSkull_01", points = 10,
		test = function() return countKills() >= 1 end },
	{ id = "kill10", name = "Raid Finder Hero", desc = "Defeat 10 CI bosses.", icon = "INV_Misc_Head_Dragon_01", points = 25,
		test = function() return countKills() >= 10 end },
	{ id = "raidleader", name = "Raid Leader", desc = "Have 5 missions running at once.", icon = "Ability_Warrior_BattleShout", points = 10,
		test = function() return sessionsWhere(function(s) return s.status == "busy" end) >= 5 end },
	{ id = "bigbrain", name = "Galaxy Brain", desc = "A mission spends 75% of its mana.", icon = "Spell_Arcane_MindMastery", points = 10,
		test = function() return sessionsWhere(function(s) return (s.context or 0) >= 0.75 end) >= 1 end },
	{ id = "spells1000", name = "Spell Spammer", desc = "Your missions cast 1,000 spells.", icon = "Spell_Fire_Fireball02", points = 25,
		test = function() return companionStat("toolCalls") >= 1000 end },
}

function ns.AchievementPoints()
	local earned, total = 0, 0
	for _, a in ipairs(ns.ACHIEVEMENTS) do
		total = total + a.points
		if ns.db.achievements[a.id] then earned = earned + a.points end
	end
	return earned, total
end

function ns.CheckAchievements()
	if not ns.db then return end
	local fresh = {}
	for _, a in ipairs(ns.ACHIEVEMENTS) do
		if not ns.db.achievements[a.id] then
			local ok, earned = pcall(a.test)
			if ok and earned then
				ns.db.achievements[a.id] = time()
				table.insert(fresh, a)
			end
		end
	end
	for i, a in ipairs(fresh) do
		ns.Print(string.format("You have earned the achievement |cffffff00[%s]|r!", a.name))
		if i <= 3 then
			ns.Toast({
				label = "Achievement Earned",
				title = a.name,
				icon = ICON .. a.icon,
				color = { 1, 0.82, 0 },
				points = tostring(a.points),
				sound = { "UI_ACHIEVEMENT_TOAST", "ACHIEVEMENT_MENU_OPEN", "LEVEL_UP", "READY_CHECK" },
			})
		end
	end
	if #fresh > 0 and ns.Refresh then ns.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Combat log window

local combatLog

local function buildCombatLog()
	local ui = ns.ui
	combatLog = CreateFrame("Frame", "CopilotMissionTableCombatLog", UIParent, ui.BACKDROP)
	combatLog:SetSize(500, 230)
	combatLog:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 40, 260)
	combatLog:SetFrameStrata("MEDIUM")
	combatLog:SetMovable(true)
	combatLog:SetResizable(true)
	combatLog:EnableMouse(true)
	combatLog:RegisterForDrag("LeftButton")
	combatLog:SetClampedToScreen(true)
	combatLog:SetScript("OnDragStart", combatLog.StartMoving)
	combatLog:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		ns.db.logPos = { point, relPoint, x, y }
	end)
	if ns.db.logPos then
		combatLog:ClearAllPoints()
		combatLog:SetPoint(ns.db.logPos[1], UIParent, ns.db.logPos[2], ns.db.logPos[3], ns.db.logPos[4])
	end
	ui.setBackdrop(combatLog, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 14, 4)
	combatLog:SetBackdropColor(0, 0, 0, 0.75)
	combatLog:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

	local title = ui.font(combatLog, "GameFontNormal")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetText("Copilot Combat Log")
	local close = CreateFrame("Button", nil, combatLog, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)
	close:SetScript("OnClick", function() ns.ToggleCombatLog() end)

	local messages = CreateFrame("ScrollingMessageFrame", nil, combatLog)
	messages:SetPoint("TOPLEFT", 10, -28)
	messages:SetPoint("BOTTOMRIGHT", -10, 10)
	messages:SetFontObject(ChatFontNormal or GameFontHighlightSmall)
	messages:SetJustifyH("LEFT")
	messages:SetMaxLines(300)
	messages:SetFading(false)
	messages:EnableMouseWheel(true)
	messages:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	combatLog.messages = messages

	local entries = ns.inbox and ns.inbox.combat or {}
	if #entries == 0 then
		messages:AddMessage("|cff888888The battlefield is quiet. Spells your missions cast appear here.|r")
	end
	for _, entry in ipairs(entries) do
		messages:AddMessage("|cff888888" .. date("%H:%M", entry.t) .. "|r  " .. entry.text)
	end
	combatLog:SetShown(ns.db.settings.combatLog == true)
end

function ns.ToggleCombatLog()
	if not combatLog then return end
	ns.db.settings.combatLog = not combatLog:IsShown()
	combatLog:SetShown(ns.db.settings.combatLog)
end

-- ---------------------------------------------------------------------------
-- Views

local raid = {}
local function buildRaid(frame)
	local ui = ns.ui
	raid.header = ui.font(frame, "GameFontNormalLarge")
	raid.header:SetPoint("TOPLEFT", 6, -6)
	raid.empty = ui.font(frame, "GameFontDisableLarge", "CENTER")
	raid.empty:SetPoint("TOP", 0, -120)
	raid.empty:SetText("No bosses. Your CI is clean, Commander.")

	raid.cards = {}
	for i = 1, 4 do
		local card = CreateFrame("Frame", nil, frame, ui.BACKDROP)
		card:SetPoint("TOPLEFT", 0, -34 - (i - 1) * 82)
		card:SetPoint("RIGHT", 0, 0)
		card:SetHeight(76)
		ui.setBackdrop(card, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
		card:SetBackdropColor(0.15, 0.02, 0.02, 0.9)
		card:SetBackdropBorderColor(0.8, 0.15, 0.15, 1)

		card.skull = card:CreateTexture(nil, "ARTWORK")
		card.skull:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
		card.skull:SetSize(36, 36)
		card.skull:SetPoint("LEFT", 10, 4)

		card.name = ui.font(card, "GameFontNormalLarge")
		card.name:SetPoint("TOPLEFT", card.skull, "TOPRIGHT", 10, 6)
		card.name:SetPoint("RIGHT", -110, 0)
		card.name:SetTextColor(1, 0.3, 0.3)
		card.name:SetHeight(18)
		if card.name.SetWordWrap then card.name:SetWordWrap(false) end

		card.bar = CreateFrame("StatusBar", nil, card)
		card.bar:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -4)
		card.bar:SetPoint("RIGHT", -110, 0)
		card.bar:SetHeight(14)
		card.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		card.bar:SetStatusBarColor(0.85, 0.1, 0.1)
		card.bar:SetMinMaxValues(0, 1)
		local bg = card.bar:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.6)
		card.hp = ui.font(card.bar, "GameFontHighlightSmall", "CENTER")
		card.hp:SetPoint("CENTER")

		card.abilities = ui.font(card, "GameFontHighlightSmall")
		card.abilities:SetPoint("TOPLEFT", card.bar, "BOTTOMLEFT", 0, -4)
		card.abilities:SetPoint("RIGHT", -110, 0)
		card.abilities:SetHeight(24)
		card.abilities:SetJustifyV("TOP")

		card.engage = ui.button(card, "Engage", 90, function(self)
			local boss = self.boss
			if not (boss and boss.sessionId) then return end
			ns.Draft(boss.sessionId, string.format(
				"CI is failing on PR #%d (%s): %s. Please investigate and fix.",
				boss.number, boss.repo, table.concat(boss.failing, ", ")
			))
		end)
		card.engage:SetPoint("RIGHT", -10, 0)
		raid.cards[i] = card
	end

	raid.kills = ui.font(frame, "GameFontHighlightSmall")
	raid.kills:SetPoint("BOTTOMLEFT", 6, 6)
	raid.kills:SetPoint("RIGHT", -6, 0)
	raid.kills:SetJustifyV("BOTTOM")
end

local function refreshRaid()
	local bosses = ns.Bosses()
	raid.header:SetText(#bosses > 0 and string.format("%d boss%s engaged", #bosses, #bosses == 1 and "" or "es") or "Raid")
	raid.empty:SetShown(#bosses == 0)
	for i, card in ipairs(raid.cards) do
		local boss = bosses[i]
		card:SetShown(boss ~= nil)
		if boss then
			card.name:SetText(boss.name)
			local remaining = (boss.total or 0) - (boss.passed or 0)
			local hp = (boss.total or 0) > 0 and remaining / boss.total or 1
			card.bar:SetValue(hp)
			card.hp:SetText(string.format("%d%%  (%d failing, %d pending)", math.ceil(hp * 100), #boss.failing, boss.pending or 0))
			local list = {}
			for j, check in ipairs(boss.failing) do
				if j > 4 then
					table.insert(list, "+" .. (#boss.failing - 4) .. " more")
					break
				end
				table.insert(list, check)
			end
			card.abilities:SetText(string.format("|cff888888PR #%d %s|r  Abilities: |cffff8040%s|r", boss.number, boss.repo, table.concat(list, ", ")))
			card.engage.boss = boss
			if boss.sessionId then card.engage:Enable() else card.engage:Disable() end
			ns.ui.tooltip(card.engage, "Engage",
				boss.sessionId and "Draft orders to the mission on this branch." or ("No mission is working on " .. (boss.branch or "this branch") .. "."))
		end
	end
	local kills = {}
	for _, kill in pairs(ns.db.kills) do table.insert(kills, kill) end
	table.sort(kills, function(a, b) return (a.at or 0) > (b.at or 0) end)
	local lines = {}
	for i = 1, math.min(3, #kills) do
		table.insert(lines, string.format("|TInterface\\TargetingFrame\\UI-TargetingFrame-Skull:12|t %s |cff888888%s ago|r", kills[i].name, ns.FormatAgo(kills[i].at)))
	end
	raid.kills:SetText(#lines > 0 and ("|cffffd100Recent kills|r\n" .. table.concat(lines, "\n")) or "")
end

local bag = { offset = 0 }
local BAG_COLS, BAG_ROWS, SLOT = 11, 7, 44

local function buildLoot(frame)
	local ui = ns.ui
	bag.header = ui.font(frame, "GameFontNormalLarge")
	bag.header:SetPoint("TOPLEFT", 6, -6)
	bag.slots = {}
	for r = 1, BAG_ROWS do
		for c = 1, BAG_COLS do
			local slot = CreateFrame("Button", nil, frame)
			slot:SetSize(40, 40)
			slot:SetPoint("TOPLEFT", 8 + (c - 1) * (SLOT + 26), -36 - (r - 1) * (SLOT + 10))
			slot.icon = slot:CreateTexture(nil, "ARTWORK")
			slot.icon:SetAllPoints()
			slot.border = slot:CreateTexture(nil, "OVERLAY")
			slot.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
			slot.border:SetBlendMode("ADD")
			slot.border:SetSize(72, 72)
			slot.border:SetPoint("CENTER")
			slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
			slot:SetScript("OnEnter", function(self)
				if self.item then ns.ShowLootTooltip(self, self.item) end
			end)
			slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
			table.insert(bag.slots, slot)
		end
	end
	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		bag.offset = math.max(0, bag.offset - delta * BAG_COLS)
		ns.Refresh()
	end)
end

local function refreshLoot()
	local items = ns.LootList()
	bag.offset = math.min(bag.offset, math.max(0, (math.ceil(#items / BAG_COLS) - BAG_ROWS) * BAG_COLS))
	local legendary = countLoot(function(i) return ns.LootQuality(i).name == "Legendary" end)
	bag.header:SetText(string.format(
		"Bags: |cffffffff%d|r items   |cffff8000%d|r legendary   |cff1eff00+%d|r / |cffff4040-%d|r lines",
		#items, legendary, sumLoot("additions"), sumLoot("deletions")
	))
	for i, slot in ipairs(bag.slots) do
		local item = items[i + bag.offset]
		slot.item = item
		if item then
			local q = ns.LootQuality(item)
			slot.icon:SetTexture(ICON .. ns.LootSlot(item)[2])
			slot.icon:SetVertexColor(1, 1, 1)
			slot.border:SetShown(q.min >= 50)
			slot.border:SetVertexColor(q.rgb[1], q.rgb[2], q.rgb[3])
		else
			slot.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
			slot.border:Hide()
		end
	end
end

local ach = { rows = {} }
local function buildAchievements(frame)
	local ui = ns.ui
	ach.header = ui.font(frame, "GameFontNormalLarge")
	ach.header:SetPoint("TOPLEFT", 6, -6)
	local colWidth = 384
	for i, a in ipairs(ns.ACHIEVEMENTS) do
		local col = (i - 1) % 2
		local r = math.floor((i - 1) / 2)
		local row = CreateFrame("Frame", nil, frame, ui.BACKDROP)
		row:SetSize(colWidth, 42)
		row:SetPoint("TOPLEFT", col * (colWidth + 8), -32 - r * 44)
		ui.setBackdrop(row, "Interface\\Tooltips\\UI-Tooltip-Background", "Interface\\Tooltips\\UI-Tooltip-Border", 10, 3)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(32, 32)
		row.icon:SetPoint("LEFT", 6, 0)
		row.icon:SetTexture(ICON .. a.icon)
		row.name = ui.font(row, "GameFontNormal")
		row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
		row.name:SetText(a.name)
		row.desc = ui.font(row, "GameFontHighlightSmall")
		row.desc:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.desc:SetPoint("RIGHT", -44, 0)
		row.desc:SetHeight(12)
		row.desc:SetText(a.desc)
		row.points = ui.font(row, "GameFontNormalLarge", "RIGHT")
		row.points:SetPoint("RIGHT", -10, 0)
		row.points:SetText(a.points)
		row.achievement = a
		ach.rows[i] = row
	end
end

local function refreshAchievements()
	local earned, total = ns.AchievementPoints()
	ach.header:SetText(string.format("Achievement points: |cffffd100%d|r / %d", earned, total))
	for _, row in ipairs(ach.rows) do
		local when = ns.db.achievements[row.achievement.id]
		row.icon:SetDesaturated(not when)
		row:SetBackdropColor(when and 0.18 or 0.06, when and 0.14 or 0.06, when and 0.02 or 0.07, 0.9)
		row:SetBackdropBorderColor(when and 1 or 0.35, when and 0.82 or 0.35, when and 0 or 0.35, 1)
		row.name:SetTextColor(when and 1 or 0.55, when and 0.82 or 0.55, when and 0 or 0.55)
		row.points:SetTextColor(when and 1 or 0.4, when and 0.82 or 0.4, when and 0 or 0.4)
		if when then
			row.desc:SetText(row.achievement.desc .. "  |cff888888" .. date("%m/%d/%y", when) .. "|r")
		else
			row.desc:SetText(row.achievement.desc)
		end
	end
end

function ns.BuildFun()
	buildToast()
	buildCombatLog()
	ns.AddView("Raid", buildRaid, refreshRaid)
	ns.AddView("Loot", buildLoot, refreshLoot)
	ns.AddView("Achievements", buildAchievements, refreshAchievements)
end

-- Called a moment after entering the world, once the chat frame is ready.
function ns.FunOnEnter()
	ingestLoot()
	ingestKills()
	ns.CheckAchievements()
	local bosses = ns.Bosses()
	if #bosses > 0 then
		ns.Print(string.format(
			"|cffff2020%d CI boss%s|r stand%s against you. |cffffd100/cmt raid|r",
			#bosses, #bosses == 1 and "" or "es", #bosses == 1 and "s" or ""
		))
	end
end

-- Catch achievements earned between reloads (couriers, answers, priority orders).
local origAddOrderHooks = { "QueueMessage", "Answer" }
for _, name in ipairs(origAddOrderHooks) do
	local original = ns[name]
	ns[name] = function(...)
		local ok = original(...)
		if ok then ns.CheckAchievements() end
		return ok
	end
end
