-- Run from the repository root: lua tests/ui_regressions.lua
-- These mocks verify the strings and layout settings handed to WoW, not its renderer.
local addonPath = (arg and arg[1]) or "LFGcopy.lua"
local file = assert(io.open(addonPath, "r"))
local source = file:read("*a")
file:close()
assert(loadfile(addonPath)) -- Check the complete addon's syntax, too.

-- Exercise the real refresh/clipping functions without booting the WoW client.
-- Top-level function endings are unindented; nested endings are indented.
local function ExtractFunction(name)
    return assert(source:match("local function " .. name .. "%([^\n]*\n.-\nend")
        or source:match("function " .. name .. "%([^\n]*\n.-\nend"), name .. " not found")
end

local Widget = {}
Widget.__index = Widget
local function NewWidget()
    return setmetatable({ value = "", points = {}, shown = true }, Widget)
end
function Widget:SetText(text) self.value = text end
function Widget:GetText() return self.value end
function Widget:SetTextColor() end
function Widget:SetFontObject(font) self.font = font end
function Widget:GetFontObject() return self.font or "GameFontHighlight" end
function Widget:CreateFontString() return NewWidget() end
function Widget:SetWordWrap(wrap) self.wordWrap = wrap end
function Widget:SetNonSpaceWrap(wrap) self.nonSpaceWrap = wrap end
function Widget:SetMaxLines(lines) self.maxLines = lines end
function Widget:SetWidth(width) self.width = width end
function Widget:GetWidth() return self.width or 680 end
function Widget:SetHeight(height) self.height = height end
function Widget:GetHeight() return self.height or 12 end
function Widget:GetStringHeight() return 12 end
function Widget:GetStringWidth()
    -- A short protected handle may render as a very long comment. The old
    -- substring-based clipping breaks the handle while trying to fit that text.
    local rendered = self.value:gsub("|K.-|k", string.rep("Long description ", 100))
    local _, characters = rendered:gsub("[^\128-\191]", "")
    return characters * 6
end
function Widget:ClearAllPoints() self.points = {} end
function Widget:SetPoint(point, ...) self.points[point] = { ... } end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:SetShown(shown) self.shown = shown end
function Widget:IsShown() return self.shown end
function Widget:GetName() return nil end

local function NewTab()
    local tab = NewWidget()
    tab.label, tab.activeBar = NewWidget(), NewWidget()
    return tab
end

local env = setmetatable({
    trinketAnnounced = true,
    frame = NewWidget(),
    content = NewWidget(),
    scroll = NewWidget(),
    emptyHint = NewWidget(),
    tabResults = NewTab(),
    tabWatch = NewTab(),
    rows = {},
    groups = {},
    groupNotes = {},
    parkedGroups = {},
    collapsedGroups = {},
    activeTab = "results",
    optSecondTab = true,
    optCollapsedDesc = true,
    optQuickNote = false,
    optParkOnCollapse = false,
}, { __index = _G })
env._G = env
env.BuildTrinketSet = function() end
env.BuildGroups = function() return env.groups end
env.GroupMatchesFilters = function() return true end
env.ReleaseExtraButtons = function() end
env.ReleaseExtraRows = function(count)
    for i = count + 1, #env.rows do env.rows[i]:Hide() end
end
env.AcquireRow = function(index)
    local row = env.rows[index]
    if not row then
        row = NewWidget()
        for _, child in ipairs({ "text", "activity", "desc", "headerButton", "returnButton", "noteButton" }) do
            row[child] = NewWidget()
        end
        row.noteButton.text = NewWidget()
        env.rows[index] = row
    end
    row:Show()
    return row
end

local code = table.concat({
    "local measureCache = {}",
    ExtractFunction("GetMeasureFs"),
    ExtractFunction("ClipText"),
    ExtractFunction("UpdateTabStrip"),
    ExtractFunction("RefreshWindow"),
    "return RefreshWindow, UpdateTabStrip",
}, "\n")
local chunk
if setfenv then -- WoW / Lua 5.1
    chunk = assert(loadstring(code, "@ui-under-test"))
    setfenv(chunk, env)
else
    chunk = assert(load(code, "@ui-under-test", "t", env))
end
local RefreshWindow, UpdateTabStrip = chunk()

local cases = 0
local function Equal(actual, expected, message)
    assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local descriptions = {
    "|Kk303|k",
    "|Kr303|k",
    "Group details: |Kk303|k more details",
    string.rep("Zażółć gęślą jaźń — healer needed. ", 50),
    string.rep("W", 300),
    "First line\nSecond line\nThird line",
    "Short comment",
}

for _, description in ipairs(descriptions) do
    for _, tab in ipairs({ "results", "watch" }) do
        for _, notes in ipairs({ false, true }) do
            env.activeTab = tab
            env.optQuickNote = notes
            env.optParkOnCollapse = tab == "watch"
            env.parkedGroups = {}
            env.collapsedGroups = { leader = true }
            env.groupNotes = { leader = string.rep("Note with accents: żółć. ", 40) }
            env.groups = {{ foldKey = "leader", leader = "Leader", members = 1,
                description = description, listed = "Dungeon", players = {} }}

            RefreshWindow()
            local row = env.rows[1]
            Equal(row.desc:GetText(), description, "collapsed description must be passed through intact")
            Equal(row.desc:IsShown(), true, "collapsed description visibility")
            Equal(row.desc.wordWrap, false, "collapsed word wrap")
            Equal(row.desc.nonSpaceWrap, false, "collapsed non-space wrap")
            Equal(row.desc.maxLines, 1, "collapsed line limit")
            Equal(row.desc.points.RIGHT[1], notes and row.noteButton or row, "description right anchor")
            Equal(row.noteButton:IsShown(), notes, "note visibility")
            Equal(row.returnButton:IsShown(), tab == "watch", "return arrow visibility")
            Equal(env.tabResults.label:GetText(), tab == "watch" and "Primo (0)" or "Primo (1)", "Primo count")
            Equal(env.tabWatch.label:GetText(), tab == "watch" and "Secundo (1)" or "Secundo", "Secundo count")
            if notes then
                assert(row.noteButton.text:GetStringWidth() <= 380, "long notes must still fit beside the description")
            end

            -- Reuse the same row: expanding must remove every single-line limit,
            -- and must not send a parked group back to Primo.
            env.collapsedGroups.leader = false
            RefreshWindow()
            Equal(row.desc:GetText(), description, "expanded description must be passed through intact")
            Equal(row.desc.wordWrap, true, "expanded word wrap")
            Equal(row.desc.nonSpaceWrap, true, "expanded non-space wrap")
            Equal(row.desc.maxLines, 0, "expanded line limit")
            Equal(row.desc.points.RIGHT[1], row, "expanded description uses the full row width")
            Equal(not not env.parkedGroups.leader, tab == "watch", "expanding preserves the tab")

            env.collapsedGroups.leader = true
            RefreshWindow()
            Equal(row.desc.maxLines, 1, "re-collapsing restores the line limit")
            Equal(row.desc:GetText(), description, "re-collapsing preserves the description")
            cases = cases + 1
        end
    end
end

-- The description option and empty comments must still hide the second line.
env.optQuickNote = false
env.optCollapsedDesc = false
RefreshWindow()
Equal(env.rows[1].desc:IsShown(), false, "disabled collapsed descriptions")
env.optCollapsedDesc = true
env.groups[1].description = ""
RefreshWindow()
Equal(env.rows[1].desc:IsShown(), false, "empty collapsed description")

-- Empty-state copy, initial labels, refreshed counts, and tab hiding.
env.groups = {}
RefreshWindow()
Equal(env.emptyHint:IsShown(), true, "empty Secundo hint")
assert(env.emptyHint:GetText():find("Secundo", 1, true), "empty hint must name Secundo")
assert(env.emptyHint:GetText():find("Primo", 1, true), "empty hint must name Primo")
assert(source:find('MakeTabButton("results", "Primo")', 1, true), "initial Primo label")
assert(source:find('MakeTabButton("watch", "Secundo")', 1, true), "initial Secundo label")
UpdateTabStrip(17, 3)
Equal(env.tabResults.label:GetText(), "Primo (17)", "Primo multiple-group count")
Equal(env.tabWatch.label:GetText(), "Secundo (3)", "Secundo multiple-group count")
Equal(env.tabWatch.activeBar:IsShown(), true, "active Secundo underline")
Equal(env.tabResults.activeBar:IsShown(), false, "inactive Primo underline")
env.optSecondTab = false
UpdateTabStrip(17, 0)
Equal(env.tabWatch:IsShown(), false, "hide Secundo option")

print("PASS: " .. cases .. " description/tab/note combinations, pooled-row transitions, and tab labels/options")
