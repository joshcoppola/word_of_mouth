-- tests/test_wom_recap_offline.lua
-- Standalone Lua 5.1 tests for the offline (npc == nil) paths of wom_recap_npc's
-- render_squad_status and render_current_action.
--
-- Run from the repository root:  lua tests/test_wom_recap_offline.lua
-- Run from tests/:               lua test_wom_recap_offline.lua
--
-- Both functions were npc-bound and became squad-first with an optional npc so the
-- faction wire (wom_chatter_pda) can render them for an offline squad on any map. Every
-- client-object call in them is now behind an `npc and ...` guard, and the failure mode
-- if one is missed is a nil-index crash inside a timer's pcall -- which is exactly how
-- this codebase has silently lost a whole feature before (see test_wom_outpost's header).
-- So these tests drive both functions with npc omitted entirely.
--
-- The second job here is regression cover for the ONLINE path: the daily recap is shipped
-- dialogue, and the refactor must not have changed a word of it. Each offline assertion
-- has an online twin.

-- ============================================================
-- Mutable test state
-- ============================================================

local _members       = {}     -- array of member ids for the squad under test
local _online        = {}     -- member_id -> fake client object (absent ids omitted)
local _names         = {}     -- member_id -> full name
local _record        = nil    -- ap_api.get_record result
local _scripted      = {}
local _player_comm   = "stalker"
local _goal_visibility = "public"

local function reset()
    _members, _online, _names = {}, {}, {}
    _record   = nil
    _scripted = {}
    _player_comm = "stalker"
    _goal_visibility = "public"
end

-- Fake squad server object: id/player_id/current_action/smart_id are FIELDS,
-- npc_count/commander_id are METHODS -- the real cse_alife_online_offline_group shape.
local function make_squad(opts)
    opts = opts or {}
    return {
        id                 = opts.id or 7,
        player_id          = opts.player_id or "stalker",
        current_action     = opts.current_action or 1,
        smart_id           = opts.smart_id,
        assigned_target_id = opts.assigned_target_id,
        npc_count          = function(self) return opts.count or #_members end,
        commander_id       = function(self) return opts.commander_id end,
    }
end

-- Fake client game object, for the online-path twins. position() returns a vector-like
-- table with a distance_to method so the absent-member check can run.
local function make_npc(id, x)
    return {
        id       = function(self) return id end,
        position = function(self)
            return { x = x or 0, distance_to = function(self2, other) return math.abs((x or 0) - other.x) end }
        end,
        character_community = function(self) return "stalker" end,
    }
end

-- ============================================================
-- Engine / module stubs
-- ============================================================

db = { actor = { character_community = function() return _player_comm end } }

function printf() end

game = { translate_string = function(key) return key end }

xtime  = { get_game_sec = function() return 1000000 end }
xsmart = {}
xobject = { get_se = function(id) return nil end }
axr_companions = nil

xsquad = {
    iterate_member_ids = function(squad)
        local index = 0
        return function()
            index = index + 1
            return _members[index]
        end
    end,
}

ap_api = {
    get_record          = function() return _record end,
    get_records         = function() return {} end,
    get_scripted_squads = function() return _scripted end,
}

wom_mcm = { get_goal_visibility = function() return _goal_visibility end }

wom_npc_role = {
    scheme_role   = function(npc) return "posted" end,
    current_smart = function(npc) return nil end,
}

wom_utils = {
    resolve_squad       = function(npc) return nil end,
    get_live_online_npc = function(id) return _online[id] end,
    join_list           = function(items) return table.concat(items, " and ") end,
}

wom_terminology_helper = {
    -- Appends "+REGION" when force_region is set, so a test can see the flag arrive at the
    -- terminology helper rather than only that render_current_action accepted it.
    get_location_name       = function(smart_id, _current_level_id, force_region)
        return "SMART" .. tostring(smart_id) .. (force_region and "+REGION" or "")
    end,
    get_faction_squad_term  = function(faction) return "TERM_" .. tostring(faction) end,
    number_word             = function(n) return "NUM" .. tostring(n) end,
    get_ago_phrase          = function() return "" end,
    get_period_key          = function() return "day" end,
}

wom_dialogue_helper = {
    make_pronoun_slots = function(plural) return { plural = plural } end,
    -- Echoes the pool key plus the slots a test needs to see, so an assertion can tell
    -- exactly which rung of the cascade fired and what it was handed.
    pick_dialogue_variant = function(prefix, slots, _gated, preferred)
        local parts = { prefix }
        if preferred then
            for _, token in ipairs(preferred) do parts[#parts + 1] = "pref=" .. token end
        end
        if slots then
            if slots.location    then parts[#parts + 1] = "loc=" .. tostring(slots.location) end
            if slots.squad_term  then parts[#parts + 1] = "term=" .. tostring(slots.squad_term) end
            if slots.squad_count then parts[#parts + 1] = "count=" .. tostring(slots.squad_count) end
            if slots.partner_name then parts[#parts + 1] = "partner=" .. tostring(slots.partner_name) end
            if slots.leader_name then parts[#parts + 1] = "leader=" .. tostring(slots.leader_name) end
            if slots.absent_name then parts[#parts + 1] = "absent=" .. tostring(slots.absent_name) end
        end
        return table.concat(parts, "|")
    end,
    fill_other_community_slots = function(slots) end,
    decapitalize_clause        = function(s) return s end,
    get_npc_full_name          = function(id) return _names[id] or "them" end,
    get_npc_first_name         = function(id) return (_names[id] or "them"):match("^%S+") end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
dofile(script_dir .. "/../gamedata/scripts/wom_recap_npc.script")

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

-- ============================================================
-- render_squad_status
-- ============================================================

group("render_squad_status: offline solo squad", function()
    _members = { 100 }
    local squad = make_squad({ commander_id = 100, count = 1 })
    check("alone pool, no crash without npc",
          render_squad_status(squad), "st_wom_recap_status_alone.")
end)

group("render_squad_status: offline pair, speaker is the commander", function()
    _members = { 100, 101 }
    _names   = { [101] = "Artyom Volkov" }
    local squad = make_squad({ commander_id = 100, count = 2 })
    -- With no npc the speaker is taken to be the commander, so is_leader is true and the
    -- leader_pair pool fires -- never the follower pools.
    check("leader_pair pool with the partner named",
          render_squad_status(squad), "st_wom_recap_status_leader_pair|partner=Artyom.")
end)

group("render_squad_status: offline squad of three", function()
    _members = { 100, 101, 102 }
    local squad = make_squad({ commander_id = 100, count = 3 })
    check("leader_squad pool with term and count",
          render_squad_status(squad),
          "st_wom_recap_status_leader_squad|term=TERM_stalker|count=NUM3.")
end)

group("render_squad_status: offline never reports absent members", function()
    -- An offline squad is a single alife point, so nobody can be absent from it. The
    -- online-member scan must not run at all: every member here IS registered online and
    -- far away, which would produce an absent clause if the guard were missing.
    _members = { 100, 101 }
    _names   = { [101] = "Artyom Volkov" }
    _online  = { [101] = make_npc(101, 9999) }
    local squad = make_squad({ commander_id = 100, count = 2 })
    check("no absent clause offline",
          render_squad_status(squad), "st_wom_recap_status_leader_pair|partner=Artyom.")
end)

group("render_squad_status: online path still detects absent members", function()
    _members = { 100, 101 }
    _names   = { [101] = "Artyom Volkov" }
    _online  = { [101] = make_npc(101, 9999) }
    local squad = make_squad({ commander_id = 100, count = 2 })
    local npc   = make_npc(100, 0)
    check("absent clause appended online",
          render_squad_status(squad, npc),
          "st_wom_recap_status_leader_pair|partner=Artyom Volkov, st_wom_recap_status_absent_one|absent=Artyom.")
end)

group("render_squad_status: online nearby member is not absent", function()
    _members = { 100, 101 }
    _names   = { [101] = "Artyom Volkov" }
    _online  = { [101] = make_npc(101, 5) }
    local squad = make_squad({ commander_id = 100, count = 2 })
    check("no absent clause when in range",
          render_squad_status(squad, make_npc(100, 0)),
          "st_wom_recap_status_leader_pair|partner=Artyom.")
end)

group("render_squad_status: nil squad is safe", function()
    check("returns empty", render_squad_status(nil), "")
end)

-- ============================================================
-- render_current_action
-- ============================================================

group("render_current_action: offline stationed squad reads as arrived", function()
    _record = { consequence_key = "consequence:job_explore", smart_id = 500 }
    local squad = make_squad({ current_action = 1 })
    -- No npc, so the role rungs are skipped and the cascade lands on goal + state.
    -- current_action == 1 is the gulag signal, so state is "arrived".
    check("goal_arrived pool",
          render_current_action(squad),
          "st_wom_ask_job_explore_arrived|loc=SMART500")
end)

group("render_current_action: offline travelling squad reads as moving", function()
    _record = { consequence_key = "consequence:job_explore", smart_id = 500 }
    local squad = make_squad({ current_action = 0 })
    check("goal_moving pool",
          render_current_action(squad),
          "st_wom_ask_job_explore_moving|loc=SMART500")
end)

group("render_current_action: offline falls back to the AP target smart", function()
    _record   = { consequence_key = "consequence:job_explore" }   -- no smart_id on the record
    _scripted = { [7] = { target_smart_id = 900 } }
    local squad = make_squad({ id = 7, current_action = 0 })
    check("location from the scripted target",
          render_current_action(squad),
          "st_wom_ask_job_explore_moving|loc=SMART900")
end)

group("render_current_action: offline with no AP record", function()
    _record = nil
    local squad = make_squad({ current_action = 0, assigned_target_id = 300 })
    -- No goal and no role leaves the generic state pool.
    check("generic_moving pool",
          render_current_action(squad),
          "st_wom_ask_generic_moving|loc=SMART300")
end)

group("render_current_action: offline secret goal deflects to an outsider", function()
    _record = { consequence_key = "consequence:stash_loot", smart_id = 500 }
    _player_comm     = "dolg"          -- player is not in the squad's faction
    _goal_visibility = "faction"
    local squad = make_squad({ player_id = "stalker", current_action = 0 })
    check("secretive pool",
          render_current_action(squad),
          "st_wom_ask_generic_secretive|loc=SMART500")
end)

group("render_current_action: offline secret goal is honest to own faction", function()
    _record = { consequence_key = "consequence:stash_loot", smart_id = 500 }
    _player_comm     = "stalker"
    _goal_visibility = "faction"
    local squad = make_squad({ player_id = "stalker", current_action = 0 })
    check("honest pool",
          render_current_action(squad),
          "st_wom_ask_stash_loot_moving|loc=SMART500")
end)

group("render_current_action: online path still uses the role rung", function()
    _record  = { consequence_key = "consequence:job_explore", smart_id = 500 }
    _members = { 100 }
    local squad = make_squad({ current_action = 0 })
    -- The daily recap passes current_smart_id = nil, so state stays "moving" and the
    -- goal+role rung is skipped; the role frame rung is what the role reaches.
    check("unchanged from the shipped call shape",
          render_current_action(squad, make_npc(100, 0), false, nil),
          "st_wom_ask_job_explore_moving|loc=SMART500")
end)

group("render_current_action: force_region reaches the terminology helper", function()
    _record = { consequence_key = "consequence:job_explore", smart_id = 500 }
    local squad = make_squad({ current_action = 0 })
    -- The PDA wire's call shape. Everything but the location is identical to the
    -- offline-travelling case above, so the region flag is the only difference.
    check("region forced",
          render_current_action(squad, nil, nil, nil, true),
          "st_wom_ask_job_explore_moving|loc=SMART500+REGION")
    check("omitted by default",
          render_current_action(squad),
          "st_wom_ask_job_explore_moving|loc=SMART500")
end)

group("render_current_action: force_region is independent of the online path", function()
    -- The flag is a separate question from whether an npc was supplied -- an online
    -- caller may force the region and an offline one may decline it.
    _record  = { consequence_key = "consequence:job_explore", smart_id = 500 }
    _members = { 100 }
    local squad = make_squad({ current_action = 0 })
    check("online caller can force it",
          render_current_action(squad, make_npc(100, 0), false, nil, true),
          "st_wom_ask_job_explore_moving|loc=SMART500+REGION")
end)

group("render_current_action: prefer_location steers the pick when a location resolved", function()
    _record = { consequence_key = "consequence:job_explore", smart_id = 500 }
    local squad = make_squad({ current_action = 0 })
    -- The PDA wire's call shape: the listener cannot see the speaker, so a line that
    -- names where they are beats one that does not.
    check("preference reaches the pool pick",
          render_current_action(squad, nil, nil, nil, true, true),
          "st_wom_ask_job_explore_moving|pref=location|loc=SMART500+REGION")
    check("face-to-face dialogue keeps the full pool",
          render_current_action(squad, nil, nil, nil, true),
          "st_wom_ask_job_explore_moving|loc=SMART500+REGION")
end)

group("render_current_action: prefer_location is dropped when no location resolved", function()
    -- No smart on the record, nothing scripted, no assigned target: #location# is the
    -- "a location" fallback, which is not worth steering the pick towards.
    _record   = { consequence_key = "consequence:job_explore" }
    _scripted = {}
    local squad = make_squad({ current_action = 0 })
    check("no preference passed",
          render_current_action(squad, nil, nil, nil, true, true),
          "st_wom_ask_job_explore_moving|loc=st_wom_term_location_fallback")
end)

group("render_current_action: nil squad and missing AP are safe", function()
    check("nil squad", render_current_action(nil), "")
    local saved = ap_api
    ap_api = nil
    check("no ALifePlus", render_current_action(make_squad({})), "")
    ap_api = saved
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
