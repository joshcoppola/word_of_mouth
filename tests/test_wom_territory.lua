-- tests/test_wom_territory.lua
-- Standalone Lua 5.1 tests for wom_territory.script.
--
-- Run from the repository root:  lua tests/test_wom_territory.lua
-- Run from tests/:               lua test_wom_territory.lua
--
-- Two things are worth testing here and both are pure logic: the ledger
-- (collect_holdings — the exact-key spawn-state test, the vanilla faction_controlled
-- trap, live-beats-record precedence, remembered holds, decay-window aging of the
-- record pass, ordering) and the assembly done by render_territory (cap at three
-- holds, connectors between them, the "nothing known" fallback). Everything the
-- script touches outside itself is stubbed: a fake smart registry supplies spawn
-- state, ap_api the records, wom_ap_bridge the decay windows, and the helper modules
-- return recognisable marker strings so assertions can look for them in the output.

-- ============================================================
-- Mutable test state
-- ============================================================

local _records     = {}     -- what ap_api.get_records returns
local _smarts      = {}     -- name -> fake smart server object
local _game_sec    = 0
local _level_id    = 1
local _decay_hours = { conquer = 48, swarm = 48, infest = 48 }
local _pool_hits   = {}     -- prefix -> times pick_dialogue_variant was asked for it
local _empty_pools = {}     -- prefix set that renders ""
local _speaker_smart   = nil  -- what wom_npc_role.current_smart returns
local _speaker_squad   = nil  -- what wom_utils.resolve_squad returns
local _squad_smart_id  = nil  -- what wom_npc_role.smart_id_of_squad returns for it
local _npc_pos         = nil  -- what npc:position() returns
local _position_reads  = 0    -- times npc:position() was called as a method

local function reset()
    _records     = {}
    _smarts      = {}
    _game_sec    = 100 * 3600
    _level_id    = 1
    _decay_hours = { conquer = 48, swarm = 48, infest = 48 }
    _pool_hits   = {}
    _empty_pools = {}
    _speaker_smart   = nil
    _speaker_squad   = nil
    _squad_smart_id  = nil
    _npc_pos         = nil
    _position_reads  = 0
end

-- Adds a fake smart terrain to the registry.
-- faction_controlled/faction are the two fields the mutator writes; services is a set of
-- role names, injected as the "ap_service_<role>" respawn_params keys ALifePlus uses.
-- position defaults to a far-away point so proximity never matches by accident; pass
-- `false` to model a smart with no position at all.
local function add_smart(smart_id, faction_controlled, faction, services, level_id, position)
    local respawn_params = {}
    if faction_controlled then respawn_params[faction_controlled] = { faction = faction } end
    for role in pairs(services or {}) do
        respawn_params["ap_service_" .. role] = { faction = faction }
    end
    if position == nil then position = { x = 100000, y = 0, z = 100000 } end
    _smarts["smart_" .. smart_id] = {
        id                 = smart_id,
        faction_controlled = faction_controlled,
        faction            = faction,
        respawn_params     = respawn_params,
        level_id           = level_id or 1,
        position           = position or nil,
    }
end

-- Appends a takeover record. hours_ago is in in-game hours before "now".
local function add_record(cause_key, smart_id, hours_ago, faction, level_id)
    _records[#_records + 1] = {
        cause_key           = cause_key,
        smart_id            = smart_id,
        game_hours          = math.floor(_game_sec / 3600) - hours_ago,
        level_id            = level_id or 1,
        subject_faction_key = faction or "dolg",
    }
end

-- ============================================================
-- Engine / module stubs
-- ============================================================

ap_api = {
    get_records = function(filter)
        local out = {}
        for i = 1, #_records do
            local record = _records[i]
            if not (filter and filter.level_id) or record.level_id == filter.level_id then
                out[#out + 1] = record
            end
        end
        return out
    end,
}

xtime  = { game_sec = function() return _game_sec end }

xlevel = {
    get_actor_level_id = function() return _level_id end,
    get_level_id       = function(smart) return smart and smart.level_id end,
}

xsmart = { smarts_by_names = function() return _smarts end }

-- Speaker location. Two of the three signals come from here (the smart whose job roster
-- lists the NPC, and the NPC's squad's smart); the third is proximity, which wom_territory
-- measures itself against the held smarts rather than delegating.
wom_npc_role = {
    current_smart     = function() return _speaker_smart end,
    smart_id_of_squad = function(squad) return squad and _squad_smart_id or nil end,
}

wom_utils = {
    resolve_squad = function() return _speaker_squad end,
    -- Mirrors the real helper: resolves `position` whether it is a client object's
    -- method or a server object's vector field.
    get_object_position = function(obj)
        if not obj then return nil end
        local position = obj.position
        if type(position) == "function" then
            local call_ok, result = pcall(position, obj)
            return call_ok and result or nil
        end
        return position
    end,
}

wom_outpost = {
    describe_roles = function(roles)
        local order, phrases = { "trader", "barman", "mechanic", "medic" }, {}
        for _, role in ipairs(order) do
            if roles[role] then phrases[#phrases + 1] = "ROLE_" .. role end
        end
        return table.concat(phrases, "+"), phrases[1] or ""
    end,
}

wom_ap_bridge = {
    get_area_decay_hours = function(kind) return _decay_hours[kind] end,
}

wom_terminology_helper = {
    extract_community_key = function(faction_key, species_key) return faction_key or species_key end,
    get_location_name     = function(smart_id) return "SMART" .. tostring(smart_id) end,
    get_faction_identity  = function(community) return "IDENT_" .. community end,
    get_some_faction      = function(community) return "SOME_" .. community end,
    get_a_faction_squad   = function(community) return "SQUAD_" .. community end,
    get_faction_members_plural = function(community) return "PLURAL_" .. community end,
    get_ago_phrase        = function() return "AGO" end,
}

-- Renders "<prefix>[slot values]" so a test can see which pool was used and that
-- substitution reached it, without needing the real localisation tables.
wom_dialogue_helper = {
    decapitalize_clause = function(text) return (text or ""):lower() end,
    pick_dialogue_variant = function(prefix, slots)
        _pool_hits[prefix] = (_pool_hits[prefix] or 0) + 1
        if _empty_pools[prefix] then return "" end
        local location = slots and slots.location or ""
        if location ~= "" then return prefix .. "[" .. location .. "]" end
        return prefix .. "."
    end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
dofile(script_dir .. "/../gamedata/scripts/wom_territory.script")

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

-- Convenience: collect with the stubbed clock.
local function collect()
    return collect_holdings(_level_id, math.floor(_game_sec / 3600))
end

-- position() is a METHOD on a real client game object, never a field — stubbing it as a
-- field is what let a nil-position bug ship once already, so these fakes model the method
-- and count the calls.
local function npc_of(community)
    return {
        character_community = function() return community end,
        position = function() _position_reads = _position_reads + 1; return _npc_pos end,
    }
end

local FAKE_NPC = npc_of("stalker")

-- ============================================================
-- collect_holdings: spawn state
-- ============================================================

group("collect_holdings: live holds come from the spawn pool", function()
    reset()
    add_smart(10, "ap_conquest", "dolg")
    add_smart(11, "ap_swarm",    "dog")
    add_smart(12, "ap_infest",   "bloodsucker")
    local holdings = collect()
    check("one holding per held smart", #holdings, 3)

    local by_smart = {}
    for i = 1, #holdings do by_smart[holdings[i].smart_id] = holdings[i] end
    check("ap_conquest maps to conquer", by_smart[10].kind, "conquer")
    check("ap_swarm maps to swarm",      by_smart[11].kind, "swarm")
    check("ap_infest maps to infest",    by_smart[12].kind, "infest")
    check("holder read from smart.faction", by_smart[10].community, "dolg")
    check("live holds are not remembered", by_smart[10].is_remembered, false)
    check("no record means no timestamp", by_smart[10].game_hours, nil)
end)

group("collect_holdings: vanilla faction_controlled is not a takeover", function()
    reset()
    -- Vanilla writes a faction-list string into the same field on ~10 real smarts
    -- (esc_smart_terrain_6_8, gar_smart_terrain_3_5, cit_killers_vs_bandits, ...).
    -- A truthiness test on the field would report all of them as conquered.
    add_smart(20, "stalker,dolg", "stalker")
    add_smart(21, "bandit",       "bandit")
    add_smart(22, "faction_controlled_dolg", "dolg")
    check("vanilla faction lists are ignored", #collect(), 0)

    add_smart(23, "ap_conquest", "dolg")
    local holdings = collect()
    check("a real AP key alongside them still registers", #holdings, 1)
    check("and it is the AP smart", holdings[1].smart_id, 23)
end)

group("collect_holdings: incomplete spawn state", function()
    reset()
    add_smart(30, nil, nil)              -- untouched smart
    add_smart(31, "ap_conquest", nil)    -- key but no owner faction
    check("smarts with no key or no holder are skipped", #collect(), 0)
end)

group("collect_holdings: level filter", function()
    reset()
    add_smart(40, "ap_conquest", "dolg", nil, 2)   -- another level
    check("held smarts on other levels are filtered out", #collect(), 0)

    reset()
    add_smart(41, "ap_conquest", "dolg")
    check("nil level id yields nothing", #collect_holdings(nil, 100), 0)
end)

group("collect_holdings: outpost services", function()
    reset()
    add_smart(50, "ap_conquest", "dolg", { trader = true, mechanic = true })
    local holdings = collect()
    check("trader role detected",   holdings[1].services.trader,   true)
    check("mechanic role detected", holdings[1].services.mechanic,  true)
    check("absent role not detected", holdings[1].services.medic,   nil)

    reset()
    add_smart(51, "ap_conquest", "dolg")
    check("no service entries yields an empty set", next(collect()[1].services), nil)
end)

-- ============================================================
-- collect_holdings: records (timing and remembered holds)
-- ============================================================

group("collect_holdings: a record dates a live hold", function()
    reset()
    add_smart(60, "ap_conquest", "dolg")
    add_record("cause:area_conquer", 60, 6, "dolg")
    local holdings = collect()
    check("still one holding", #holdings, 1)
    check("timestamp taken from the record", holdings[1].game_hours, math.floor(_game_sec / 3600) - 6)
    check("still a live hold", holdings[1].is_remembered, false)

    -- A record naming an earlier owner says nothing about the current one.
    reset()
    add_smart(61, "ap_conquest", "dolg")
    add_record("cause:area_conquer", 61, 6, "freedom")
    local mismatched = collect()
    check("holder still from spawn state", mismatched[1].community, "dolg")
    check("mismatched record does not date the hold", mismatched[1].game_hours, nil)
end)

group("collect_holdings: records without a live hold are remembered", function()
    reset()
    add_record("cause:area_conquer", 70, 6, "dolg")
    local holdings = collect()
    check("one remembered holding", #holdings, 1)
    check("marked as remembered", holdings[1].is_remembered, true)
    check("holder from the record", holdings[1].community, "dolg")
    check("remembered holds carry no services", holdings[1].services, nil)
end)

group("collect_holdings: remembered holds age out on the decay window", function()
    reset()
    add_record("cause:area_conquer", 80, 47, "dolg")   -- inside the 48 h window
    add_record("cause:area_conquer", 81, 49, "dolg")   -- expired
    local holdings = collect()
    check("only the in-window memory survives", #holdings, 1)
    check("and it is the recent one", holdings[1].smart_id, 80)

    reset()
    _decay_hours.conquer = 0    -- 0 means the takeover never decays
    add_record("cause:area_conquer", 82, 500, "dolg")
    check("a permanent kind never ages out", #collect(), 1)

    reset()
    _decay_hours.swarm = 4
    add_record("cause:area_conquer", 83, 6, "dolg")
    add_record("cause:area_swarm",   84, 6, "dog")
    local per_kind = collect()
    check("each kind ages on its own window", #per_kind, 1)
    check("the conquer memory is the survivor", per_kind[1].smart_id, 83)
end)

group("collect_holdings: newest record wins per smart", function()
    reset()
    add_record("cause:area_conquer", 90, 20, "dolg")
    add_record("cause:area_swarm",   90, 2,  "dog")
    local holdings = collect()
    check("one memory per smart terrain", #holdings, 1)
    check("newest takeover wins", holdings[1].kind, "swarm")
    check("holder comes from the newest record", holdings[1].community, "dog")
end)

group("collect_holdings: ordering", function()
    reset()
    add_record("cause:area_conquer", 100, 2, "dolg")     -- remembered, recent
    add_smart(101, "ap_conquest", "dolg")                -- live, undated
    add_smart(102, "ap_conquest", "freedom")
    add_record("cause:area_conquer", 102, 20, "freedom") -- live, dated
    local holdings = collect()
    check("three holdings", #holdings, 3)
    check("dated live hold leads", holdings[1].smart_id, 102)
    check("undated live hold next", holdings[2].smart_id, 101)
    check("remembered holds come last", holdings[3].smart_id, 100)
end)

-- ============================================================
-- render_territory
-- ============================================================

group("render_territory: nothing known", function()
    reset()
    check_contains("falls back to the none pool",
        render_territory(FAKE_NPC), "st_wom_territory_none")

    reset()
    add_record("cause:area_conquer", 110, 1, "dolg")
    local real_ap_api = ap_api
    ap_api = nil
    check_contains("ALifePlus absent → none pool",
        render_territory(FAKE_NPC), "st_wom_territory_none")
    ap_api = real_ap_api

    reset()
    add_smart(111, "ap_conquest", "dolg")
    local real_xsmart = xsmart
    xsmart = nil
    check_contains("smart registry absent → none pool",
        render_territory(FAKE_NPC), "st_wom_territory_none")
    xsmart = real_xsmart
end)

group("render_territory: pool selection per kind and staleness", function()
    reset()
    add_smart(120, "ap_conquest", "dolg")
    check_contains("live conquer uses the held pool",
        render_territory(FAKE_NPC), "st_wom_territory_held_conquer[SMART120]")

    reset()
    add_smart(121, "ap_infest", "bloodsucker")
    check_contains("live infest uses its own pool",
        render_territory(FAKE_NPC), "st_wom_territory_held_infest[SMART121]")

    reset()
    add_record("cause:area_conquer", 122, 6, "dolg")
    check_contains("remembered conquer uses the fading pool",
        render_territory(FAKE_NPC), "st_wom_territory_fading_conquer[SMART122]")

    reset()
    add_record("cause:area_swarm", 123, 6, "dog")
    check_contains("remembered swarm uses the fading pool",
        render_territory(FAKE_NPC), "st_wom_territory_fading_swarm[SMART123]")
end)

-- Captures the slot table passed to one pool prefix during a render.
local function slots_for(prefix, fn)
    local captured = nil
    local real_pick = wom_dialogue_helper.pick_dialogue_variant
    wom_dialogue_helper.pick_dialogue_variant = function(p, s, gated)
        if p == prefix then captured = s end
        return real_pick(p, s, gated)
    end
    fn()
    wom_dialogue_helper.pick_dialogue_variant = real_pick
    return captured
end

group("render_territory: service slots", function()
    reset()
    add_smart(130, "ap_conquest", "dolg", { trader = true, medic = true })
    local slots = slots_for("st_wom_territory_service_conquer", function() render_territory(FAKE_NPC) end)
    check("service list rendered in canonical order", slots and slots.service_list, "ROLE_trader+ROLE_medic")
    check("representative role is the first one",     slots and slots.service_role, "ROLE_trader")

    -- A hold with no services leaves both slots empty so their variants gate out.
    reset()
    add_smart(131, "ap_conquest", "dolg")
    slots = slots_for("st_wom_territory_held_conquer", function() render_territory(FAKE_NPC) end)
    check("empty service list", slots and slots.service_list, "")
    check("empty service role", slots and slots.service_role, "")
end)

group("render_territory: the service pool is separate from the plain one", function()
    reset()
    add_smart(160, "ap_conquest", "dolg", { trader = true })
    local text = render_territory(FAKE_NPC)
    check_contains("a camp with services uses the service pool",
        text, "st_wom_territory_service_conquer[SMART160]")
    check("and never the plain pool", _pool_hits["st_wom_territory_held_conquer"], nil)

    reset()
    add_smart(161, "ap_conquest", "dolg")
    text = render_territory(FAKE_NPC)
    check_contains("a camp with no services uses the plain pool",
        text, "st_wom_territory_held_conquer[SMART161]")
    check("and never the service pool", _pool_hits["st_wom_territory_service_conquer"], nil)

    -- Only conquest grows services, so _service_swarm / _service_infest are unauthored;
    -- an empty pool must fall back rather than render nothing.
    reset()
    add_smart(162, "ap_conquest", "dolg", { trader = true })
    _empty_pools["st_wom_territory_service_conquer"] = true
    check_contains("unauthored/gated service pool falls back to the plain pool",
        render_territory(FAKE_NPC), "st_wom_territory_held_conquer[SMART162]")

    -- A remembered hold never carries services, so it stays on the fading pool.
    reset()
    add_record("cause:area_conquer", 163, 6, "dolg")
    text = render_territory(FAKE_NPC)
    check_contains("remembered hold still uses the fading pool",
        text, "st_wom_territory_fading_conquer[SMART163]")
    check("service pool untouched for remembered holds",
        _pool_hits["st_wom_territory_service_conquer"], nil)
end)

-- Convenience: collect with the stubbed clock and a speaker.
local function collect_asking(npc)
    return collect_holdings(_level_id, math.floor(_game_sec / 3600), npc)
end

group("collect_holdings: the speaker's own location", function()
    reset()
    add_smart(170, "ap_conquest", "dolg")
    add_smart(171, "ap_conquest", "freedom")
    _speaker_smart = { id = 171 }
    local holdings = collect_asking(FAKE_NPC)
    check("the speaker's camp sorts first", holdings[1].smart_id, 171)
    check("and is flagged", holdings[1].is_here, true)
    check("the other hold is not", holdings[2].is_here, false)

    -- Ordering must beat both the live/remembered split and recency.
    reset()
    add_smart(172, "ap_conquest", "dolg")            -- here, undated
    add_smart(173, "ap_conquest", "freedom")
    add_record("cause:area_conquer", 173, 1, "freedom")  -- live and very recent
    _speaker_smart = { id = 172 }
    holdings = collect_asking(FAKE_NPC)
    check("here beats a more recent hold", holdings[1].smart_id, 172)

    -- Every candidate must be checked against the held set. A signal naming a smart that
    -- is not under a takeover (a neighbouring camp, a travelling squad's destination) must
    -- not be returned as "here", nor stop the remaining signals from being tried.
    reset()
    add_smart(174, "ap_conquest", "dolg")
    _speaker_smart = { id = 999 }
    holdings = collect_asking(FAKE_NPC)
    check("an unheld job-roster smart flags nothing", holdings[1].is_here, false)

    reset()
    add_smart(1740, "ap_conquest", "dolg")
    _speaker_smart  = { id = 999 }        -- unheld neighbour
    _speaker_squad  = { id = 7 }
    _squad_smart_id = 1740                -- the real answer, behind it
    holdings = collect_asking(FAKE_NPC)
    check("an unheld candidate does not block later signals", holdings[1].is_here, true)

    -- No speaker at all: nothing is "here".
    reset()
    add_smart(176, "ap_conquest", "dolg")
    check("no speaker means no here flag", collect_asking(nil)[1].is_here, false)

    -- A remembered hold is never "here": there is nothing left to see.
    reset()
    add_record("cause:area_conquer", 175, 6, "dolg")
    _speaker_smart = { id = 175 }
    holdings = collect_asking(FAKE_NPC)
    check("remembered holds are never here", holdings[1].is_here, false)
end)

group("collect_holdings: proximity to a held smart", function()
    -- The proximity test measures against the held smarts' own positions, so an unheld
    -- smart standing closer can never win.
    reset()
    add_smart(177, "ap_conquest", "dolg", nil, 1, { x = 10, y = 0, z = 10 })
    _npc_pos = { x = 12, y = 0, z = 14 }
    check("a held smart within radius is here", collect_asking(FAKE_NPC)[1].is_here, true)

    reset()
    add_smart(178, "ap_conquest", "dolg", nil, 1, { x = 5000, y = 0, z = 5000 })
    _npc_pos = { x = 0, y = 0, z = 0 }
    check("a held smart beyond radius is not", collect_asking(FAKE_NPC)[1].is_here, false)

    -- Distance is ground-plane only: a speaker one floor up is still at the camp.
    reset()
    add_smart(179, "ap_conquest", "dolg", nil, 1, { x = 0, y = 0, z = 0 })
    _npc_pos = { x = 0, y = 400, z = 0 }
    check("height is ignored", collect_asking(FAKE_NPC)[1].is_here, true)

    -- A smart with no position cannot be matched by proximity.
    reset()
    add_smart(1790, "ap_conquest", "dolg", nil, 1, false)
    _npc_pos = { x = 0, y = 0, z = 0 }
    check("a positionless smart is not here", collect_asking(FAKE_NPC)[1].is_here, false)
end)

group("render_territory: here pools", function()
    -- Slotted into the smart's jobs — the authoritative signal.
    reset()
    add_smart(180, "ap_conquest", "dolg")
    _speaker_smart = { id = 180 }
    check_contains("another faction's camp uses the here pool",
        render_territory(FAKE_NPC), "st_wom_territory_here_conquer[SMART180]")

    -- Same camp, but the speaker belongs to the holding faction.
    reset()
    add_smart(181, "ap_conquest", "dolg")
    _speaker_smart = { id = 181 }
    check_contains("own faction's camp uses the here_own pool",
        render_territory(npc_of("dolg")), "st_wom_territory_here_own_conquer[SMART181]")

    -- Not in any smart's job roster, but posted there with their squad. ALifePlus pins
    -- garrison squads with scripted_target rather than through the board, so this is the
    -- signal that catches a conquered camp's own defenders.
    reset()
    add_smart(1820, "ap_conquest", "dolg")
    _speaker_squad  = { id = 7 }
    _squad_smart_id = 1820
    check_contains("squad's smart counts as here",
        render_territory(FAKE_NPC), "st_wom_territory_here_conquer[SMART1820]")

    -- Belonging to no camp at all: proximity answers, and it must read position as a
    -- method — stubbing it as a field is what let this ship dead once.
    reset()
    add_smart(182, "ap_conquest", "dolg", nil, 1, { x = 0, y = 0, z = 0 })
    _npc_pos = { x = 20, y = 0, z = 20 }
    check_contains("proximity still counts as here",
        render_territory(FAKE_NPC), "st_wom_territory_here_conquer[SMART182]")
    check("position was read as a method", _position_reads > 0, true)

    -- Standing nowhere near a held camp.
    reset()
    add_smart(183, "ap_conquest", "dolg")
    _npc_pos = { x = 0, y = 0, z = 0 }
    check_contains("speaker elsewhere uses the plain pool",
        render_territory(FAKE_NPC), "st_wom_territory_held_conquer[SMART183]")

    -- Signal precedence: the job roster wins over the squad, which wins over proximity.
    reset()
    add_smart(1830, "ap_conquest", "dolg")
    add_smart(1831, "ap_conquest", "freedom")
    add_smart(1832, "ap_conquest", "killer", nil, 1, { x = 0, y = 0, z = 0 })
    _speaker_smart   = { id = 1830 }
    _speaker_squad   = { id = 7 }
    _squad_smart_id  = 1831
    _npc_pos         = { x = 0, y = 0, z = 0 }
    check_contains("job roster outranks squad and proximity",
        render_territory(FAKE_NPC), "st_wom_territory_here_conquer[SMART1830]")

    reset()
    add_smart(1833, "ap_conquest", "freedom")
    add_smart(1834, "ap_conquest", "killer", nil, 1, { x = 0, y = 0, z = 0 })
    _speaker_squad   = { id = 7 }
    _squad_smart_id  = 1833
    _npc_pos         = { x = 0, y = 0, z = 0 }
    check_contains("squad outranks proximity",
        render_territory(FAKE_NPC), "st_wom_territory_here_conquer[SMART1833]")

    -- here_own is only tried for the own-faction case.
    reset()
    add_smart(184, "ap_conquest", "dolg")
    _speaker_smart = { id = 184 }
    render_territory(FAKE_NPC)
    check("here_own not consulted for another faction's camp",
        _pool_hits["st_wom_territory_here_own_conquer"], nil)

    -- Unauthored/gated here pools fall back through service to plain.
    reset()
    add_smart(185, "ap_conquest", "dolg", { trader = true })
    _speaker_smart = { id = 185 }
    _empty_pools["st_wom_territory_here_own_service_conquer"] = true
    _empty_pools["st_wom_territory_here_own_conquer"] = true
    _empty_pools["st_wom_territory_here_service_conquer"] = true
    _empty_pools["st_wom_territory_here_conquer"] = true
    check_contains("gated here pools fall back to the service pool",
        render_territory(npc_of("dolg")), "st_wom_territory_service_conquer[SMART185]")

    reset()
    add_smart(186, "ap_conquest", "dolg")
    _speaker_smart = { id = 186 }
    _empty_pools["st_wom_territory_here_conquer"] = true
    check_contains("and to the plain pool when there are no services",
        render_territory(FAKE_NPC), "st_wom_territory_held_conquer[SMART186]")

    -- A here camp with services uses the here-service pools, never the generic one.
    reset()
    add_smart(187, "ap_conquest", "dolg", { trader = true })
    _speaker_smart = { id = 187 }
    check_contains("someone else's here camp with services",
        render_territory(FAKE_NPC), "st_wom_territory_here_service_conquer[SMART187]")
    check("generic service pool skipped for a here camp",
        _pool_hits["st_wom_territory_service_conquer"], nil)
    check("plain here pool skipped when services exist",
        _pool_hits["st_wom_territory_here_conquer"], nil)

    reset()
    add_smart(188, "ap_conquest", "dolg", { trader = true })
    _speaker_smart = { id = 188 }
    check_contains("own here camp with services",
        render_territory(npc_of("dolg")), "st_wom_territory_here_own_service_conquer[SMART188]")
    check("plain here_own pool skipped when services exist",
        _pool_hits["st_wom_territory_here_own_conquer"], nil)

    -- The speaker relationship outranks the service split: a missing own-service pool
    -- degrades to own-without-services, not to a stranger's phrasing.
    reset()
    add_smart(189, "ap_conquest", "dolg", { trader = true })
    _speaker_smart = { id = 189 }
    _empty_pools["st_wom_territory_here_own_service_conquer"] = true
    check_contains("own-service falls back to own, not to here_service",
        render_territory(npc_of("dolg")), "st_wom_territory_here_own_conquer[SMART189]")

    -- Mutant takeovers get their own here pools.
    reset()
    add_smart(190, "ap_infest", "bloodsucker", nil, 1, { x = 0, y = 0, z = 0 })
    _npc_pos = { x = 30, y = 0, z = 0 }
    check_contains("infest has a here pool too",
        render_territory(FAKE_NPC), "st_wom_territory_here_infest[SMART190]")
end)

group("render_territory: assembly", function()
    reset()
    add_smart(140, "ap_conquest", "dolg")
    add_smart(141, "ap_conquest", "freedom")
    add_smart(142, "ap_swarm",    "dog")
    add_smart(143, "ap_infest",   "bloodsucker")
    local text = render_territory(FAKE_NPC)
    check_contains("intro is prepended", text, "st_wom_territory_intro")
    check("connector used between holds", _pool_hits["st_wom_territory_seq"], 2)

    local reported = 0
    for _, smart_id in ipairs({ 140, 141, 142, 143 }) do
        if text:find("SMART" .. smart_id, 1, true) then reported = reported + 1 end
    end
    check("exactly three holds reported", reported, 3)

    -- A hold whose location cannot be resolved contributes nothing.
    reset()
    add_smart(150, "ap_conquest", "dolg")
    local real_get_location_name = wom_terminology_helper.get_location_name
    wom_terminology_helper.get_location_name = function() return "" end
    check_contains("unresolvable location → none pool",
        render_territory(FAKE_NPC), "st_wom_territory_none")
    wom_terminology_helper.get_location_name = real_get_location_name

    -- Every hold pool gating out is the same case as having no holds.
    reset()
    add_smart(151, "ap_conquest", "dolg")
    _empty_pools["st_wom_territory_held_conquer"] = true
    check_contains("all templates gated → none pool",
        render_territory(FAKE_NPC), "st_wom_territory_none")
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
