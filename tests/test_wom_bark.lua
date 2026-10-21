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
-- give_game_news is what actually puts a line on the player's PDA, and both delivery
-- functions stamp the shared quiet window immediately after calling it, so the window
-- tests need a real (if inert) method here.
-- Whether the actor is in dialogue. The vanilla task/item/money news funnels route to
-- give_talk_message2 instead of the news feed while talking, so the external-news hooks
-- must not stamp the quiet window then; see the hook tests at the bottom of this file.
local _actor_talking = false

db       = {
    actor = {
        position       = function() return make_vector(0, 0) end,
        give_game_news = function() end,
        id             = function() return 0 end,
        is_talking     = function() return _actor_talking end,
    },
    OnlineStalkers = {},
}
xmath    = nil
xr_sound = nil
printf   = function() end

-- Mirrors the real helper's contract (nil for any id whose object is missing, stale
-- or dead) against this harness's registry. The real implementation's four engine
-- guards are covered in test_wom_utils.lua; what matters here is that the picker
-- routes through it and honours a nil.
wom_utils = {
    get_live_online_npc = function(id) return _live_npcs[id] end,
    play_hello_bark     = function() end,
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
-- allowed_factions
-- ============================================================

-- allowed_factions is faction_matches precomputed, so its whole contract is that the two
-- agree. They diverge exactly where faction_matches answers a question the precompute's
-- iteration cannot reach: a community outside HUMAN_FACTIONS.
group("allowed_factions: agrees with faction_matches", function()
    set_standard_relations()
    local allowed = allowed_factions("stalker", "allies")
    check("own faction in scope", allowed["stalker"], true)
    check("ally in scope",        allowed["dolg"],    true)
    check("neutral out of scope", allowed["ecolog"],  nil)
    check("enemy out of scope",   allowed["bandit"],  nil)

    allowed = allowed_factions("stalker", "neutral")
    check("neutral in scope at neutral", allowed["ecolog"], true)
    check("enemy still out of scope",    allowed["bandit"], nil)
end)

group("allowed_factions: a player community outside HUMAN_FACTIONS", function()
    set_standard_relations()
    -- The regression: monolith is a real talking community and playable in GAMMA
    -- (actor_monolith), but is not in HUMAN_FACTIONS, so iterating that table alone
    -- returned an empty set for a Monolith player. Every sampling pass then matched
    -- nothing and the faction wire never fired an exchange at any scope.
    for _, scope in ipairs({ "faction", "allies", "neutral" }) do
        local allowed = allowed_factions("monolith", scope)
        check("own faction present at " .. scope .. " scope", allowed["monolith"], true)
    end
    check("still not offered to a stalker player", allowed_factions("stalker", "neutral")["monolith"], nil)
end)

group("allowed_factions: nil player community", function()
    set_standard_relations()
    local allowed = allowed_factions(nil, "neutral")
    check("no nil key seeded", allowed[nil], nil)
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
-- is_pda_quiet: the shared PDA quiet window
-- ============================================================

-- Drives time_global() for the window tests. The engine's time_global is milliseconds
-- since level load, so it can only ever be moved forwards by the game — except across a
-- load, which is the backwards case tested below.
local _clock_ms = 0
time_global = function() return _clock_ms end

-- Clears the window and puts the clock at a nonzero point, so a test that expects
-- "nothing sent yet" is not passing merely because the clock reads 0.
local function reset_window()
    reset_quiet_window()
    _clock_ms = 500000
end

-- Sends one message through the real delivery path, so the tests assert the stamp
-- the shipped call sites actually produce rather than poking module state.
local function deliver()
    send_news_pda("Sender", "icon", "message", "test")
end

group("is_pda_quiet: nothing sent yet", function()
    reset_window()
    check("quiet before any message", is_pda_quiet(20), true)
end)

group("is_pda_quiet: a delivered message closes the window", function()
    reset_window()
    deliver()
    check("silent immediately after", is_pda_quiet(20), false)

    _clock_ms = _clock_ms + 19000
    check("still silent one second short", is_pda_quiet(20), false)

    _clock_ms = _clock_ms + 1000
    check("open exactly on the boundary", is_pda_quiet(20), true)
end)

group("is_pda_quiet: send_pda stamps the same window as send_news_pda", function()
    reset_window()
    -- This is the asymmetry the feature rests on: only wom_chatter_pda READS the window,
    -- but every feature WRITES it, so a campfire bark (send_pda) has to close it just as
    -- a news-wire message does. If this ever regresses, the wire stops yielding to the
    -- proximity features and nothing else in the suite would notice.
    --
    -- The proximity path takes an NPC object and plays a bark; wom_utils is stubbed at
    -- the top of this file, so only the give_game_news call actually runs.
    send_pda({
        character_name = function() return "Speaker" end,
        character_icon = function() return "icon" end,
        id             = function() return 1 end,
    }, "message", "test")
    check("proximity delivery closes the window too", is_pda_quiet(20), false)
end)

group("is_pda_quiet: zero disables the rule", function()
    reset_window()
    deliver()
    check("gap of 0 is always quiet", is_pda_quiet(0), true)
    check("nil gap is always quiet", is_pda_quiet(nil), true)
end)

group("is_pda_quiet: a backwards clock is treated as a fresh session", function()
    reset_window()
    deliver()
    check("silent before the jump", is_pda_quiet(20), false)

    -- time_global() restarts near 0 on a load or level change. Left unhandled this
    -- produces a negative elapsed time, which reads as "not quiet" and would mute every
    -- feature until the clock caught back up to the pre-load value.
    _clock_ms = 100
    check("quiet again after the clock rewinds", is_pda_quiet(20), true)
    check("and the stale stamp is gone, not just skipped", is_pda_quiet(999999), true)
end)

group("is_pda_quiet: no delivery without an actor, no stamp either", function()
    reset_window()
    local saved_actor = db.actor
    db.actor = nil
    deliver()
    check("window stays open when nothing reached the PDA", is_pda_quiet(20), true)
    db.actor = saved_actor
end)

-- ============================================================
-- hook_external_news: non-WoM PDA messages close the window too
-- ============================================================

-- The funnel stubs stand in for vanilla news_manager / dynamic_news_helper and xlibs'
-- xpda. Each records the arguments it was handed and returns whatever the test asked
-- for, so the tests can assert both halves of the wrapper's contract: that it stamps on
-- a real delivery, and that it is transparent to the original's callers.
local _funnel_calls = {}
local _send_tip_result, _relocate_result = true, nil

news_manager = {
    send_tip = function(...)
        _funnel_calls[#_funnel_calls + 1] = { name = "send_tip", args = { ... } }
        return _send_tip_result
    end,
    relocate_item = function(...)
        _funnel_calls[#_funnel_calls + 1] = { name = "relocate_item", args = { ... } }
        return _relocate_result
    end,
    -- Returns two values, to prove the wrapper is not collapsing them to one.
    send_sound = function() return true, "extra" end,
}

-- dynamic_news_helper is deliberately left undefined and xpda only half-defined: a funnel
-- module that is absent, or present without one of the named functions, must be skipped
-- rather than erroring. dynamic_news_helper is exactly the case that goes missing when the
-- player has a stripped news setup.
-- Records what WoM's own delivery hands to xpda.publish_news; see the delivery-path tests.
local _published = {}
xpda = {   -- no show_npc_tip
    publish_news = function(caption, msg, icon)
        _published[#_published + 1] = { caption = caption, msg = msg, icon = icon }
        return true
    end,
}

hook_external_news()

group("hook_external_news: a vanilla tip closes the window", function()
    reset_window()
    _send_tip_result = true
    news_manager.send_tip(db.actor, "st_something")
    check("send_tip stamped the window", is_pda_quiet(20), false)
end)

group("hook_external_news: a funnel that bailed does not close the window", function()
    reset_window()
    -- send_tip returns false when its sender is dead or heavily wounded: nothing reached
    -- the PDA, so muting the wire for it would be a phantom interruption.
    _send_tip_result = false
    news_manager.send_tip(db.actor, "st_something")
    check("a false return leaves the window open", is_pda_quiet(20), true)
end)

group("hook_external_news: the not_false funnels stamp on a silent success", function()
    reset_window()
    -- relocate_item returns nothing at all when it displays a message, and false only on
    -- a bail, so "truthy" would never stamp it and the player's loot notifications would
    -- not count as PDA traffic.
    _relocate_result = nil
    news_manager.relocate_item(db.actor, "in", "wpn_ak74", 1)
    check("no return value still counts as delivered", is_pda_quiet(20), false)

    reset_window()
    _relocate_result = false
    news_manager.relocate_item(db.actor, "in", "bad_section", 1)
    check("an explicit false does not", is_pda_quiet(20), true)
end)

group("hook_external_news: dialogue messages are not PDA messages", function()
    reset_window()
    -- While the actor is talking these funnels call give_talk_message2 instead, which puts
    -- the line in the dialogue box and never touches the news feed.
    _relocate_result = nil
    _actor_talking = true
    news_manager.relocate_item(db.actor, "in", "wpn_ak74", 1)
    check("window stays open during dialogue", is_pda_quiet(20), true)
    _actor_talking = false
end)

group("hook_external_news: the wrapper is transparent to the original's callers", function()
    reset_window()
    _funnel_calls = {}
    _send_tip_result = true
    local returned = news_manager.send_tip(db.actor, "st_something", 3, "dolg")
    check("return value passed through", returned, true)
    check("original was called once", #_funnel_calls, 1)
    check("first argument passed through", _funnel_calls[1].args[1], db.actor)
    check("last argument passed through",  _funnel_calls[1].args[4], "dolg")

    local first, second = news_manager.send_sound()
    check("multiple return values survive (1)", first, true)
    check("multiple return values survive (2)", second, "extra")
end)

group("hook_external_news: hooking twice does not nest wrappers", function()
    -- on_game_start runs on every save load. Without the guard each load would wrap the
    -- previous session's wrapper, growing one call layer deeper per load for the rest of
    -- the process.
    local wrapped_before = news_manager.send_tip
    hook_external_news()
    check("send_tip still the same function", news_manager.send_tip == wrapped_before, true)
end)

group("hook_external_news: absent funnels are skipped, not errors", function()
    reset_window()
    -- xpda.publish_news exists and was hooked; xpda.show_npc_tip and the whole of
    -- dynamic_news_helper did not exist when hook_external_news ran.
    -- This is also the regression check for the xlibs 1.9.0 rename (xpda.send ->
    -- publish_news, npc_tip -> show_npc_tip, no aliases): with the old names in the
    -- funnel table publish_news is skipped as "absent", and ALifePlus 1.8.9's reports,
    -- which all go through it, never closed the window.
    check("dynamic_news_helper stayed absent", dynamic_news_helper, nil)
    check("xpda.show_npc_tip stayed absent", xpda.show_npc_tip, nil)
    xpda.publish_news("Sender", "message")
    check("the funnel that did exist is hooked", is_pda_quiet(20), false)
end)

-- ============================================================
-- Delivery path: WoM's own lines go through xpda when it is present
-- ============================================================

group("delivery: prefers xpda.publish_news so ALifePlus sees WoM's lines", function()
    -- ALifePlus 1.8.9 holds its own reports while xpda's last-news clock is fresh. A line
    -- put on the PDA with a raw give_game_news never stamps that clock, so an ALifePlus
    -- report could land straight on top of a WoM bark.
    reset_window()
    _published = {}
    local direct_calls = 0
    local saved_give = db.actor.give_game_news
    db.actor.give_game_news = function() direct_calls = direct_calls + 1 end

    send_news_pda("Sender", "icon", "message", "test")
    check("published through xpda", #_published, 1)
    check("caption passed through", _published[1] and _published[1].caption, "Sender")
    check("icon passed through", _published[1] and _published[1].icon, "icon")
    check("styled text carries the message",
          _published[1] and _published[1].msg:find("message", 1, true) ~= nil, true)
    check("no direct give_game_news as well", direct_calls, 0)
    check("WoM's own window is still stamped", is_pda_quiet(20), false)

    db.actor.give_game_news = saved_give
end)

group("delivery: falls back to give_game_news without xpda", function()
    reset_window()
    local saved_xpda = xpda
    xpda = nil
    local direct_calls = 0
    local saved_give = db.actor.give_game_news
    db.actor.give_game_news = function() direct_calls = direct_calls + 1 end

    send_news_pda("Sender", "icon", "message", "test")
    check("delivered directly", direct_calls, 1)
    check("window stamped on the fallback path too", is_pda_quiet(20), false)

    db.actor.give_game_news = saved_give
    xpda = saved_xpda
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
