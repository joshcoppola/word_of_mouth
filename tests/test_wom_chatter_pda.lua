-- tests/test_wom_chatter_pda.lua
-- Standalone Lua 5.1 tests for wom_chatter_pda.script.
--
-- Run from the repository root:  lua tests/test_wom_chatter_pda.lua
-- Run from tests/:               lua test_wom_chatter_pda.lua
--
-- The feature's whole cost argument rests on the asker walk staying at one luabind call
-- per squad, which means every cheap filter (faction, current_action, AP-scripted) has to
-- happen inside the walk and every expensive one (commander, cooldown) after the draw.
-- These tests pin that split down: they assert WHICH squads are eligible, not how the
-- scan is written, so the walk can be re-tuned without rewriting them.
--
-- The other thing pinned here is ordering: both speakers must be chosen before the
-- question is delivered. Sending a question and only then discovering nothing can answer
-- leaves the player looking at an unanswered radio call, which is worse than silence.
--
-- Strategy follows test_wom_outpost: capture the callbacks on_game_start registers, then
-- invoke them directly to drive one exchange. Squad fakes mirror the real server-object
-- shape -- `id`, `player_id`, `current_action`, `smart_id` are FIELDS; `npc_count` and
-- `commander_id` are METHODS.

-- ============================================================
-- Mutable test state
-- ============================================================

local _squads        = {}    -- array of fake server squad objects
local _by_id         = {}    -- squad_id -> fake squad
local _scripted      = {}    -- squad_id -> AP scripted entry
local _pda_calls     = {}    -- one entry per send_news_pda, in delivery order
local _tick_callback = nil
local _now_ms        = 0     -- drives time_global(); the module schedules against it
local _traces        = {}
local _game_sec      = 1000000
local _player_comm   = "stalker"
local _enabled       = true
local _scope         = "faction"
local _cooldowns     = {}    -- npc_id -> game_sec last spoke
local _action_text   = "ACTION"
local _status_text   = "STATUS"
local _opener_text   = "OPEN"  -- the reply's leading acknowledgement; "" == pool rendered empty
local _name_raises   = false   -- make get_commander_name raise, as a destroyed object does
local _actor_level   = 1       -- the player's level; squads default to 2, i.e. off-map
local _render_raises = false   -- make the reply render raise, to test delivery failure
local _wire_quiet    = true    -- shared PDA quiet window: true == nothing on the wire
local _pda_quiet_gap = 20      -- what the module reads from MCM and hands to is_pda_quiet
local _last_force_region       -- force_region as the reply render last received it
local _hooks_installed = 0     -- times on_game_start asked wom_bark to hook external news
local _goal_by_squad = {}      -- squad_id -> goal suffix; absent == "job_explore" (public)
local _goal_visibility = {}    -- goal suffix -> MCM visibility; absent == "public"

local function reset()
    _squads, _by_id, _scripted = {}, {}, {}
    _pda_calls, _traces        = {}, {}
    _now_ms      = 0
    _game_sec    = 1000000
    _player_comm = "stalker"
    _enabled     = true
    _scope       = "faction"
    _cooldowns   = {}
    _action_text = "ACTION"
    _status_text = "STATUS"
    _opener_text = "OPEN"
    _name_raises = false
    _actor_level = 1
    _render_raises = false
    _wire_quiet    = true
    _pda_quiet_gap = 20
    _last_force_region = nil
    _goal_by_squad   = {}
    _goal_visibility = {}
    db.actor     = {}
    on_game_start()
end

-- Adds a fake squad. current_action 1 == stationed under smart-terrain control,
-- anything else == in transit. scripted=true also registers it as AP-driven.
-- `level` defaults to 2 while the player sits on 1, so every squad is off-map unless a
-- test says otherwise -- the asker filter would otherwise reject the whole fixture.
-- The real xlevel.get_level_id reads m_game_vertex_id and maps it through game.graph;
-- the stub below reads this field instead, since the mapping itself is not under test.
local function add_squad(squad_id, faction, current_action, opts)
    opts = opts or {}
    local squad = {
        id             = squad_id,
        player_id      = faction,
        current_action = current_action,
        level          = opts.level == nil and 2 or opts.level,
        smart_id       = opts.smart_id,
        npc_count      = function(self) return opts.count or 2 end,
        commander_id   = function(self) return squad_id + 1000 end,
    }
    _squads[#_squads + 1] = squad
    _by_id[squad_id]      = squad
    if opts.scripted then _scripted[squad_id] = { target_smart_id = opts.smart_id } end
    return squad
end

-- ============================================================
-- Engine / module stubs
-- ============================================================

db = { actor = {} }

function printf() end

math.randomseed(1)

alife = function()
    return { object = function(self, id) return _by_id[id] end }
end

xtime  = { game_sec = function() return _game_sec end }
xobject = { se = function(id) return nil end }   -- icon falls back to the faction handle

xlevel = {
    get_actor_level_id = function() return _actor_level end,
    -- `or nil` matters: a fixture sets level=false to mean "unresolvable", and the real
    -- xlevel.get_level_id returns nil, never false. Without the normalisation the guard
    -- `level_id ~= nil` passes on false and the test silently proves nothing.
    get_level_id       = function(squad) return (squad and squad.level) or nil end,
}

xsquad = {
    iter_squads = function()
        local index = 0
        return function()
            index = index + 1
            return _squads[index]
        end
    end,
    -- The real implementation reaches into db.storage[cmd_id].object and calls methods on
    -- it, which raises "you are trying to use a destroyed object" when that entry has
    -- outlived the object. _name_raises reproduces that.
    get_commander_name = function(squad)
        if _name_raises then error("you are trying to use a destroyed object") end
        return "Commander" .. tostring(squad.id)
    end,
}

-- Exactly ONE time event is registered, ever. Scheduling is plain arithmetic against
-- time_global() inside the module, so the harness drives it by moving the clock rather
-- than by capturing a second callback. See the note on TICK_INTERVAL in the script: the
-- second event used to be created from inside the first event's own callback, which meant
-- inserting a key into the table ProcessEventQueue was mid-pairs() over.
CreateTimeEvent = function(_, event, delay, callback) _tick_callback = callback end
ResetTimeEvent  = function() end

time_global = function() return _now_ms end

get_actor_true_community = function() return _player_comm end

ap_api = {
    get_scripted_squads = function()
        local out = {}
        for k, v in pairs(_scripted) do out[k] = v end
        return out
    end,
    -- Mirrors the { squad_id, assigned = true } fast path: the goal is per-squad, so a
    -- fixture can give one candidate a secret goal and leave the rest public.
    get_record = function(opts)
        local goal = (opts and _goal_by_squad[opts.squad_id]) or "job_explore"
        return { consequence_key = "consequence:" .. goal }
    end,
}

wom_debug = { log_trace = function(_, message) _traces[#_traces + 1] = message end }

wom_mcm = {
    chatter_pda_enabled     = function() return _enabled end,
    chatter_pda_interval    = function() return 60 end,
    chatter_pda_reply_delay = function() return 4 end,
    chatter_pda_scope       = function() return _scope end,
    chatter_pda_quiet_gap   = function() return _pda_quiet_gap end,
    -- The real reader returns "public" for any goal with no MCM entry, and migrates legacy
    -- booleans; that migration is wom_mcm's business, not this feature's.
    get_goal_visibility     = function(goal) return _goal_visibility[goal] or "public" end,
}

wom_bark = {
    -- Mirrors the real precomputed-set contract: own faction always, "dolg" only at
    -- the wider scopes. The real implementation is covered by test_wom_bark.
    allowed_factions = function(player_comm, scope)
        local allowed = { [player_comm] = true }
        if scope == "allies" or scope == "neutral" then allowed.dolg = true end
        return allowed
    end,
    faction_display = function(faction) return "FACTION_" .. tostring(faction), "icon" end,
    can_speak       = function(npc_id, now_sec, cooldown) return (now_sec - (_cooldowns[npc_id] or 0)) >= cooldown end,
    mark_spoke      = function(npc_id, now_sec) _cooldowns[npc_id] = now_sec end,
    reset_cooldowns = function() _cooldowns = {} end,
    -- The shared PDA quiet window. Driven by a flag rather than a clock: this suite is
    -- testing that the module ASKS at the right points (exchange yes, reply no), not the
    -- window arithmetic, which test_wom_bark covers against the real implementation.
    is_pda_quiet       = function() return _wire_quiet end,
    reset_quiet_window = function() _wire_quiet = true end,
    -- Installs the hooks that let non-WoM PDA messages close the window. Inert here; the
    -- real implementation and its wrapper contract are covered in test_wom_bark.
    hook_external_news = function() _hooks_installed = _hooks_installed + 1 end,
    send_news_pda   = function(name, icon, message) _pda_calls[#_pda_calls + 1] = { name = name, message = message } end,
}

wom_recap_npc = {
    render_current_action = function(squad, _npc, _plural, _current_smart_id, force_region)
        if _render_raises then error("you are trying to use a destroyed object") end
        _last_force_region = force_region
        return _action_text == "" and "" or (_action_text .. squad.id)
    end,
    render_squad_status   = function(squad) return _status_text == "" and "" or (_status_text .. squad.id) end,
}

wom_dialogue_helper = {
    make_pronoun_slots    = function(plural) return { plural = plural } end,
    pick_dialogue_variant = function(prefix, slots)
        -- The reply opener draws from its own pool and uses only the pronoun slots, so it
        -- renders as a flat marker; _opener_text = "" reproduces an empty pool.
        if prefix == "st_wom_chatter_pda_reply_open" then return _opener_text end
        return prefix .. "[" .. tostring(slots and slots.location) .. "]"
    end,
}

wom_terminology_helper = {
    get_location_name = function(smart_id) return "SMART" .. tostring(smart_id) end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
dofile(script_dir .. "/../gamedata/scripts/wom_chatter_pda.script")

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

local function group(name, body)
    io.write(name .. "\n")
    reset()
    body()
end

-- Advances the clock by `ms` and runs one pump.
local function pump(ms)
    _now_ms = _now_ms + (ms or 0)
    _tick_callback()
end

-- One exchange attempt. The first pump only arms the schedule on a fresh module state
-- (FIRST_TICK_DELAY); the second jumps well past both that and the 60s MCM interval.
local function tick()
    pump(0)
    pump(120000)
end

-- Delivers a reply that is owed, by jumping past the 4s reply delay.
local function fire_reply()
    pump(10000)
end

local function trace_contains(fragment)
    for i = 1, #_traces do
        if _traces[i]:find(fragment, 1, true) then return true end
    end
    return false
end

-- ============================================================
-- Tests
-- ============================================================

group("asker eligibility", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })              -- stationed, eligible
    add_squad(2, "stalker", 0, { scripted = true })             -- moving + scripted: answerer
    tick()
    check("question delivered", #_pda_calls, 1)
    check("asker is the stationed squad", _pda_calls[1].name, "Commander1")
    check("question carries the asker location", _pda_calls[1].message,
          "st_wom_chatter_pda_ask[SMART500]")
end)

group("the asker must be off the player's map", function()
    add_squad(1, "stalker", 1, { smart_id = 500, level = 1 })   -- same level as the player
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("an on-map squad never asks", #_pda_calls, 0)
    check("traced as no off-map squad", trace_contains("off-map squad in scope"), true)

    reset()
    add_squad(1, "stalker", 1, { smart_id = 500, level = 3 })   -- a third level, still off-map
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("any other level qualifies", #_pda_calls, 1)
end)

group("an unresolvable level is not proof of being off-map", function()
    add_squad(1, "stalker", 1, { smart_id = 500, level = false })  -- get_level_id returns nil
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("squad mid-transition never asks", #_pda_calls, 0)
end)

group("no exchange while the actor level is unresolved", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _actor_level = nil                                          -- loading / level transition
    tick()
    check("tick skipped entirely", #_pda_calls, 0)
    check("traced as actor level unresolved", trace_contains("actor level unresolved"), true)
end)

group("the answerer is deliberately not level-filtered", function()
    -- The answerer may be anywhere, including the player's own map: its location slot is
    -- where it is HEADING, not where it stands. The destination is qualified with its
    -- region regardless (force_region below), since the listener is on a radio and has no
    -- way to tell which map the voice is talking about.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true, level = 1 })  -- on the player's map
    tick()
    fire_reply()
    check("on-map squad still answers", #_pda_calls, 2)
    check("reply came from the on-map squad", _pda_calls[2].name, "Commander2")
end)

group("the reply always names its region", function()
    -- The wire renders through render_current_action with force_region set, so an on-map
    -- destination still reads "the bus stop in Cordon" rather than "the bus stop".
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true, level = 1 })
    tick()
    fire_reply()
    check("force_region reached the render", _last_force_region, true)
end)

group("a travelling squad never asks", function()
    add_squad(1, "stalker", 0)                                  -- in transit, not stationed
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("nothing delivered", #_pda_calls, 0)
    check("traced as no stationed squad", trace_contains("no stationed unscripted off-map squad"), true)
end)

group("an AP-driven squad never asks", function()
    add_squad(1, "stalker", 1, { scripted = true })             -- stationed but AP is driving it
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("nothing delivered", #_pda_calls, 0)
    check("traced as no stationed squad", trace_contains("no stationed unscripted off-map squad"), true)
end)

group("faction scope gates both speakers", function()
    add_squad(1, "dolg", 1, { smart_id = 500 })
    add_squad(2, "dolg", 0, { scripted = true })
    tick()
    check("out-of-scope faction is silent at 'faction'", #_pda_calls, 0)

    reset()
    _scope = "allies"
    add_squad(1, "dolg", 1, { smart_id = 500 })
    add_squad(2, "dolg", 0, { scripted = true })
    tick()
    check("in scope at 'allies'", #_pda_calls, 1)
end)

group("no answerer means no question", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })              -- asker available
    -- no AP-scripted squad at all
    tick()
    check("question withheld", #_pda_calls, 0)
    check("traced as no answerer", trace_contains("no AP-scripted squad in scope"), true)
    check("no reply scheduled", _reply_callback, nil)
end)

group("answerer prefers a moving squad", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 1, { scripted = true })             -- scripted but parked
    add_squad(3, "stalker", 0, { scripted = true })             -- scripted and on the road
    tick()
    fire_reply()
    check("both messages delivered", #_pda_calls, 2)
    check("reply came from the moving squad", _pda_calls[2].name, "Commander3")
    check("reply is opener, status, action", _pda_calls[2].message, "OPEN STATUS3 ACTION3")
end)

group("answerer falls back to a parked squad", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 1, { scripted = true })             -- the only scripted squad
    tick()
    fire_reply()
    check("both messages delivered", #_pda_calls, 2)
    check("reply came from the parked squad", _pda_calls[2].name, "Commander2")
end)

group("the asker is never also the answerer", function()
    -- The asker is excluded from the scripted pool by the not-scripted rule, but the
    -- exclusion is asserted independently so removing that rule cannot produce a squad
    -- talking to itself unnoticed.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    fire_reply()
    check("two distinct senders", _pda_calls[1].name ~= _pda_calls[2].name, true)
end)

group("reply re-resolves the squad at fire time", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    _by_id[2] = nil                                             -- squad released during the delay
    fire_reply()
    check("no reply from a released squad", #_pda_calls, 1)
    check("traced as gone", trace_contains("no longer exists"), true)
end)

group("empty action render suppresses the reply", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _action_text = ""
    tick()
    fire_reply()
    check("question sent but no reply", #_pda_calls, 1)
    check("traced as nothing rendered", trace_contains("nothing rendered"), true)
end)

group("empty status render still allows the action line", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _status_text = ""
    tick()
    fire_reply()
    check("reply delivered", #_pda_calls, 2)
    check("reply is the opener and the action", _pda_calls[2].message, "OPEN ACTION2")
end)

group("the opener leads the reply but never carries it", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _opener_text = ""                                           -- pool rendered nothing
    tick()
    fire_reply()
    check("reply still delivered", #_pda_calls, 2)
    check("and starts at the status line", _pda_calls[2].message, "STATUS2 ACTION2")

    -- An opener alone is a radio hail with no news in it, so it must not turn a reply
    -- that had nothing to say into a delivered message.
    reset()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _action_text = ""
    _status_text = ""
    tick()
    fire_reply()
    check("no reply from an opener on its own", #_pda_calls, 1)
end)

group("cooldown gates the asker", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    fire_reply()
    check("first exchange delivered", #_pda_calls, 2)

    _pda_calls = {}
    tick()                                                      -- same asker, still on cooldown
    check("asker suppressed while on cooldown", #_pda_calls, 0)
    check("traced as gated", trace_contains("asker candidates gated"), true)

    _pda_calls = {}
    _game_sec = _game_sec + 2000                                -- past SPEAKER_COOLDOWN_GAME_SEC
    tick()
    check("asker speaks again once off cooldown", #_pda_calls, 1)
end)

group("a pending reply defers the next exchange until it is due", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    pump(1000)                                                  -- inside the 4s reply delay
    check("no second exchange while a reply is owed", #_pda_calls, 1)
    pump(10000)                                                 -- past the delay
    check("the pump delivers the reply, not a new question", #_pda_calls, 2)
    check("reply came from the answerer", _pda_calls[2].name, "Commander2")
end)

group("disabling mid-exchange drops the owed reply", function()
    -- The regression: the enabled check sat ahead of the pending-reply branch and simply
    -- returned, so toggling off inside the reply delay parked _pending_reply with an
    -- expired due_at. Re-enabling minutes or hours later fired it on the very next tick,
    -- detached from the question it answered.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    _enabled = false
    pump(10000)                                                 -- past the reply delay
    check("nothing delivered while disabled", #_pda_calls, 1)
    _enabled = true
    pump(1000)
    check("no stale reply after re-enabling", #_pda_calls, 1)
end)

group("feature toggle and missing prerequisites", function()
    _enabled = false
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("disabled feature is silent", #_pda_calls, 0)

    reset()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    local saved = ap_api
    ap_api = nil
    tick()
    ap_api = saved
    check("no ALifePlus, no exchange", #_pda_calls, 0)
    check("traced as AP absent", trace_contains("ALifePlus not available"), true)
end)

group("squads with no members are skipped", function()
    add_squad(1, "stalker", 1, { smart_id = 500, count = 0 })   -- wiped out
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("empty asker rejected", #_pda_calls, 0)
end)

-- ============================================================
-- Lifecycle: what can change between the question and the reply
-- ============================================================

group("answerer wiped out during the delay", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    local answerer = add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    -- The squad object outlives its last member for a moment. Without the count guard
    -- this renders through the "alone" pool and a dead squad reports it is on its own.
    answerer.npc_count = function(self) return 0 end
    fire_reply()
    check("no reply from a wiped squad", #_pda_calls, 1)
    check("traced as wiped", trace_contains("was wiped out"), true)
end)

group("answerer squad ID recycled during the delay", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    -- alife recycles object IDs. ID 2 now belongs to a different squad of another
    -- faction; answering as them would put words in the wrong mouth.
    _by_id[2] = { id = 2, player_id = "bandit", current_action = 0,
                  npc_count = function() return 3 end,
                  commander_id = function() return 9002 end }
    fire_reply()
    check("no reply from a recycled ID", #_pda_calls, 1)
    check("traced as reused", trace_contains("was reused"), true)
end)

group("commander dies during the delay", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    -- A destroyed db.storage object makes the real get_commander_name raise. The reply
    -- must survive it and fall back to the faction handle, not vanish into a log line.
    _name_raises = true
    fire_reply()
    check("reply still delivered", #_pda_calls, 2)
    check("sender degraded to the faction handle", _pda_calls[2].name, "FACTION_stalker")
    check("message content unaffected", _pda_calls[2].message, "OPEN STATUS2 ACTION2")
end)

group("a raise while picking the asker loses only that exchange", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _name_raises = true
    tick()
    -- The asker falls back to the faction handle too, so the exchange still happens.
    check("question delivered via the faction handle", #_pda_calls, 1)
    check("asker name degraded", _pda_calls[1].name, "FACTION_stalker")
end)

group("actor gone when the reply fires", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    local commander = 1002
    db.actor = nil                                              -- loading screen / death
    fire_reply()
    check("nothing delivered", #_pda_calls, 1)
    check("traced as no actor", trace_contains("no actor to receive it"), true)
    -- The cooldown must not be burned on a message nobody saw: a 30-minute in-game
    -- cooldown spent on a dropped reply silences that NPC for no reason.
    check("answerer cooldown not marked", _cooldowns[commander], nil)
end)

group("answerer cooldown falls back to another candidate", function()
    -- This is the bug that took the feature off the air in play: with one answerer
    -- sampled and no fallback, a single cooled-down commander aborted every exchange for
    -- minutes. The sampler now returns a list and the gate walks it.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })             -- commander 1002
    add_squad(3, "stalker", 0, { scripted = true })             -- commander 1003
    _cooldowns[1002] = _game_sec
    _cooldowns[1003] = _game_sec
    tick()
    check("no exchange when every candidate is cooled", #_pda_calls, 0)
    check("traced as all candidates cooled",
          trace_contains("answerer candidates gated"), true)

    reset()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    add_squad(3, "stalker", 0, { scripted = true })
    _cooldowns[1002] = _game_sec                                -- only one is cooled
    tick()
    fire_reply()
    check("the other candidate answers", #_pda_calls, 2)
    check("and it is not the cooled one", _pda_calls[2].name, "Commander3")
end)

group("a squad on a secret goal never answers", function()
    -- "Secret" on the wire means visibility anything other than "public". Face-to-face,
    -- "faction" still answers honestly to one's own faction and "none" deflects to the
    -- generic secretive line; neither survives a broadcast the player always overhears,
    -- so the squad is dropped from the candidate list instead.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _goal_by_squad[2]           = "stash_loot"
    _goal_visibility.stash_loot = "none"
    tick()
    check("no exchange when the only answerer is secret", #_pda_calls, 0)
    check("traced as a secret goal", trace_contains("goal is secret"), true)

    reset()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _goal_by_squad[2]           = "stash_loot"
    _goal_visibility.stash_loot = "faction"   -- same faction as the player, still excluded
    tick()
    check("\"faction\" visibility is excluded too", #_pda_calls, 0)

    reset()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _goal_by_squad[2]           = "stash_loot"
    _goal_visibility.stash_loot = "public"    -- the same goal, left public in MCM
    tick()
    check("a public goal answers normally", #_pda_calls, 1)
end)

group("a secret goal falls back to another candidate", function()
    -- The gate must reject the one squad, not the exchange: mirrors the cooldown fallback.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    add_squad(3, "stalker", 0, { scripted = true })
    _goal_by_squad[2]           = "stash_loot"
    _goal_visibility.stash_loot = "none"
    tick()
    fire_reply()
    check("the other candidate answers", #_pda_calls, 2)
    check("and it is not the secretive one", _pda_calls[2].name, "Commander3")
end)

group("a goal that turns secret during the reply delay is dropped", function()
    -- The reply renders whatever goal is assigned at DELIVERY time, so gating only at
    -- selection would let AP reassign a squad inside the delay and have it announce the
    -- new secret goal.
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    _goal_by_squad[2]           = "stash_loot"
    _goal_visibility.stash_loot = "none"
    fire_reply()
    check("no reply delivered", #_pda_calls, 1)
    check("traced as picked up a secret goal",
          trace_contains("picked up a secret goal"), true)
    -- A dropped reply must not burn the answerer's cooldown; same rule as every other
    -- delivery bail.
    check("answerer cooldown not marked", _cooldowns[1002], nil)
end)

group("answerer cooldown is marked on delivery", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    fire_reply()
    check("reply delivered", #_pda_calls, 2)
    check("answerer commander marked", _cooldowns[1002], _game_sec)
end)

group("a raise during delivery cannot wedge the feature", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)
    -- The owed reply is cleared BEFORE delivery is attempted, so a raise inside it loses
    -- that one reply and nothing else. Previously this needed a tick-counting watchdog,
    -- because the pending flag guarded an external time event that might never fire; with
    -- the reply owed in module state there is nothing left to go missing.
    _render_raises = true
    fire_reply()
    check("no reply delivered", #_pda_calls, 1)
    _render_raises = false

    _pda_calls = {}
    _game_sec  = _game_sec + 5000                               -- clear the asker cooldown
    tick()
    check("the next exchange runs normally", #_pda_calls, 1)
end)

group("a busy PDA blocks the exchange before any scan", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    _wire_quiet = false
    tick()
    check("no question delivered", #_pda_calls, 0)
    check("and the reason is traced", trace_contains("PDA quiet window"), true)

    -- The gate sits ahead of every registry walk, so a blocked exchange must not have
    -- burned the asker's cooldown on a question nobody heard.
    check("asker cooldown untouched", _cooldowns[1001], nil)

    _wire_quiet = true
    _now_ms     = _now_ms + 120000
    _tick_callback()
    check("the exchange runs once the wire clears", #_pda_calls, 1)
end)

group("the reply is exempt from the quiet window", function()
    add_squad(1, "stalker", 1, { smart_id = 500 })
    add_squad(2, "stalker", 0, { scripted = true })
    tick()
    check("question delivered", #_pda_calls, 1)

    -- The question itself is what most recently stamped the window, so by the time the
    -- reply comes due the wire is by construction busy. Gating it here would leave the
    -- player watching a question go permanently unanswered, which is worse than silence.
    _wire_quiet = false
    fire_reply()
    check("reply delivered anyway", #_pda_calls, 2)
end)

group("startup installs the external-news hooks", function()
    -- The wire is the only reader of the quiet window, so it is also what asks wom_bark to
    -- hook the funnels other mods and the base game deliver PDA messages through. Without
    -- that call the window only ever sees WoM's own messages and the wire talks over
    -- everything else.
    local before = _hooks_installed
    on_game_start()
    check("on_game_start hooked external news", _hooks_installed, before + 1)
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
