-- tests/test_wom_bark.lua
-- Standalone Lua 5.1 tests for wom_bark.faction_matches.
--
-- Run from the repository root:  lua tests/test_wom_bark.lua
-- Run from tests/:               lua test_wom_bark.lua
--
-- faction_matches is the single relevance gate every news-wire feature reads, so the
-- three scopes have to mean the same thing everywhere. test_wom_outpost stubs this
-- function out (it is testing the scan, not the gate), which means the real
-- implementation had no coverage at all — including the "neutral" scope the outpost
-- MCM option added. This file exercises the real thing against a fake relation table.

-- ============================================================
-- Fake engine: game_relations over an explicit relation table
-- ============================================================

-- player_comm -> other_comm -> "friend" | "neutral" | "enemy".
-- Anything absent has NO registered relation, which is the case the "neutral" branch
-- must NOT treat as neutral (see the note in wom_bark.faction_matches).
local _relations = {}

local function relation_of(a, b)
    return _relations[a] and _relations[a][b] or nil
end

game_relations = {
    is_factions_friends  = function(a, b) return relation_of(a, b) == "friend" end,
    is_factions_neutrals = function(a, b) return relation_of(a, b) == "neutral" end,
    is_factions_enemies  = function(a, b) return relation_of(a, b) == "enemy" end,
}

-- ============================================================
-- Fake engine: online NPC registry for pick_nearby_stalker
-- ============================================================

-- Squared 3D distance, the fallback _range_sqr uses when xlibs is absent.
-- @param x number
-- @param z number
-- @return table  vector stub
local function make_vector(x, z)
    local v = { x = x, y = 0, z = z }
    function v:distance_to_sqr(other)
        local dx, dz = self.x - other.x, self.z - other.z
        return dx * dx + dz * dz
    end
    return v
end

-- npc_id -> stub NPC, or nil for an id whose client object is gone. Standing in for
-- the engine's live object map, this is what get_live_online_npc reads: an id present
-- in OnlineStalkers but absent here is exactly the stale entry that used to abort the
-- whole scan when the picker read db.storage[id].object and called :alive() on it.
local _live_npcs = {}

-- @param id        number
-- @param community string
-- @param x         number  world x; the actor sits at the origin
-- @return table  stub NPC registered as live
local function make_npc(id, community, x)
    local npc = { _id = id, _pos = make_vector(x, 0) }
    function npc:id() return self._id end
    function npc:position() return self._pos end
    function npc:character_community() return community end
    _live_npcs[id] = npc
    return npc
end

-- wom_bark's module body only builds local tables, but its other functions reference
-- these at call time; stub them so dofile and any incidental access stay safe.
db       = { actor = { position = function() return make_vector(0, 0) end }, OnlineStalkers = {} }
xmath    = nil
xr_sound = nil
printf   = function() end

-- Mirrors the real helper's contract (nil for any id whose object is missing, stale
-- or dead) against this harness's registry. The real implementation's three engine
-- guards are covered in test_wom_utils.lua; what matters here is that the picker
-- routes through it and honours a nil.
wom_utils = {
    get_live_online_npc = function(id) return _live_npcs[id] end,
}

-- ============================================================
-- Load the module under test
-- ============================================================

local script_dir = arg[0]:match("^(.*)[/\\][^/\\]*$") or "."
dofile(script_dir .. "/../gamedata/scripts/wom_bark.script")

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

local function group(name, fn)
    io.write(name .. "\n")
    fn()
end

-- The player is a Loner: allied with Duty, neutral toward Ecologists, hostile to
-- Bandits, and with no registered relation to Monolith.
local function set_standard_relations()
    _relations = {
        stalker = {
            dolg     = "friend",
            ecolog   = "neutral",
            bandit   = "enemy",
        },
    }
end

-- ============================================================
-- Tests
-- ============================================================

group("faction_matches: own faction", function()
    set_standard_relations()
    check("own faction at faction scope", faction_matches("stalker", "stalker", "faction"), true)
    check("own faction at allies scope",  faction_matches("stalker", "stalker", "allies"),  true)
    check("own faction at neutral scope", faction_matches("stalker", "stalker", "neutral"), true)
    check("nil community is never a match", faction_matches(nil, "stalker", "neutral"), false)
end)

group("faction_matches: faction scope admits nothing else", function()
    set_standard_relations()
    check("ally rejected",    faction_matches("dolg",     "stalker", "faction"), false)
    check("neutral rejected", faction_matches("ecolog",   "stalker", "faction"), false)
    check("enemy rejected",   faction_matches("bandit",   "stalker", "faction"), false)
    check("unrelated rejected", faction_matches("monolith", "stalker", "faction"), false)
end)

group("faction_matches: allies scope admits allies only", function()
    set_standard_relations()
    check("ally accepted",    faction_matches("dolg",     "stalker", "allies"), true)
    check("neutral rejected", faction_matches("ecolog",   "stalker", "allies"), false)
    check("enemy rejected",   faction_matches("bandit",   "stalker", "allies"), false)
    check("unrelated rejected", faction_matches("monolith", "stalker", "allies"), false)
end)

group("faction_matches: neutral scope is cumulative", function()
    set_standard_relations()
    -- The widest scope must still admit everything the narrower ones do; the earlier
    -- implementation returned early on the friends test, so widening it without this
    -- assertion could have dropped allies.
    check("ally still accepted", faction_matches("dolg",   "stalker", "neutral"), true)
    check("neutral accepted",    faction_matches("ecolog", "stalker", "neutral"), true)
    check("enemy still rejected", faction_matches("bandit", "stalker", "neutral"), false)
    -- A faction with no registered relation is not neutral. This is why the branch uses
    -- is_factions_neutrals rather than "not is_factions_enemies", which would be true here.
    check("unrelated faction is not neutral", faction_matches("monolith", "stalker", "neutral"), false)
end)

group("faction_matches: unknown scope falls back to own faction only", function()
    set_standard_relations()
    check("own faction still matches", faction_matches("stalker", "stalker", "everyone"), true)
    check("ally rejected under an unknown scope", faction_matches("dolg", "stalker", "everyone"), false)
end)

group("faction_matches: absent game_relations degrades safely", function()
    set_standard_relations()
    local saved = game_relations
    game_relations = nil
    check("own faction still matches", faction_matches("stalker", "stalker", "neutral"), true)
    check("ally no longer resolvable", faction_matches("dolg", "stalker", "neutral"), false)
    game_relations = saved
end)

group("faction_matches: partial game_relations degrades safely", function()
    set_standard_relations()
    local saved = game_relations
    -- An engine build without is_factions_neutrals must still honour the allies half of
    -- the neutral scope rather than erroring on a nil call.
    game_relations = { is_factions_friends = saved.is_factions_friends }
    check("ally accepted without is_factions_neutrals", faction_matches("dolg", "stalker", "neutral"), true)
    check("neutral rejected without is_factions_neutrals", faction_matches("ecolog", "stalker", "neutral"), false)
    game_relations = saved
end)

-- ============================================================
-- pick_nearby_stalker
-- ============================================================

-- Clears the registry, the online list and the shared cooldown table, then returns
-- the opts table every group below starts from: a 10 m radius, no dev override, and
-- no cooldown owed.
-- @return table  opts for pick_nearby_stalker
local function reset_picker()
    _live_npcs = {}
    db.OnlineStalkers = {}
    reset_cooldowns()
    return { range_sqr = 100, dev = false, now_sec = 1000, cooldown_sec = 60 }
end

-- The picker shuffles OnlineStalkers, so every group below leaves exactly one
-- eligible candidate and asserts identity. That keeps the assertions independent of
-- math.random without seeding it.
group("pick_nearby_stalker: eligibility", function()
    local opts = reset_picker()
    local speaker = make_npc(1, "stalker", 5)
    db.OnlineStalkers = { 1 }
    check("in-range human stalker is returned", pick_nearby_stalker(db.actor, opts), speaker)

    opts = reset_picker()
    db.OnlineStalkers = { 1 }
    check("empty registry → nil", pick_nearby_stalker(db.actor, opts), nil)
end)

group("pick_nearby_stalker: a stale id is skipped, not fatal", function()
    -- The regression this guards: the picker used to read db.storage[id].object and
    -- call :alive() on it, so one id whose client object the engine had already
    -- destroyed raised and killed the whole scan — every later candidate included.
    -- Routing through get_live_online_npc must demote that to a skip.
    local opts = reset_picker()
    local speaker = make_npc(2, "stalker", 5)
    db.OnlineStalkers = { 1, 2 }   -- id 1 was never registered: stale entry
    check("scan continues past the stale id", pick_nearby_stalker(db.actor, opts), speaker)
end)

group("pick_nearby_stalker: non-human factions are excluded", function()
    local opts = reset_picker()
    make_npc(1, "dog", 5)
    make_npc(2, "bloodsucker", 5)
    db.OnlineStalkers = { 1, 2 }
    check("mutants only → nil", pick_nearby_stalker(db.actor, opts), nil)

    local speaker = make_npc(3, "bandit", 5)
    db.OnlineStalkers = { 1, 2, 3 }
    check("the one human is found among mutants", pick_nearby_stalker(db.actor, opts), speaker)
end)

group("pick_nearby_stalker: range gate", function()
    local opts = reset_picker()
    make_npc(1, "stalker", 50)          -- 50 m out, radius is 10 m
    db.OnlineStalkers = { 1 }
    check("out of range → nil", pick_nearby_stalker(db.actor, opts), nil)

    opts.dev = true
    check("dev mode removes the range gate", pick_nearby_stalker(db.actor, opts) ~= nil, true)
end)

group("pick_nearby_stalker: shared cooldown", function()
    local opts = reset_picker()
    local speaker = make_npc(1, "stalker", 5)
    db.OnlineStalkers = { 1 }
    mark_spoke(1, opts.now_sec - 10)    -- spoke 10 s ago, cooldown is 60 s
    check("NPC on cooldown → nil", pick_nearby_stalker(db.actor, opts), nil)

    opts.now_sec = opts.now_sec + 60
    check("NPC off cooldown → returned", pick_nearby_stalker(db.actor, opts), speaker)
end)

group("pick_nearby_stalker: filter_fn", function()
    local opts = reset_picker()
    local wanted = make_npc(1, "stalker", 5)
    make_npc(2, "stalker", 5)
    db.OnlineStalkers = { 1, 2 }
    opts.filter_fn = function(npc) return npc:id() == 1 end
    check("only the filtered NPC is returned", pick_nearby_stalker(db.actor, opts), wanted)

    opts.filter_fn = function() return false end
    check("filter rejecting everyone → nil", pick_nearby_stalker(db.actor, opts), nil)
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
