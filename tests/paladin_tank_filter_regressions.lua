-- Run from the repository root: lua tests/paladin_tank_filter_regressions.lua
-- Optional first argument: another addon source to reproduce the old failure.
--
-- Exercises GroupHasPaladinTank()/GroupMatchesFilters() exactly as they
-- exist in LFGcopy.lua (pulled verbatim via Section()), with the three
-- filter flags (filterTrinketOnly/filterPaladinTankOnly/filterSearch)
-- supplied as mutable locals in the synthetic chunk so each case can flip
-- them independently, the same way the real UI toggles do.
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
    "local filterTrinketOnly, filterPaladinTankOnly, filterSearch = false, false, ''",
    Section("local function GroupHasPaladinTank", "\nlocal trinketAnnounced"),
    [[return function(flags, group)
        filterTrinketOnly = flags.trinket or false
        filterPaladinTankOnly = flags.paladin or false
        filterSearch = flags.search or ""
        return GroupMatchesFilters(group), GroupHasPaladinTank(group)
    end]],
}, "\n")

local chunk = assert(load(code, "@paladin-filter-under-test"))
local Check = chunk()

local function Player(name, class, roles)
    return { name = name, class = class, roles = roles }
end

local paladinTankGroup = {
    leader = "Highlord", description = "",
    players = {
        Player("Highlord", "PALADIN", { "TANK" }),
        Player("Zapzap", "MAGE", { "DAMAGER" }),
    },
}
local healadinGroup = {
    leader = "Lightbringer", description = "",
    players = {
        Player("Bruiser", "WARRIOR", { "TANK" }),
        Player("Lightbringer", "PALADIN", { "HEALER" }),
    },
}
local noPlayersGroup = { leader = "Mystery", description = "", players = {} }

-- GroupHasPaladinTank() detects a Paladin specifically in the TANK role,
-- not just any Paladin, and not a non-Paladin tank.
do
    local _, hasPT = Check({}, paladinTankGroup)
    Equal(hasPT, true, "a Paladin occupying TANK is detected")
end
do
    local _, hasPT = Check({}, healadinGroup)
    Equal(hasPT, false, "a healing Paladin alongside a non-Paladin tank does not count")
end
do
    local _, hasPT = Check({}, noPlayersGroup)
    Equal(hasPT, false, "a group with no roster data never matches")
end

-- GroupMatchesFilters() only applies the Paladin-tank filter when it's on.
do
    local matches = Check({}, paladinTankGroup)
    Equal(matches, true, "filter off: every group passes regardless of roster")
end
do
    local matches = Check({}, healadinGroup)
    Equal(matches, true, "filter off: a group without a Paladin tank still passes")
end
do
    local matches = Check({ paladin = true }, paladinTankGroup)
    Equal(matches, true, "filter on: a group with a Paladin tank passes")
end
do
    local matches = Check({ paladin = true }, healadinGroup)
    Equal(matches, false, "filter on: a group without a Paladin tank is hidden")
end
do
    local matches = Check({ paladin = true }, noPlayersGroup)
    Equal(matches, false, "filter on: a group with no roster data is hidden")
end

-- The Paladin-tank filter combines with the existing filters (AND logic),
-- matching how the trinket toggle and search box already interact.
do
    local combinedGroup = {
        leader = "Highlord", description = "",
        players = {
            Player("Highlord", "PALADIN", { "TANK" }),
        },
        hasTrinket = false,
    }
    local matches = Check({ paladin = true, trinket = true }, combinedGroup)
    Equal(matches, false, "both filters on: a Paladin-tank group without the trinket flag is still hidden")
end
do
    local combinedGroup = {
        leader = "Highlord", description = "",
        players = {
            Player("Highlord", "PALADIN", { "TANK" }),
        },
        hasTrinket = true,
    }
    local matches = Check({ paladin = true, trinket = true }, combinedGroup)
    Equal(matches, true, "both filters on: a Paladin-tank group with the trinket flag passes")
end

print("PASS: Paladin-tank filter detection, toggle gating, and combination with existing filters")
