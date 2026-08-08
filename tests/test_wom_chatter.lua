-- tests/test_wom_chatter.lua
-- Standalone Lua 5.1 tests for wom_chatter.script.
--
-- Run from the repository root:  lua tests/test_wom_chatter.lua
-- Run from tests/:               lua test_wom_chatter.lua
--
-- wom_chatter has no public API beyond on_game_start.  Strategy (same as
-- test_wom_campfire): mock CreateTimeEvent to capture the _on_timer callback, then
-- invoke it directly to drive _poll_goal_changes and observe side-effects through
-- spies on give_game_news and play_hello_bark.
--
-- What these tests exist to pin, beyond "it still announces":
--
--   * The COST SHAPE.  The scan's whole design is that per-NPC work is at most one
--     luabind crossing and that client game objects are resolved only for a squad
--     that is actually about to speak.  Both are invisible to an output-only test and
--     both are easy to undo by accident, so _crossings and _live_npc_calls count them
--     and several tests assert on the counts directly.
--
--   * The MEMBERSHIP CACHE.  Correctness here is about what is NOT cached (positions,
--     across a reload) as much as what is.  The clock is driven manually via _now_ms
--     so TTL expiry and the backwards-jump case are testable without sleeping.
--
-- Baseline behaviour: the first sighting of a squad's goal only baselines _last_goal,
-- so every announce test has to run the timer twice with a changed cons_id.

-- ============================================================
-- Mutable test state
-- ============================================================

local _pda_calls       = {}    -- { name, styled } per give_game_news call
local _bark_count      = 0
local _timer_callback  = nil
local _now_ms          = 1000  -- drives time_global(); advanced explicitly by tests

local _server_npcs     = {}    -- npc_id   -> { group_id, position, character_name }
local _server_squads   = {}    -- squad_id -> squad server object stub
local _client_npcs     = {}    -- npc_id   -> client object stub (nil = offline/destroyed)
local _assigned        = {}    -- squad_id -> AP assigned record

-- Cost counters: every stubbed luabind-equivalent call bumps _crossings.
local _crossings       = 0
local _live_npc_calls  = 0

-- MCM knobs
local _chatter_enabled = true
local _dev_mode        = false
local _chatter_range   = 50

-- ============================================================
-- STALKER / engine global stubs
-- ============================================================

time_global = function() return _now_ms end

printf = nil  -- suppress in-module logging

game = {
    translate_string = function(key) return key end,
}

CreateTimeEvent = function(id, ev, interval, callback) _timer_callback = callback end
ResetTimeEvent  = function() end

-- Positions are plain tables carrying x/y/z, which is all _distance_sqr reads.
local function pos(x, y, z)
    return { x = x or 0, y = y or 0, z = z or 0 }
end

local _actor = {
    id       = function() return 0 end,
    position = function() return pos(0, 0, 0) end,
    give_game_news = function(self, name, styled)
        _pda_calls[#_pda_calls + 1] = { name = name, styled = styled }
    end,
}

db = { actor = _actor, OnlineStalkers = {}, storage = {} }

-- alife():object is the crossing the scan is trying to avoid paying per NPC, so it is
-- the primary thing counted.  Serves both NPC and squad server objects, as the real one does.
alife = function()
    return {
        object = function(self, id)
            _crossings = _crossings + 1
            return _server_npcs[id] or _server_squads[id]
        end,
    }
end

ap_api = {
    get_record = function(opts)
        return opts and opts.squad_id and _assigned[opts.squad_id] or nil
    end,
    get_scripted_squads = function() return {} end,
}

xtime = { game_sec = function() return 0 end }

-- xsquad is deliberately absent: the module must derive membership from the
-- server-object group_id field rather than reaching for xsquad.get_squad_by_member,
-- which costs two crossings to return a squad object the scan does not want.
xsquad = nil

-- ============================================================
-- Module stubs
-- ============================================================

wom_mcm = {
    chatter_enabled = function() return _chatter_enabled end,
    dev_mode        = function() return _dev_mode end,
    chatter_range   = function() return _chatter_range end,
    get_goal_visibility = function() return "public" end,
}

wom_bark = {
    is_human_faction = function(faction)
        return faction == "stalker" or faction == "dolg" or faction == "csky"
    end,
    send_pda = function(npc, message, tag)
        _bark_count = _bark_count + 1
        db.actor:give_game_news(npc:character_name(), message)
    end,
    mark_spoke = function() end,
}

wom_utils = {
    -- Counted separately from _crossings: the design claim is not merely "few crossings"
    -- but specifically that no client object is resolved unless a squad will speak.
    get_live_online_npc = function(id)
        _live_npc_calls = _live_npc_calls + 1
        return _client_npcs[id]
    end,
}

wom_npc_role = {
    -- nil = leader is not slotted into any smart, so _is_same_terrain_goal never suppresses.
    current_smart = function(npc) return nil end,
}

wom_dialogue_helper = {
    pick_dialogue_variant = function(prefix, slots, gated)
        if prefix == "st_wom_goal_generic" then return "moving out" end
        return ""
    end,
    get_npc_first_name = function(server_id)
        local se = _server_npcs[server_id]
        return se and se.first_name or "them"
    end,
}

wom_terminology_helper = {
    get_location_name = function(smart_id) return smart_id and "the test camp" or "" end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir  = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
dofile(script_dir .. "/../gamedata/scripts/wom_chatter.script")

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

local function check_true(label, got)  check(label, not not got, true)  end
local function check_false(label, got) check(label, not not got, false) end

local function suite(title, fn)
    io.write(string.format("[%s]\n", title))
    fn()
    io.write("\n")
end

-- ============================================================
-- Fixture builders
-- ============================================================

-- Resets all mutable state and re-arms the timer via on_game_start.
local function reset()
    _pda_calls, _bark_count = {}, 0
    _server_npcs, _server_squads, _client_npcs, _assigned = {}, {}, {}, {}
    db.OnlineStalkers = {}
    _crossings, _live_npc_calls = 0, 0
    _chatter_enabled, _dev_mode, _chatter_range = true, false, 50
    _now_ms = 1000
    on_game_start()   -- clears _last_goal and _squad_of_npc, captures _on_timer
end

-- Adds an online NPC with a server object, and (unless offline) a client object.
-- distance is along x, so r_sqr comparisons are exact.
local function add_npc(id, squad_id, distance, opts)
    opts = opts or {}
    _server_npcs[id] = {
        group_id   = squad_id or 65535,
        position   = pos(distance or 0, 0, 0),
        first_name = opts.first_name,
    }
    if not opts.offline then
        _client_npcs[id] = {
            id             = function() return id end,
            character_name = function() return opts.name or ("npc" .. id) end,
            position       = function() return pos(distance or 0, 0, 0) end,
        }
    end
    db.OnlineStalkers[#db.OnlineStalkers + 1] = id
end

-- Adds a squad server object.  player_id is a plain field (free); npc_count and
-- commander_id are methods (one crossing each in the real engine).
local function add_squad(squad_id, commander_id, opts)
    opts = opts or {}
    _server_squads[squad_id] = {
        player_id    = opts.faction or "stalker",
        npc_count    = function() return opts.count or 2 end,
        commander_id = function() return commander_id end,
    }
end

local function set_goal(squad_id, cons_id)
    _assigned[squad_id] = { cons_id = cons_id, consequence_key = "consequence:job_explore", smart_id = 77 }
end

local function tick() _timer_callback() end

-- Runs one tick to baseline the squad's goal, then changes it and ticks again.
-- Counters are zeroed between the two so assertions describe the announcing tick only.
local function baseline_then_change(squad_id, new_cons_id)
    tick()
    _crossings, _live_npc_calls = 0, 0
    _pda_calls, _bark_count = {}, 0
    set_goal(squad_id, new_cons_id)
    tick()
end

-- ============================================================
-- Suite 1: announce behaviour
-- ============================================================

suite("1. announce behaviour", function()
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5, { first_name = "Boris" })
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    check("first sighting baselines only, no announce", #_pda_calls, 0)

    set_goal(1, 200)
    tick()
    check("goal change announces", #_pda_calls, 1)
    check("attributed to the commander", _pda_calls[1] and _pda_calls[1].name, "npc10")
    check("hello bark played", _bark_count, 1)

    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    tick()
    check("unchanged goal does not re-announce", #_pda_calls, 0)
end)

-- ============================================================
-- Suite 2: gates
-- ============================================================

suite("2. gates", function()
    reset()
    add_npc(10, 1, 500)   -- well beyond range 50
    add_npc(11, 1, 500)
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("commander out of range does not announce", #_pda_calls, 0)

    reset()
    _dev_mode = true
    add_npc(10, 1, 5000)
    add_npc(11, 1, 5000)
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("dev mode ignores range", #_pda_calls, 1)

    -- The earshot test is on the COMMANDER, not on any member: a squadmate standing next
    -- to the player does not make a distant leader audible.
    reset()
    add_npc(10, 1, 500)   -- commander, far
    add_npc(11, 1, 1)     -- member, adjacent
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("near member does not qualify a far commander", #_pda_calls, 0)

    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10, { faction = "monolith" })
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("non-human faction skipped", #_pda_calls, 0)

    reset()
    add_npc(10, 1, 5)
    add_squad(1, 10, { count = 1 })
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("solo squad skipped (no talking to oneself)", #_pda_calls, 0)

    -- The commander must be online: an offline commander has no client object to speak
    -- through, and the squad must not fall back to some other member.
    reset()
    add_npc(10, 1, 5, { offline = true })
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("offline commander does not announce", #_pda_calls, 0)

    -- A goal change that could not be spoken must NOT be consumed. Regression test: the
    -- _last_goal write originally sat above the speaker resolution, so a commander who was
    -- momentarily unresolvable (dead, destroyed, mid-transition) silently ate the change —
    -- the next tick compared equal and the line was lost for good. Pass 1 no longer filters
    -- on liveness, so this is the only place that condition is caught.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()                       -- baseline
    _client_npcs[10] = nil       -- commander becomes unresolvable
    set_goal(1, 200)
    tick()
    check("unresolvable commander does not announce", #_pda_calls, 0)
    _client_npcs[10] = {         -- commander live again, same pending goal
        id             = function() return 10 end,
        character_name = function() return "npc10" end,
        position       = function() return pos(5, 0, 0) end,
    }
    tick()
    check("pending goal change survives and announces later", #_pda_calls, 1)

    reset()
    add_npc(10, 65535, 5)   -- in no squad
    add_npc(11, 65535, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("ungrouped NPCs form no squad", #_pda_calls, 0)

    reset()
    _chatter_enabled = false
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    tick()
    check("disabled in MCM does nothing", #_pda_calls, 0)
end)

-- ============================================================
-- Suite 3: cost shape
-- ============================================================

suite("3. cost shape", function()
    -- 20 online NPCs across 10 squads, none of which changes goal.  This is the ordinary
    -- tick, and it must not resolve a single client object.
    reset()
    -- NPC ids start at 1000 so they cannot collide with squad ids: alife():object serves
    -- both from one id space (as the real engine does), and an overlapping id would hand
    -- back an NPC server object where a squad was wanted.
    for squad_id = 1, 10 do
        local commander = 1000 + squad_id * 10
        add_npc(commander, squad_id, 5)
        add_npc(commander + 1, squad_id, 5)
        add_squad(squad_id, commander)
        set_goal(squad_id, 100 + squad_id)
    end
    tick()
    _crossings, _live_npc_calls = 0, 0
    tick()   -- second tick: memberships cached, no goal changes

    check("no client objects resolved on a quiet tick", _live_npc_calls, 0)
    -- Per squad: sim:object(squad_id), commander_id's server object for the range test.
    -- Per NPC: zero, because membership is cached.  20 NPCs + 10 squads => 20, not 120.
    check("crossings scale with squads, not online NPCs", _crossings, 20)

    -- Exactly one client object on the tick that speaks: the speaker's.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("announcing tick resolves exactly one client object", _live_npc_calls, 1)

    -- A squad rejected by a free gate must not reach the position crossing at all.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10, { faction = "monolith" })
    set_goal(1, 100)
    tick()
    _crossings = 0
    tick()
    check("faction-rejected squad costs one crossing, not two", _crossings, 1)
end)

-- ============================================================
-- Suite 4: membership cache
-- ============================================================

suite("4. membership cache", function()
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    local first_tick_crossings = _crossings
    _crossings = 0
    tick()
    check_true("first tick pays per-NPC crossings", first_tick_crossings > _crossings)
    check("second tick pays none for membership", _crossings, 2)  -- squad + commander pos only

    -- TTL expiry re-derives membership.  MEMBERSHIP_TTL_MS is 60000 and jitter tops out
    -- at 15000, so 80s guarantees expiry regardless of the roll.
    _now_ms = _now_ms + 80000
    _crossings = 0
    tick()
    check("membership re-derived after TTL", _crossings, 4)  -- 2 NPCs + squad + commander pos

    -- A backwards time_global jump (level change / load) must expire rather than pin the
    -- entry: serving a cached membership until the clock catches up is the worse failure.
    _now_ms = 500
    _crossings = 0
    tick()
    check("backwards clock jump re-derives", _crossings, 4)

    -- Positions must never be cached: the same NPC, unmoved in the cache but moved in the
    -- world, has to fall out of earshot immediately rather than after a TTL.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    _server_npcs[10].position = pos(500, 0, 0)   -- commander walks away, membership unchanged
    set_goal(1, 200)
    _pda_calls = {}
    tick()
    check("position is read fresh, never cached", #_pda_calls, 0)

    -- Entries for NPCs that have gone offline must not accumulate for the session.
    -- Asserted on the cache's own size: a crossing count cannot see this, because a
    -- lingering entry is a cache HIT and therefore costs nothing — the leak is memory,
    -- not time, and would grow for the whole session as the player moves between areas.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    check("both NPCs cached", membership_cache_size(), 2)
    db.OnlineStalkers = { 10 }        -- 11 goes offline
    _server_npcs[11] = nil
    tick()
    check("offline NPC pruned from the cache", membership_cache_size(), 1)

    -- on_game_start must clear the cache: alife recycles object ids, so an entry carried
    -- across a reload could name a different NPC entirely.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    tick()
    on_game_start()
    _crossings = 0
    tick()
    check("reload clears membership cache", _crossings, 4)
end)

-- ============================================================
-- Suite 5: partner resolution
-- ============================================================

suite("5. partner resolution", function()
    -- Names come off the SERVER object now; a squad of exactly 2 names the other member.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5, { first_name = "Boris" })
    add_squad(1, 10, { count = 2 })
    set_goal(1, 100)
    local seen_partner
    wom_dialogue_helper.pick_dialogue_variant = function(prefix, slots)
        seen_partner = slots and slots.partner
        return prefix == "st_wom_goal_generic" and "moving out" or ""
    end
    baseline_then_change(1, 200)
    check("squad of 2 names the other member", seen_partner, "Boris")

    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)   -- no first_name -> get_npc_first_name returns "them"
    add_squad(1, 10, { count = 2 })
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("unresolvable name falls back to solo term", seen_partner, "st_wom_partner_solo")

    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5, { first_name = "Boris" })
    add_npc(12, 1, 5, { first_name = "Anton" })
    add_squad(1, 10, { count = 3 })
    set_goal(1, 100)
    baseline_then_change(1, 200)
    check("squad of 3+ uses the group term", seen_partner, "st_wom_partner_group")
end)

-- ============================================================
-- Suite 6: performance readout
-- ============================================================

suite("6. performance readout", function()
    -- Captures printf output for the duration of fn.
    --
    -- This stub mirrors Anomaly's printf (_g.script:612-630) and NOT string.format, which
    -- is the whole point: the real printf substitutes only %s, via a gsub on "%%s", and
    -- passes %d / %.3f through untouched. A string.format stub is laxer than the real API
    -- and manufactured a passing test for a readout that printed its raw format string
    -- verbatim in game. When varargs are absent the real one skips substitution entirely.
    local function with_printf(fn)
        local lines = {}
        printf = function(fmt, ...)
            fmt = tostring(fmt)
            if select('#', ...) >= 1 then
                local i, p = 0, { ... }
                fmt = string.gsub(fmt, "%%s", function()
                    i = i + 1
                    return tostring(p[i])
                end)
            end
            lines[#lines + 1] = fmt
        end
        fn()
        printf = nil
        return lines
    end

    -- Anything printf cannot substitute must already be resolved by the caller.
    local function check_fully_formatted(label, line)
        check_true(label, line and line:find("%%[-0-9.]*[dfisxX]") == nil)
    end

    -- Off by default: a normal session must not print a poll line every 5 seconds.
    reset()
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    local lines = with_printf(function() tick() end)
    check("no readout when dev mode is off", #lines, 0)

    reset()
    _dev_mode = true
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    lines = with_printf(function() tick() end)
    check("one readout line per poll in dev mode", #lines, 1)
    check_true("line reports elapsed ms", lines[1]:find("poll", 1, true) ~= nil)
    check_true("line carries the dev-mode caveat", lines[1]:find("range gate OFF", 1, true) ~= nil)
    -- Regression: this shipped printing "poll %.3fms | online=%d ..." to the console,
    -- because Anomaly's printf resolves %s only and the caller must format everything else.
    check_fully_formatted("no unsubstituted format specifiers reach the console", lines[1])

    -- Counters describe the poll just run.  With 2 online NPCs in 1 squad, a cold cache
    -- misses twice; the next poll misses zero, which is the whole point of the cache and
    -- the number worth watching in the console.
    check_true("cold poll reports 2 membership misses", lines[1]:find("membership_miss=2", 1, true) ~= nil)
    check_true("cold poll reports the online count", lines[1]:find("online=2", 1, true) ~= nil)
    check_true("cold poll reports the squad count", lines[1]:find("squads=1", 1, true) ~= nil)

    lines = with_printf(function() tick() end)
    check_true("warm poll reports 0 membership misses", lines[1]:find("membership_miss=0", 1, true) ~= nil)

    -- Counters must not accumulate across polls.
    lines = with_printf(function() tick() end)
    check_true("counts are per-poll, not cumulative", lines[1]:find("online=2", 1, true) ~= nil)

    -- A poll that raises still reports: hiding it would flatter the average.
    reset()
    _dev_mode = true
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    local original = wom_bark.is_human_faction
    wom_bark.is_human_faction = function() error("boom") end
    lines = with_printf(function() tick() end)
    wom_bark.is_human_faction = original
    check("failed poll still reports timing", #lines, 2)   -- scan error + poll line
    check_true("timing line present after a raise",
        (lines[1]:find("poll", 1, true) or lines[2]:find("poll", 1, true)) ~= nil)

    -- on_game_start clears the rolling average so it never spans a reload.
    reset()
    _dev_mode = true
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    with_printf(function() tick() tick() tick() end)
    on_game_start()
    lines = with_printf(function() tick() end)
    check_true("rolling stats reset on load", lines[1]:find("over 1 polls", 1, true) ~= nil)

    -- Dev mode alone is not enough: _poll_goal_changes returns immediately when chatter is
    -- disabled, so reporting anyway printed an all-zero line every 5 seconds — noise that
    -- also reads as a bug ("online=0" in a Zone full of stalkers). Last in the suite
    -- because it leaves `lines` empty, which would break any assertion placed after it.
    reset()
    _dev_mode, _chatter_enabled = true, false
    add_npc(10, 1, 5)
    add_npc(11, 1, 5)
    add_squad(1, 10)
    set_goal(1, 100)
    lines = with_printf(function() tick() end)
    check("no readout when the feature itself is off", #lines, 0)
end)

-- ============================================================
-- Results
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
os.exit(fail_count == 0 and 0 or 1)
