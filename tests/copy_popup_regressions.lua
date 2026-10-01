-- Run from the repository root: lua tests/copy_popup_regressions.lua
-- Optional first argument: another addon source to reproduce the old failure.
local addonPath = (arg and arg[1]) or "LFGcopy.lua"
local file = assert(io.open(addonPath, "r"))
local source = file:read("*a")
file:close()
assert(loadfile(addonPath))
local function Section(first, last)
    local start = assert(source:find(first, 1, true), first)
    local finish = assert(source:find(last, start, true), last)
    return source:sub(start, finish - 1)
end
local function Function(name)
    return assert(source:match("local function " .. name .. "%([^\n]*\n.-\nend"), name)
end
local function Equal(actual, expected, message)
    assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local closed
local env = setmetatable({
    StaticPopupDialogs = {}, groupNotes = {},
    StaticPopup_Hide = function(which) closed = which end,
    GetCurrentRegionName = function() return "EU" end,
    GetNormalizedRealmName = function() return "A Realm With A Long Name" end,
    Ambiguate = function(name) return name:match("^[^-]+") or name end,
}, { __index = _G })
local code = table.concat({
    Section("local function GetClassColor", "\n-------------------------------------------------\n-- Trinket owners"),
    Section("\nlocal WCL_SUBDOMAIN = ", "\n-------------------------------------------------\n-- /who helper"),
    Section("\nlocal function CloseCopyPopup", "\n-- Main Window"),
    Section("\nlocal function TrimNoteText", "\nlocal function ApplyOption"),
    "return GetWCLLink",
}, "\n")
local chunk
if setfenv then
    chunk = assert(loadstring(code, "@copy-popup-under-test"))
    setfenv(chunk, env)
else
    chunk = assert(load(code, "@copy-popup-under-test", "t", env))
end
local GetWCLLink = chunk()
local copyDialog = env.StaticPopupDialogs.LFG_STANDALONE_COPY
local noteDialog = env.StaticPopupDialogs.LFGCOPY_GROUP_NOTE

local function CutCharacters(text, limit)
    local count = 0
    for i = 1, #text do
        local byte = text:byte(i)
        if byte < 128 or byte >= 192 then
            count = count + 1
            if count > limit then return text:sub(1, i - 1) end
        end
    end
    return text
end
local function NewEditBox(hasByteLimit)
    local box = { text = "", scripts = {}, maxLetters = 0, maxBytes = 0 }
    function box:SetMaxLetters(limit) self.maxLetters = limit end
    if hasByteLimit then
        function box:SetMaxBytes(limit) self.maxBytes = limit end
    end
    function box:SetText(text)
        if self.maxLetters > 0 then text = CutCharacters(text, self.maxLetters) end
        if self.maxBytes > 0 then text = text:sub(1, self.maxBytes) end
        self.text = text
    end
    function box:GetText() return self.text end
    function box:SetFocus()
        self.focused = true
        -- Exercise a client where taking focus resets the selection/caret.
        self.selectionStart, self.selectionEnd = #self.text, #self.text
    end
    function box:HighlightText(first, last)
        self.selectionStart, self.selectionEnd = first or 0, last or #self.text
    end
    function box:SetScript(event, callback) self.scripts[event] = callback end
    return box
end

local url = GetWCLLink("Verylongname")
assert(#url > 60, "fixture must exceed the note popup's character limit")
assert(url:find("https://fresh.warcraftlogs.com/character/eu/", 1, true) == 1, "copy the real generated URL")
assert(url:sub(-12) == "Verylongname", "the complete player name must be included")
local cases = 0
for _, field in ipairs({ "EditBox", "editBox" }) do
    for _, hasByteLimit in ipairs({ false, true }) do
        local box = NewEditBox(hasByteLimit)
        local popup = { [field] = box }

        -- The same pooled edit box is first used for a group note, then a URL.
        noteDialog.OnShow(popup, { key = "leader:mez-testrealm" })
        box:SetText(string.rep("n", 100))
        Equal(#box:GetText(), 60, "notes retain their intended length limit")
        copyDialog.OnShow(popup, url)
        Equal(box:GetText(), url, "full Warcraft Logs URL after a note popup")
        Equal(box.maxLetters, 0, "copy popup clears the inherited character limit")
        Equal(box.selectionStart, 0, "selection starts at the beginning of the URL")
        Equal(box.selectionEnd, #url, "selection includes the entire URL")
        Equal(box.focused, true, "copy popup has keyboard focus")
        box.scripts.OnEscapePressed(box)
        Equal(closed, "LFG_STANDALONE_COPY", "Escape closes the copy popup")

        -- Other pooled dialogs can leave byte limits too; the reset must happen
        -- before SetText, including for multibyte player names and longer links.
        if hasByteLimit then box:SetMaxBytes(20) end
        box:SetMaxLetters(12)
        local unicodeURL = GetWCLLink("Zażółć") .. "?filter=" .. string.rep("a", 200)
        popup.data = unicodeURL
        copyDialog.OnShow(popup) -- legacy callbacks may expose data on self only
        Equal(box:GetText(), unicodeURL, "full URL with inherited byte limit and legacy callback")
        Equal(box.selectionEnd, #unicodeURL, "all multibyte URL bytes are selected")
        if hasByteLimit then Equal(box.maxBytes, 0, "inherited byte limit is cleared") end

        -- Switching back to notes must reinstate its limit and Escape handler.
        noteDialog.OnShow(popup, { key = "leader:mez-testrealm" })
        Equal(box.maxLetters, 60, "notes still have a limit after copying a URL")
        box.scripts.OnEscapePressed(box)
        Equal(closed, "LFGCOPY_GROUP_NOTE", "notes restore their own Escape handler")
        copyDialog.OnShow(popup, "Mez")
        Equal(box:GetText(), "Mez", "copying a name still works")
        Equal(box.selectionStart, 0, "full name is selected")
        Equal(box.selectionEnd, 3, "name selection does not retain an old link length")
        copyDialog.OnShow(popup, "")
        Equal(box:GetText(), "", "empty data clears the previous copy text")
        cases = cases + 1
    end
end
print("PASS: " .. cases .. " pooled-popup/client variants, complete long URLs, selection, byte limits, names, and Escape")
