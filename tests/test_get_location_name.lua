-- tests/test_get_location_name.lua
-- Standalone Lua 5.1 tests for wom_terminology_helper.get_location_name.
--
-- Run from the repo root:  lua tests/test_get_location_name.lua
-- Run from tests/:         lua test_get_location_name.lua
--
-- Tests the prefix-stripping, on-map vs off-map determination, and suffix logic.
-- Covers the regression where level_display is lowercase (e.g. "garbage") but
-- the GAMMA smart-terrain display name uses Title Case ("Garbage Bus Stop").

-- ============================================================
-- Level ID constants
-- ============================================================

local L_GARBAGE = 1
local L_CORDON  = 2
local L_DV      = 3   -- Dark Valley
local L_YANTAR  = 4
local L_GS      = 5   -- Great Swamp (internal name: "marsh")

-- ============================================================
-- Mutable test context (reset per test)
-- ============================================================

local _smarts      = {}         -- [id] = { _name, _level }
local _actor_level = L_GARBAGE  -- what xlevel.get_actor_level_id() returns

-- What xlevel.get_level_name(level_id) returns.
-- xlevel.get_level_name calls game.translate_string(alife():level_name(level_id)).
-- For Great Swamp: level_name="k00_marsh", translate("k00_marsh")="Great Swamps" (vanilla plural).
local _level_name_map = {
    [L_GARBAGE] = "garbage",       -- lowercase internal — the buggy case (no translation key)
    [L_CORDON]  = "Cordon",
    [L_DV]      = "dark valley",   -- lowercase two-word (no translation key)
    [L_YANTAR]  = "Yantar",
    [L_GS]      = "Great Swamps",  -- plural (vanilla Anomaly) — GAMMA smart names use singular
}

-- What alife():level_name(level_id) returns (the internal folder name from game_levels.ltx).
-- For Great Swamp, game_levels.ltx has name = k00_marsh, so level_name returns "k00_marsh".
local _raw_level_map = {
    [L_GARBAGE] = "garbage",
    [L_CORDON]  = "escape",
    [L_DV]      = "darkvalley",
    [L_YANTAR]  = "yantar",
    [L_GS]      = "k00_marsh",
}

-- Translations available via game.translate_string (subset that are localized).
-- Keys are the values that alife():level_name() returns (the internal folder name).
-- In vanilla Anomaly: game_levels.ltx uses the full folder name (e.g. "k00_marsh"),
-- and st_levels.xml maps that key to the display name (e.g. "Great Swamps" — note plural).
local _translations = {
    escape       = "Cordon",
    darkvalley   = "Dark Valley",
    ["k00_marsh"] = "Great Swamps",  -- vanilla Anomaly plural form (GAMMA uses singular in smart names)
}

-- ============================================================
-- STALKER API stubs
-- ============================================================

xobject = {
    se = function(id) return _smarts[id] end,
}

xlevel = {
    get_smart_display_name = function(s) return s._name end,
    get_level_id           = function(s) return s._level end,
    get_actor_level_id     = function() return _actor_level end,
    get_level_name         = function(lid) return _level_name_map[lid] end,
}

alife = function()
    return {
        level_name = function(self, lid) return _raw_level_map[lid] end,
        object     = function(self, id)  return _smarts[id]         end,
    }
end

game = {
    translate_string = function(k) return _translations[k] or k end,
}

-- wom_utils stub: only pick_random_item is needed by terminology_helper
wom_utils = {
    pick_random_item = function(t) return t[1] end,
}

-- ============================================================
-- Load the module under test
-- ============================================================

local script_dir = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
local script_path = script_dir .. "/../gamedata/scripts/wom_terminology_helper.script"
dofile(script_path)

-- ============================================================
-- Test harness
-- ============================================================

local pass_count, fail_count = 0, 0

local function check(label, got, expected)
    if got == expected then
        io.write(string.format("    PASS  %s\n", label))
        pass_count = pass_count + 1
    else
        io.write(string.format("    FAIL  %s\n", label))
        io.write(string.format("          got:      %s\n", tostring(got)))
        io.write(string.format("          expected: %s\n", tostring(expected)))
        fail_count = fail_count + 1
    end
end

local function make_smart(display_name, level_id)
    local id = #_smarts + 100
    _smarts[id] = { _name = display_name, _level = level_id }
    return id
end

local function reset_context()
    _smarts = {}
    _actor_level = L_GARBAGE
    _level_name_map = {
        [L_GARBAGE] = "garbage",
        [L_CORDON]  = "Cordon",
        [L_DV]      = "dark valley",
        [L_YANTAR]  = "Yantar",
        [L_GS]      = "Great Swamps",
    }
end

local function suite(title, fn)
    io.write(string.format("[%s]\n", title))
    reset_context()
    fn()
    io.write("\n")
end

-- ============================================================
-- Test suites
-- ============================================================

suite("1. On-map, period-space format (Anomaly vanilla)", function()
    local id = make_smart("Garbage. Bus Stop", L_GARBAGE)
    check("strips period-space prefix, no suffix", get_location_name(id), "the bus stop")
end)

suite("2. On-map, comma-space format", function()
    local id = make_smart("Garbage, Bus Stop", L_GARBAGE)
    check("strips comma-space prefix, no suffix", get_location_name(id), "the bus stop")
end)

suite("3. On-map, GAMMA space-only — level_display case matches name", function()
    _level_name_map[L_GARBAGE] = "Garbage"   -- xlevel returns capitalized form
    local id = make_smart("Garbage Bus Stop", L_GARBAGE)
    check("strips space-only prefix (case match), no suffix", get_location_name(id), "the bus stop")
end)

suite("4. On-map, GAMMA space-only — level_display is lowercase [THE BUG]", function()
    -- xlevel.get_level_name returns "garbage" but smart name is "Garbage Bus Stop".
    -- Requires case-insensitive strip to work correctly.
    local id = make_smart("Garbage Bus Stop", L_GARBAGE)
    check("strips space-only prefix (case mismatch), no suffix", get_location_name(id), "the bus stop")
end)

suite("5. Off-map, period-space format", function()
    _actor_level = L_GARBAGE
    _level_name_map[L_CORDON] = "Cordon"
    local id = make_smart("Cordon. Bus Stop", L_CORDON)
    check("strips period-space prefix, appends level suffix", get_location_name(id), "the bus stop in Cordon")
end)

suite("6. Off-map, GAMMA space-only — level_display case matches name", function()
    _actor_level = L_GARBAGE
    _level_name_map[L_CORDON] = "Cordon"
    local id = make_smart("Cordon Bus Stop", L_CORDON)
    check("strips prefix, appends level suffix", get_location_name(id), "the bus stop in Cordon")
end)

suite("7. Off-map, GAMMA space-only — level_display lowercase two-word", function()
    -- level_name returns "dark valley" but smart name is "Dark Valley Pig Farm".
    -- Case-insensitive strip extracts "Pig Farm"; off-map check appends level suffix.
    -- NOTE: suffix uses level_display as-is ("dark valley"), which is a pre-existing
    -- cosmetic limitation separate from the prefix-strip bug being fixed here.
    _actor_level = L_GARBAGE
    local id = make_smart("Dark Valley Pig Farm", L_DV)
    check("strips prefix, appends lowercase suffix (known cosmetic limitation)",
        get_location_name(id), "the pig farm in dark valley")
end)

suite("8. On-map — proper noun inside location is preserved", function()
    -- "Pripyat" is in PROTECTED_PROPER_NOUNS so it stays capitalised.
    -- "hotel" is a common noun and correctly goes lowercase.
    local id = make_smart("Garbage Pripyat Hotel", L_GARBAGE)
    check("Pripyat stays capitalised; hotel goes lowercase", get_location_name(id), "the Pripyat hotel")
end)

suite("9. On-map — possessive proper noun (no leading 'the')", function()
    local id = make_smart("Garbage Sakharov's Bunker", L_GARBAGE)
    check("no 'the' prefix when phrase starts with possessive proper noun",
        get_location_name(id), "Sakharov's bunker")
end)

suite("10. Unknown smart terrain — xobject.se returns nil", function()
    check("returns empty string", get_location_name(9999), "")
end)

suite("11. Off-map — plural/singular mismatch (Great Swamps → Great Swamp)", function()
    -- xlevel.get_level_name returns "Great Swamps" (vanilla plural, via k00_marsh translation).
    -- GAMMA smart terrain names use the singular prefix "Great Swamp Eerie Bonfire".
    -- Strips 1-4 all fail because "great swamps" doesn't match "great swamp" prefix.
    -- Plural→singular strip (strip 5): try "Great Swamp" (minus trailing 's') → matches.
    -- level_display is updated to "Great Swamp" (singular) so the suffix reads correctly.
    -- "clear sky" is not in PROTECTED_PROPER_NOUNS so it goes lowercase.
    _actor_level = L_GARBAGE
    local id = make_smart("Great Swamp Clear Sky Base", L_GS)
    check("singular strip extracts location, suffix uses singular level name",
        get_location_name(id), "the clear sky base in Great Swamp")
end)

suite("12. On-map — level name already properly cased, no double-prefix bug", function()
    _level_name_map[L_GS] = "Great Swamp"
    _actor_level = L_GS
    local id = make_smart("Great Swamp Bus Stop", L_GS)
    check("strips properly-cased prefix, returns without suffix", get_location_name(id), "the bus stop")
end)

suite("13. On-map — single-word location name after strip", function()
    local id = make_smart("Garbage Outpost", L_GARBAGE)
    check("single word stripped correctly", get_location_name(id), "the outpost")
end)

suite("14. Off-map — skip suffix when location part already begins with level name", function()
    -- e81f092 skip check: when stripping fails and name = "Garbage Bus Stop" would
    -- produce spoken = "the Garbage bus stop", the skip check fires and we don't
    -- append "in Garbage" again (avoids "the Garbage bus stop in Garbage").
    -- With the new case-insensitive strip, the prefix IS now removed for GAMMA format,
    -- so this case now hits the normal path ("the bus stop in Garbage") instead.
    -- This test validates that the e81f092 skip check is no longer the main path.
    _actor_level = L_YANTAR   -- player is in Yantar
    _level_name_map[L_GARBAGE] = "Garbage"  -- off-map level has proper case
    local id = make_smart("Garbage Bus Stop", L_GARBAGE)
    check("off-map with proper-case level_display: strip works, suffix appended",
        get_location_name(id), "the bus stop in Garbage")
end)

suite("15. On-map Great Swamp — plural/singular strip, no suffix [THE REPORTED BUG]", function()
    -- The user saw "the great swamp eerie bonfire" in game while standing in Great Swamp.
    -- xlevel.get_level_name returns "Great Swamps" (plural, vanilla k00_marsh translation).
    -- GAMMA smart name uses the singular prefix. Plural→singular strip extracts "Eerie Bonfire".
    -- On-map check fires → no " in Great Swamp" suffix appended.
    _actor_level = L_GS
    local id = make_smart("Great Swamp Eerie Bonfire", L_GS)
    check("strips plural-vs-singular prefix, returns plain location on-map",
        get_location_name(id), "the eerie bonfire")
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
