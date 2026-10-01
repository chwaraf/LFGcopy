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

-- Prefer the modern C_ClassColor API when it exists (present on Forever's
-- Mainline API surface, and on Retail/Anniversary) and fall back to the
-- plain CLASS_COLORS table lookup everywhere else (Classic/BC Classic).
-- Both return a {r,g,b,...} color object/table, so callers don't need to
-- care which path was used.
local function GetClassColor(classFilename)
    if not classFilename then return nil end
    if C_ClassColor and C_ClassColor.GetClassColor then
        local c = C_ClassColor.GetClassColor(classFilename)
        if c then return c end
    end
    return CLASS_COLORS[classFilename]
end

-------------------------------------------------
-- World of Warcraft: Forever compatibility layer
-------------------------------------------------
-- World of Warcraft: Forever is Blizzard's realmless, permanent level-60
-- "Classic+" game line (beta started Sept 17 2026, launching Nov 4 2026).
-- It matters to LFGcopy for three unrelated reasons:
--
-- 1. Client/API identification is backwards. Forever runs the modern
--    "Mainline" addon API (same family as Retail: MenuUtil, C_LFGList with
--    the newer multi-activityIDs shape, etc.) and reports
--    WOW_PROJECT_ID == WOW_PROJECT_MAINLINE, exactly like real Retail.
--    BUT its TOC "## Interface" number is vanilla-shaped and LOW (16001 as
--    of beta build 1.60.1; it's generated as major*10000+minor*100+patch,
--    so it ticks up slightly with every point release -- 16002 for 1.60.2,
--    and so on). That means neither "WOW_PROJECT_ID == MAINLINE" nor
--    "interface number is small" alone tells you anything (Classic Era/
--    SoD/Anniversary also have a small interface number, just under a
--    different project id; real Retail has WOW_PROJECT_MAINLINE too, just
--    with a much bigger interface number). The PAIR is what's unique to
--    Forever, so that's what IsForeverClient() below checks.
--
-- 2. Two-part, realmless character names. Forever has no realms, so every
--    character is identified by a two-word "First Last" display name
--    (Blizzard's own example: "Ana Forever") instead of the familiar
--    single name or "Name-Realm" pair. There's no hyphen to strip, so
--    Ambiguate() already leaves these names alone -- but anything that
--    builds a raw "/w NAME " chat line breaks, because the chat parser
--    reads only the first space-separated word as the whisper target and
--    treats the rest as the message. See OpenWhisper() below. The
--    WarcraftLogs link builder also needs to percent-encode the space.
--
-- 3. "Secret values". Forever shares Mainline/Midnight's anti-bot "secret
--    value" system (https://warcraft.wiki.gg/wiki/Secret_values). Under
--    certain client-side restrictions (new/low-level accounts, a chat-
--    messaging lockdown, etc.) strings and booleans handed back by
--    C_LFGList can arrive as opaque "secret" values. Reading them is fine,
--    but lower()/gsub()/find()/concatenation/equality-branching on one
--    throws a taint error -- and this addon does exactly that kind of bulk
--    string work on every name, comment, and activity title it sees. Every
--    raw value pulled out of the LFG List API is therefore passed through
--    SafeString()/SafeFlag() the moment it leaves the API, before anything
--    else touches it. This is harmless (a no-op) on clients that don't
--    have the secret-value system at all, like BC Classic.
local WOW_PROJECT_MAINLINE_SAFE = WOW_PROJECT_MAINLINE or 1

local function IsForeverClient()
    if not WOW_PROJECT_ID or WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE_SAFE then
        return false
    end
    local interfaceVersion = select(4, GetBuildInfo())
    -- Real Retail is comfortably above 50000 (110000+ as of 2026); Forever
    -- is still vanilla-versioned (16001-ish). Anything Mainline-flagged but
    -- below that line is Forever.
    return (interfaceVersion or 0) > 0 and interfaceVersion < 50000
end

-- Cached once: the game version can't change mid-session.
local IS_FOREVER = IsForeverClient()

-- issecretvalue()/issecrettable() only exist on clients that have the
-- secret-value system (Forever and other modern Mainline builds). Wrap
-- them so calling code never has to guard the guard.
local function IsSecretValue(v)
    if v == nil or type(issecretvalue) ~= "function" then return false end
    local ok, result = pcall(issecretvalue, v)
    return ok and result == true
end

local function IsSecretTable(t)
    if type(t) ~= "table" or type(issecrettable) ~= "function" then return false end
    local ok, result = pcall(issecrettable, t)
    return ok and result == true
end

-- Returns a plain, safe-to-touch string: `v` itself if it's an ordinary,
-- non-secret string, or `fallback` for nil/secret/any other type. Call this
-- on every raw string the moment it comes out of a Blizzard API, before any
-- lower()/gsub()/find()/concatenation is attempted on it.
local function SafeString(v, fallback)
    fallback = fallback or ""
    if type(v) ~= "string" then return fallback end
    if IsSecretValue(v) then return fallback end
    return v
end

-- Returns a plain, safe-to-branch-on value, treating a secret value as
-- "unknown" (false) instead of letting a comparison on it error out.
local function SafeFlag(v)
    if IsSecretValue(v) then return false end
    return v
end

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
    name = SafeString(name, nil)          -- bail out cleanly on nil/secret values
    if not name then return nil end
    name = Ambiguate(name, "none")        -- strip realm if present (no-op on Forever's realmless names)
    -- NOTE: this intentionally strips ALL whitespace, including the space
    -- inside a Forever "First Last" name, so trinket-owner lookups keep
    -- matching regardless of whether the other addon's list stored the
    -- name with or without a space. Don't reuse this for anything that
    -- needs to preserve the original display name.
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

-- WarcraftLogs has no confirmed subdomain/URL shape for World of Warcraft:
-- Forever yet -- it's a brand-new client still in beta as of this writing,
-- and WCL hasn't published parsing/URL support for it. Forever's dungeons
-- and raids are still "Classic-style" vanilla encounters under the hood, so
-- this guesses the Classic Era subdomain as the closest existing match.
-- Change this (or WCL_SUBDOMAIN above) the moment WarcraftLogs documents
-- Forever's real URL shape.
local WCL_FOREVER_SUBDOMAIN = "classic"

-- Realm segment to use in the URL when running on Forever and the client
-- doesn't hand back a usable realm name (Forever is realmless, so there's
-- no guarantee GetNormalizedRealmName()/GetRealmName() return anything
-- meaningful). Adjust this once WCL's real Forever URL shape is known.
local WCL_FOREVER_REALM_FALLBACK = "forever"

local function Slugify(realm)
    if not realm or realm == "" then return "" end
    realm = realm:gsub("'", "")        -- drop apostrophes (e.g. Mal'Ganis)
    realm = realm:gsub("%s+", "-")     -- spaces -> hyphens
    realm = realm:gsub("[^%w%-]", "")  -- strip any other punctuation
    return realm:lower()
end

-- Percent-encodes anything a URL path segment can't contain safely,
-- most importantly the space in Forever's two-part "First Last" names
-- (e.g. "Ana Forever" -> "Ana%20Forever"). Letters, digits, '-', '.', '_'
-- and '~' are left alone; everything else (spaces, apostrophes, non-ASCII
-- letters, etc.) is escaped.
local function UrlEncode(str)
    if not str or str == "" then return "" end
    return (str:gsub("([^%w%-%.%_%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local foreverWclWarned = false
local function GetWCLLink(playerName)
    if IS_FOREVER and not foreverWclWarned then
        foreverWclWarned = true
        print("|cffff8800[LFGcopy]|r WarcraftLogs support for WoW Forever isn't confirmed yet -- "
            .. "the copied link is a best guess. Edit WCL_FOREVER_SUBDOMAIN / WCL_FOREVER_REALM_FALLBACK "
            .. "near the top of LFGcopy.lua once WarcraftLogs documents Forever's real URL shape.")
    end

    -- Region: prefer the string API, fall back to numeric id mapping
    local region
    if GetCurrentRegionName then
        region = SafeString(GetCurrentRegionName(), nil)
    end
    if not region and GetCurrentRegion then
        local map = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
        region = map[GetCurrentRegion()]
    end
    region = (region or "us"):lower()

    -- Realm: the player's own realm (single-realm server = everyone shares it).
    -- Forever is realmless, so this may come back empty -- fall back to a
    -- placeholder segment rather than producing a broken double-slash URL.
    local realm = SafeString(GetNormalizedRealmName and GetNormalizedRealmName(), nil)
        or SafeString(GetRealmName and GetRealmName(), nil)
        or ""
    local realmSlug = Slugify(realm)
    if realmSlug == "" and IS_FOREVER then
        realmSlug = WCL_FOREVER_REALM_FALLBACK
    end

    -- Player name: strip realm if somehow present, then percent-encode so a
    -- Forever "First Last" name (with its space) doesn't break the URL.
    local name = Ambiguate(SafeString(playerName, ""), "none")

    local subdomain = IS_FOREVER and WCL_FOREVER_SUBDOMAIN or WCL_SUBDOMAIN

    return string.format(
        "https://%s.warcraftlogs.com/character/%s/%s/%s",
        subdomain, region, realmSlug, UrlEncode(name)
    )
end

-------------------------------------------------
-- /who helper
-- toChat = true  -> results print in the chat frame (detailed line,
--                   same as typing /who name manually)
-- toChat = false -> results show in the default Who window
-------------------------------------------------
local function DoWho(name, toChat)
    local who = Ambiguate(SafeString(name, ""), "none")
    -- Quoting the name handles Forever's space-containing two-part names
    -- fine: '/who n-"Ana Forever"' matches the full name as one literal,
    -- the same way '/who n-"Multi Word Guild"' already works for guilds.
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
    local who = Ambiguate(SafeString(name, ""), "none")
    if who == "" or who == "Unknown" then return end

    -- Forever's realmless "First Last" names contain a space, so just
    -- typing "/w First Last " into the edit box is unsafe: the chat parser
    -- reads only the first space-separated word as the whisper target and
    -- treats everything after it (including the rest of the name) as the
    -- start of the message. Blizzard's own "send tell" helpers set the
    -- whisper target as structured data instead of raw text, so prefer
    -- those whenever they exist -- they've been around well before Forever
    -- too, so this is strictly safer on every client, not just a Forever-
    -- only code path.
    if ChatFrameUtil and ChatFrameUtil.SendTell then
        ChatFrameUtil.SendTell(who, DEFAULT_CHAT_FRAME)
        return
    end
    if ChatFrame_SendTell then
        ChatFrame_SendTell(who, DEFAULT_CHAT_FRAME)
        return
    end

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

-- Collapsed/expanded state per group. Clicking the leader name toggles this.
-- Keyed mostly by leader name instead of resultID so folded groups stay folded
-- after pressing Blizzard's "Search Again" button, which can assign new resultIDs.
local collapsedGroups = {}

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
-- Scroll
-------------------------------------------------
local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 10, -30)
scroll:SetPoint("BOTTOMRIGHT", -30, 10)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(700, 1)
scroll:SetScrollChild(content)

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
        elseif parent.groupKey then
            collapsedGroups[parent.groupKey] = not collapsedGroups[parent.groupKey]
            if RefreshWindow then RefreshWindow() end
        end
    end)
    row.headerButton:SetScript("OnEnter", function(self)
        local parent = self:GetParent()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if parent and parent.isCollapsed then
            GameTooltip:AddLine("Left-click: expand this group", 1, 1, 1)
        else
            GameTooltip:AddLine("Left-click: collapse this group", 1, 1, 1)
        end
        GameTooltip:AddLine("Right-click: whisper leader", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    row.headerButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
    -- Under Forever's secret-value system a role flag can come back as a
    -- secret boolean/number; comparing it directly (v == true) would throw
    -- a taint error instead of returning false. Treat "secret" the same as
    -- "unknown" here -- GetPlayers() already falls through to several other
    -- sources (MemberInfo, MemberCounts, base role string) if this comes
    -- back empty, so this just means one of those sources has to win
    -- instead.
    v = SafeFlag(v)
    -- Treat nil, false, and 0 all as "not set". Lua only treats nil/false as
    -- falsy, so a numeric 0 (which some API variants return instead of a
    -- real boolean) would otherwise be misread as "selected".
    return v == true or (type(v) == "number" and v ~= 0)
end

local function GetPlayerRoleFlags(player)
    if not player then return {} end
    if IsSecretTable(player) then return {} end
    local flags = {}
    local hasTank, hasHealer, hasDamage = false, false, false

    -- Check direct boolean flags
    if IsRoleFlagSet(player.tank) or IsRoleFlagSet(player.isTank) then hasTank = true end
    if IsRoleFlagSet(player.healer) or IsRoleFlagSet(player.isHealer) then hasHealer = true end
    if IsRoleFlagSet(player.damage) or IsRoleFlagSet(player.isDamage) or IsRoleFlagSet(player.damager) or IsRoleFlagSet(player.isDamager) or IsRoleFlagSet(player.dps) then hasDamage = true end
    
    -- Check lfgRoles sub-table (used by TBC Anniversary for solo listings)
    if player.lfgRoles and not IsSecretTable(player.lfgRoles) then
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
    if not player or IsSecretTable(player) then return nil end
    local role = SafeString(player.role, nil)
    if role and role ~= "" then return role end
    local assignedRole = SafeString(player.assignedRole, nil)
    if assignedRole and assignedRole ~= "" then return assignedRole end
    return nil
end

local function GetPlayers(resultID, leaderName)
    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info or IsSecretTable(info) then
        return {}
    end

    local players = {}

    for i = 1, (SafeFlag(info.numMembers) or 0) do
        local player = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
        if player and not IsSecretTable(player) then
            -- A secret/missing name (e.g. a new/restricted account under a
            -- chat-messaging lockdown on Forever) shouldn't drop the whole
            -- member silently -- fall back to a distinct placeholder so the
            -- slot, role icon, and member count still render correctly.
            local rawName = SafeString(player.name, nil) or string.format("Hidden Player %d", i)
            local clean = Ambiguate(rawName, "none")
            local exists = false
            for _, v in ipairs(players) do
                if v.name == clean then
                    exists = true
                    break
                end
            end
            if not exists then
                local finalRoles = {}
                local isSolo = (SafeFlag(info.numMembers) or 0) <= 1
                
                if not isSolo then
                    -- In a group, a player occupies exactly ONE assigned role.
                    -- Prioritize their explicit assigned base role so we don't show all the multi-roles they CAN play.
                    local r = GetPlayerBaseRole(player)
                    if not r and C_LFGList.GetSearchResultMemberInfo then
                        local memberInfoRole = SafeString(C_LFGList.GetSearchResultMemberInfo(resultID, i), nil)
                        if memberInfoRole and memberInfoRole ~= "" then r = memberInfoRole end
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
                        local r = SafeString(C_LFGList.GetSearchResultMemberInfo(resultID, i), nil)
                        if r and r ~= "" then table.insert(finalRoles, r) end
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
                    class = SafeString(player.classFilename, nil),
                    roles = finalRoles,
                })
            end
        end
    end

    -- Fallback leader (if info.numMembers was completely missing/0)
    if #players == 0 then
        local leader = C_LFGList.GetSearchResultLeaderInfo(resultID)
        if leader and not IsSecretTable(leader) then
            local leaderRawName = SafeString(leader.name, nil) or "Hidden Player 1"
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
                local r = SafeString(C_LFGList.GetSearchResultMemberInfo(resultID, 1), nil)
                if r and r ~= "" then table.insert(finalRoles, r) end
            end
            table.insert(players, {
                name = Ambiguate(leaderRawName, "none"),
                class = SafeString(leader.classFilename, nil),
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

    -- Onyxia's Lair is a long-standing omission from the Burning Crusade
    -- list above (it's a Vanilla raid that stuck around into BC and every
    -- version since). Added here rather than Forever-gated, but it's
    -- especially relevant to Forever, which keeps Onyxia's Lair as its
    -- one 40-player raid alongside the two new smaller raids below.
    ["onyxia's lair"]          = "Ony",
    ["onyxias lair"]           = "Ony",
    ["onyxia"]                 = "Ony",

    -- World of Warcraft: Forever (beta, launching Nov 4 2026) -- its nine
    -- new leveling dungeons and two new raids. Names/levels are current as
    -- of the Forever beta client; Blizzard can still rename or re-theme
    -- any of these before/after the Nov 4 2026 launch, so double-check
    -- against in-game listings if an abbreviation stops matching.
    ["hall of thanes"]             = "HoT",       -- levels 13-18, beneath Ironforge
    ["ruins of lordaeron"]         = "RoL",        -- levels 15-20
    ["excavation site: wetlands"]  = "ExcW",       -- levels 24-29, above Whelgar's Excavation
    ["excavation site"]            = "ExcW",
    ["city of dalaran"]            = "CoD",        -- levels 28-33
    ["the drowned city"]           = "TDC",        -- levels 35-40
    ["krol'dok stronghold"]        = "KDS",        -- levels 40-45, Riverglades
    ["kroldok stronghold"]         = "KDS",
    ["alcaz island prison"]        = "AP",         -- levels 48-53, Alcaz Island
    ["alcaz prison"]               = "AP",
    ["blackmaw hold"]              = "BMH",        -- levels 55-60, northern Azshara
    ["shaper's terrace"]           = "ShT",        -- levels 58-60, Un'Goro Crater
    ["shapers terrace"]            = "ShT",

    -- Forever's two new raids unlock Dec 9 2026, five weeks after launch.
    -- "Hyjal Summit" is deliberately a different tag from the existing
    -- "Hyjal" above (Burning Crusade's Battle for Mount Hyjal) -- they are
    -- two unrelated instances that both involve Mount Hyjal.
    ["hyjal summit"]               = "HyS",        -- 20-player raid
    ["the barrow deeps"]           = "BD",         -- 10-player raid
    ["barrow deeps"]               = "BD",
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
    -- Defensive: every caller already runs raw API text through SafeString
    -- before it reaches here, but guard again in case this is ever called
    -- directly with something un-sanitized.
    if IsSecretValue(text) then return "" end

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
        -- A fully "secret" info table (possible under Forever's chat-
        -- messaging lockdown) can't be indexed at all -- skip the result for
        -- this refresh pass rather than erroring; it reappears once the
        -- restriction clears and the next LFG_LIST_SEARCH_RESULT_UPDATED
        -- fires.
        if info and not IsSecretTable(info) and not SafeFlag(info.isDelisted) then
            local leaderName = "Unknown"
            local leader = C_LFGList.GetSearchResultLeaderInfo(resultID)
            if leader and not IsSecretTable(leader) then
                local rawLeaderName = SafeString(leader.name, nil)
                if rawLeaderName then
                    leaderName = Ambiguate(rawLeaderName, "none")
                end
            end

            -- What the group is listed for.
            -- activityIDs (plural array, 11.0.7+) can contain several
            -- activities. Collect all of their names, deduped.
            local listed = ""
            local ids = {}
            if info.activityIDs and not IsSecretTable(info.activityIDs) then
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
                    local act = C_LFGList.GetActivityInfoTable(aid, nil, SafeFlag(info.isWarMode))
                    if act and not IsSecretTable(act) then
                        n = SafeString(act.fullName, nil) or SafeString(act.shortName, nil)
                    end
                end
                if (not n or n == "") and C_LFGList.GetActivityInfo then
                    n = SafeString(C_LFGList.GetActivityInfo(aid), nil)
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
            local title = SafeString(info.name, nil)
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
            if (SafeFlag(info.numMembers) or 0) == 1 and players[1] and players[1].roles then
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
                members = SafeFlag(info.numMembers) or 0,
                listed = listed or "",
                -- The comment can be a secret string under Forever's
                -- lockdown as well as Blizzard's older "protected" comment
                -- strings (see the note by row.desc's creation above) --
                -- either way it's display-only, so a safe fallback is fine.
                description = SafeString(info.comment, ""),
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

    local perRow = 5
    local buttonWidth = 125
    local buttonHeight = 22
    local spacingX = 6
    local spacingY = 4
    local startX = 8

    -- Apply filters first so row indices stay contiguous
    local shown = {}
    for _, group in ipairs(groups) do
        if GroupMatchesFilters(group) then
            shown[#shown + 1] = group
        end
    end

    for rowIndex, group in ipairs(shown) do
        local row = AcquireRow(rowIndex)
        row.groupKey = group.foldKey or group.resultID or group.leader
        row.leaderName = group.leader
        row.isCollapsed = collapsedGroups[row.groupKey] or false

        local foldMarker = row.isCollapsed and "+" or "-"
        row.text:SetText(string.format("[%s] %s (%d)", foldMarker, group.leader, group.members))
        row.activity:SetText(group.listed ~= "" and ("- " .. group.listed) or "")

        -- Top block = leader line beside the (possibly wrapped) activity.
        local topH = math.max(row.text:GetStringHeight() or 0, row.activity:GetStringHeight() or 0, 18)

        if row.isCollapsed then
            -- Folded group: keep only the leader/activity header visible.
            row.desc:Hide()
            ReleaseExtraButtons(row, 0)
            row:SetHeight(8 + topH + 8)
        else
            -- Expanded group: show description/comment and all player buttons.
            row.desc:Show()

            -- Description / comment (display only)
            local desc = group.description or ""
            row.desc:SetText(desc)

            local players = group.players or {}

            -- Re-anchor the description below whichever is taller (leader line
            -- or the wrapped activity list) so they never overlap.
            row.desc:ClearAllPoints()
            row.desc:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -(8 + topH + 2))
            row.desc:SetPoint("RIGHT", row, "RIGHT", -8, 0)

            local descH = 0
            if desc ~= "" then
                descH = (row.desc:GetStringHeight() or 12) + 4
            end

            local headerOffset = 8 + topH + descH + 8
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
                local classColor = GetClassColor(player.class)
                if classColor then
                    fs:SetTextColor(classColor.r, classColor.g, classColor.b)
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
    content:SetHeight(totalHeight + 20)

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
-- Dumps every key/value of a table safely, even on a client with the
-- secret-value system: a secret TABLE can't be iterated at all (pairs()
-- itself would error), and an individual secret VALUE can usually still be
-- handed to tostring()/print() but is flagged as such so you know not to
-- trust it for matching/filtering.
local function DumpTableSafely(t)
    if type(t) ~= "table" then
        print(tostring(t))
        return
    end
    if IsSecretTable(t) then
        print("<entire table is a secret value -- likely a Forever chat-messaging lockdown; can't be iterated>")
        return
    end
    for k, v in pairs(t) do
        if IsSecretValue(v) then
            local ok, shown = pcall(tostring, v)
            print(k, "SECRET VALUE" .. (ok and (" (tostring: " .. shown .. ")") or ""))
        else
            print(k, tostring(v))
        end
    end
end

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
            DumpTableSafely(info)
        end

        local members = (info and SafeFlag(info.numMembers)) or 0

        for i = 1, members do

            print("----- PLAYER "..i.." PLAYERINFO -----")

            local player = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
            if player then
                DumpTableSafely(player)
            else
                print("nil")
            end

            if C_LFGList.GetSearchResultMemberInfo then
                print("----- PLAYER "..i.." MEMBERINFO -----")

                local member = C_LFGList.GetSearchResultMemberInfo(resultID, i)

                if type(member) == "table" then
                    DumpTableSafely(member)
                else
                    print(IsSecretValue(member) and "SECRET VALUE" or tostring(member))
                end
            end

        end
    end
end

-- Quick environment probe, mainly useful for checking whether LFGcopy has
-- correctly identified a World of Warcraft: Forever client (or any other
-- client) and whether the secret-value system is active, without having to
-- dig through /lfgcopyroles output. Report this output when filing a bug.
SLASH_LFGCOPYCLIENT1 = "/lfgcopyclient"
SlashCmdList["LFGCOPYCLIENT"] = function()
    local build, buildNum, buildDate, interfaceVersion = GetBuildInfo()
    print("|cff00ff00[LFGcopy]|r client probe:")
    print("  WOW_PROJECT_ID:", tostring(WOW_PROJECT_ID))
    print("  Build / interface:", tostring(build), "/", tostring(interfaceVersion))
    print("  Detected as WoW Forever:", tostring(IS_FOREVER))
    print("  Secret-value system present:", tostring(type(issecretvalue) == "function"))
    print("  MenuUtil context menu available:", tostring(MenuUtil ~= nil and MenuUtil.CreateContextMenu ~= nil))
    print("  ChatFrame_SendTell available:", tostring(ChatFrame_SendTell ~= nil or (ChatFrameUtil and ChatFrameUtil.SendTell ~= nil)))
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

print("|cff00ff00LFGcopy v6.3 loaded"
    .. (IS_FOREVER and " (WoW Forever detected)" or "")
    .. ". Use /lfgcopy or Alt+I. /lfgcopyclient for a compatibility probe.|r")
