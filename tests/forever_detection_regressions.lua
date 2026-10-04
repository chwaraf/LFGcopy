-- Run from the repository root: lua tests/forever_detection_regressions.lua
-- Optional first argument: another addon source to reproduce the old failure.
--
-- Exercises IsForeverClient() (pulled verbatim via Section()) against the
-- client "shapes" LFGcopy needs to tell apart. Blizzard changed WoW
-- Forever's WOW_PROJECT_ID partway through the beta (1 -> 18, exposed as
-- WOW_PROJECT_CAMELOT on clients that define it), so this specifically
-- guards against regressing to only recognizing one of the two ids.
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

local function Equal(actual, expected, message)
    assert(actual == expected, message .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local code = table.concat({
    "local WOW_PROJECT_ID, WOW_PROJECT_MAINLINE, WOW_PROJECT_CAMELOT, GetBuildInfo",
    Section("local WOW_PROJECT_MAINLINE_SAFE = WOW_PROJECT_MAINLINE or 1", "\nlocal IS_FOREVER = IsForeverClient()"),
    [[return function(projectId, interfaceVersion, mainlineConst, camelotConst)
        WOW_PROJECT_ID = projectId
        WOW_PROJECT_MAINLINE = mainlineConst
        WOW_PROJECT_CAMELOT = camelotConst
        GetBuildInfo = function() return "x.x.x", 0, "", interfaceVersion end
        return IsForeverClient()
    end]],
}, "\n")

local chunk = assert(load(code, "@forever-detection-under-test"))
local Check = chunk()

-- Early Forever beta builds (through ~1.60.1.70124): no WOW_PROJECT_CAMELOT
-- global exists yet, so Forever still reports the Mainline project id.
Equal(Check(1, 16001, 1, nil), true, "early-beta Forever (project id 1, no Camelot const) is detected")

-- Later Forever builds (1.60.1.70170+): Blizzard gave Forever its own
-- project id (18), exposed as the WOW_PROJECT_CAMELOT global.
Equal(Check(18, 16001, 1, 18), true, "current Forever (project id 18 / WOW_PROJECT_CAMELOT) is detected")

-- A client with WOW_PROJECT_ID == 18 but no WOW_PROJECT_CAMELOT global
-- (older LFGcopy-side fallback: literal 18) must still be recognized.
Equal(Check(18, 16001, 1, nil), true, "project id 18 is recognized even without the WOW_PROJECT_CAMELOT global existing")

-- Real Retail: Mainline project id, but a modern (five/six-digit) interface
-- number -- must NOT be mistaken for Forever.
Equal(Check(1, 110105, 1, 18), false, "real Retail (Mainline id, high interface number) is not detected as Forever")

-- Classic Era / Anniversary / SoD: low interface number, but a project id
-- that is neither Mainline nor Camelot -- must NOT be mistaken for Forever.
Equal(Check(2, 11500, 1, 18), false, "Classic Era (non-Mainline/Camelot id, low interface number) is not detected as Forever")

-- Burning Crusade Classic: same shape as Classic Era for this check.
Equal(Check(5, 20505, 1, 18), false, "BC Classic is not detected as Forever")

-- No WOW_PROJECT_ID at all (very old API surface) must fail closed, not error.
Equal(Check(nil, 16001, 1, 18), false, "a missing WOW_PROJECT_ID is not detected as Forever")

print("PASS: Forever client detection across pre/post project-id-change builds, Retail, and Classic lines")
