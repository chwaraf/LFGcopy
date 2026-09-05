local addon = CreateFrame("Frame")

-- Keybinding names shown in WoW's Key Bindings UI when Bindings.xml is loaded.
BINDING_HEADER_LFGCOPY = "LFGcopy"
BINDING_NAME_LFGCOPY_TOGGLE = "Open/close LFGcopy"

local DEFAULT_LFGCOPY_BINDING_KEY = "ALT-I"
local DEFAULT_LFGCOPY_BINDING_COMMAND = "LFGCOPY_TOGGLE"

-- Binding wrapper defined near the top so the Bindings.xml keybind always has
-- a global function to call, even though the real ToggleLFGCopy is defined later.
function LFGCopy_ToggleBinding()
    if ToggleLFGCopy then
        ToggleLFGCopy()
    else
        print("|cffff8800[LFGcopy]|r addon is still loading. Try again or use /lfgcopy.")
    end
end

local CLASS_COLORS = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS

-------------------------------------------------
-- Trinket owners (read from another addon's saved data)
-------------------------------------------------
-- Set this to the GLOBAL table name your other addon stores the names in.
-- (e.g. a SavedVariables table like "MyTrinketDB"). Adjust the parsing in
-- BuildTrinketSet() to match how that table is shaped.
local TRINKET_DB_GLOBAL = "SCB_Mages"   -- global table from the MageFinder data file

-- Optional: an inline fallback list (used if the global isn't found).
-- You can paste names here too if you ever want a hardcoded copy.
local TRINKET_FALLBACK = {
    -- "Mez", "Thrall",
}

-- Normalized lookup set built at runtime: { ["mez"] = true, ... }
local trinketOwners = {}

local function NormalizeName(name)
    if not name then return nil end
    name = Ambiguate(name, "none")        -- strip realm if present
    name = name:gsub("%s+", "")           -- drop stray spaces
    return name:lower()
end

local function AddOwner(name)
    local key = NormalizeName(name)
    if key and key ~= "" then
        trinketOwners[key] = true
    end
end

local trinketCount = 0

local function BuildTrinketSet()
    wipe(trinketOwners)

    local db = _G[TRINKET_DB_GLOBAL]
    if type(db) == "table" then
        -- Handle the common shapes automatically:
        for k, v in pairs(db) do
            if type(v) == "table" and v.name then
                -- shape: { {name="Mez", guild=..., server=...}, ... }
                AddOwner(v.name)
            elseif type(v) == "string" then
                -- shape: { "Mez", "Thrall", ... }
                AddOwner(v)
            elseif type(k) == "string" and v then
                -- shape: { ["Mez"] = true }
                AddOwner(k)
            end
        end
    end

    -- Inline fallback list
    for _, n in ipairs(TRINKET_FALLBACK) do
        AddOwner(n)
    end

    -- Count how many unique owners we loaded (for the confirmation message)
    trinketCount = 0
    for _ in pairs(trinketOwners) do
        trinketCount = trinketCount + 1
    end
end

local function OwnsTrinket(name)
    local key = NormalizeName(name)
    return key and trinketOwners[key] or false
end

-------------------------------------------------
-- WarcraftLogs URL builder
-------------------------------------------------
-- Subdomain: "fresh" (Anniversary), "classic" (Classic Era/SoD/Cata),
-- or "www" (retail). No game API tells us which, so set it here.
local WCL_SUBDOMAIN = "fresh"

local function Slugify(realm)
    if not realm or realm == "" then return "" end
    realm = realm:gsub("'", "")        -- drop apostrophes (e.g. Mal'Ganis)
    realm = realm:gsub("%s+", "-")     -- spaces -> hyphens
    realm = realm:gsub("[^%w%-]", "")  -- strip any other punctuation
    return realm:lower()
end

local function GetWCLLink(playerName)
    -- Region: prefer the string API, fall back to numeric id mapping
    local region
    if GetCurrentRegionName then
        region = GetCurrentRegionName()
    end
    if not region and GetCurrentRegion then
        local map = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
        region = map[GetCurrentRegion()]
    end
    region = (region or "us"):lower()

    -- Realm: the player's own realm (single-realm server = everyone shares it)
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and GetRealmName())
        or ""
    local realmSlug = Slugify(realm)

    -- Player name: strip realm if somehow present, lowercased for the URL
    local name = Ambiguate(playerName or "", "none")

    return string.format(
        "https://%s.warcraftlogs.com/character/%s/%s/%s",
        WCL_SUBDOMAIN, region, realmSlug, name
    )
end

-------------------------------------------------
-- /who helper
-- toChat = true  -> results print in the chat frame (detailed line,
--                   same as typing /who name manually)
-- toChat = false -> results show in the default Who window
-------------------------------------------------
local function DoWho(name, toChat)
    local who = Ambiguate(name, "none")
    local filter = 'n-"' .. who .. '"'

    if SetWhoToUI then
        SetWhoToUI(not toChat)
    elseif C_FriendList and C_FriendList.SetWhoToUi then
        C_FriendList.SetWhoToUi(not toChat)
    end

    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(filter)
    elseif SendWho then
        SendWho(filter)
    else
        local edit = ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
        if edit then
            edit:SetText("/who " .. filter)
            ChatEdit_SendText(edit, 0)
        end
    end
end

local function OpenWhisper(name)
    local who = Ambiguate(name or "", "none")
    if who == "" or who == "Unknown" then return end

    if ChatFrame_OpenChat then
        ChatFrame_OpenChat("/w " .. who .. " ")
        return
    end

    local edit = ChatEdit_ChooseBoxForSend and ChatEdit_ChooseBoxForSend()
    if edit then
        if ChatEdit_ActivateChat then
            ChatEdit_ActivateChat(edit)
        end
        edit:SetText("/w " .. who .. " ")
    end
end

-------------------------------------------------
-- Context menu (Shift+Right-click)
-------------------------------------------------
local function ShowPlayerMenu(anchorButton, name)
    -- Modern menu API (present on Anniversary/retail)
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchorButton, function(owner, root)
            root:CreateTitle(name)
            root:CreateButton("/who (to chat)", function() DoWho(name, true) end)
            root:CreateButton("/who (to window)", function() DoWho(name, false) end)
            root:CreateButton("Copy name", function()
                StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, name)
            end)
            root:CreateButton("Copy WarcraftLogs link", function()
                StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, GetWCLLink(name))
            end)
        end)
        return
    end

    -- Fallback: classic EasyMenu
    if EasyMenu then
        local menu = {
            { text = name, isTitle = true, notCheckable = true },
            { text = "/who (to chat)", notCheckable = true, func = function() DoWho(name, true) end },
            { text = "/who (to window)", notCheckable = true, func = function() DoWho(name, false) end },
            { text = "Copy name", notCheckable = true, func = function()
                StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, name)
            end },
            { text = "Copy WarcraftLogs link", notCheckable = true, func = function()
                StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, GetWCLLink(name))
            end },
        }
        local menuFrame = LFGCopyMenuFrame or CreateFrame("Frame", "LFGCopyMenuFrame", UIParent, "UIDropDownMenuTemplate")
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
        return
    end

    -- Last resort: just do /who to chat
    DoWho(name, true)
end

-------------------------------------------------
-- Role icon (rounded portrait-role icons, like the LFG tool uses)
-- Applied as a real Texture object on the button's right side.
-------------------------------------------------
-- TexCoords within Interface\LFGFrame\UI-LFG-ICON-PORTRAITROLES (64x64 sheet)
-- left, right, top, bottom (in 0-1)
local ROLE_TCOORDS = {
    TANK    = { 0,     19/64, 22/64, 41/64 },
    HEALER  = { 20/64, 39/64, 1/64,  20/64 },
    DAMAGER = { 20/64, 39/64, 22/64, 41/64 },
    LEADER  = { 0,     19/64, 1/64,  20/64 },
}

local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"

local function ApplyRoleIcon(tex, role)
    local t = ROLE_TCOORDS[role]
    if not t then
        tex:Hide()
        return
    end
    tex:SetTexture(ROLE_TEXTURE)
    tex:SetTexCoord(t[1], t[2], t[3], t[4])
    tex:Show()
end

-- Class display order so same classes group together nicely
local CLASS_ORDER = {
    DEATHKNIGHT = 1, DEMONHUNTER = 2, DRUID = 3, EVOKER = 4,
    HUNTER = 5, MAGE = 6, MONK = 7, PALADIN = 8, PRIEST = 9,
    ROGUE = 10, SHAMAN = 11, WARLOCK = 12, WARRIOR = 13,
}

-------------------------------------------------
-- Popup
-------------------------------------------------
local function CloseCopyPopup(editBox)
    -- Escape should close the copy popup even when the edit box has keyboard focus.
    -- StaticPopup_Hide keeps Blizzard's popup bookkeeping clean; Hide() is fallback.
    if StaticPopup_Hide then
        StaticPopup_Hide("LFG_STANDALONE_COPY")
    elseif editBox and editBox.GetParent then
        local popup = editBox:GetParent()
        if popup then
            popup:Hide()
        end
    end
end

StaticPopupDialogs["LFG_STANDALONE_COPY"] = {
    text = "Copy Name / Link",
    button1 = "Close",
    hasEditBox = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, data)
        local editBox = self.EditBox or self.editBox
        if editBox then
            editBox:SetText(data or "")
            editBox:HighlightText()
            editBox:SetFocus()

            -- Some WoW clients/templates route Escape through the edit box script.
            editBox:SetScript("OnEscapePressed", CloseCopyPopup)
        end
    end,
    -- Some WoW clients/templates route Escape through this StaticPopup callback.
    EditBoxOnEscapePressed = CloseCopyPopup,
}

-------------------------------------------------
-- Main Window
-------------------------------------------------
local frame = CreateFrame("Frame", "LFGcopyFrame", UIParent, "BasicFrameTemplateWithInset")
frame:SetSize(760, 600)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 5, 0)
frame.title:SetText("LFGcopy")
frame:Hide()

-------------------------------------------------
-- Filters (trinket-only toggle + search box)
-------------------------------------------------
local filterTrinketOnly = false
local filterSearch = ""   -- lowercased search string

-- forward declaration so the controls can trigger a rebuild
local RefreshWindow

-------------------------------------------------
-- Options
-------------------------------------------------
-- Optionally persisted to SavedVariables (LFGcopyDB, declared in the .toc):
-- defaults stay live while the addon runs, and the DB only overrides when a
-- key already exists, so adding a new option never wipes old settings.
local db = (type(LFGcopyDB) == "table") and LFGcopyDB or {}
local function Opt(key, default)
    if db[key] == nil then
        db[key] = default
    end
    return db[key]
end

-- 1) On collapse, send the group to the second tab. The old collapsed look
--    disappears entirely: after the header click the group is parked and is
--    only visible on the second tab. Expanding a parked group never sends it
--    back -- the arrow button next to the (+) marker is the only way back.
local optParkOnCollapse = Opt("parkOnCollapse", false)

-- 2) Show the group's leader description/comment even when collapsed (a dim
--    line under the leader row on the first tab).
local optCollapsedDesc = Opt("showCollapsedDescription", true)

-- 3) Quick note per group. The note is always visible on the collapsed row
--    (right of the description area) and as a slim line on expanded rows.
local optQuickNote = Opt("quickNote", false)

-- Show the parked groups tab bar. Turning it off also empties the watch tab
-- (every parked group goes back to the first tab, expanded).
local optSecondTab = Opt("secondTab", true)

-- Which tab is shown. "results" = the normal first tab, "watch" = the second
-- tab that parked groups live on.
local activeTab = "results"

-- Collapsed/expanded state per group. Clicking the leader name toggles this.
-- Keyed mostly by leader name instead of resultID so folded groups stay folded
-- after pressing Blizzard's "Search Again" button, which can assign new resultIDs.
local collapsedGroups = {}

-- Groups parked on the SECOND tab ("Watch"). A group lands here by collapsing
-- it while the "park on collapse" option is on. While parked, the group is
-- NOT shown on the first tab and stays on the second tab no matter what --
-- expanding or collapsing it there only acts on the parked copy. The way back
-- to the first tab is the return-arrow button next to the fold marker on the
-- parked row ("Move all parked groups back" in the options menu does the same
-- for every parked group at once; the menu toggle that hides the watch tab
-- also sends everything back). Like collapsedGroups, entries are keyed by
-- group key (leader name, see below), not resultID, so parked groups stay
-- parked across "Search Again".
local parkedGroups = {}

-- Per-group notes entered by the player. Also keyed by group key. A note is
-- attached to the group listing itself (not the fold state), so it is shown
-- whenever the group is visible, on both tabs, collapsed or not.
local groupNotes = {}

-- "Trinket only" toggle button (vertically centered on the title bar)
local trinketToggle = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
trinketToggle:SetSize(110, 20)
trinketToggle:SetPoint("RIGHT", frame.TitleBg, "RIGHT", -24, 0)

-- Pulsing glow border (4 edge strips) shown only while the filter is ON.
-- A holder frame lets all 4 edges pulse together via one animation group.
local glow = CreateFrame("Frame", nil, trinketToggle)
glow:SetPoint("TOPLEFT", trinketToggle, "TOPLEFT", -2, 2)
glow:SetPoint("BOTTOMRIGHT", trinketToggle, "BOTTOMRIGHT", 2, -2)
glow:Hide()
local function gedge()
    local t = glow:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(1, 0.55, 0, 1)  -- orange
    return t
end
local gThick = 2
local gT, gB, gL, gR = gedge(), gedge(), gedge(), gedge()
gT:SetPoint("TOPLEFT", glow, "TOPLEFT", 0, 0)
gT:SetPoint("TOPRIGHT", glow, "TOPRIGHT", 0, 0)
gT:SetHeight(gThick)
gB:SetPoint("BOTTOMLEFT", glow, "BOTTOMLEFT", 0, 0)
gB:SetPoint("BOTTOMRIGHT", glow, "BOTTOMRIGHT", 0, 0)
gB:SetHeight(gThick)
gL:SetPoint("TOPLEFT", glow, "TOPLEFT", 0, 0)
gL:SetPoint("BOTTOMLEFT", glow, "BOTTOMLEFT", 0, 0)
gL:SetWidth(gThick)
gR:SetPoint("TOPRIGHT", glow, "TOPRIGHT", 0, 0)
gR:SetPoint("BOTTOMRIGHT", glow, "BOTTOMRIGHT", 0, 0)
gR:SetWidth(gThick)

-- pulse animation: fade the whole border in/out forever
local pulse = glow:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(1.0)
fade:SetToAlpha(0.2)
fade:SetDuration(0.6)
fade:SetSmoothing("IN_OUT")

local function UpdateTrinketToggle()
    if filterTrinketOnly then
        trinketToggle:SetText("Trinket: ON")
        glow:Show()
        pulse:Play()
    else
        trinketToggle:SetText("Trinket: Off")
        pulse:Stop()
        glow:Hide()
    end
end

trinketToggle:SetText("Trinket: Off")
trinketToggle:SetScript("OnClick", function(self)
    filterTrinketOnly = not filterTrinketOnly
    UpdateTrinketToggle()
    if RefreshWindow then RefreshWindow() end
end)
trinketToggle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Show only groups with a marked mage")
    GameTooltip:Show()
end)
trinketToggle:SetScript("OnLeave", function() GameTooltip:Hide() end)
UpdateTrinketToggle()

-- Search box (left of the toggle, vertically centered on the title bar)
local searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
searchBox:SetSize(150, 20)
searchBox:SetPoint("RIGHT", trinketToggle, "LEFT", -12, 0)
searchBox:SetAutoFocus(false)
searchBox:SetMaxLetters(40)
searchBox:SetScript("OnTextChanged", function(self)
    filterSearch = (self:GetText() or ""):lower()
    if RefreshWindow then RefreshWindow() end
end)
searchBox:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
end)
searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

-- Placeholder label shown when the box is empty and unfocused
searchBox.placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchBox.placeholder:SetPoint("LEFT", searchBox, "LEFT", 4, 0)
searchBox.placeholder:SetText("Search...")
local function UpdatePlaceholder(self)
    if self:GetText() == "" and not self:HasFocus() then
        self.placeholder:Show()
    else
        self.placeholder:Hide()
    end
end
searchBox:HookScript("OnTextChanged", UpdatePlaceholder)
searchBox:HookScript("OnEditFocusGained", UpdatePlaceholder)
searchBox:HookScript("OnEditFocusLost", UpdatePlaceholder)
UpdatePlaceholder(searchBox)

-------------------------------------------------
-- Single-line text helpers
-------------------------------------------------
-- Reusable, unanchored font strings used purely for measuring text. Font
-- strings that are anchored/layouted can report misleading widths, and
-- reusing one measurer per font keeps SetText churn off the visible frames.
local measureCache = {}
local function GetMeasureFs(fs)
    local fontObj = fs:GetFontObject()
    local tmp = measureCache[fontObj]
    if not tmp then
        tmp = frame:CreateFontString(nil, "ARTWORK")
        if fontObj then
            tmp:SetFontObject(fontObj)
        end
        measureCache[fontObj] = tmp
    end
    return tmp
end

-- Clip a string so it fits a single line at maxW pixels, appending "..."
-- whenever anything had to be cut. Sizes the text by counting code points
-- (never splits a multi-byte UTF-8 character), measures on a private font
-- string, and binary-searches the longest prefix that still fits, so it can
-- never loop forever or cut the text down to nothing.
local function ClipText(fs, s, maxW)
    if not s or s == "" then
        fs:SetText("")
        return
    end
    if not maxW or maxW <= 0 then
        fs:SetText(s)
        return
    end

    local tmp = GetMeasureFs(fs)
    tmp:SetText(s)
    if (tmp:GetStringWidth() or 0) <= maxW then
        fs:SetText(s)   -- fits as-is
        return
    end

    -- Byte offsets where each code point starts, so prefixes always cut at
    -- character boundaries.
    local starts = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b < 128 or b >= 192 then   -- start of a code point
            starts[#starts + 1] = i
        end
    end
    local function Prefix(n)
        if n <= 0 then return "" end
        local stop = starts[n + 1]
        return s:sub(1, (stop and (stop - 1)) or #s)
    end

    tmp:SetText("...")
    local dotW = tmp:GetStringWidth() or 12

    -- Longest prefix whose text + "..." still fits.
    local lo, hi = 1, #starts
    local best = 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        tmp:SetText(Prefix(mid))
        if ((tmp:GetStringWidth() or 0) + dotW) <= maxW then
            best = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    if best == 0 then best = 1 end   -- never collapse down to just "..."

    -- Exact fit check (ellipsis kerning can push the total a pixel or two
    -- over the prefix-only estimate).
    while best > 1 do
        tmp:SetText(Prefix(best) .. "...")
        if (tmp:GetStringWidth() or 0) <= maxW then break end
        best = best - 1
    end

    if best == 1 then
        -- Keep at least one real character before the ellipsis unless the
        -- line is so narrow that even "x..." cannot fit.
        tmp:SetText(Prefix(1) .. "...")
        if (tmp:GetStringWidth() or 0) > maxW then
            fs:SetText("...")
            return
        end
    end

    fs:SetText(Prefix(best) .. "...")
end

-------------------------------------------------
-- Group note popup
-------------------------------------------------
-- Notes are per group key and live in groupNotes above. They are NOT saved
-- to disk on purpose: a note keyed by leader name would otherwise stick
-- around forever, so notes live for the session (like collapse state does).
local function TrimNoteText(s)
    s = s or ""
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function CloseNotePopup()
    if StaticPopup_Hide then
        StaticPopup_Hide("LFGCOPY_GROUP_NOTE")
    end
end

StaticPopupDialogs["LFGCOPY_GROUP_NOTE"] = {
    text = "Note for this group (stays visible on the collapsed row)",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnShow = function(self, data)
        local editBox = self.EditBox or self.editBox
        if editBox then
            editBox:SetMaxLetters(60)
            editBox:SetText((data and data.key and groupNotes[data.key]) or "")
            editBox:HighlightText()
            editBox:SetFocus()
            editBox:SetScript("OnEscapePressed", CloseNotePopup)
        end
    end,
    OnAccept = function(self, data)
        if not data or not data.key then return end
        local editBox = self.EditBox or self.editBox
        local note = TrimNoteText(editBox and editBox:GetText())
        if note == "" then
            groupNotes[data.key] = nil
        else
            groupNotes[data.key] = note
        end
        if RefreshWindow then RefreshWindow() end
    end,
    EditBoxOnEscapePressed = CloseNotePopup,
}

local function ShowGroupNotePopup(key)
    StaticPopup_Show("LFGCOPY_GROUP_NOTE", nil, nil, { key = key })
end

-------------------------------------------------
-- Options menu (right-click the tab strip or click "Options")
-------------------------------------------------
local function ApplyOption(key, value)
    db[key] = value
    if key == "parkOnCollapse" then
        optParkOnCollapse = value
    elseif key == "showCollapsedDescription" then
        optCollapsedDesc = value
    elseif key == "quickNote" then
        optQuickNote = value
    elseif key == "secondTab" then
        optSecondTab = value
        if not value then
            -- Watch tab disabled: every parked group goes home (expanded).
            for k in pairs(parkedGroups) do
                parkedGroups[k] = nil
                collapsedGroups[k] = false
            end
            if activeTab == "watch" then
                activeTab = "results"
            end
        end
    end
end

local function MoveAllParkedBack()
    for k in pairs(parkedGroups) do
        parkedGroups[k] = nil
        collapsedGroups[k] = false   -- they return expanded
    end
    activeTab = "results"
    if RefreshWindow then RefreshWindow() end
end

local function ShowOptionsMenu(anchor)
    -- Modern menu API
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(anchor, function(owner, root)
            -- Only root:CreateButton is guaranteed across clients -- the
            -- TBC Anniversary backport of the menu framework has no
            -- CreateSeparator (calling it errors out), and even the title
            -- is optional, so every extra call is guarded.
            if root.CreateTitle then
                root:CreateTitle("LFGcopy options")
            end
            local function item(text, checked, onClick)
                local mark = checked and "[x]" or "[ ]"
                root:CreateButton(mark .. " " .. text, onClick)
            end
            item("Park collapsed groups on the second tab", optParkOnCollapse,
                function() ApplyOption("parkOnCollapse", not optParkOnCollapse) if RefreshWindow then RefreshWindow() end end)
            item("Show descriptions on collapsed groups", optCollapsedDesc,
                function() ApplyOption("showCollapsedDescription", not optCollapsedDesc) if RefreshWindow then RefreshWindow() end end)
            item("Show group notes", optQuickNote,
                function() ApplyOption("quickNote", not optQuickNote) if RefreshWindow then RefreshWindow() end end)
            item("Show the second tab", optSecondTab,
                function() ApplyOption("secondTab", not optSecondTab) if RefreshWindow then RefreshWindow() end end)
            if next(parkedGroups) then
                root:CreateButton("Move all parked groups back", MoveAllParkedBack)
            end
        end)
        return
    end

    -- Fallback: classic EasyMenu
    if EasyMenu then
        local menu = {
            { text = "LFGcopy options", isTitle = true, notCheckable = true },
            { text = "Park collapsed groups on the second tab", checked = optParkOnCollapse, notCheckable = false, func = function()
                ApplyOption("parkOnCollapse", not optParkOnCollapse)
                if RefreshWindow then RefreshWindow() end
            end },
            { text = "Show descriptions on collapsed groups", checked = optCollapsedDesc, notCheckable = false, func = function()
                ApplyOption("showCollapsedDescription", not optCollapsedDesc)
                if RefreshWindow then RefreshWindow() end
            end },
            { text = "Show group notes", checked = optQuickNote, notCheckable = false, func = function()
                ApplyOption("quickNote", not optQuickNote)
                if RefreshWindow then RefreshWindow() end
            end },
            { text = "Show the second tab", checked = optSecondTab, notCheckable = false, func = function()
                ApplyOption("secondTab", not optSecondTab)
                if RefreshWindow then RefreshWindow() end
            end },
        }
        if next(parkedGroups) then
            menu[#menu + 1] = { text = "Move all parked groups back", notCheckable = true, func = MoveAllParkedBack }
        end
        local menuFrame = LFGCopyMenuFrame or CreateFrame("Frame", "LFGCopyMenuFrame", UIParent, "UIDropDownMenuTemplate")
        EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    end
end

-------------------------------------------------
-- Tab strip ("Results" / "Watch") under the title bar
-------------------------------------------------
-- The second tab ("Watch") holds parked groups. Left-click a tab to switch,
-- right-click the strip (or click "Options") for the options menu above.
local TAB_BAR_H = 22

local tabStrip = CreateFrame("Frame", nil, frame)
tabStrip:SetPoint("TOPLEFT", 12, -32)
tabStrip:SetSize(676, TAB_BAR_H)

-- thin divider under the whole strip
tabStrip.divider = tabStrip:CreateTexture(nil, "BACKGROUND")
tabStrip.divider:SetColorTexture(0.4, 0.4, 0.4, 0.25)
tabStrip.divider:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMLEFT", 0, -2)
tabStrip.divider:SetPoint("BOTTOMRIGHT", tabStrip, "BOTTOMRIGHT", 0, -2)
tabStrip.divider:SetHeight(1)

local function MakeTabButton(name, text)
    local btn = CreateFrame("Button", nil, tabStrip)
    btn.tab = name
    btn:SetSize(100, TAB_BAR_H)
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.label:SetPoint("LEFT", btn, "LEFT", 0, 0)
    btn.label:SetJustifyH("LEFT")
    btn.label:SetText(text)
    btn.activeBar = btn:CreateTexture(nil, "OVERLAY")
    btn.activeBar:SetColorTexture(0.9, 0.82, 0.4, 1)
    btn.activeBar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, -3)
    btn.activeBar:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, -3)
    btn.activeBar:SetHeight(2)
    btn.activeBar:Hide()
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            ShowOptionsMenu(self)
            return
        end
        local tab = self.tab
        if tab == "watch" and not optSecondTab then return end
        if activeTab == tab then return end
        activeTab = tab
        if RefreshWindow then RefreshWindow() end
    end)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.tab == "watch" then
            GameTooltip:AddLine("Second tab: groups you park (collapsed) here", 1, 1, 1)
            GameTooltip:AddLine("Left-click: switch tab", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Right-click: options", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Left-click: switch tab", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Right-click: options", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

local tabResults = MakeTabButton("results", "Results")
tabResults:SetPoint("LEFT", tabStrip, "LEFT", 2, 0)

local tabWatch = MakeTabButton("watch", "Watch")
tabWatch:SetPoint("LEFT", tabResults, "RIGHT", 18, 0)

local optionsButton = CreateFrame("Button", nil, tabStrip)
optionsButton:SetSize(58, 18)
optionsButton:SetPoint("RIGHT", tabStrip, "RIGHT", -2, -1)
optionsButton.text = optionsButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
optionsButton.text:SetPoint("CENTER")
optionsButton.text:SetText("Options")
optionsButton.text:SetTextColor(0.7, 0.7, 0.7)
optionsButton:SetScript("OnClick", function(self)
    ShowOptionsMenu(self)
end)
optionsButton:SetScript("OnEnter", function(self)
    self.text:SetTextColor(1, 1, 1)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("LFGcopy options", 1, 1, 1)
    GameTooltip:AddLine("Click: park-on-collapse, collapsed descriptions, group notes", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end)
optionsButton:SetScript("OnLeave", function(self)
    self.text:SetTextColor(0.7, 0.7, 0.7)
    GameTooltip:Hide()
end)

-- Paints the two tabs after every refresh: label (with live counts), active
-- color/underline, and hides the watch tab while the option is off.
local function UpdateTabStrip(resultCount, parkedCount)
    local function paint(btn, active, text)
        btn.label:SetText(text)
        if active then
            btn.label:SetTextColor(1, 0.85, 0.4)
            btn.activeBar:Show()
        else
            btn.label:SetTextColor(0.62, 0.62, 0.62)
            btn.activeBar:Hide()
        end
    end

    paint(tabResults, activeTab == "results", string.format("Results (%d)", resultCount))
    if optSecondTab then
        tabWatch:Show()
        local watchLabel = parkedCount > 0 and string.format("Watch (%d)", parkedCount) or "Watch"
        paint(tabWatch, activeTab == "watch", watchLabel)
    else
        tabWatch:Hide()
    end
end

-------------------------------------------------
-- Scroll
-------------------------------------------------
local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
-- Leave a little breathing room between the tab divider and the first group.
scroll:SetPoint("TOPLEFT", 10, -(30 + TAB_BAR_H + 10))
scroll:SetPoint("BOTTOMRIGHT", -30, 10)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(700, 1)
scroll:SetScrollChild(content)

-- Friendly hint shown when the second (Watch) tab is empty.
local emptyHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
emptyHint:SetPoint("TOPLEFT", content, "TOPLEFT", 14, -14)
emptyHint:SetWidth(660)
emptyHint:SetJustifyH("LEFT")
emptyHint:SetSpacing(4)
emptyHint:SetTextColor(0.6, 0.6, 0.6)
emptyHint:Hide()

-- Slow mousewheel scrolling to ~50% speed by driving the scrollbar
-- directly (keeps the slider and wheel perfectly in sync).
scroll:EnableMouseWheel(true)
scroll:SetScript("OnMouseWheel", function(self, delta)
    local sb = self.ScrollBar
        or self.scrollbar
        or _G[(self:GetName() or "") .. "ScrollBar"]
    if not sb then return end

    local step = 25  -- half of the usual ~50px wheel step
    local cur = sb:GetValue()
    local minV, maxV = sb:GetMinMaxValues()
    local newV = cur - (delta * step)
    if newV < minV then newV = minV end
    if newV > maxV then newV = maxV end
    sb:SetValue(newV)
end)

-------------------------------------------------
-- Rows (pooled and reused across refreshes for performance)
-------------------------------------------------
local rows = {}          -- all created rows (active + inactive)
local activeRowCount = 0

local function AcquireButton(row, index)
    -- Reuse an existing button on this row, or create one
    row.buttons = row.buttons or {}
    local btn = row.buttons[index]
    if not btn then
        btn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        btn:SetSize(125, 22)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        -- role icon textures, created once, reused
        btn.roleIcons = {}
        for rIdx = 1, 3 do
            local tex = btn:CreateTexture(nil, "OVERLAY")
            tex:SetSize(16, 16)
            if rIdx == 1 then
                tex:SetPoint("RIGHT", btn, "RIGHT", -3, 0)
            else
                tex:SetPoint("RIGHT", btn.roleIcons[rIdx - 1], "LEFT", 0, 0)
            end
            tex:Hide()
            btn.roleIcons[rIdx] = tex
        end

        -- Trinket-owner border (4 edge strips that frame the button so it
        -- reads as a glowing outline rather than a filled backdrop)
        local function edge(self)
            local t = self:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 0.5, 0, 0.9)  -- orange
            t:Hide()
            return t
        end
        btn.glowTop    = edge(btn)
        btn.glowBottom = edge(btn)
        btn.glowLeft   = edge(btn)
        btn.glowRight  = edge(btn)
        local thick = 2
        btn.glowTop:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)
        btn.glowTop:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1)
        btn.glowTop:SetHeight(thick)
        btn.glowBottom:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -1, -1)
        btn.glowBottom:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)
        btn.glowBottom:SetHeight(thick)
        btn.glowLeft:SetPoint("TOPLEFT", btn, "TOPLEFT", -1, 1)
        btn.glowLeft:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", -1, -1)
        btn.glowLeft:SetWidth(thick)
        btn.glowRight:SetPoint("TOPRIGHT", btn, "TOPRIGHT", 1, 1)
        btn.glowRight:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 1, -1)
        btn.glowRight:SetWidth(thick)

        function btn:SetTrinketGlow(show)
            local a = show and 1 or 0
            self.glowTop:SetShown(show)
            self.glowBottom:SetShown(show)
            self.glowLeft:SetShown(show)
            self.glowRight:SetShown(show)
        end

        row.buttons[index] = btn
    end
    return btn
end

local function ReleaseExtraButtons(row, usedCount)
    if not row.buttons then return end
    for i = usedCount + 1, #row.buttons do
        row.buttons[i]:Hide()
    end
end

local function AcquireRow(index)
    local row = rows[index]
    if row then
        row:Show()
        return row
    end

    row = CreateFrame("Frame", nil, content)
    row:SetSize(680, 80)

    if index == 1 then
        row:SetPoint("TOPLEFT", 0, 0)
    else
        row:SetPoint("TOPLEFT", rows[index - 1], "BOTTOMLEFT", 0, -8)
    end

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    if index % 2 == 0 then
        row.bg:SetColorTexture(0.1, 0.1, 0.1, 0.2)
    else
        row.bg:SetColorTexture(0.2, 0.2, 0.2, 0.2)
    end

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    row.text:SetPoint("TOPLEFT", 8, -8)
    row.text:SetWidth(280)
    row.text:SetJustifyH("LEFT")

    -- Invisible clickable area over the leader name.
    -- Click leader once to fold/collapse the group; click again to open it.
    row.headerButton = CreateFrame("Button", nil, row)
    row.headerButton:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -4)
    row.headerButton:SetSize(300, 24)
    row.headerButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.headerButton:SetScript("OnClick", function(self, mouseButton)
        local parent = self:GetParent()
        if not parent then return end

        if mouseButton == "RightButton" then
            OpenWhisper(parent.leaderName)
            return
        end

        local key = parent.groupKey
        if not key then return end

        if parent.entryType == "parked" then
            -- Second tab: the header click only folds/unfolds the parked
            -- copy. It NEVER sends the group back to the first tab -- the
            -- only way back is the return-arrow button next to the marker.
            collapsedGroups[key] = not collapsedGroups[key]
        elseif collapsedGroups[key] then
            -- Collapsed row on the first tab: expand it. (With "park on
            -- collapse" on, collapsed first-tab rows are normally migrated
            -- to the watch tab right away; this path covers the classic
            -- mode and any leftovers from an older session.)
            collapsedGroups[key] = false
        elseif optParkOnCollapse and optSecondTab then
            -- First tab + "park on collapse": collapsing IS the send-to-
            -- second-tab gesture, so the group leaves this tab entirely.
            collapsedGroups[key] = true
            parkedGroups[key] = true
        else
            -- Classic fold: the row stays here, collapsed.
            collapsedGroups[key] = true
        end
        if RefreshWindow then RefreshWindow() end
    end)
    row.headerButton:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if parent then
            if parent.entryType == "parked" then
                if parent.isCollapsed then
                    GameTooltip:AddLine("Left-click: expand this group on the second tab", 1, 1, 1)
                else
                    GameTooltip:AddLine("Left-click: collapse this group (it stays on the second tab)", 1, 1, 1)
                end
            elseif parent.isCollapsed then
                GameTooltip:AddLine("Left-click: expand this group", 1, 1, 1)
            elseif optParkOnCollapse and optSecondTab then
                GameTooltip:AddLine("Left-click: send this group to the second tab", 1, 1, 1)
            else
                GameTooltip:AddLine("Left-click: collapse this group", 1, 1, 1)
            end
        end
        GameTooltip:AddLine("Right-click: whisper leader", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row.headerButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Return-arrow button: the ONLY control that moves a parked group back
    -- to the first tab. It sits just left of the fold marker ("near the
    -- plus"), and is shown only on parked rows (second tab). A full-size
    -- button look with a padded click area -- a tiny 16px target was too
    -- easy to miss.
    row.returnButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.returnButton:SetSize(24, 20)
    row.returnButton:SetPoint("TOPLEFT", row, "TOPLEFT", 4, -5)
    row.returnButton:RegisterForClicks("LeftButtonUp")
    if row.returnButton.SetHitRectInsets then
        pcall(function()
            row.returnButton:SetHitRectInsets(-4, -4, -4, -3)
        end)
    end
    row.returnButton:SetText("^")
    row.returnButton:GetFontString():SetTextColor(0.9, 0.82, 0.4)
    row.returnButton:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent and parent.groupKey then
            parkedGroups[parent.groupKey] = nil
            collapsedGroups[parent.groupKey] = false   -- returns expanded
            if RefreshWindow then RefreshWindow() end
        end
    end)
    row.returnButton:SetScript("OnEnter", function(self)
        self:GetFontString():SetTextColor(1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Move this group back to the first tab (expanded)", 1, 1, 1)
        GameTooltip:AddLine("Only this button moves it back -- expanding does not", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row.returnButton:SetScript("OnLeave", function(self)
        self:GetFontString():SetTextColor(0.9, 0.82, 0.4)
        GameTooltip:Hide()
    end)
    row.returnButton:Hide()

    -- Note line (clickable). Shown when the notes option is on: on collapsed
    -- rows it shares the description line (right side), on expanded rows it
    -- is a slim line under the description. Clicking it opens the note popup.
    row.noteButton = CreateFrame("Button", nil, row)
    row.noteButton:SetHeight(14)
    row.noteButton:RegisterForClicks("LeftButtonUp")
    row.noteButton.text = row.noteButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.noteButton.text:SetPoint("RIGHT", row.noteButton, "RIGHT", -2, 0)
    row.noteButton.text:SetJustifyH("RIGHT")
    row.noteButton:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        if parent and parent.groupKey then
            ShowGroupNotePopup(parent.groupKey)
        end
    end)
    row.noteButton:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if parent and parent.groupKey and groupNotes[parent.groupKey] then
            GameTooltip:AddLine("Note for this group:", 1, 1, 1)
            GameTooltip:AddLine(groupNotes[parent.groupKey], 1, 0.82, 0.4, true)
            GameTooltip:AddLine("Left-click: edit the note", 0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Left-click: add a note to this group", 1, 1, 1)
            GameTooltip:AddLine("The note stays visible even when the group is collapsed", 0.7, 0.7, 0.7)
        end
        GameTooltip:Show()
    end)
    row.noteButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.noteButton:Hide()

    -- Activity / what the group is listed for (right of the leader name).
    row.activity = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    row.activity:SetPoint("TOPLEFT", row.text, "TOPRIGHT", 8, 0)
    row.activity:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.activity:SetJustifyH("LEFT")
    row.activity:SetJustifyV("TOP")
    row.activity:SetTextColor(0.9, 0.82, 0.4)
    row.activity:SetWordWrap(true)

    -- Description / comment (below the leader name) — display only.
    -- (The comment is Blizzard's protected secret string; it renders as
    -- readable text but cannot be copied out programmatically.)
    row.desc = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    row.desc:SetPoint("TOPLEFT", row.text, "BOTTOMLEFT", 0, -2)
    row.desc:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.desc:SetJustifyH("LEFT")
    row.desc:SetJustifyV("TOP")
    row.desc:SetTextColor(0.75, 0.75, 0.75)
    row.desc:SetWordWrap(true)

    row.buttons = {}

    rows[index] = row
    return row
end

local function ReleaseExtraRows(usedCount)
    for i = usedCount + 1, #rows do
        rows[i]:Hide()
    end
end

-------------------------------------------------
-- Get names + classes
-------------------------------------------------
-- Work out a single role for a search-result player, matching how the
-- LFG tool itself prioritizes when a player is flagged for more than one
-- role: Tank first, then Healer, then Damage. We check the self-selected
-- tank/healer/damage flags FIRST and only fall back to assignedRole if
-- none of them are set. assignedRole reflects an already-formed group's
-- assignment, not what a solo-queued applicant flagged themselves as, and
-- trusting it first was causing DPS to show even for tank/healer-only
-- applicants whenever it came back populated but stale/wrong.
local function IsRoleFlagSet(v)
    -- Treat nil, false, and 0 all as "not set". Lua only treats nil/false as
    -- falsy, so a numeric 0 (which some API variants return instead of a
    -- real boolean) would otherwise be misread as "selected".
    return v == true or (type(v) == "number" and v ~= 0)
end

local function GetPlayerRoleFlags(player)
    if not player then return {} end
    local flags = {}
    local hasTank, hasHealer, hasDamage = false, false, false

    -- Check direct boolean flags
    if IsRoleFlagSet(player.tank) or IsRoleFlagSet(player.isTank) then hasTank = true end
    if IsRoleFlagSet(player.healer) or IsRoleFlagSet(player.isHealer) then hasHealer = true end
    if IsRoleFlagSet(player.damage) or IsRoleFlagSet(player.isDamage) or IsRoleFlagSet(player.damager) or IsRoleFlagSet(player.isDamager) or IsRoleFlagSet(player.dps) then hasDamage = true end
    
    -- Check lfgRoles sub-table (used by TBC Anniversary for solo listings)
    if player.lfgRoles then
        if IsRoleFlagSet(player.lfgRoles.tank) then hasTank = true end
        if IsRoleFlagSet(player.lfgRoles.healer) then hasHealer = true end
        if IsRoleFlagSet(player.lfgRoles.dps) or IsRoleFlagSet(player.lfgRoles.damage) then hasDamage = true end
    end
    
    if hasTank then table.insert(flags, "TANK") end
    if hasHealer then table.insert(flags, "HEALER") end
    if hasDamage then table.insert(flags, "DAMAGER") end

    return flags
end

local function GetPlayerBaseRole(player)
    if not player then return nil end
    if type(player.role) == "string" and player.role ~= "" then return player.role end
    if player.assignedRole and player.assignedRole ~= "" then return player.assignedRole end
    return nil
end

local function GetPlayers(resultID, leaderName)
    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info then
        return {}
    end

    local players = {}

    for i = 1, (info.numMembers or 0) do
        local player = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
        if player and player.name then
            local clean = Ambiguate(player.name, "none")
            local exists = false
            for _, v in ipairs(players) do
                if v.name == clean then
                    exists = true
                    break
                end
            end
            if not exists then
                local finalRoles = {}
                local isSolo = (info.numMembers or 0) <= 1
                
                if not isSolo then
                    -- In a group, a player occupies exactly ONE assigned role.
                    -- Prioritize their explicit assigned base role so we don't show all the multi-roles they CAN play.
                    local r = GetPlayerBaseRole(player)
                    if not r and C_LFGList.GetSearchResultMemberInfo then
                        local memberInfoRole = C_LFGList.GetSearchResultMemberInfo(resultID, i)
                        if type(memberInfoRole) == "string" and memberInfoRole ~= "" then r = memberInfoRole end
                    end
                    if r then
                        table.insert(finalRoles, r)
                    else
                        finalRoles = GetPlayerRoleFlags(player)
                    end
                else
                    -- For solo listings, we WANT to see all the multi-roles they queued with.
                    finalRoles = GetPlayerRoleFlags(player)
                    
                    -- Sometimes solo listed players have their queued roles on the leader info.
                    if #finalRoles == 0 and i == 1 then
                        local leader = C_LFGList.GetSearchResultLeaderInfo and C_LFGList.GetSearchResultLeaderInfo(resultID)
                        finalRoles = GetPlayerRoleFlags(leader)
                    end

                    -- If STILL no explicit flags, and they are the ONLY player in the group,
                    -- we can deduce their queued roles directly from the group's MemberCounts!
                    if #finalRoles == 0 and C_LFGList.GetSearchResultMemberCounts then
                        local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
                        if counts then
                            if (counts.TANK or 0) > 0 then table.insert(finalRoles, "TANK") end
                            if (counts.HEALER or 0) > 0 then table.insert(finalRoles, "HEALER") end
                            if (counts.DAMAGER or 0) > 0 then table.insert(finalRoles, "DAMAGER") end
                        end
                    end

                    -- Fallback to the base .role or .assignedRole string
                    if #finalRoles == 0 then
                        local r = GetPlayerBaseRole(player)
                        if r then table.insert(finalRoles, r) end
                    end

                    -- Fallback to MemberInfo (returns multiple values, first is role string)
                    if #finalRoles == 0 and C_LFGList.GetSearchResultMemberInfo then
                        local r = C_LFGList.GetSearchResultMemberInfo(resultID, i)
                        if type(r) == "string" and r ~= "" then table.insert(finalRoles, r) end
                    end
                    
                    -- Fallback to leader base role
                    if #finalRoles == 0 and i == 1 then
                        local leader = C_LFGList.GetSearchResultLeaderInfo and C_LFGList.GetSearchResultLeaderInfo(resultID)
                        local r = GetPlayerBaseRole(leader)
                        if r then table.insert(finalRoles, r) end
                    end
                end

                table.insert(players, {
                    name = clean,
                    class = player.classFilename,
                    roles = finalRoles,
                })
            end
        end
    end

    -- Fallback leader (if info.numMembers was completely missing/0)
    if #players == 0 then
        local leader = C_LFGList.GetSearchResultLeaderInfo(resultID)
        if leader and leader.name then
            local finalRoles = GetPlayerRoleFlags(leader)
            
            if #finalRoles == 0 and C_LFGList.GetSearchResultMemberCounts then
                local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
                if counts then
                    if (counts.TANK or 0) > 0 then table.insert(finalRoles, "TANK") end
                    if (counts.HEALER or 0) > 0 then table.insert(finalRoles, "HEALER") end
                    if (counts.DAMAGER or 0) > 0 then table.insert(finalRoles, "DAMAGER") end
                end
            end

            if #finalRoles == 0 then
                local r = GetPlayerBaseRole(leader)
                if r then table.insert(finalRoles, r) end
            end
            if #finalRoles == 0 and C_LFGList.GetSearchResultMemberInfo then
                local r = C_LFGList.GetSearchResultMemberInfo(resultID, 1)
                if type(r) == "string" and r ~= "" then table.insert(finalRoles, r) end
            end
            table.insert(players, {
                name = Ambiguate(leader.name, "none"),
                class = leader.classFilename,
                roles = finalRoles,
            })
        end
    end

    -- Keep the raid/group leader first, then keep classes together,
    -- then sort names alphabetically within each class.
    local leaderKey = NormalizeName(leaderName)
    table.sort(players, function(a, b)
        local aIsLeader = leaderKey and NormalizeName(a.name) == leaderKey
        local bIsLeader = leaderKey and NormalizeName(b.name) == leaderKey
        if aIsLeader ~= bIsLeader then
            return aIsLeader
        end

        local oa = (a.class and CLASS_ORDER[a.class]) or 99
        local ob = (b.class and CLASS_ORDER[b.class]) or 99
        if oa ~= ob then
            return oa < ob
        end
        return a.name:lower() < b.name:lower()
    end)

    return players
end

-------------------------------------------------
-- Dungeon / raid name abbreviations
-------------------------------------------------
-- Table is keyed on the dungeon/raid name (lowercase, matched case-
-- insensitively and as a substring anywhere in the text -- see
-- AbbreviateMentions below). Uses the most common shorthand used by the
-- TBC classic community (checked against community abbreviation lists),
-- picking forms that avoid collisions -- e.g. Sethekk Halls is "SH" and
-- The Shattered Halls is "ShH", since "SH" is the far more common
-- shorthand for Sethekk.
local ACTIVITY_ABBREV = {
    -- Hellfire Citadel
    ["hellfire ramparts"]      = "HFR",
    ["blood furnace"]          = "BF",
    ["shattered halls"]        = "ShH",
    -- Coilfang Reservoir
    ["slave pens"]             = "SP",
    ["underbog"]               = "UB",
    ["steamvault"]             = "SV",
    -- Auchindoun
    ["mana-tombs"]             = "MT",
    ["mana tombs"]             = "MT",
    ["auchenai crypts"]        = "AC",
    ["sethekk halls"]          = "SH",
    ["shadow labyrinth"]       = "SL",
    -- Caverns of Time
    ["old hillsbrad foothills"] = "OHF",
    ["escape from durnholde"]  = "OHF",
    ["black morass"]           = "BM",
    ["opening the dark portal"] = "BM",
    -- Tempest Keep (5-man) / Netherstorm
    ["mechanar"]               = "Mech",
    ["botanica"]               = "Bot",
    ["arcatraz"]               = "Arc",
    -- Isle of Quel'Danas
    ["magisters' terrace"]     = "MgT",
    ["magisters terrace"]      = "MgT",
    -- Raids
    ["karazhan"]               = "Kara",
    ["gruul's lair"]           = "Gruul",
    ["gruuls lair"]            = "Gruul",
    ["magtheridon's lair"]     = "Mag",
    ["magtheridons lair"]      = "Mag",
    ["serpentshrine cavern"]   = "SSC",
    ["tempest keep"]           = "TK",
    ["the eye"]                = "TK",
    ["battle for mount hyjal"] = "Hyjal",
    ["mount hyjal"]            = "Hyjal",
    ["black temple"]           = "BT",
    ["sunwell plateau"]        = "SWP",
    ["zul'aman"]               = "ZA",
    ["zulaman"]                = "ZA",
}

-- Case-insensitive-pattern builder: turns a plain lowercase key like
-- "mana-tombs" into a Lua pattern that matches it regardless of case,
-- e.g. "[Mm][Aa][Nn][Aa]%-[Tt][Oo][Mm][Bb][Ss]" (magic characters escaped).
local PATTERN_MAGIC = "^$()%.[]*+-?"
local function BuildCiPattern(key)
    local out = {}
    for i = 1, #key do
        local c = key:sub(i, i)
        if c:match("%a") then
            out[#out + 1] = "[" .. c:lower() .. c:upper() .. "]"
        elseif PATTERN_MAGIC:find(c, 1, true) then
            out[#out + 1] = "%" .. c
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

-- Built once, longest key first so e.g. "shattered halls" is matched as a
-- whole rather than accidentally letting a shorter overlapping key win.
local SORTED_ABBREV_KEYS = {}
for key in pairs(ACTIVITY_ABBREV) do
    SORTED_ABBREV_KEYS[#SORTED_ABBREV_KEYS + 1] = key
end
table.sort(SORTED_ABBREV_KEYS, function(a, b) return #a > #b end)

local ABBREV_PATTERNS = {}
for _, key in ipairs(SORTED_ABBREV_KEYS) do
    ABBREV_PATTERNS[key] = BuildCiPattern(key)
end

-- Scans ANY text -- a structured activity name ("Heroic: The Shattered
-- Halls") or a leader's free-typed listing title ("LFM sethekk hc need
-- tank") -- and replaces every recognized dungeon/raid name with its short
-- tag, appending "*" to it if the text mentions "heroic" anywhere (then
-- strips the now-redundant word "heroic" itself). Text that doesn't match
-- anything in the table passes through completely untouched.
local function AbbreviateMentions(text)
    if not text or text == "" then return text end

    text = text:gsub("\226\128\153", "'")  -- normalize curly apostrophe to straight
    
    -- Strip common Blizzard area prefixes first (case-insensitive via character classes)
    -- Handles formats like "Area Name: Dungeon", "Area Name - Dungeon", etc.
    -- We require a colon or hyphen so we don't accidentally erase the entire text if the user just queued for "Tempest Keep" (The Eye).
    text = text:gsub("[Hh][Ee][Ll][Ll][Ff][Ii][Rr][Ee]%s+[Cc][Ii][Tt][Aa][Dd][Ee][Ll]%s*[:-]+%s*", "")
    text = text:gsub("[Cc][Oo][Ii][Ll][Ff][Aa][Nn][Gg]%s+[Rr][Ee][Ss][Ee][Rr][Vv][Oo][Ii][Rr]%s*[:-]+%s*", "")
    text = text:gsub("[Cc][Oo][Ii][Ll][Ff][Aa][Nn][Gg]%s*[:-]+%s*", "") -- sometimes just Coilfang
    text = text:gsub("[Aa][Uu][Cc][Hh][Ii][Nn][Dd][Oo][Uu][Nn]%s*[:-]+%s*", "")
    text = text:gsub("[Cc][Aa][Vv][Ee][Rr][Nn][Ss]%s+[Oo][Ff]%s+[Tt][Ii][Mm][Ee]%s*[:-]+%s*", "")
    text = text:gsub("[Tt][Ee][Mm][Pp][Ee][Ss][Tt]%s+[Kk][Ee][Ee][Pp]%s*[:-]+%s*", "")

    local isHeroic = text:lower():find("heroic", 1, true) ~= nil

    local out = text
    for _, key in ipairs(SORTED_ABBREV_KEYS) do
        local abbr = ACTIVITY_ABBREV[key]
        local replacement = isHeroic and (abbr .. "*") or abbr
        out = out:gsub(ABBREV_PATTERNS[key], replacement)
    end

    if isHeroic then
        out = out:gsub("%(%s*[Hh]eroic%s*%)", "")
        out = out:gsub("[Hh]eroic%s*:?%s*", "")
        out = out:gsub("%s+", " ")
        out = out:gsub("^%s+", ""):gsub("%s+$", "")
    end

    return out
end

-------------------------------------------------
-- Build groups
-------------------------------------------------
local function BuildGroups()
    local groups = {}
    local count, results = C_LFGList.GetSearchResults()
    if not results then
        return groups
    end

    for _, resultID in ipairs(results) do
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if info and not info.isDelisted then
            local leaderName = "Unknown"
            local leader = C_LFGList.GetSearchResultLeaderInfo(resultID)
            if leader and leader.name then
                leaderName = Ambiguate(leader.name, "none")
            end

            -- What the group is listed for.
            -- activityIDs (plural array, 11.0.7+) can contain several
            -- activities. Collect all of their names, deduped.
            local listed = ""
            local ids = {}
            if info.activityIDs then
                for _, v in ipairs(info.activityIDs) do
                    ids[#ids + 1] = v
                end
            elseif info.activityID then
                ids[1] = info.activityID
            end

            local names = {}
            local seen = {}
            for _, aid in ipairs(ids) do
                local n
                if C_LFGList.GetActivityInfoTable then
                    local act = C_LFGList.GetActivityInfoTable(aid, nil, info.isWarMode)
                    if act then
                        n = act.fullName or act.shortName
                    end
                end
                if (not n or n == "") and C_LFGList.GetActivityInfo then
                    n = C_LFGList.GetActivityInfo(aid)
                end
                if n and n ~= "" then
                    n = AbbreviateMentions(n)
                    if not seen[n] then
                        seen[n] = true
                        names[#names + 1] = n
                    end
                end
            end
            listed = table.concat(names, ", ")

            -- Append the leader's custom title if present and different
            local title = info.name
            if title and title ~= "" then
                title = AbbreviateMentions(title)
                if listed == "" then
                    listed = title
                elseif not listed:find(title, 1, true) then
                    listed = listed .. " | " .. title
                end
            end

            -- Resolve players now so filters can use them, and flag trinket owners
            local players = GetPlayers(resultID, leaderName)
            local hasTrinket = false
            for _, p in ipairs(players) do
                if p.class == "MAGE" and OwnsTrinket(p.name) then
                    hasTrinket = true
                    break
                end
            end

            local primaryRoleWeight = 4
            if (info.numMembers or 0) == 1 and players[1] and players[1].roles then
                local hasT, hasH, hasD = false, false, false
                for _, r in ipairs(players[1].roles) do
                    if r == "TANK" then hasT = true end
                    if r == "HEALER" then hasH = true end
                    if r == "DAMAGER" then hasD = true end
                end
                if hasT then primaryRoleWeight = 1
                elseif hasH then primaryRoleWeight = 2
                elseif hasD then primaryRoleWeight = 3
                end
            end

            -- Stable key for collapse state. LFG resultID can change after "Search Again",
            -- but the same group leader normally stays the same.
            local foldKey = (leaderName ~= "Unknown" and NormalizeName(leaderName)) or tostring(resultID)

            table.insert(groups, {
                resultID = resultID,
                foldKey = foldKey,
                leader = leaderName,
                members = info.numMembers or 0,
                listed = listed or "",
                description = info.comment or "",
                players = players,
                hasTrinket = hasTrinket,
                primaryRoleWeight = primaryRoleWeight,
            })
        end
    end

    table.sort(groups, function(a, b)
        if a.members ~= b.members then
            return a.members > b.members
        end
        if a.members == 1 then
            if a.primaryRoleWeight ~= b.primaryRoleWeight then
                return a.primaryRoleWeight < b.primaryRoleWeight
            end
        end
        return a.leader:lower() < b.leader:lower()
    end)

    return groups
end

-------------------------------------------------
-- Request full member info for every result
-- This is what fixes "not all members show on first scan".
-- The detailed roster is fetched lazily, so we ask for it
-- and rebuild when LFG_LIST_SEARCH_RESULT_UPDATED fires.
-------------------------------------------------
local function RequestAllMemberInfo()
    local count, results = C_LFGList.GetSearchResults()
    if not results then return end
    for _, resultID in ipairs(results) do
        if C_LFGList.RequestSearchResultMemberInfo then
            C_LFGList.RequestSearchResultMemberInfo(resultID)
        end
    end
end

-------------------------------------------------
-- Refresh
-------------------------------------------------
-- Returns true if a group passes the active filters
local function GroupMatchesFilters(group)
    if filterTrinketOnly and not group.hasTrinket then
        return false
    end
    if filterSearch ~= "" then
        local s = filterSearch
        -- match leader, activity, description, or any member name
        if (group.leader or ""):lower():find(s, 1, true) then return true end
        if (group.listed or ""):lower():find(s, 1, true) then return true end
        if (group.description or ""):lower():find(s, 1, true) then return true end
        for _, p in ipairs(group.players or {}) do
            if (p.name or ""):lower():find(s, 1, true) then return true end
        end
        return false
    end
    return true
end

local trinketAnnounced = false
function RefreshWindow()
    BuildTrinketSet()
    if not trinketAnnounced then
        trinketAnnounced = true
        if trinketCount > 0 then
            print(string.format(
                "|cff00ff00[LFGCopy]|r loaded %d marked mages from %s.",
                trinketCount, TRINKET_DB_GLOBAL))
        else
            print(string.format(
                "|cffff8800[LFGCopy]|r couldn't find the mage list (%s). Is MageFinder enabled?",
                TRINKET_DB_GLOBAL))
        end
    end
    local groups = BuildGroups()

    -- With "park on collapse" on, EVERY collapsed group belongs on the second
    -- tab. This migrates groups that were collapsed earlier (classic mode or
    -- a previous session) the moment the option is on.
    if optParkOnCollapse then
        for key, collapsed in pairs(collapsedGroups) do
            if collapsed then
                parkedGroups[key] = true
            end
        end
    end

    -- Tab strip counts (all results, before search/trinket filters)
    local resultCount, parkedCount = 0, 0
    for _, group in ipairs(groups) do
        local key = group.foldKey or group.resultID or group.leader
        if parkedGroups[key] then
            parkedCount = parkedCount + 1
        else
            resultCount = resultCount + 1
        end
    end
    UpdateTabStrip(resultCount, parkedCount)

    local perRow = 5
    local buttonWidth = 125
    local buttonHeight = 22
    local spacingX = 6
    local spacingY = 4
    local startX = 8

    -- Decide which groups the ACTIVE tab lists. Parked groups live only on
    -- the second tab; every other group only on the first. Filters apply to
    -- whichever tab is open, so row indices stay contiguous.
    local shown = {}
    for _, group in ipairs(groups) do
        local key = group.foldKey or group.resultID or group.leader
        local isParked = parkedGroups[key] and true or false
        local onActiveTab = false
        if activeTab == "watch" then
            onActiveTab = isParked
        else
            onActiveTab = not isParked
        end
        if onActiveTab and GroupMatchesFilters(group) then
            group.groupKey = key
            group.isParked = isParked
            shown[#shown + 1] = group
        end
    end

    -- Hint for the (empty) watch tab
    if activeTab == "watch" and #shown == 0 then
        emptyHint:SetText(
            "No groups on the Watch tab yet.\n\n" ..
            "With \"Park collapsed groups on the second tab\" enabled (Options button, top right of this strip),\n" ..
            "collapsing ANY group on the Results tab moves it here instead. While a group is here you can\n" ..
            "collapse or expand it freely. To send one back, press the ^ arrow next to its [+] marker\n" ..
            "(or use \"Move all parked groups back\" in the options menu).")
        emptyHint:Show()
    else
        emptyHint:Hide()
    end

    for rowIndex, group in ipairs(shown) do
        local row = AcquireRow(rowIndex)
        row.groupKey = group.groupKey
        row.leaderName = group.leader
        row.entryType = group.isParked and "parked" or "main"
        row.isCollapsed = collapsedGroups[row.groupKey] or false

        local desc = group.description or ""
        local note = optQuickNote and (groupNotes[row.groupKey] or "") or ""
        local foldMarker = row.isCollapsed and "+" or "-"

        -- Parked rows make room for the return-arrow button at the left edge
        -- ("near the plus"); the header click area follows the text so the
        -- button never covers it.
        row.returnButton:SetShown(group.isParked)
        row.text:ClearAllPoints()
        row.text:SetPoint("TOPLEFT", row, "TOPLEFT", group.isParked and 36 or 8, -8)
        row.headerButton:ClearAllPoints()
        row.headerButton:SetPoint("TOPLEFT", row, "TOPLEFT", group.isParked and 36 or 4, -4)
        row.headerButton:SetWidth(group.isParked and 310 or 300)
        row.text:SetText(string.format("[%s] %s (%d)", foldMarker, group.leader, group.members))
        row.activity:SetText(group.listed ~= "" and ("- " .. group.listed) or "")

        -- Top block = leader line beside the (possibly wrapped) activity.
        local topH = math.max(row.text:GetStringHeight() or 0, row.activity:GetStringHeight() or 0, 18)

        -- Y position of the line right under the leader/activity block.
        local line2Top = -(8 + topH + 2)

        if row.isCollapsed then
            -- Collapsed group: only the header, plus (optionally) the leader
            -- description and the always-visible note on a shared second line.
            ReleaseExtraButtons(row, 0)

            local showDescLine = (optCollapsedDesc and desc ~= "")
            row.desc:SetWordWrap(false)

            -- Note first so the description can size itself next to it.
            if optQuickNote then
                local noteLabel = note ~= "" and note or "Add note..."
                row.noteButton:Show()
                ClipText(row.noteButton.text, noteLabel, 380)
                row.noteButton:SetWidth((row.noteButton.text:GetStringWidth() or 0) + 8)
                row.noteButton:ClearAllPoints()
                row.noteButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, line2Top)
                if note == "" then
                    row.noteButton.text:SetTextColor(0.5, 0.5, 0.5)
                else
                    row.noteButton.text:SetTextColor(1, 1, 1)
                end
            else
                row.noteButton:Hide()
            end

            if showDescLine then
                row.desc:Show()
                row.desc:ClearAllPoints()
                row.desc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, line2Top)
                local descMaxW
                if optQuickNote then
                    row.desc:SetPoint("RIGHT", row.noteButton, "LEFT", -8)
                    descMaxW = 680 - 8 - 8 - (row.noteButton:GetWidth() + 8)
                else
                    row.desc:SetPoint("RIGHT", row, "RIGHT", -8)
                    descMaxW = 680 - 16
                end
                row.desc:SetTextColor(0.62, 0.62, 0.62)
                ClipText(row.desc, desc, descMaxW)
            else
                row.desc:Hide()
            end

            -- Second line present only when something is drawn on it.
            if showDescLine or optQuickNote then
                row:SetHeight(8 + topH + 2 + 16 + 8)
            else
                row:SetHeight(8 + topH + 8)
            end
        else
            -- Expanded group: show description/comment and all player buttons.
            row.desc:Show()
            row.desc:SetWordWrap(true)
            row.desc:SetTextColor(0.75, 0.75, 0.75)

            -- Description / comment (display only)
            row.desc:SetText(desc)

            local players = group.players or {}

            -- Re-anchor the description below whichever is taller (leader line
            -- or the wrapped activity list) so they never overlap.
            row.desc:ClearAllPoints()
            row.desc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, line2Top)
            row.desc:SetPoint("RIGHT", row, "RIGHT", -8, 0)

            local descH = 0
            if desc ~= "" then
                descH = (row.desc:GetStringHeight() or 12) + 4
            end

            -- Note line (only while the notes option is on): a slim, dim,
            -- right-aligned row under the description. Click it to add/edit.
            local noteH = 0
            if optQuickNote then
                row.noteButton:Show()
                if note == "" then
                    row.noteButton.text:SetText("Add a note...")
                    row.noteButton.text:SetTextColor(0.45, 0.45, 0.45)
                else
                    row.noteButton.text:SetText(note)
                    row.noteButton.text:SetTextColor(1, 1, 1)
                end
                ClipText(row.noteButton.text, row.noteButton.text:GetText(), 500)
                row.noteButton:SetWidth((row.noteButton.text:GetStringWidth() or 0) + 8)
                row.noteButton:ClearAllPoints()
                row.noteButton:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, line2Top - descH - 4)
                noteH = 20
            else
                row.noteButton:Hide()
            end

            local headerOffset = 8 + topH + 2 + descH + noteH + 8
            local startY = -headerOffset

            local currentRow = 0
            local currentCol = 0

            for i, player in ipairs(players) do
                local btn = AcquireButton(row, i)
                btn:Show()

                local x = startX + (currentCol * (buttonWidth + spacingX))
                local y = startY - (currentRow * (buttonHeight + spacingY))
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", row, "TOPLEFT", x, y)
                btn:SetText(player.name)

                local fs = btn:GetFontString()
                if player.class and CLASS_COLORS[player.class] then
                    local c = CLASS_COLORS[player.class]
                    fs:SetTextColor(c.r, c.g, c.b)
                else
                    fs:SetTextColor(1, 1, 1)
                end

                -- Role icons (reused textures)
                local roles = player.roles or {}
                if #roles == 0 and player.role then
                    roles = {player.role}
                end

                local activeIcons = 0
                -- We build from right-to-left (roleIcons[1] is rightmost).
                -- To maintain a visual left-to-right priority (Tank -> Heal -> DPS),
                -- we assign the highest priority roles to the leftmost available slot
                -- by iterating the roles array backwards.
                for rIdx = #roles, 1, -1 do
                    local r = roles[rIdx]
                    if r and activeIcons < 3 then
                        activeIcons = activeIcons + 1
                        ApplyRoleIcon(btn.roleIcons[activeIcons], r)
                    end
                end

                for rIdx = activeIcons + 1, 3 do
                    btn.roleIcons[rIdx]:Hide()
                end

                if activeIcons > 0 then
                    fs:ClearAllPoints()
                    fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                    fs:SetPoint("RIGHT", btn.roleIcons[activeIcons], "LEFT", -2, 0)
                    fs:SetJustifyH("LEFT")
                else
                    for rIdx = 1, 3 do btn.roleIcons[rIdx]:Hide() end
                    fs:ClearAllPoints()
                    fs:SetPoint("LEFT", btn, "LEFT", 4, 0)
                    fs:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
                    fs:SetJustifyH("CENTER")
                end

                -- Trinket owner marking (orange border glow)
                local owns = player.class == "MAGE" and OwnsTrinket(player.name)
                btn.ownsTrinket = owns
                btn:SetTrinketGlow(owns)

                -- Store current player so handlers always use fresh data
                btn.playerName = player.name

                btn:SetScript("OnClick", function(self, mouseButton)
                    if mouseButton == "RightButton" then
                        if IsShiftKeyDown() then
                            ShowPlayerMenu(self, self.playerName)
                        else
                            DoWho(self.playerName, true)
                        end
                    elseif IsShiftKeyDown() then
                        -- Shift+Left-click: show a copy box with the player's WarcraftLogs URL.
                        -- WoW addons cannot open browser links directly, so this lets you copy it.
                        StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, GetWCLLink(self.playerName))
                    else
                        -- Left-click: show a copy box with just the player name.
                        StaticPopup_Show("LFG_STANDALONE_COPY", nil, nil, self.playerName)
                    end
                end)

                btn:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:AddLine(self.playerName, 1, 1, 1)
                    if self.ownsTrinket then
                        GameTooltip:AddLine("Owns the trinket", 1, 0.5, 0)
                    end
                    GameTooltip:AddLine("Left-click: copy name", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Shift+Left-click: copy WarcraftLogs link", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Right-click: /who (to chat)", 0.7, 0.7, 0.7)
                    GameTooltip:AddLine("Shift+Right-click: menu (WarcraftLogs, /who...)", 0.7, 0.7, 0.7)
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                currentCol = currentCol + 1
                if currentCol >= perRow then
                    currentCol = 0
                    currentRow = currentRow + 1
                end
            end

            -- Hide any leftover buttons from a previous, larger group
            ReleaseExtraButtons(row, #players)

            local neededRows = math.ceil(#players / perRow)
            row:SetHeight(headerOffset + 8 + (neededRows * (buttonHeight + spacingY)))
        end
    end

    -- Hide rows we didn't use this pass
    ReleaseExtraRows(#shown)
    activeRowCount = #shown

    local totalHeight = 0
    for i = 1, activeRowCount do
        totalHeight = totalHeight + rows[i]:GetHeight() + 8
    end
    if emptyHint:IsShown() then
        -- make room for the multi-line hint on the empty watch tab
        content:SetHeight(140)
    else
        content:SetHeight(totalHeight + 20)
    end

    -- Nudge the template so the scrollbar range recalculates from the
    -- new content height (otherwise the wheel can clamp too early).
    if scroll.UpdateScrollChildRect then
        scroll:UpdateScrollChildRect()
    end
    local sb = scroll.ScrollBar or scroll.scrollbar
        or _G[(scroll:GetName() or "") .. "ScrollBar"]
    if sb then
        local cur = sb:GetValue()
        sb:SetValue(0)
        sb:SetValue(cur)
    end
end

-------------------------------------------------
-- Throttled refresh so multiple incoming events
-- don't rebuild the whole window dozens of times
-------------------------------------------------
local pendingRefresh = false
local function ScheduleRefresh()
    if not frame:IsShown() then return end
    if pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(0.3, function()
        pendingRefresh = false
        if frame:IsShown() then
            RefreshWindow()
        end
    end)
end

-------------------------------------------------
-- Toggle / Slash Command / Keybind
-------------------------------------------------
function ToggleLFGCopy()
    -- If chat/search/copy edit boxes have focus, release it so the keybind behaves consistently.
    if GetCurrentKeyBoardFocus then
        local focus = GetCurrentKeyBoardFocus()
        if focus and focus.ClearFocus then
            focus:ClearFocus()
        end
    end

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        RequestAllMemberInfo()
        RefreshWindow()
    end
end

SLASH_LFGCOPY1 = "/lfgcopy"
SlashCmdList["LFGCOPY"] = ToggleLFGCopy

-- Debug helper: dumps the raw tank/healer/damage/assignedRole fields the
-- game is actually returning for every visible player, straight from the
-- API, with no interpretation. Use this to see ground truth if role icons
-- still look wrong -- paste the output back so the resolver can be
-- corrected against real data instead of guesses.
SLASH_LFGCOPYROLES1 = "/lfgcopyroles"
SlashCmdList["LFGCOPYROLES"] = function()

    local _, results = C_LFGList.GetSearchResults()

    if not results then
        print("No search results.")
        return
    end

    for _, resultID in ipairs(results) do

        print("====================================")
        print("ResultID:", resultID)

        local info = C_LFGList.GetSearchResultInfo(resultID)
        if info then
            print("----- SEARCH RESULT INFO -----")
            for k,v in pairs(info) do
                print(k, tostring(v))
            end

        end

        local members = (info and info.numMembers) or 0

        for i = 1, members do

            print("----- PLAYER "..i.." PLAYERINFO -----")

            local player = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
            if player then
                for k,v in pairs(player) do
                    print(k, tostring(v))
                end
            else
                print("nil")
            end

            if C_LFGList.GetSearchResultMemberInfo then
                print("----- PLAYER "..i.." MEMBERINFO -----")

                local member = C_LFGList.GetSearchResultMemberInfo(resultID, i)

                if type(member) == "table" then
                    for k,v in pairs(member) do
                        print(k, tostring(v))
                    end
                else
                    print(tostring(member))
                end
            end

        end
    end
end

-- Fallback clickable button used only if Bindings.xml is not loaded.
-- With Bindings.xml loaded, the keybind is configurable in WoW Key Bindings.
local keybindButton = CreateFrame("Button", "LFGCopyKeybindButton", UIParent)
keybindButton:RegisterForClicks("AnyUp")
keybindButton:SetScript("OnClick", ToggleLFGCopy)

local function EnsureDefaultKeybind()
    -- Do not overwrite an existing user binding for this addon.
    if GetBindingKey and GetBindingKey(DEFAULT_LFGCOPY_BINDING_COMMAND) then
        return
    end

    -- Do not steal Alt+I if the player already uses it for something else.
    local existing = GetBindingAction and GetBindingAction(DEFAULT_LFGCOPY_BINDING_KEY)
    if existing and existing ~= "" then
        print(string.format(
            "|cffff8800[LFGCopy]|r %s is already bound to %s. Set LFGcopy in Key Bindings if you want to change it.",
            DEFAULT_LFGCOPY_BINDING_KEY, existing))
        return
    end

    local ok

    -- Preferred path: bind the configurable command from Bindings.xml.
    if SetBinding then
        ok = SetBinding(DEFAULT_LFGCOPY_BINDING_KEY, DEFAULT_LFGCOPY_BINDING_COMMAND)
    end

    -- Fallback path: bind directly to our hidden click button if Bindings.xml was not loaded.
    if not ok and SetBindingClick then
        ok = SetBindingClick(DEFAULT_LFGCOPY_BINDING_KEY, "LFGCopyKeybindButton")
    end

    if ok then
        if SaveBindings and GetCurrentBindingSet then
            SaveBindings(GetCurrentBindingSet())
        end
        print(string.format("|cff00ff00[LFGCopy]|r default keybind set: %s", DEFAULT_LFGCOPY_BINDING_KEY))
    end
end

-------------------------------------------------
-- Events
-------------------------------------------------
addon:RegisterEvent("PLAYER_LOGIN")
addon:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
addon:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")

addon:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        -- Delay slightly so WoW's binding system and any existing saved bindings are fully loaded.
        if C_Timer and C_Timer.After then
            C_Timer.After(1, EnsureDefaultKeybind)
        else
            EnsureDefaultKeybind()
        end
    elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
        -- New batch of results: ask the server for every group's roster
        RequestAllMemberInfo()
        ScheduleRefresh()
    elseif event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
        -- A group's detailed member info just arrived
        ScheduleRefresh()
    end
end)

print("|cff00ff00LFGcopy v6.3.1 loaded. Use /lfgcopy or Alt+I|r")
