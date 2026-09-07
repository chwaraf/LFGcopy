-- Run from the repository root: lua tests/persistence_regressions.lua
-- Simulate separate addon loads using copies of the SavedVariables tables.
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
local function Load(text, env)
    if setfenv then
        local chunk = assert(loadstring(text, "@persistence-under-test"))
        setfenv(chunk, env)
        return chunk()
    end
    return assert(load(text, "@persistence-under-test", "t", env))()
end
local function Equal(actual, expected, message)
    assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function Snapshot(value)
    if type(value) ~= "table" then
        assert(type(value) == "string" or type(value) == "boolean" or type(value) == "number", "only serializable values may be saved")
        return value
    end
    local copy = {}
    for key, child in pairs(value) do copy[key] = Snapshot(child) end
    return copy
end

local Widget = {}
Widget.__index = Widget
local function NewWidget() return setmetatable({ scripts = {}, events = {} }, Widget) end
function Widget:SetScript(event, callback) self.scripts[event] = callback end
function Widget:RegisterEvent(event) self.events[event] = true end
function Widget:UnregisterEvent(event) self.events[event] = nil end
function Widget:CreateFontString() return NewWidget() end
function Widget:CreateTexture() return NewWidget() end
function Widget:SetSize() end
function Widget:SetPoint() end
function Widget:SetJustifyH() end
function Widget:SetText(text) self.text = text end
function Widget:SetColorTexture() end
function Widget:SetHeight() end
function Widget:Hide() end
function Widget:RegisterForClicks() end

local code = table.concat({
    Section("\nlocal db = ", '-- "Trinket only" toggle button'),
    Section("\nlocal function TrimNoteText", "\nlocal function ApplyOption"),
    Function("ApplyOption"),
    Function("MoveAllParkedBack"),
    Function("MakeTabButton"),
    Function("BuildGroups"),
    Section('addon:RegisterEvent("ADDON_LOADED")', '\nprint("|cff00ff00LFGcopy v'),
    [[return function() return {
        options = db, state = charDB, notes = groupNotes,
        parked = parkedGroups, collapsed = collapsedGroups,
        key = GetLeaderGroupKey, groups = BuildGroups, makeTab = MakeTabButton,
        selected = function() return activeTab end,
        select = SetActiveTab, moveAll = MoveAllParkedBack, option = ApplyOption,
    } end]],
}, "\n")

local function NewSession(options, state)
    local env = setmetatable({
        ADDON_NAME = "LFGcopy",
        StaticPopupDialogs = {}, addon = NewWidget(),
        TAB_BAR_H = 22, tabStrip = NewWidget(), CreateFrame = NewWidget,
        GetNormalizedRealmName = function() return "TestRealm" end,
        GetRealmName = function() return "Test Realm" end,
        Ambiguate = function(name) return name:match("^[^-]+") end,
        GetPlayers = function() return {} end,
        RefreshWindow = function() end,
        currentID = 10, currentLeader = "Mez", currentComment = "|Kk303|k",
    }, { __index = _G })
    env.C_LFGList = {
        GetSearchResults = function()
            if not env.currentID then return 0, {} end
            return 1, { env.currentID }
        end,
        GetSearchResultInfo = function() return { numMembers = 1, comment = env.currentComment } end,
        GetSearchResultLeaderInfo = function()
            if env.currentLeader then return { name = env.currentLeader } end
        end,
    }
    local currentState = Load(code, env)
    Equal(env.LFGcopyDB, nil, "do not bind options before SavedVariables have loaded")
    Equal(env.LFGcopyCharDB, nil, "do not bind character state before SavedVariables have loaded")
    -- Real loading order: addon Lua executes, saved globals are populated,
    -- then ADDON_LOADED identifies which addon's data is ready.
    env.LFGcopyDB, env.LFGcopyCharDB = options, state
    env.addon.scripts.OnEvent(env.addon, "ADDON_LOADED", "AnotherAddon")
    Equal(env.LFGcopyDB, options, "ignore other addons' load events")
    env.addon.scripts.OnEvent(env.addon, "ADDON_LOADED", "LFGcopy")
    Equal(env.addon.events.ADDON_LOADED, nil, "stop listening once our saved data is initialized")
    return currentState(), env
end

local first, env = NewSession()
Equal(env.LFGcopyDB, first.options, "fresh options must be bound to the saved global")
Equal(env.LFGcopyCharDB, first.state, "fresh character state must be bound to the saved global")
Equal(first.options.parkOnCollapse, true, "parking defaults on")
first.option("quickNote", true)
Equal(env.LFGcopyDB.quickNote, true, "option changes update the saved global")
Equal(first.selected(), "results", "new character starts on Primo")
local group = first.groups()[1]
local key = group.foldKey
Equal(key, "leader:mez-testrealm", "stable realm-qualified identity")
Equal(first.key("Mez-TestRealm"), key, "bare and qualified leader names match")
assert(first.key("Mez-OtherRealm") ~= key, "same name on a different realm must not share state")
Equal(first.key("|Kk303|k"), nil, "temporary display handles must not become saved identities")

-- Exercise actual note-save and tab-click callbacks, then save a parked row.
local notePopup = { EditBox = { GetText = function() return "  Check gear before inviting  " end } }
env.StaticPopupDialogs.LFGCOPY_GROUP_NOTE.OnAccept(notePopup, { key = key })
Equal(first.state.groupNotes[key], "Check gear before inviting", "saved notes reference the persistent table")
first.collapsed[key], first.parked[key] = true, true
local secundo = first.makeTab("watch", "Secundo")
secundo.scripts.OnClick(secundo, "LeftButton")
Equal(first.state.activeTab, "watch", "tab clicks update saved selection")
Equal(group.description, "|Kk303|k", "live description is passed through, not decoded")
Equal(first.state.description, nil, "live comments are not persisted")

-- Unknown result IDs are useful only in this session. Run the actual logout
-- handler before serializing, including the same path used during a UI reload.
first.parked["result:25"] = true
first.collapsed["result:25"] = true
first.notes["result:25"] = "Temporary note"
assert(env.addon.events.PLAYER_LOGOUT, "logout cleanup must be registered")
env.addon.scripts.OnEvent(env.addon, "PLAYER_LOGOUT")
Equal(first.state.parkedGroups["result:25"], nil, "temporary placement is not saved")
Equal(first.state.collapsedGroups["result:25"], nil, "temporary collapse state is not saved")
Equal(first.state.groupNotes["result:25"], nil, "unidentified notes are not saved under recyclable IDs")

local savedOptions, savedState = Snapshot(env.LFGcopyDB), Snapshot(env.LFGcopyCharDB)
local second, nextEnv = NewSession(savedOptions, savedState)
Equal(second.selected(), "watch", "Secundo selection survives reload")
Equal(second.options.quickNote, true, "saved options are read after SavedVariables load")
Equal(second.notes[key], "Check gear before inviting", "notes survive reload")
Equal(second.parked[key], true, "placement survives reload")
Equal(second.collapsed[key], true, "collapse state survives reload")
nextEnv.currentID, nextEnv.currentLeader, nextEnv.currentComment = 99, "Mez-TestRealm", "|Kr999|k"
local refreshed = second.groups()[1]
Equal(refreshed.foldKey, key, "fresh result IDs reattach to saved state")
Equal(refreshed.description, "|Kr999|k", "fresh live comments replace old session handles")
Equal(second.notes[refreshed.foldKey], "Check gear before inviting", "fresh result recovers the note")
nextEnv.currentID = nil
Equal(#second.groups(), 0, "saved metadata never creates stale/offline listings")
Equal(second.parked[key], true, "missing results do not erase saved placement")

-- Another character gets a separate view; account-wide options still apply.
local other = NewSession(Snapshot(savedOptions))
Equal(next(other.notes), nil, "character notes are isolated")
Equal(next(other.parked), nil, "character placement is isolated")
Equal(other.selected(), "results", "character tab selection is isolated")

-- The return-all action and deleting a note must also survive the next load.
second.moveAll()
Equal(second.state.activeTab, "results", "return-all saves Primo selection")
Equal(second.state.parkedGroups[key], nil, "return-all clears saved placement")
Equal(second.state.collapsedGroups[key], false, "returned groups are saved expanded")
notePopup.EditBox.GetText = function() return "   " end
nextEnv.StaticPopupDialogs.LFGCOPY_GROUP_NOTE.OnAccept(notePopup, { key = key })
local third = NewSession(Snapshot(second.options), Snapshot(second.state))
Equal(third.notes[key], nil, "deleted notes stay deleted after relog")
Equal(third.parked[key], nil, "returned groups stay on Primo after relog")
Equal(third.selected(), "results", "Primo selection survives relog")

-- Safely normalize malformed old state and retire the old visibility option.
local repaired = NewSession({ parkOnCollapse = false, secondTab = false }, {
    activeTab = "missing", collapsedGroups = "bad", parkedGroups = 42,
    groupNotes = { [key] = "Keep me", ["result:25"] = "Stale", ["leader:bad"] = false },
})
Equal(repaired.options.parkOnCollapse, false, "deliberately saved parking choice is respected")
Equal(repaired.options.secondTab, nil, "obsolete visibility setting is discarded")
Equal(repaired.selected(), "results", "invalid selection resets safely")
Equal(repaired.notes[key], "Keep me", "valid notes survive repair")
Equal(repaired.notes["result:25"], nil, "legacy result IDs cannot attach to new groups")
Equal(repaired.notes["leader:bad"], nil, "malformed note values are ignored")
Equal(next(repaired.collapsed), nil, "malformed collapse table is repaired")
local tab = repaired.makeTab("watch", "Secundo")
tab.scripts.OnClick(tab, "LeftButton")
Equal(repaired.selected(), "watch", "old secondTab=false cannot prevent selecting Secundo")
repaired.select("invalid")
Equal(repaired.selected(), "watch", "invalid tab IDs cannot be persisted")

local toc = assert(io.open("LFGcopy.toc", "r"))
assert(toc:read("*a"):find("## SavedVariablesPerCharacter: LFGcopyCharDB", 1, true), "character state must be declared for saving")
toc:close()
print("PASS: reload/relog persistence, live-result matching, character isolation, deletions, defaults, and legacy-state repair")
