-- tests/test_wom_combat.lua
-- Standalone Lua 5.1 tests for wom_combat.script.
--
-- Run from the repository root:  lua tests/test_wom_combat.lua
-- Run from tests/:               lua test_wom_combat.lua
--
-- wom_combat is the hottest path in the mod: it runs inside three engine death
-- callbacks, so every death in the simulation — online and offline, human and
-- mutant — pays its cost and inherits its bugs. It is also the only module that
-- persists across saves. Until this file existed none of that was covered.
--
-- What the suite pins down, and why each one is load-bearing:
--
--   * Dedup. Online deaths fire BOTH npc_on_death_callback and squad_on_npc_death.
--     Without the DEDUP_WINDOW guard every online squad death is counted twice and
--     every recap doubles its casualty figures.
--   * Engagement folding. The (level_id, smart_id, ENC_WINDOW) key is what turns a
--     firefight into one story instead of nine. Unlocated deaths (smart_id == nil)
--     must NEVER fold — folding them would merge a Zaton kill into a Cordon one.
--   * Level confinement of the smart lookup. Positions are per-level coordinate
--     frames. The suite asserts nearest_smart_id is handed the VICTIM's level id,
--     not left to default to the actor's, and that a squad smart on another level
--     is discarded rather than used.
--   * Object shape. get_object_position must be the only way a position is read;
--     a client object's `position` is a METHOD and reading it as a field yields the
--     function, which is truthy, sails past every nil guard, and crashes inside
--     xsmart.find_smart. That is the shipped Miracle Machine CTD.
--   * Save/load. SAVE_VERSION mismatch, a corrupt payload, and a missing id counter
--     must each degrade to empty/derived state rather than propagating garbage into
--     a live session.
--   * Trim. RETENTION_HOURS and MAX_ENGAGEMENTS are the only things bounding a table
--     that grows on every death in a 48-hour session.

-- ============================================================
-- Engine globals touched by the modules under test
-- ============================================================

local _time_hours = 12.5

level = {
    get_time_hours = function() return _time_hours end,
    object_by_id   = function() return nil end,
}

game   = { translate_string = function(key) return key end }
printf = function() end
db     = { storage = {} }

-- Game clock, driven by the tests.
local _game_sec = 0
xtime = { get_game_sec = function() return _game_sec end }

-- Server objects in these tests carry a plain `level_id` field; xlevel reads it.
xlevel = {
    get_level_id       = function(se) return se and se.level_id or nil end,
    get_actor_level    = function() return 999 end,   -- deliberately wrong, to catch defaults
}

-- Captured RegisterScriptCallback handlers. _on_save / _on_load are module-locals,
-- so registration is the only way a test can reach them.
local registered = {}
function RegisterScriptCallback(name, fn) registered[name] = fn end

-- The fake simulator. Tests populate _sim_objects[id].
local _sim_objects = {}
local _sim_present = true
function alife()
    if not _sim_present then return nil end
    return { object = function(_, id) return _sim_objects[id] end }
end

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."

local function load_script_as_module(path)
    local env = setmetatable({}, { __index = _G })
    local chunk
    if setfenv then
        chunk = assert(loadfile(path))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile(path, "t", env))
    end
    chunk()
    return env
end

-- wom_utils and wom_npc_role are pure and load for real: the object-shape and
-- level-confinement behaviour under test lives in them, and stubbing them out
-- would test the stubs.
wom_utils    = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_utils.script")
wom_npc_role = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_npc_role.script")

-- ---- stubs for the rest ------------------------------------------------------

-- Faction resolution: tests set _faction_of[object] before acting.
local _faction_of = setmetatable({}, { __mode = "k" })
wom_terminology_helper = {
    get_object_faction = function(_sim, obj, _squad)
        return obj and _faction_of[obj] or nil
    end,
}

local dedup_log = {}
local kill_log  = {}
wom_debug = {
    log_dedup = function(victim_id, gap) dedup_log[#dedup_log + 1] = { victim_id, gap } end,
    log_kill  = function(eng, k, v)      kill_log[#kill_log + 1]  = { eng.id, k, v }   end,
    log_trace = function() end,
}

-- xsquad backs wom_npc_role.smart_id_of_squad. A squad's assigned smart is read from
-- a plain `smart` field the tests set.
xsquad = {
    get_squad_smart = function(squad) return squad and squad.smart or nil end,
}

-- xsmart backs wom_npc_role.nearest_smart_id. Every call is recorded so the suite can
-- assert the level id that was handed down, not merely the smart that came back.
local find_smart_calls = {}
local _find_smart_result = nil
xsmart = {
    find_smart = function(pos, opts)
        find_smart_calls[#find_smart_calls + 1] = {
            pos = pos, level_id = opts and opts.level_id, max_distance = opts and opts.max_distance,
        }
        return _find_smart_result
    end,
}

wom_combat = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_combat.script")

-- ============================================================
-- Harness
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

local function group(name, fn)
    io.write("\n" .. name .. "\n")
    fn()
end

-- ============================================================
-- Object builders
-- ============================================================

local _next_object_id = 100

-- A server object: id, position and group_id are plain fields.
local function server_npc(faction, opts)
    opts = opts or {}
    _next_object_id = _next_object_id + 1
    local obj = {
        id       = opts.id or _next_object_id,
        position = opts.position or { x = 1, y = 0, z = 1 },
        group_id = opts.group_id,
        level_id = opts.level_id or 1,
    }
    _faction_of[obj] = faction
    _sim_objects[obj.id] = obj
    return obj
end

-- A client object: id and position are METHODS. This is the shape that has crashed
-- the mod twice; anything reading `.position` off one gets the function back.
local function client_npc(faction, opts)
    opts = opts or {}
    _next_object_id = _next_object_id + 1
    local id  = opts.id or _next_object_id
    local pos = opts.position or { x = 5, y = 0, z = 5 }
    local obj = {
        id       = function() return id end,
        position = function() return pos end,
    }
    _faction_of[obj] = faction
    return obj, id
end

-- A squad server object: `id` and `position` are fields, `smart` is what xsquad reports.
local function squad_object(opts)
    opts = opts or {}
    _next_object_id = _next_object_id + 1
    local squad = {
        id         = opts.id or _next_object_id,
        position   = opts.position,
        smart      = opts.smart,
        npc_count  = function(self) return opts.count or 0 end,
    }
    _sim_objects[squad.id] = squad
    return squad
end

-- Resets everything the module and the fakes hold, then re-runs on_game_start so the
-- callbacks are re-registered against fresh state.
local function reset(now_sec)
    _game_sec        = now_sec or 0
    _sim_objects     = {}
    _find_smart_result = nil
    find_smart_calls = {}
    dedup_log        = {}
    kill_log         = {}
    _sim_present     = true
    _next_object_id  = 100
    wom_combat.on_game_start()
end

local function engagements() return wom_combat.get_engagements() end

-- ============================================================
-- 1. Dedup guard
-- ============================================================

group("1. Dedup guard (the double-count that doubles every recap figure)", function()
    reset(1000)
    local victim = server_npc("stalker", { level_id = 1 })
    local killer = server_npc("bandit",  { level_id = 1 })

    -- Same death arriving twice, as it does for every online squad member.
    wom_combat.on_squad_npc_death(nil, victim, killer)
    wom_combat.on_squad_npc_death(nil, victim, killer)

    check("one engagement after a duplicated death", #engagements(), 1)
    check("victim credited exactly one loss", engagements()[1].total_losses, 1)
    check("killer credited exactly one kill", engagements()[1].total_kills, 1)
    check("the suppression was logged", #dedup_log, 1)

    -- Past the DEDUP_WINDOW the same id is a legitimately different death
    -- (id reuse), so it must record again. These deaths are unlocated, so the new
    -- record lands in its own engagement rather than folding — see suite 3.
    _game_sec = 1000 + 5
    wom_combat.on_squad_npc_death(nil, victim, killer)
    check("recorded again once DEDUP_WINDOW has elapsed", #engagements(), 2)
    check("...as a fresh loss", engagements()[2].total_losses, 1)
end)

-- ============================================================
-- 2. Skip conditions
-- ============================================================

group("2. Skip conditions", function()
    reset(1000)
    local victim = server_npc("dolg", { level_id = 1 })
    local killer = server_npc("dolg", { level_id = 1 })
    wom_combat.on_squad_npc_death(nil, victim, killer)
    check("friendly fire creates no engagement", #engagements(), 0)

    reset(1000)
    local unknown = server_npc(nil, { level_id = 1 })
    wom_combat.on_squad_npc_death(nil, unknown, nil)
    check("unidentifiable victim creates no engagement", #engagements(), 0)

    reset(1000)
    -- level_id nil: xlevel.get_level_id returns nil, so wom_utils.get_level_id does too.
    local nowhere = server_npc("stalker", { level_id = false })
    nowhere.level_id = nil
    wom_combat.on_squad_npc_death(nil, nowhere, nil)
    check("unresolvable level creates no engagement", #engagements(), 0)

    reset(1000)
    -- A victim with no killer is still a real loss and must be recorded.
    local lone = server_npc("stalker", { level_id = 1 })
    wom_combat.on_squad_npc_death(nil, lone, nil)
    check("killerless death still records a loss", #engagements(), 1)
    check("...with no kill credited", engagements()[1].total_kills, 0)
end)

-- ============================================================
-- 3. Engagement folding
-- ============================================================

group("3. Engagement folding on (level, smart, window)", function()
    reset(1000)
    local squad = squad_object({ smart = { id = 7 }, count = 3 })
    local v1 = server_npc("stalker", { level_id = 1 })
    local v2 = server_npc("stalker", { level_id = 1 })
    wom_combat.on_squad_npc_death(squad, v1, server_npc("bandit", { level_id = 1 }))
    _game_sec = 1000 + 100
    wom_combat.on_squad_npc_death(squad, v2, server_npc("bandit", { level_id = 1 }))

    check("two deaths at one smart inside the window fold into one engagement", #engagements(), 1)
    check("losses accumulate", engagements()[1].total_losses, 2)
    check("t_last advances to the newest death", engagements()[1].t_last, 1100)
    check("t_start stays at the first death", engagements()[1].t_start, 1000)

    -- Past ENC_WINDOW (900s) the same place is a new fight.
    _game_sec = 1100 + 901
    wom_combat.on_squad_npc_death(squad, server_npc("stalker", { level_id = 1 }),
                                         server_npc("bandit",  { level_id = 1 }))
    check("a death past ENC_WINDOW starts a new engagement", #engagements(), 2)

    -- Different smart, same instant: never folds.
    reset(1000)
    local squad_a = squad_object({ smart = { id = 7 } })
    local squad_b = squad_object({ smart = { id = 8 } })
    wom_combat.on_squad_npc_death(squad_a, server_npc("stalker", { level_id = 1 }),
                                           server_npc("bandit",  { level_id = 1 }))
    wom_combat.on_squad_npc_death(squad_b, server_npc("stalker", { level_id = 1 }),
                                           server_npc("bandit",  { level_id = 1 }))
    check("different smart terrains stay separate", #engagements(), 2)

    -- Same smart id on a DIFFERENT level must not fold. smart_id is only unique
    -- within a level, so the level half of the key is what stops a Zaton fight
    -- being folded into a Cordon one.
    reset(1000)
    local shared_smart = squad_object({ smart = { id = 7 } })
    wom_combat.on_squad_npc_death(shared_smart, server_npc("stalker", { level_id = 1 }),
                                                server_npc("bandit",  { level_id = 1 }))
    wom_combat.on_squad_npc_death(shared_smart, server_npc("stalker", { level_id = 2 }),
                                                server_npc("bandit",  { level_id = 2 }))
    check("same smart id on another level stays separate", #engagements(), 2)

    -- Unlocated deaths must NEVER fold, even back to back at the same instant.
    reset(1000)
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("unlocated deaths never fold together", #engagements(), 2)
    check("both carry a nil smart_id", engagements()[1].smart_id == nil
                                       and engagements()[2].smart_id == nil, true)
end)

-- ============================================================
-- 4. Smart-terrain resolution and level confinement
-- ============================================================

group("4. Smart resolution: order, level confinement, and the crash guard", function()
    -- NPC path (prefer_squad = true): squad smart wins, position never consulted.
    reset(1000)
    local squad = squad_object({ smart = { id = 42 }, position = { x = 1, y = 0, z = 1 } })
    _find_smart_result = { id = 99 }
    wom_combat.on_squad_npc_death(squad, server_npc("stalker", { level_id = 3 }),
                                         server_npc("bandit",  { level_id = 3 }))
    check("NPC death anchors to the squad's smart", engagements()[1].smart_id, 42)
    check("...without paying for a position scan", #find_smart_calls, 0)

    -- NPC path with no squad smart: falls back to the position scan.
    reset(1000)
    local squadless = squad_object({ smart = nil, position = { x = 4, y = 0, z = 4 } })
    _find_smart_result = { id = 99 }
    wom_combat.on_squad_npc_death(squadless, server_npc("stalker", { level_id = 3 }),
                                             server_npc("bandit",  { level_id = 3 }))
    check("falls back to the nearest smart by position", engagements()[1].smart_id, 99)
    check("the scan is confined to the VICTIM's level, not the actor's",
          find_smart_calls[1].level_id, 3)
    check("...and uses the squad's position, not the NPC's",
          find_smart_calls[1].pos.x, 4)

    -- A squad smart that lives on another level is discarded, not used.
    reset(1000)
    local far_smart = { id = 55, level_id = 8 }
    _sim_objects[55] = far_smart
    local wrong_level_squad = squad_object({ smart = far_smart, position = { x = 2, y = 0, z = 2 } })
    _find_smart_result = nil
    wom_combat.on_squad_npc_death(wrong_level_squad, server_npc("stalker", { level_id = 3 }),
                                                     server_npc("bandit",  { level_id = 3 }))
    check("a squad smart on another level is discarded", engagements()[1].smart_id, nil)
    check("...and the position fallback is attempted instead", #find_smart_calls, 1)

    -- Monster path (prefer_squad = false): position first.
    reset(1000)
    local monster, monster_id = client_npc("bloodsucker", { position = { x = 9, y = 0, z = 9 } })
    _sim_objects[monster_id] = { id = monster_id, level_id = 4, group_id = 65535 }
    _faction_of[_sim_objects[monster_id]] = "bloodsucker"
    local hunter, hunter_id = client_npc("stalker")
    _sim_objects[hunter_id] = { id = hunter_id, level_id = 4 }
    _faction_of[_sim_objects[hunter_id]] = "stalker"
    _find_smart_result = { id = 77 }
    wom_combat.on_monster_death(monster, hunter)
    check("monster death anchors by position first", engagements()[1].smart_id, 77)
    check("the monster scan is confined to the victim's level", find_smart_calls[1].level_id, 4)
    check("the client object's position was RESOLVED, not read as a field",
          type(find_smart_calls[1].pos), "table")
    check("...and carries the real coordinates", find_smart_calls[1].pos.x, 9)

    -- The crash guard: a raw function reaching nearest_smart_id must be refused,
    -- not passed on to xsmart.find_smart (which would index pos.x and CTD).
    local before = #find_smart_calls
    check("a function position is refused outright",
          wom_npc_role.nearest_smart_id(function() end, nil, 1), nil)
    check("...and never reaches find_smart", #find_smart_calls, before)
end)

-- ============================================================
-- 5. Squad participation and sizes
-- ============================================================

group("5. Squad participation and initial sizes", function()
    reset(1000)
    -- npc_count() has already decremented by the time the callback runs, so the
    -- victim's squad size must be recorded as count + 1. Getting this wrong
    -- under-reports every enemy force by one in the recap.
    local victim_squad = squad_object({ smart = { id = 7 }, count = 3 })
    local killer_squad = squad_object({ smart = { id = 7 }, count = 5 })
    local killer = server_npc("bandit", { level_id = 1, group_id = killer_squad.id })

    wom_combat.on_squad_npc_death(victim_squad, server_npc("stalker", { level_id = 1 }), killer)

    local eng = engagements()[1]
    check("victim squad size is npc_count + 1", eng.squad_sizes[victim_squad.id], 4)
    check("killer squad size is npc_count as-is", eng.squad_sizes[killer_squad.id], 5)
    check("victim squad faction recorded", eng.squad_factions[victim_squad.id], "stalker")
    check("killer squad faction recorded", eng.squad_factions[killer_squad.id], "bandit")
    check("victim squad marked a participant", eng.squads[victim_squad.id], true)
    check("killer squad marked a participant", eng.squads[killer_squad.id], true)

    -- Second death from the same squad must not overwrite the first-seen size.
    _game_sec = 1010
    wom_combat.on_squad_npc_death(victim_squad, server_npc("stalker", { level_id = 1 }), killer)
    check("size is captured once, at first appearance", eng.squad_sizes[victim_squad.id], 4)

    -- The engine's "no squad" sentinel must not be treated as a squad id.
    reset(1000)
    local orphan_killer = server_npc("bandit", { level_id = 1, group_id = 65535 })
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }), orphan_killer)
    local sentinel_seen = engagements()[1].squads[65535]
    check("INVALID_GROUP_ID is never recorded as a participant squad", sentinel_seen, nil)
end)

-- ============================================================
-- 6. Clock stamp
-- ============================================================

group("6. Wall-clock stamp", function()
    reset(1000)
    _time_hours = 7.5
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("started_clock is the calendar clock, zero-padded", engagements()[1].started_clock, "07:30")

    reset(1000)
    _time_hours = 23.99
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("late-hour stamp does not roll over to 24:xx", engagements()[1].started_clock, "23:59")
    _time_hours = 12.5
end)

-- ============================================================
-- 7. Trim: retention and capacity
-- ============================================================

group("7. Trim: retention window and capacity cap", function()
    reset(0)
    -- One located engagement at t=0, then a death 49 in-game hours later. The trim
    -- on the second death must evict the first (RETENTION_HOURS = 48).
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("first engagement exists", #engagements(), 1)
    _game_sec = 49 * 3600
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("an engagement past RETENTION_HOURS is evicted", #engagements(), 1)
    check("the survivor is the recent one", engagements()[1].t_start, 49 * 3600)

    -- Capacity: 60 unlocated deaths, each its own engagement, capped at 50 newest.
    reset(0)
    for i = 1, 60 do
        _game_sec = i          -- inside the retention window, outside dedup collisions
        wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                           server_npc("bandit",  { level_id = 1 }))
    end
    check("engagement count is capped at MAX_ENGAGEMENTS", #engagements(), 50)
    check("the OLDEST are evicted, newest kept", engagements()[#engagements()].t_start, 60)
    check("...and the surviving head is the 11th death", engagements()[1].t_start, 11)

    -- Ids stay monotonic across eviction: a recap must never see two engagements
    -- claiming the same id.
    local seen_ids = {}
    local duplicate = false
    for _, eng in ipairs(engagements()) do
        if seen_ids[eng.id] then duplicate = true end
        seen_ids[eng.id] = true
    end
    check("engagement ids remain unique after eviction", duplicate, false)
end)

-- ============================================================
-- 8. Queries
-- ============================================================

group("8. Query helpers", function()
    reset(1000)
    local squad_a = squad_object({ smart = { id = 7 } })
    local squad_b = squad_object({ smart = { id = 8 } })
    wom_combat.on_squad_npc_death(squad_a, server_npc("stalker", { level_id = 1 }),
                                           server_npc("bandit",  { level_id = 1 }))
    wom_combat.on_squad_npc_death(squad_b, server_npc("stalker", { level_id = 2 }),
                                           server_npc("bandit",  { level_id = 2 }))

    check("get_engagements_for_level filters by level", #wom_combat.get_engagements_for_level(1), 1)
    check("...and finds the other one too",            #wom_combat.get_engagements_for_level(2), 1)
    check("an empty level yields an empty array",      #wom_combat.get_engagements_for_level(3), 0)
    check("get_engagements_for_smart filters by smart", #wom_combat.get_engagements_for_smart(7), 1)
    check("an unknown smart yields an empty array",     #wom_combat.get_engagements_for_smart(99), 0)

    -- get_engagements_for_smart deliberately does NOT filter by level, so a smart id
    -- shared across levels returns both. Pinned here because the recap callers pass
    -- level-filtered input; a future caller that does not would silently cross maps.
    reset(1000)
    local shared = squad_object({ smart = { id = 7 } })
    wom_combat.on_squad_npc_death(shared, server_npc("stalker", { level_id = 1 }),
                                          server_npc("bandit",  { level_id = 1 }))
    wom_combat.on_squad_npc_death(shared, server_npc("stalker", { level_id = 2 }),
                                          server_npc("bandit",  { level_id = 2 }))
    check("get_engagements_for_smart is level-agnostic by design",
          #wom_combat.get_engagements_for_smart(7), 2)
end)

-- ============================================================
-- 9. Save / load
-- ============================================================

group("9. Save / load", function()
    reset(1000)
    local squad = squad_object({ smart = { id = 7 }, count = 2 })
    wom_combat.on_squad_npc_death(squad, server_npc("stalker", { level_id = 1 }),
                                         server_npc("bandit",  { level_id = 1 }))

    local md = {}
    registered.save_state(md)
    local saved = md["word_of_mouth_combat"]
    check("save writes under the namespaced key", type(saved), "table")
    check("...with a version stamp", saved.v, 1)
    check("...and the engagement array", #saved.e, 1)
    check("...and the id counter", saved.nid, 2)

    -- Round trip through a fresh session.
    reset(1000)
    check("state is empty after on_game_start", #engagements(), 0)
    registered.load_state(md)
    check("load restores the engagements", #engagements(), 1)
    check("...with their smart terrain intact", engagements()[1].smart_id, 7)

    -- A save from an incompatible version must be dropped, not partially adopted.
    reset(1000)
    registered.load_state({ ["word_of_mouth_combat"] = { v = 0, e = { { id = 1 } }, nid = 9 } })
    check("a stale SAVE_VERSION discards the payload", #engagements(), 0)

    -- Garbage in the payload must degrade the same way.
    reset(1000)
    registered.load_state({ ["word_of_mouth_combat"] = { v = 1, e = "not a table" } })
    check("a non-table engagement list discards the payload", #engagements(), 0)

    reset(1000)
    registered.load_state({})
    check("an absent key leaves state empty", #engagements(), 0)
    reset(1000)
    registered.load_state(nil)
    check("a nil metadata table is tolerated", #engagements(), 0)

    -- A save written before nid existed must derive a counter rather than restart at 1,
    -- which would hand a fresh engagement an id an existing one already holds.
    reset(1000)
    registered.load_state({ ["word_of_mouth_combat"] = {
        v = 1,
        e = { { id = 1, level_id = 1, t_start = 1000, t_last = 1000, factions = {},
                squads = {}, squad_sizes = {}, squad_factions = {},
                total_kills = 0, total_losses = 0 },
              { id = 2, level_id = 1, t_start = 1000, t_last = 1000, factions = {},
                squads = {}, squad_sizes = {}, squad_factions = {},
                total_kills = 0, total_losses = 0 } },
    } })
    check("a missing id counter is derived from the array", #engagements(), 2)
    _game_sec = 2000
    wom_combat.on_squad_npc_death(nil, server_npc("stalker", { level_id = 1 }),
                                       server_npc("bandit",  { level_id = 1 }))
    check("...and the next engagement gets a non-colliding id", engagements()[3].id, 3)
end)

-- ============================================================
-- 10. Callback entry points and lifecycle hazards
-- ============================================================

group("10. Callback entry points", function()
    -- on_npc_death receives CLIENT objects. Every read of id/position must go through
    -- the shape helpers; a field read here is the shipped CTD.
    reset(1000)
    local victim, victim_id = client_npc("stalker", { position = { x = 3, y = 0, z = 3 } })
    _sim_objects[victim_id] = { id = victim_id, level_id = 1, group_id = 65535 }
    _faction_of[_sim_objects[victim_id]] = "stalker"
    local killer, killer_id = client_npc("bandit")
    _sim_objects[killer_id] = { id = killer_id, level_id = 1 }
    _faction_of[_sim_objects[killer_id]] = "bandit"
    _find_smart_result = { id = 21 }

    wom_combat.on_npc_death(victim, killer)
    check("on_npc_death records from client objects", #engagements(), 1)
    check("...anchored via the resolved position", engagements()[1].smart_id, 21)
    check("...crediting the killer", engagements()[1].total_kills, 1)

    -- No simulator (mid-transition): must return quietly, not raise inside a callback.
    reset(1000)
    _sim_present = false
    local ok = pcall(wom_combat.on_npc_death, client_npc("stalker"), nil)
    check("on_npc_death survives a missing simulator", ok, true)
    check("...and records nothing", #engagements(), 0)
    ok = pcall(wom_combat.on_monster_death, client_npc("bloodsucker"), nil)
    check("on_monster_death survives a missing simulator", ok, true)
    _sim_present = true

    -- on_squad_npc_death is the only callback that may run with no simulator at all
    -- (offline deaths on an unloaded map), so it must not require one.
    reset(1000)
    _sim_present = false
    ok = pcall(wom_combat.on_squad_npc_death, nil,
               server_npc("stalker", { level_id = 1 }), server_npc("bandit", { level_id = 1 }))
    check("on_squad_npc_death survives a missing simulator", ok, true)
    check("...and still records the loss", #engagements(), 1)
    _sim_present = true

    -- The squad's position is preferred over the NPC's: for an offline death the
    -- squad's aggregate position is the reliably-set one.
    reset(1000)
    local located_squad = squad_object({ smart = nil, position = { x = 6, y = 0, z = 6 } })
    _find_smart_result = { id = 31 }
    wom_combat.on_squad_npc_death(located_squad,
                                  server_npc("stalker", { level_id = 1, position = { x = 1, y = 0, z = 1 } }),
                                  server_npc("bandit",  { level_id = 1 }))
    check("the squad position wins over the NPC's", find_smart_calls[1].pos.x, 6)

    -- A squad with no position at all falls back to the NPC's.
    reset(1000)
    local posless_squad = squad_object({ smart = nil, position = nil })
    _find_smart_result = { id = 41 }
    wom_combat.on_squad_npc_death(posless_squad,
                                  server_npc("stalker", { level_id = 1, position = { x = 8, y = 0, z = 8 } }),
                                  server_npc("bandit",  { level_id = 1 }))
    check("falls back to the NPC position when the squad has none",
          find_smart_calls[1] and find_smart_calls[1].pos.x, 8)

    -- Mixed shapes in one call: server squad, CLIENT npc. This is what the online
    -- branch of squad_on_npc_death hands over. Two things are pinned here.
    --
    -- First, it must not raise: reading position off a client object as a field
    -- yields the method and detonates downstream, and a raise inside a death
    -- callback is a CTD.
    --
    -- Second, the record is silently DROPPED, because on_squad_npc_death passes the
    -- client object straight through as victim_se and wom_utils.get_level_id needs a
    -- server object to resolve a level. That is harmless today only because an online
    -- death has already been recorded by on_npc_death (which does resolve the server
    -- object) and this call is the dedup duplicate anyway. It is pinned rather than
    -- fixed so the coupling is visible: if the online callbacks ever stop firing
    -- first, or dedup is retuned, this path starts losing online squad deaths.
    reset(1000)
    local mixed_squad = squad_object({ smart = nil, position = { x = 6, y = 0, z = 6 } })
    local client_victim, client_victim_id = client_npc("stalker", { position = { x = 1, y = 0, z = 1 } })
    _sim_objects[client_victim_id] = { id = client_victim_id, level_id = 1 }
    _find_smart_result = { id = 31 }
    ok = pcall(wom_combat.on_squad_npc_death, mixed_squad, client_victim,
               server_npc("bandit", { level_id = 1 }))
    check("mixed server/client shapes do not raise", ok, true)
    check("...but the client-object victim cannot resolve a level, so nothing records",
          #engagements(), 0)
end)

-- ============================================================
-- 11. Dedup table stays bounded
-- ============================================================

group("11. Dedup table is pruned even when every death is skipped", function()
    -- Same-faction infighting never reaches _trim, so _prune_dedup has to run on the
    -- unconditional path. If it did not, a long session of friendly fire would grow
    -- _processed_deaths without bound. Observable only through behaviour: a victim id
    -- recorded long ago must no longer suppress a fresh death.
    reset(1000)
    local a = server_npc("dolg", { level_id = 1, id = 500 })
    local b = server_npc("dolg", { level_id = 1 })
    for i = 1, 20 do
        _game_sec = 1000 + i * 100
        wom_combat.on_squad_npc_death(nil, a, b)   -- friendly fire: always skipped
    end
    check("friendly fire recorded nothing", #engagements(), 0)

    -- id 500 was stamped repeatedly but is long expired by now; a real death on that
    -- id must record rather than be swallowed by a stale dedup entry.
    _game_sec = 1000 + 20 * 100 + 50
    _faction_of[a] = "stalker"
    wom_combat.on_squad_npc_death(nil, a, server_npc("bandit", { level_id = 1 }))
    check("a stale dedup entry does not suppress a later death", #engagements(), 1)
end)

-- ============================================================

io.write(string.format("\nResults: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
