-- tests/test_wom_outpost.lua
-- Standalone Lua 5.1 tests for wom_outpost.script.
--
-- Run from the repository root:  lua tests/test_wom_outpost.lua
-- Run from tests/:               lua test_wom_outpost.lua
--
-- Written after a shipped bug that disabled the entire feature in silence: the scan
-- called squad:id() on a SERVER object, where `id` is a field, not a method. That threw
-- "attempt to call method 'id' (a number value)" on the first service squad found, the
-- pcall in the timer swallowed it into a log line, and from then on nothing announced and
-- get_outposts_for_level always returned empty. So the squad fakes here deliberately
-- mirror the real server-object shape — `id` a plain field, `section_name`/`commander_id`
-- methods — and the first test asserts a scan finds a service squad at all.
--
-- Strategy follows test_wom_campfire: capture the timer callback that on_game_start
-- registers, then invoke it directly to drive one scan.

-- ============================================================
-- Mutable test state
-- ============================================================

local _squads        = {}    -- array of fake server squad objects
local _smarts        = {}    -- smart_id -> fake smart server object
local _pda_calls     = {}    -- one entry per send_news_pda
local _timer_callback = nil
local _game_sec      = 0
local _player_comm   = "stalker"
local _enabled       = true
local _announce_services = true
local _scope         = "allies"

-- Clears both the harness state and the module's own state. on_game_start resets _known,
-- _baselined, _pending and _last_fire_sec, without which every group would inherit the
-- previous group's known outposts.
local function reset()
    _squads        = {}
    _smarts        = {}
    _pda_calls     = {}
    _game_sec      = 1000000
    _player_comm   = "stalker"
    _enabled       = true
    _announce_services = true
    _scope         = "allies"
    on_game_start()
end

-- Adds a fake ALifePlus service squad. `id` is a FIELD; section_name/commander_id are
-- METHODS — exactly like a real cse_alife_online_offline_group.
local function add_service_squad(squad_id, faction, role, smart_id)
    _smarts[smart_id] = _smarts[smart_id] or { id = smart_id, m_game_vertex_id = 1 }
    _squads[#_squads + 1] = {
        id                = squad_id,
        smart_id          = smart_id,
        section_name      = function(self) return "ap_service_" .. faction .. "_" .. role end,
        commander_id      = function(self) return squad_id + 1000 end,
        character_icon    = function(self) return "icon" end,
    }
end

-- Adds a squad that is not a service squad at all.
local function add_other_squad(squad_id, section)
    _squads[#_squads + 1] = {
        id           = squad_id,
        section_name = function(self) return section end,
    }
end

-- ============================================================
-- Engine / module stubs
-- ============================================================

db = { actor = {} }

function printf() end

game = { translate_string = function(key) return key end }

xtime  = { game_sec = function() return _game_sec end }
xlevel = { get_level_id = function(smart) return smart and 1 or nil end }

xsquad = {
    iter_squads = function()
        local index = 0
        return function()
            index = index + 1
            return _squads[index]
        end
    end,
    get_squad_smart     = function(squad) return squad and _smarts[squad.smart_id] or nil end,
    get_commander_name  = function(squad) return "Commander" .. tostring(squad.id) end,
}

xobject = { se = function(id) return nil end }   -- sender falls back to the faction handle

CreateTimeEvent = function(_, _, _, callback) _timer_callback = callback end
ResetTimeEvent  = function() end

get_actor_true_community = function() return _player_comm end

wom_mcm = {
    outpost_enabled           = function() return _enabled end,
    outpost_scope             = function() return _scope end,
    outpost_announce_services = function() return _announce_services end,
}

wom_bark = {
    faction_matches = function(community, player_comm, scope)
        if not community then return false end
        if community == player_comm then return true end
        return scope == "allies" and community == "dolg"
    end,
    faction_display = function(faction) return "FACTION_" .. faction, "icon" end,
    send_news_pda   = function(name, icon, message) _pda_calls[#_pda_calls + 1] = { name = name, message = message } end,
}

wom_utils = {
    join_list = function(items) return table.concat(items, "+") end,
}

wom_terminology_helper = {
    get_location_name    = function(smart_id) return "SMART" .. tostring(smart_id) end,
    get_faction_identity = function(community) return "IDENT_" .. community end,
}

wom_dialogue_helper = {
    pick_dialogue_variant = function(prefix, slots)
        return prefix .. "[" .. tostring(slots and slots.location) .. "|"
               .. tostring(slots and slots.roles ~= "" and slots.roles or slots.role) .. "]"
    end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
dofile(script_dir .. "/../gamedata/scripts/wom_outpost.script")

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

local function check_contains(label, got, substring)
    if type(got) == "string" and got:find(substring, 1, true) then
        io.write(string.format("    PASS  %s\n", label))
        pass_count = pass_count + 1
    else
        io.write(string.format("    FAIL  %s\n", label))
        io.write(string.format("          got:      %s\n", tostring(got)))
        io.write(string.format("          expected to contain: %s\n", tostring(substring)))
        fail_count = fail_count + 1
    end
end

local function group(name, fn)
    io.write(name .. "\n")
    fn()
end

-- Runs one scan pass. The timer callback wraps _scan in a pcall, so a raw error surfaces
-- only as "nothing happened" — assert on observable effects, and use scan_strict below
-- when an error itself must fail the test.
local function scan()
    if not _timer_callback then error("on_game_start did not register a timer") end
    _timer_callback()
end

-- ============================================================
-- Tests
-- ============================================================

-- TEMPORARILY DISABLED, in step with the feature itself. wom_outpost.on_game_start
-- currently has its CreateTimeEvent call commented out and wom_mcm.outpost_enabled()
-- is hardcoded false, so no timer is registered and every group below dies on
-- scan()'s "on_game_start did not register a timer".
--
-- Flip this to false when the feature is restored (uncomment the CreateTimeEvent
-- line in wom_outpost.on_game_start). Nothing else here needs changing — the harness
-- stubs wom_mcm, so the MCM hardcode never reaches these tests.
--
-- Kept as one switch rather than commenting out the ~250 lines of groups below: the
-- coverage is the point (this suite exists because a squad:id() typo shipped the
-- feature dead and silent), and commented-out test bodies rot against the module.
local FEATURE_DISABLED = true

if FEATURE_DISABLED then
    io.write("SKIPPED: wom_outpost is temporarily disabled "
             .. "(no timer registered by on_game_start).\n")
    io.write("         Set FEATURE_DISABLED = false in this file when it is restored.\n")
    return
end

-- Registers the timer; reset() calls it again per group to clear module state.
on_game_start()

group("scan: service squads are found at all (the shipped-dead case)", function()
    reset()
    add_service_squad(8951, "stalker", "trader", 500)
    scan()   -- first scan baselines silently
    check("baseline scan announces nothing", #_pda_calls, 0)
    -- If the scan errored, the baseline would be empty and this would be empty too.
    check("the outpost is known after the baseline scan",
        #get_outposts_for_level(1), 1)
end)

group("scan: server squad shape", function()
    -- `id` must be read as a field. A fake that only offered id() as a method would make
    -- the code that shipped pass and this test fail, which is the point.
    reset()
    add_service_squad(8951, "stalker", "trader", 500)
    scan()
    local outposts = get_outposts_for_level(1)
    check("smart id resolved", outposts[1] and outposts[1].smart_id, 500)
    check("holding faction parsed from the section", outposts[1] and outposts[1].faction, "stalker")
    check("role phrase rendered", outposts[1] and outposts[1].service_role, "trader")
end)

group("scan: non-service squads are ignored", function()
    reset()
    add_other_squad(1, "stalker_sim_squad_novice")
    add_other_squad(2, "ap_service_notarole")           -- prefix but not a real role
    add_other_squad(3, "ap_service_stalker_plumber")    -- well-formed but unknown role
    scan()
    check("nothing is treated as an outpost", #get_outposts_for_level(1), 0)
end)

group("announcements: a new outpost after the baseline", function()
    reset()
    add_service_squad(10, "stalker", "trader", 500)
    scan()                       -- baseline
    check("baseline is silent", #_pda_calls, 0)

    add_service_squad(11, "stalker", "medic", 501)      -- new smart, new outpost
    _game_sec = _game_sec + 100000
    scan()
    check("the new outpost announces", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("as an established outpost", _pda_calls[1].message, "st_wom_outpost_established")
        check_contains("naming its location", _pda_calls[1].message, "SMART501")
    end
end)

group("announcements: the throttle does not eat the first message", function()
    -- _last_fire_sec starts at 0, which must mean "never fired", not "fired at game
    -- second zero". Treating it as a real timestamp suppressed the first announcement for
    -- the opening 10 in-game minutes of a new game, and suppressed delivery forever on any
    -- setup where xtime is unavailable and the clock reads a constant 0. Every other test
    -- here runs at game_sec 1000000+, which hid this entirely.
    reset()
    _game_sec = 0
    scan()                       -- baseline on an empty registry
    add_service_squad(30, "stalker", "trader", 600)
    scan()                       -- still at game_sec 0
    check("first announcement fires at game_sec 0", #_pda_calls, 1)

    -- The throttle must still apply once something has actually been delivered.
    add_service_squad(31, "stalker", "medic", 601)
    scan()
    check("a second announcement is throttled", #_pda_calls, 1)

    _game_sec = _game_sec + 100000
    scan()
    check("and arrives once the window elapses", #_pda_calls, 2)
end)

group("announcements: a later role at a known outpost", function()
    reset()
    add_service_squad(20, "stalker", "trader", 500)
    scan()                       -- baseline
    add_service_squad(21, "stalker", "medic", 500)      -- same smart, extra role
    _game_sec = _game_sec + 100000
    scan()
    check("the extra specialist announces", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("as a service addition", _pda_calls[1].message, "st_wom_outpost_service")
    end

    -- ... unless the player turned that off.
    reset()
    _announce_services = false
    add_service_squad(22, "stalker", "trader", 500)
    scan()
    add_service_squad(23, "stalker", "medic", 500)
    _game_sec = _game_sec + 100000
    scan()
    check("suppressed when announce_services is off", #_pda_calls, 0)
    check("but the outpost still knows both roles",
        get_outposts_for_level(1)[1].service_list, "trader+medic")
end)

group("relevance and gating", function()
    reset()
    add_service_squad(30, "killer", "trader", 500)      -- neither the player's faction nor an ally
    scan()
    add_service_squad(31, "killer", "medic", 501)
    _game_sec = _game_sec + 100000
    scan()
    check("an unrelated faction's outpost stays quiet", #_pda_calls, 0)

    reset()
    _enabled = false
    add_service_squad(32, "stalker", "trader", 500)
    scan()
    check("disabled feature reports no outposts", #get_outposts_for_level(1), 0)

    reset()
    add_service_squad(33, "stalker", "trader", 500)
    scan()
    check("other levels are filtered out", #get_outposts_for_level(99), 0)
end)

group("decay: an outpost that disappears drops out", function()
    reset()
    add_service_squad(40, "stalker", "trader", 500)
    scan()
    check("known after baseline", #get_outposts_for_level(1), 1)

    _squads = {}                 -- registry now empty: transient, not four decays at once
    _game_sec = _game_sec + 100000
    scan()
    check("an empty registry read is ignored", #get_outposts_for_level(1), 1)

    add_other_squad(99, "stalker_sim_squad_novice")     -- registry populated, service gone
    _game_sec = _game_sec + 100000
    scan()
    check("a genuinely gone outpost is forgotten", #get_outposts_for_level(1), 0)
end)

group("describe_roles", function()
    check("empty set", (describe_roles({})), "")
    local list, first = describe_roles({ medic = true, trader = true })
    check("canonical order", list, "trader+medic")
    check("first role in canonical order", first, "trader")
    check("unknown roles are dropped", (describe_roles({ plumber = true })), "")
    check("role_phrase rejects a non-role", role_phrase("plumber"), "")
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
