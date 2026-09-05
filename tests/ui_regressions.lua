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
function Widget:SetText(text)
    self.value = text
    if self.isDescription then
        self.widthWhenSetText = self.width
        self.heightWhenSetText = self.height
    end
end
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
-- Model the sizing distinction that the old constant-height mock missed:
-- anchors alone need not give FontString measurements a wrapping width, and
-- an existing height can make GetStringHeight report only the clipped text.
function Widget:GetNaturalHeight()
    if self.value == "" then return 0 end
    local height = self.renderedHeight or 12
    if not self.width or self.width <= 0 or self.wordWrap == false then
        height = math.min(height, 12)
    end
    if self.maxLines and self.maxLines > 0 then
        height = math.min(height, self.maxLines * 12)
    end
    return height
end
function Widget:GetHeight()
    if self.isDescription and (not self.height or self.height == 0) then
        return self:GetNaturalHeight()
    end
    return self.height or 12
end
function Widget:GetStringHeight()
    if not self.isDescription then return self.renderedHeight or 12 end
    local height = self:GetNaturalHeight()
    if self.unwrappedStringHeight then height = math.min(height, 12) end
    if self.height and self.height > 0 then height = math.min(height, self.height) end
    return height
end
function Widget:IsTruncated()
    return self.isDescription and self.value ~= ""
        and (self:GetHeight() < (self.renderedHeight or 12)
            or self:GetNaturalHeight() < (self.renderedHeight or 12))
end
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
    descriptionHeights = {}, -- simulate heights measured by the WoW renderer
    groupNotes = {},
    parkedGroups = {},
    collapsedGroups = {},
    activeTab = "results",
    optSecondTab = true,
    optCollapsedDesc = true,
    optQuickNote = false,
    optParkOnCollapse = true,
}, { __index = _G })
env._G = env
env.BuildTrinketSet = function() end
env.BuildGroups = function() return env.groups end
env.GroupMatchesFilters = function() return true end
env.ReleaseExtraButtons = function(row, count) row.visiblePlayers = count end
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
        row.desc.isDescription = true
        row.desc:SetHeight(12) -- stale single-line size that must be reset
        env.rows[index] = row
    end
    row.desc.renderedHeight = env.descriptionHeights[index] or 12
    row.desc.unwrappedStringHeight = env.unwrappedStringHeight
    row:Show()
    return row
end

local code = table.concat({
    "local measureCache = {}",
    ExtractFunction("GetMeasureFs"),
    ExtractFunction("ClipText"),
    ExtractFunction("LayoutDescription"),
    ExtractFunction("UpdateTabStrip"),
    ExtractFunction("RefreshWindow"),
    "return RefreshWindow, UpdateTabStrip",
}, "\n")
local function LoadInEnvironment(text, environment)
    if setfenv then -- WoW / Lua 5.1
        local chunk = assert(loadstring(text, "@ui-under-test"))
        setfenv(chunk, environment)
        return chunk
    end
    return assert(load(text, "@ui-under-test", "t", environment))
end
local RefreshWindow, UpdateTabStrip = LoadInEnvironment(code, env)()

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

-- A short display handle can have a tall rendered description. Feed different
-- measured heights back into RefreshWindow to catch fixed-height/overlap bugs.
local descriptionHeights = { 120.5, 180, 144.25, 360, 60, 36, 12 }
local function CheckDescriptionFits(row)
    local textBottom = -row.desc.points.TOPLEFT[4] + row.desc:GetHeight()
    assert(row:GetHeight() >= textBottom + 8, "row must contain the full text box plus bottom padding")
    Equal(row.desc:IsTruncated(), false, "description must not be truncated by its text box")
    Equal(row.desc.heightWhenSetText, 0, "reset stale height before assigning text")
    Equal(row.desc.widthWhenSetText, row.desc:GetWidth(), "set explicit wrapping width before assigning text")
    local anchors = 0
    for _ in pairs(row.desc.points) do anchors = anchors + 1 end
    Equal(anchors, 1, "description uses a single anchor, not anchor-implied dimensions")
end

for descriptionIndex, description in ipairs(descriptions) do
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
            local fullWidthHeight = descriptionHeights[descriptionIndex]
            local collapsedHeight = (notes and fullWidthHeight > 12) and fullWidthHeight * 2 or fullWidthHeight
            env.descriptionHeights = { collapsedHeight }
            -- Also exercise clients where GetStringHeight omits word wrapping;
            -- automatic GetHeight at an explicit width must supply the height.
            env.unwrappedStringHeight = descriptionIndex % 2 == 0

            RefreshWindow()
            local row = env.rows[1]
            Equal(row.desc:GetText(), description, "collapsed description must be passed through intact")
            Equal(row.desc:IsShown(), true, "collapsed description visibility")
            Equal(row.desc.wordWrap, true, "collapsed word wrap")
            Equal(row.desc.nonSpaceWrap, true, "collapsed non-space wrap")
            Equal(row.desc.maxLines, 0, "collapsed descriptions must not have a line limit")
            local descWidth = row:GetWidth() - 16 - (notes and (row.noteButton:GetWidth() + 8) or 0)
            local allocatedHeight = math.ceil(collapsedHeight) + 4
            Equal(row.desc:GetWidth(), descWidth, "explicit collapsed width leaves room for notes")
            Equal(row.desc:GetHeight(), allocatedHeight, "collapsed text box includes full height and rounding padding")
            Equal(row:GetHeight(), 8 + 18 + 2 + math.max(allocatedHeight, 16) + 8, "collapsed row follows allocated text height")
            Equal(env.content:GetHeight(), row:GetHeight() + 28, "scroll content includes the entire row")
            Equal(row.visiblePlayers, 0, "full collapsed descriptions do not reveal the player list")
            CheckDescriptionFits(row)
            Equal(row.noteButton:IsShown(), notes, "note visibility")
            Equal(row.returnButton:IsShown(), tab == "watch", "return arrow visibility")
            Equal(env.tabResults.label:GetText(), tab == "watch" and "Primo (0)" or "Primo (1)", "Primo count")
            Equal(env.tabWatch.label:GetText(), tab == "watch" and "Secundo (1)" or "Secundo", "Secundo count")
            if notes then
                assert(row.noteButton.text:GetStringWidth() <= 380, "long notes must still fit beside the description")
            end

            -- Reuse the same row: expanding keeps full descriptions, uses the
            -- whole row width, and must not send a parked group back to Primo.
            env.collapsedGroups.leader = false
            env.descriptionHeights = { fullWidthHeight }
            RefreshWindow()
            Equal(row.desc:GetText(), description, "expanded description must be passed through intact")
            Equal(row.desc.wordWrap, true, "expanded word wrap")
            Equal(row.desc.nonSpaceWrap, true, "expanded non-space wrap")
            Equal(row.desc.maxLines, 0, "expanded line limit")
            Equal(row.desc:GetWidth(), row:GetWidth() - 16, "expanded description uses the full row width")
            Equal(row.desc:GetHeight(), math.ceil(fullWidthHeight) + 4, "expanded text box follows the new wrapped height")
            CheckDescriptionFits(row)
            Equal(not not env.parkedGroups.leader, tab == "watch", "expanding preserves the tab")

            env.collapsedGroups.leader = true
            env.descriptionHeights = { collapsedHeight }
            RefreshWindow()
            Equal(row.desc.maxLines, 0, "re-collapsing must not restore a line limit")
            Equal(row.desc:GetText(), description, "re-collapsing preserves the description")
            CheckDescriptionFits(row)
            cases = cases + 1
        end
    end
end

-- The description option and empty comments must still hide the text block
-- without leaving stale multi-line height behind on a pooled row.
env.optQuickNote = false
env.optCollapsedDesc = false
env.descriptionHeights = { 240 }
RefreshWindow()
Equal(env.rows[1].desc:IsShown(), false, "disabled collapsed descriptions")
Equal(env.rows[1]:GetHeight(), 34, "hidden descriptions leave a header-only row")
env.optCollapsedDesc = true
env.groups[1].description = ""
RefreshWindow()
Equal(env.rows[1].desc:IsShown(), false, "empty collapsed description")
Equal(env.rows[1]:GetHeight(), 34, "empty comments do not leave extra row height")
env.optQuickNote = true
RefreshWindow()
Equal(env.rows[1].desc:IsShown(), false, "empty description beside a note")
Equal(env.rows[1]:GetHeight(), 52, "notes still have room without a description")
env.collapsedGroups.leader = false
RefreshWindow()
Equal(env.rows[1].desc:GetText(), "", "empty expanded comments clear the recycled text")
Equal(env.rows[1].desc:GetHeight(), 0, "empty expanded comments clear the recycled height")
env.collapsedGroups.leader = true

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

-- Tall adjacent rows contribute their entire heights to the scroll content.
env.optSecondTab = true
env.optQuickNote = false
env.optParkOnCollapse = true
env.parkedGroups = {}
env.collapsedGroups = { first = true, second = true }
env.descriptionHeights = { 240, 96 }
env.groups = {
    { foldKey = "first", leader = "First", members = 1, description = "|Kk303|k", listed = "", players = {} },
    { foldKey = "second", leader = "Second", members = 1, description = "|Kr303|k", listed = "", players = {} },
}
RefreshWindow()
CheckDescriptionFits(env.rows[1])
CheckDescriptionFits(env.rows[2])
Equal(env.content:GetHeight(), env.rows[1]:GetHeight() + env.rows[2]:GetHeight() + 36, "scroll height includes both full descriptions")

-- The new default must never park collapsed groups on an inaccessible tab.
env.activeTab = "results"
env.optSecondTab = false
env.parkedGroups = {}
RefreshWindow()
Equal(env.activeRowCount, 2, "collapsed groups remain visible when Secundo is hidden")
Equal(next(env.parkedGroups), nil, "no groups parked on a hidden tab")
CheckDescriptionFits(env.rows[1])

-- Execute the actual option initialization: default on, but never overwrite
-- an existing saved choice (including a deliberate false value).
local optionsCode = assert(source:match("\nlocal db =.-\nlocal optParkOnCollapse = [^\n]+"))
    .. "\nreturn optParkOnCollapse, db"
local default, defaultDB = LoadInEnvironment(optionsCode, setmetatable({}, { __index = _G }))()
Equal(default, true, "parking is enabled by default")
Equal(defaultDB.parkOnCollapse, true, "new parking default is stored")
for _, saved in ipairs({ false, true }) do
    local savedDB = { parkOnCollapse = saved }
    local optionEnv = setmetatable({ LFGcopyDB = savedDB }, { __index = _G })
    local actual, actualDB = LoadInEnvironment(optionsCode, optionEnv)()
    Equal(actual, saved, "existing saved parking choice is respected")
    Equal(actualDB, savedDB, "existing options table is preserved")
end

local tocFile = assert(io.open("LFGcopy.toc", "r"))
local version = assert(tocFile:read("*a"):match("## Version: ([^\n]+)"))
tocFile:close()
assert(source:find("LFGcopy v" .. version .. " loaded.", 1, true), "startup message must identify the installed addon version")

print("PASS: " .. cases .. " full-description/tab/note combinations, explicit sizing, stale-height resets, transitions, labels, defaults, and version")
