-- tests/test_wom_reaction.lua
-- Standalone Lua 5.1 tests for wom_reaction.script.
--
-- Run from the repository root:  lua tests/test_wom_reaction.lua
-- Run from tests/:               lua test_wom_reaction.lua
--
-- wom_reaction is a polling feature that writes to the player's PDA, so its failure
-- modes are the two most annoying ones a mod can have: silence, and spam. It polls
-- ap_api.get_records() every 5 real seconds across ALL maps, so it also walks the
-- record store far more often than any dialogue path does. None of it was covered.
--
-- What the suite pins down:
--
--   * The load baseline. Every record present on the first tick must be adopted as
--     old news. Without it, loading a save 30 in-game hours in dumps the entire AP
--     backlog onto the PDA.
--   * cons_id bookkeeping. A record must fire once, ever. The suite also pins the
--     less obvious half: a throttled record is CONSUMED, not retried, and a record
--     that ages out of the AP FIFO and is re-issued under the same id is treated as
--     fresh again (which is what _prune_seen buys, and its cost).
--   * The relevance gate and sender attribution. A mutant event always fires; a
--     faction event fires only inside the MCM scope; the sender is a stationed
--     commander of the AFFECTED faction, not of the player's.
--   * force_region. Records come from every map and the sender is invisible to the
--     player, so every location must name its region. This is a single boolean at a
--     single call site and nothing else would catch it flipping.
--   * The throttle boundary, including a documented defect at session start.

-- ============================================================
-- Engine + xlibs globals
-- ============================================================

local _game_sec = 100000
xtime  = { game_sec = function() return _game_sec end }
xconst = { INVALID_ENTITY_ID = 65535 }

local _printf_log = {}
printf = function(fmt, ...) _printf_log[#_printf_log + 1] = string.format(fmt, ...) end

db = { actor = { id = function() return 0 end } }

local _player_community = "stalker"
function get_actor_true_community() return _player_community end

-- Timer plumbing: the scan is a module-local reached only through the timer callback.
local _timer_callback = nil
local _reset_calls    = 0
function CreateTimeEvent(_id, _ev, _sec, fn) _timer_callback = fn end
function ResetTimeEvent(_id, _ev, _sec)      _reset_calls = _reset_calls + 1 end

-- ============================================================
-- Module stubs
-- ============================================================

local _records = {}
ap_api = { get_records = function() return _records end }

local _mcm = { enabled = true, scope = "faction" }
wom_mcm = {
    reaction_enabled = function() return _mcm.enabled end,
    reaction_scope   = function() return _mcm.scope   end,
}

-- Relationship model for the fake faction gate: "stalker" and "csky" are allies.
local ALLIES = { stalker = { csky = true }, csky = { stalker = true } }
local HUMANS = { stalker = true, csky = true, dolg = true, freedom = true, bandit = true, monolith = true }

local _sent = {}      -- delivered PDA messages
local _nearby_stalker = nil
local _story_ids = {}  -- id -> true, for is_story_character stub

wom_bark = {
    reset_cooldowns  = function() end,
    is_human_faction = function(c) return c ~= nil and HUMANS[c] == true end,
    faction_matches  = function(community, player_comm, scope)
        if not (community and player_comm) then return false end
        if community == player_comm then return true end
        if scope == "faction" then return false end
        return (ALLIES[player_comm] or {})[community] == true
    end,
    faction_display  = function(faction) return "The " .. tostring(faction), "icon_" .. tostring(faction) end,
    send_news_pda    = function(name, icon, message, tag)
        _sent[#_sent + 1] = { name = name, icon = icon, message = message, tag = tag }
    end,
    pick_nearby_stalker = function() return _nearby_stalker end,
    is_story_character = function(object_id) return object_id ~= nil and _story_ids[object_id] == true end,
}

wom_terminology_helper = {
    -- Mirrors the real contract closely enough for the gate: a faction key wins,
    -- otherwise the species key, with the "st_wom_term_..." wrapper stripped.
    extract_community_key = function(faction_key, species_key)
        return faction_key or species_key or nil
    end,
    get_location_name = function(smart_id, level_id, force_region)
        _sent.last_location_args = { smart_id = smart_id, level_id = level_id, force_region = force_region }
        return "the bus stop"
    end,
}

local _event_marker = nil
wom_recap_smart_terrain = {
    record_to_event = function(record, category)
        _event_marker = { record = record, category = category }
        return _event_marker
    end,
}

local _render_result = "Heard shooting up north."
local _render_args   = nil
wom_dialogue_helper = {
    render_reaction = function(event, location_name, affected_faction, extra)
        _render_args = { event = event, location = location_name,
                         faction = affected_faction, extra = extra }
        return _render_result
    end,
}

-- Squad registry for sender selection.
local _squads = {}
xsquad = {
    iter_squads = function()
        local i = 0
        return function()
            i = i + 1
            return _squads[i]
        end
    end,
    is_stationed        = function(squad) return squad.stationed == true end,
    get_commander_name  = function(squad) return squad.commander_name end,
}
xobject = { se = function(id) return { character_icon = function() return "icon_" .. tostring(id) end } end }

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

wom_reaction = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_reaction.script")

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
-- Fixtures
-- ============================================================

local _next_cons_id = 0

-- Builds an AP record. Defaults to a massacre by the player's own faction, dated now.
local function record(overrides)
    overrides = overrides or {}
    _next_cons_id = _next_cons_id + 1
    local r = {
        cons_id             = overrides.cons_id or _next_cons_id,
        cause_key           = overrides.cause_key or "cause:massacre",
        game_hours          = overrides.game_hours or math.floor(_game_sec / 3600),
        subject_faction_key = overrides.subject_faction_key,
        subject_species_key = overrides.subject_species_key,
        other_faction_key   = overrides.other_faction_key,
        other_species_key   = overrides.other_species_key,
        smart_id            = overrides.smart_id or 500,
    }
    if overrides.subject_faction_key == nil and overrides.subject_species_key == nil then
        r.subject_faction_key = "stalker"
    end
    if overrides.other_faction_key == nil and overrides.other_species_key == nil then
        r.other_faction_key = "bandit"
    end
    return r
end

local function squad(faction, opts)
    opts = opts or {}
    return {
        id             = opts.id,
        player_id      = faction,
        stationed      = opts.stationed or false,
        commander_name = opts.commander_name,
        commander_id   = function() return opts.commander_id or 1234 end,
    }
end

-- Fresh session. `now` is the game time the session resumes at; the default is far
-- past the throttle window so tests do not accidentally exercise the start-of-game
-- edge (which suite 7 covers deliberately).
local function reset(now)
    _game_sec        = now or 100000
    _records         = {}
    _sent            = {}
    _squads          = {}
    _printf_log      = {}
    _render_result   = "Heard shooting up north."
    _render_args     = nil
    _mcm.enabled     = true
    _mcm.scope       = "faction"
    _player_community = "stalker"
    _nearby_stalker  = nil
    _next_cons_id    = 0
    _timer_callback  = nil
    _story_ids       = {}
    wom_reaction.on_game_start()
end

-- Runs one poll. Any error inside _scan is swallowed by the module's own pcall and
-- surfaces through printf, so tests assert on _printf_log rather than a raise.
local function tick()
    assert(_timer_callback, "timer callback was never registered")
    _timer_callback()
end

local function scan_errors()
    return #_printf_log
end

-- ============================================================
-- 1. Load baseline
-- ============================================================

group("1. Load baseline (the difference between a PDA and a backlog dump)", function()
    reset()
    _records = { record(), record(), record() }
    tick()
    check("nothing fires on the first tick after load", #_sent, 0)
    check("...and no scan error was logged", scan_errors(), 0)

    tick()
    check("the baselined records still do not fire on later ticks", #_sent, 0)

    -- A record arriving after the baseline is genuine news.
    _records[#_records + 1] = record()
    tick()
    check("a record arriving after the baseline fires", #_sent, 1)

    -- on_game_start runs again on every save load; the baseline must re-arm, or
    -- loading a save would replay everything the previous session had marked seen.
    reset()
    _records = { record(), record() }
    tick()
    check("a reload re-arms the baseline", #_sent, 0)
end)

-- ============================================================
-- 2. Fire-once bookkeeping
-- ============================================================

group("2. cons_id bookkeeping", function()
    reset()
    tick()                              -- baseline on an empty store
    local r = record()
    _records = { r }
    tick()
    check("a fresh record fires", #_sent, 1)

    tick()
    tick()
    check("...exactly once, however many polls follow", #_sent, 1)

    -- Two relevant records in the same window: only one message, and it is the newest
    -- (highest cons_id). Firing both would be the spam failure.
    reset()
    tick()
    _records = { record({ cons_id = 10 }), record({ cons_id = 12 }), record({ cons_id = 11 }) }
    tick()
    check("a burst delivers a single message", #_sent, 1)
    check("...and it is the newest record", _render_args.event.record.cons_id, 12)

    -- The other records in the burst were consumed, not queued: advancing past the
    -- throttle must not release them later.
    _game_sec = _game_sec + 100000
    tick()
    check("the rest of the burst is consumed, not queued", #_sent, 1)

    -- _prune_seen keeps the seen table bounded to the AP FIFO. The cost is that a
    -- cons_id that leaves the store and comes back reads as fresh. Pinned so the
    -- trade-off is visible if AP ever recycles ids.
    reset()
    tick()
    local recycled = record({ cons_id = 77 })
    _records = { recycled }
    tick()
    check("record 77 fires", #_sent, 1)
    _records = {}
    tick()                              -- 77 leaves the store; _seen_cons_ids is pruned
    _game_sec = _game_sec + 100000      -- clear the throttle
    _records = { record({ cons_id = 77 }) }
    tick()
    check("a cons_id re-issued after leaving the store fires again", #_sent, 2)
end)

-- ============================================================
-- 3. Relevance gate
-- ============================================================

group("3. Relevance gate", function()
    -- A fight between two factions the player has nothing to do with is not news.
    reset()
    tick()
    _records = { record({ subject_faction_key = "dolg", other_faction_key = "freedom" }) }
    tick()
    check("an unrelated faction event does not fire", #_sent, 0)

    -- The player's own faction on either side qualifies.
    reset()
    tick()
    _records = { record({ subject_faction_key = "dolg", other_faction_key = "stalker" }) }
    tick()
    check("the player's faction on the OTHER side still fires", #_sent, 1)

    -- Scope: an ally only counts when the scope says so.
    reset()
    tick()
    _mcm.scope = "faction"
    _records = { record({ subject_faction_key = "csky", other_faction_key = "dolg" }) }
    tick()
    check("an ally event is filtered out at scope=faction", #_sent, 0)

    reset()
    tick()
    _mcm.scope = "allies"
    _records = { record({ subject_faction_key = "csky", other_faction_key = "dolg" }) }
    tick()
    check("...and fires at scope=allies", #_sent, 1)

    -- Mutant categories bypass the faction gate entirely: an alpha mutant is
    -- everybody's problem.
    reset()
    tick()
    _nearby_stalker = { character_name = function() return "Wolf" end,
                        character_icon = function() return "icon_wolf" end }
    _records = { record({ cause_key = "cause:alpha",
                          subject_faction_key = false, subject_species_key = "bloodsucker",
                          other_faction_key   = false, other_species_key   = nil }) }
    _records[1].subject_faction_key = nil
    _records[1].other_faction_key   = nil
    tick()
    check("a pure mutant event fires regardless of faction", #_sent, 1)
    check("...attributed to any available human stalker", _sent[1].name, "Wolf")

    -- ...but only if a human can be found to say it.
    reset()
    tick()
    _nearby_stalker = nil
    local mutant = record({ cause_key = "cause:alpha", subject_species_key = "bloodsucker" })
    mutant.subject_faction_key = nil
    mutant.other_faction_key   = nil
    _records = { mutant }
    tick()
    check("no available human means no message", #_sent, 0)

    -- Causes outside REACTION_CAUSES are ignored, and must not even be baselined
    -- into the seen set in a way that matters.
    reset()
    tick()
    _records = { record({ cause_key = "cause:harvest" }),
                 record({ cause_key = "cause:stash_loot" }),
                 record({ cause_key = "cause:wounded" }) }
    tick()
    check("low-signal causes never fire", #_sent, 0)

    -- A record with no cons_id or no timestamp is unusable and must be skipped
    -- rather than crashing the scan.
    reset()
    tick()
    local malformed_a = record(); malformed_a.cons_id    = nil
    local malformed_b = record(); malformed_b.game_hours = nil
    _records = { malformed_a, malformed_b }
    tick()
    check("malformed records do not fire", #_sent, 0)
    check("...and do not error the scan", scan_errors(), 0)
end)

-- ============================================================
-- 4. Age gate
-- ============================================================

group("4. Age gate", function()
    reset()
    tick()
    -- Three in-game hours old, against a 2-hour ceiling.
    _records = { record({ game_hours = math.floor(_game_sec / 3600) - 3 }) }
    tick()
    check("a stale record does not fire", #_sent, 0)

    -- ...and it is consumed while being skipped, so it cannot fire once the clock
    -- makes some other record eligible.
    _game_sec = _game_sec + 100000
    _records[1].game_hours = math.floor(_game_sec / 3600)
    tick()
    check("a skipped stale record stays consumed", #_sent, 0)

    reset()
    tick()
    _records = { record({ game_hours = math.floor(_game_sec / 3600) - 2 }) }
    tick()
    check("a record exactly at the age ceiling still fires", #_sent, 1)
end)

-- ============================================================
-- 5. Sender attribution
-- ============================================================

group("5. Sender attribution", function()
    -- The sender belongs to the AFFECTED faction, and a stationed commander is
    -- preferred over one on the move.
    reset()
    tick()
    _squads = {
        squad("dolg",    { stationed = true,  commander_name = "Wrong Faction" }),
        squad("stalker", { stationed = false, commander_name = "Roaming Sid"  }),
        squad("stalker", { stationed = true,  commander_name = "Stationed Sid" }),
    }
    _records = { record({ subject_faction_key = "stalker", other_faction_key = "bandit" }) }
    tick()
    check("a stationed commander of the affected faction is preferred",
          _sent[1] and _sent[1].name, "Stationed Sid")
    check("...with the commander's own icon", _sent[1] and _sent[1].icon, "icon_1234")
    check("...tagged for the log", _sent[1] and _sent[1].tag, "wom_reaction")

    -- With nobody stationed, any squad of the faction will do.
    reset()
    tick()
    _squads = { squad("stalker", { stationed = false, commander_name = "Roaming Sid" }) }
    _records = { record() }
    tick()
    check("falls back to a squad on the move", _sent[1] and _sent[1].name, "Roaming Sid")

    -- A squad whose commander has no character name (a mutant squad's leader) must not
    -- be used as a voice; the generic faction handle takes over.
    reset()
    tick()
    _squads = { squad("stalker", { stationed = true, commander_name = nil }) }
    _records = { record() }
    tick()
    check("a nameless commander degrades to the faction handle",
          _sent[1] and _sent[1].name, "The stalker")
    check("...and the faction portrait", _sent[1] and _sent[1].icon, "icon_stalker")

    -- The engine's "no commander" sentinel must never be treated as a real leader.
    reset()
    tick()
    _squads = { squad("stalker", { stationed = true, commander_name = "Ghost Sid",
                                   commander_id = 65535 }) }
    _records = { record() }
    tick()
    check("a squad with the INVALID_ENTITY_ID commander is skipped",
          _sent[1] and _sent[1].name, "The stalker")

    -- An empty registry still produces a message: the faction itself is the sender.
    reset()
    tick()
    _squads = {}
    _records = { record() }
    tick()
    check("an empty squad registry still delivers", #_sent, 1)

    -- The affected faction, not the player's, is what gets attributed and rendered.
    reset()
    tick()
    _mcm.scope = "allies"
    _squads = { squad("csky", { stationed = true, commander_name = "Cold" }) }
    _records = { record({ subject_faction_key = "csky", other_faction_key = "dolg" }) }
    tick()
    check("an ally event is voiced by the ALLY, not the player's faction",
          _sent[1] and _sent[1].name, "Cold")
    check("...and rendered as that faction", _render_args.faction, "csky")

    -- A faction whose only squads are story characters (trader, leader) must not have
    -- its news voiced by one of them; the generic faction handle takes over instead.
    reset()
    tick()
    _squads = {
        squad("stalker", { id = 1, stationed = true, commander_name = "Story Squad",
                            commander_id = 1234 }),
        squad("stalker", { id = 2, stationed = true, commander_name = "Story Commander",
                            commander_id = 5678 }),
    }
    _story_ids[1]    = true   -- squad-level story character
    _story_ids[5678] = true   -- commander-level story character
    _records = { record() }
    tick()
    check("a story-only faction falls back to the generic handle",
          _sent[1] and _sent[1].name, "The stalker")
    check("...and the faction portrait", _sent[1] and _sent[1].icon, "icon_stalker")
end)

-- ============================================================
-- 6. Rendering contract
-- ============================================================

group("6. Rendering contract", function()
    reset()
    tick()
    _records = { record({ smart_id = 4242 }) }
    tick()
    check("the location is resolved for the record's smart", _sent.last_location_args.smart_id, 4242)
    check("...against no explicit level", _sent.last_location_args.level_id, nil)
    check("...with force_region SET, because the wire spans every map",
          _sent.last_location_args.force_region, true)
    check("the rendered location is handed to render_reaction", _render_args.location, "the bus stop")
    check("the category reaches record_to_event", _render_args.event.category, "massacre")
    check("the delivered body is the rendered line", _sent[1].message, "Heard shooting up north.")

    -- An empty render must suppress delivery AND leave the throttle unspent, so the
    -- next genuine event is not swallowed by a message that never existed.
    reset()
    tick()
    _render_result = ""
    _records = { record({ cons_id = 1 }) }
    tick()
    check("an empty render delivers nothing", #_sent, 0)
    _render_result = "Real news."
    _records[#_records + 1] = record({ cons_id = 2 })
    tick()
    check("...and does not spend the throttle", #_sent, 1)

    -- Same for a nil render.
    reset()
    tick()
    _render_result = nil
    _records = { record({ cons_id = 1 }) }
    tick()
    check("a nil render delivers nothing", #_sent, 0)
    check("...and does not error the scan", scan_errors(), 0)
end)

-- ============================================================
-- 7. Throttle
-- ============================================================

group("7. Global throttle", function()
    reset()
    tick()
    _records = { record({ cons_id = 1 }) }
    tick()
    check("the first message is delivered", #_sent, 1)

    -- 29 in-game minutes later: still inside the 30-minute window.
    _game_sec = _game_sec + 29 * 60
    _records[#_records + 1] = record({ cons_id = 2 })
    tick()
    check("a second event inside the throttle window is suppressed", #_sent, 1)

    -- Past the window, a NEW event fires. (The suppressed one was consumed — see
    -- suite 2 — so it takes a fresh cons_id to hear anything again.)
    _game_sec = _game_sec + 2 * 60
    _records[#_records + 1] = record({ cons_id = 3 })
    tick()
    check("a new event past the window fires", #_sent, 2)

    -- DEFECT MARKER — start of a brand-new game.
    --
    -- on_game_start sets _last_fire_sec = 0, and xtime.game_sec() genuinely IS ~0 on a
    -- new game, so an in-band 0 cannot distinguish "never fired" from "fired just now".
    -- The result: for the first 30 in-game minutes of a new game every qualifying
    -- reaction is silently consumed by the throttle and never heard. This is the exact
    -- nil-vs-0 trap wom_outpost documents and solves with a nil _last_fire_sec.
    --
    -- The behaviour is pinned as-is rather than fixed here, so that changing
    -- _last_fire_sec to nil flips this test and the intent is unambiguous.
    reset(60)                            -- one in-game minute into a new game
    tick()
    _records = { record({ cons_id = 1, game_hours = 0 }) }
    tick()
    check("[defect] a new game swallows reactions for the first 30 in-game minutes",
          #_sent, 0)
    _game_sec = 1900                     -- past REACTION_MIN_INTERVAL from zero
    _records[#_records + 1] = record({ cons_id = 2, game_hours = 0 })
    tick()
    check("[defect] ...and only starts speaking after that window", #_sent, 1)
end)

-- ============================================================
-- 8. Guard rails
-- ============================================================

group("8. Guard rails", function()
    -- Disabled in MCM: no delivery, and — importantly — no baseline either, so
    -- re-enabling mid-session must not dump the accumulated backlog.
    reset()
    _mcm.enabled = false
    _records = { record(), record() }
    tick()
    tick()
    check("nothing fires while the feature is off", #_sent, 0)
    _mcm.enabled = true
    tick()
    check("re-enabling baselines rather than dumping the backlog", #_sent, 0)
    _records[#_records + 1] = record()
    tick()
    check("...and news from then on is delivered", #_sent, 1)

    -- No actor (loading screen, level change): the scan must not touch anything.
    reset()
    tick()
    local saved_actor = db.actor
    db.actor = nil
    _records = { record() }
    tick()
    check("no actor means no delivery", #_sent, 0)
    check("...and no error", scan_errors(), 0)
    db.actor = saved_actor
    tick()
    check("the record is still there once the actor returns", #_sent, 1)

    -- An empty record store on every tick is the common case and must stay quiet.
    reset()
    tick()
    _records = {}
    tick(); tick()
    check("an empty store stays silent", #_sent, 0)
    check("...without errors", scan_errors(), 0)

    -- ap_api returning nil (AP mid-reload) must be tolerated.
    reset()
    tick()
    local saved_get = ap_api.get_records
    ap_api.get_records = function() return nil end
    tick()
    check("a nil record store does not error the scan", scan_errors(), 0)
    ap_api.get_records = saved_get

    -- The timer always reschedules itself, whatever the scan did. If this ever stops,
    -- the feature dies silently after one tick.
    reset()
    local before = _reset_calls
    tick()
    check("the timer reschedules on every tick", _reset_calls, before + 1)
    _mcm.enabled = false
    tick()
    check("...including when the feature is disabled", _reset_calls, before + 2)
    check("the timer callback keeps the event registered", _timer_callback() , false)
end)

-- ============================================================

io.write(string.format("\nResults: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
