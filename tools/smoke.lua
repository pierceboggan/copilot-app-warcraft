-- Headless smoke test: runs the addon against stubbed WoW APIs.
-- Usage: lua tools/smoke.lua <path to Inbox.lua> [savedvariables out file]
-- Set CMT_TARGET=<session id> to queue a real order for that session.
local inboxPath, svOut = arg[1], arg[2]
local addonDir = "addon/CopilotMissionTable/"

local now = os.time()
function time() return now end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function print(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
	io.write(table.concat(parts, " "), "\n")
end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) io.write("[chat] ", msg, "\n") end }
SOUNDKIT = setmetatable({}, { __index = function(_, k) return k end })
local sounds = {}
function PlaySound(id) table.insert(sounds, id) end
local reloaded = false
function ReloadUI() reloaded = true end
ChatTypeInfo = { RAID_WARNING = {} }
local warnings = {}
RaidWarningFrame = {}
function RaidNotice_AddMessage(_, msg) table.insert(warnings, msg) end
UISpecialFrames = {}
SlashCmdList = {}
local timers = {}
C_Timer = { After = function(_, fn) table.insert(timers, fn) end }
BackdropTemplateMixin = {}

local frames = {}
local function newObject(kind)
	local o = { kind = kind, shown = true, text = "", scripts = {}, w = 400 }
	return setmetatable(o, {
		__index = function(_, key)
			if not key:match("^%u") then return nil end
			local impl = {
				SetScript = function(s, name, fn) s.scripts[name] = fn end,
				Show = function(s) s.shown = true; if s.scripts.OnShow then s.scripts.OnShow(s) end end,
				Hide = function(s) s.shown = false; if s.scripts.OnHide then s.scripts.OnHide(s) end end,
				SetShown = function(s, v) s.shown = not not v end,
				IsShown = function(s) return s.shown end,
				SetText = function(s, t) s.text = t == nil and "" or tostring(t) end,
				GetText = function(s) return s.text end,
				GetStringHeight = function() return 42 end,
				GetWidth = function(s) return s.w end,
				SetWidth = function(s, w) s.w = w end,
				GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
				CreateTexture = function() return newObject("Texture") end,
				CreateFontString = function() return newObject("FontString") end,
			}
			return impl[key] or function() end
		end,
	})
end

function CreateFrame(kind, name)
	local f = newObject(kind)
	if name then _G[name] = f end
	table.insert(frames, f)
	return f
end
UIParent = newObject("Frame")
GameTooltip = newObject("GameTooltip")

local function load(path, ...)
	return assert(loadfile(path))(...)
end

load(inboxPath)
local ns = {}
load(addonDir .. "Core.lua", "CopilotMissionTable", ns)
load(addonDir .. "UI.lua", "CopilotMissionTable", ns)

local eventFrame = frames[1]
eventFrame.scripts.OnEvent(eventFrame, "ADDON_LOADED", "CopilotMissionTable")
CopilotMissionTableFrame.shown = false
eventFrame.scripts.OnEvent(eventFrame, "PLAYER_ENTERING_WORLD")
for _, fn in ipairs(timers) do fn() end

ns.Show()
assert(CopilotMissionTableFrame.shown, "main frame should open")
for _ = 1, 60 do
	for _, f in ipairs(frames) do
		if f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.1) end
	end
end
SlashCmdList.COPILOTMISSIONTABLE("list")

for _, f in ipairs(frames) do
	if f.kind == "Button" and f.scripts.OnClick and f.sessionId then f.scripts.OnClick(f) end
end
for _, f in ipairs(frames) do
	if f.scripts.OnEnter then f.scripts.OnEnter(f) end
end

local target = os.getenv("CMT_TARGET")
for i, s in ipairs(ns.Sessions()) do
	if s.question then
		SlashCmdList.COPILOTMISSIONTABLE("answer " .. i .. " 1")
		local order = CopilotMissionTableDB.outbox[#CopilotMissionTableDB.outbox]
		assert(order.kind == "answer" and order.text == s.question.rawChoices[1], "answer should use the raw choice")
		SlashCmdList.COPILOTMISSIONTABLE("answer " .. i .. " Actually, use DuckDB")
		assert(#CopilotMissionTableDB.outbox == 1 and CopilotMissionTableDB.outbox[1].text == "Actually, use DuckDB", "re-answering replaces the sealed answer")
		CopilotMissionTableDB.outbox = {}
		print("answer flow ok")
		break
	end
end
if target then
	local _, index = ns.FindSession(target)
	assert(index, "target session not in the inbox")
	SlashCmdList.COPILOTMISSIONTABLE(index .. " [Mission Table smoke test] A courier from Azeroth says hi. No action needed; reply with just: Zug zug.")
else
	SlashCmdList.COPILOTMISSIONTABLE("1 smoke test order")
	SlashCmdList.COPILOTMISSIONTABLE("2! smoke test priority order with a || pipe")
end
print(("sessions=%d outbox=%d warnings=%d sounds=%d"):format(
	#ns.Sessions(), #CopilotMissionTableDB.outbox, #warnings, #sounds))
SlashCmdList.COPILOTMISSIONTABLE("sync")
assert(reloaded, "sync should reload")

-- Serialize like WoW does on logout.
local function ser(v, indent)
	indent = indent or ""
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) ~= "table" then return tostring(v) end
	local out = { "{\n" }
	local n = #v
	for i = 1, n do out[#out + 1] = indent .. "\t" .. ser(v[i], indent .. "\t") .. ", -- [" .. i .. "]\n" end
	for k, val in pairs(v) do
		if not (type(k) == "number" and k >= 1 and k <= n) then
			local key = type(k) == "string" and string.format("[%q]", k) or "[" .. k .. "]"
			out[#out + 1] = indent .. "\t" .. key .. " = " .. ser(val, indent .. "\t") .. ",\n"
		end
	end
	out[#out + 1] = indent .. "}"
	return table.concat(out)
end
if svOut then
	local f = assert(io.open(svOut, "w"))
	f:write("\nCopilotMissionTableDB = " .. ser(CopilotMissionTableDB) .. "\n")
	f:close()
	print("wrote " .. svOut)
end
print("SMOKE OK")
