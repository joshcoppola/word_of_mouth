-- tests/test_wom_campfire.lua
-- Standalone Lua 5.1 tests for wom_campfire.script.
--
-- Run from the repository root:  lua tests/test_wom_campfire.lua
-- Run from tests/:               lua test_wom_campfire.lua
--
-- wom_campfire has no public API beyond on_game_start.  Strategy: mock
-- CreateTimeEvent to capture the _on_timer callback, then invoke it directly
-- to drive _poll_social_chatter and observe side-effects through spies on give_game_news,
-- play_hello_bark, and content-function stubs.
--
-- CAMPFIRE_NPC_COOLDOWN_GAME_SEC = 1800.  The default _game_sec in reset()
-- is 7200 so that fresh NPCs (_last_spoke[id] == nil → last=0, diff=7200)
-- always pass the cooldown gate unless a test explicitly tightens it.

-- ============================================================
-- Mutable test state
-- ============================================================

local _pda_calls      = {}   -- { name, styled } per give_game_news call
local _bark_count     = 0
local _timer_callback = nil
local _game_sec       = 7200
local _server_npcs    = {}   -- npc_id -> { group_id }
local _npc_id_counter = 0

-- Content-function return values (nil = return nothing)
local _area_sentence  = nil
local _day_sentence   = nil
local _day_clock      = nil
local _day_hours      = nil
local _needs_sentence = nil

-- MCM knobs
local _campfire_enabled = true
local _dev_mode         = false
local _campfire_range   = 15

-- math.random override (nil = use real random)
local _forced_roll         = nil
local _math_random_original = math.random
math.random = function(n)
    if _forced_roll then return _forced_roll end
    return _math_random_original(n)
end

-- ============================================================
-- Actor stub factory
-- ============================================================

local _actor_position = {
    -- Called as actor_pos:distance_to_sqr(npc:position()), so self=actor_pos,
    -- first arg is the NPC position table which carries _dist_sqr.
    distance_to_sqr = function(self, other_pos)
        return other_pos._dist_sqr or 0
    end,
}

local function make_actor()
    return {
        id       = function() return 0 end,
        position = function() return _actor_position end,
        give_game_news = function(self, name, styled, icon, delay, duration)
            _pda_calls[#_pda_calls + 1] = { name = name, styled = styled }
        end,
    }
end

-- ============================================================
-- NPC stub factory
-- ============================================================

local function make_npc(opts)
    opts = opts or {}
    _npc_id_counter = _npc_id_counter + 1
    local id = opts.id or _npc_id_counter
    return {
        _id       = id,
        _scheme   = opts.scheme   or "campfire_point",
        _dist_sqr = opts.dist_sqr or 0,
        id                  = function(self) return self._id end,
        alive               = function(self) return opts.alive ~= false end,
        character_community = function(self) return opts.faction or "stalker" end,
        character_name      = function(self) return opts.name end, -- nil is valid (fallback test)
        character_icon      = function(self) return opts.icon or "icon" end,
        position            = function(self) return { _dist_sqr = self._dist_sqr } end,
    }
end

-- Register npc in db.OnlineStalkers + db.storage, and optionally in _server_npcs.
-- group_id: nil → use 1.  false → no server_npc entry at all (tests alife().object nil).
local function add_npc(npc, group_id)
    db.OnlineStalkers[#db.OnlineStalkers + 1] = npc._id
    db.storage[npc._id] = { object = npc }
    if group_id ~= false then
        _server_npcs[npc._id] = { group_id = group_id or 1 }
    end
end

local function add_eligible_npc(opts)
    local npc = make_npc(opts)
    add_npc(npc)
    return npc
end

-- ============================================================
-- STALKER / engine global stubs
-- ============================================================

db = {
    actor          = make_actor(),
    OnlineStalkers = {},
    storage        = {},
}

ap_api = { get_records = function() return {} end }

xtime = { game_sec = function() return _game_sec end }

xr_sound = { set_sound_play = function() end }

printf = nil  -- suppress in-module logging

CreateTimeEvent = function(id, ev, interval, callback)
    _timer_callback = callback
end

ResetTimeEvent = function() end

alife = function()
    return {
        object = function(self, id) return _server_npcs[id] end,
    }
end

-- ============================================================
-- Module stubs
-- ============================================================

wom_mcm = {
    campfire_enabled  = function() return _campfire_enabled end,
    dev_mode          = function() return _dev_mode end,
    campfire_range    = function() return _campfire_range end,
    campfire_interval = function() return 30 end,
}

wom_npc_role = {
    scheme_role = function(npc) return nil, npc._scheme end,
}

wom_recap_smart_terrain = {
    collect_eligible_news = function()
        if _area_sentence then
            return {
                events        = { { sentence = _area_sentence } },
                location_name = "the test area",
            }
        end
        return nil
    end,
}

wom_recap_npc = {
    pick_day_event_line = function(npc)
        return _day_sentence, _day_clock, _day_hours
    end,
}

wom_npc_status = {
    pick_campfire_needs_line = function(npc) return _needs_sentence end,
}

wom_dialogue_helper = {
    render_solo_event = function(event, location_name, npc_faction, npc_squad_id)
        return event and event.sentence or ""
    end,
    -- Returns a stamp when clock or game_hours is provided; "" otherwise.
    make_time_stamp = function(period, started_clock, game_hours, now_gh)
        if started_clock then return "At 3:00 " .. (period or "morning") end
        if game_hours    then return "2 hours ago" end
        return ""
    end,
    decapitalize_clause = function(s)
        if not s or s == "" then return s end
        return s:sub(1, 1):lower() .. s:sub(2)
    end,
}

wom_terminology_helper = {
    get_now_context = function() return 100, 9 end,
    get_event_hour  = function(c, gh, now_gh, now_hod) return 9 end,
    get_period_key  = function(h) return "morning" end,
}

wom_utils = {
    pick_random_item = function(t)
        if not t or #t == 0 then return nil end
        return t[1]
    end,
    play_hello_bark = function(npc) _bark_count = _bark_count + 1 end,
    -- Mirrors the real helper's contract (nil for a missing/dead/stale object)
    -- against this harness's db.storage model.
    get_live_online_npc = function(id)
        local storage_entry = db.storage and db.storage[id]
        local npc = storage_entry and storage_entry.object
        if npc and npc:alive() then return npc end
        return nil
    end,
}

-- ============================================================
-- Load module under test
-- ============================================================

local script_dir  = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."

-- wom_bark is loaded for real rather than stubbed: the campfire scan delegates
-- the human-faction test, the shared per-NPC cooldown, and PDA delivery to it, so
-- stubbing it would erase most of what these tests assert. It is loaded into its
-- own environment table (falling through to _G for db/wom_utils/xr_sound/printf)
-- so its functions land on the wom_bark global the way the game loads a module,
-- instead of leaking into _G alongside wom_campfire's.
local function load_script_as_module(path)
    local env   = setmetatable({}, { __index = _G })
    local chunk
    if setfenv then                      -- Lua 5.1
        chunk = assert(loadfile(path))
        setfenv(chunk, env)
    else                                 -- Lua 5.2+
        chunk = assert(loadfile(path, "t", env))
    end
    chunk()
    return env
end

wom_bark = load_script_as_module(script_dir .. "/../gamedata/scripts/wom_bark.script")

local script_path = script_dir .. "/../gamedata/scripts/wom_campfire.script"
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

local function check_contains(label, got, substring)
    if type(got) == "string" and string.find(got, substring, 1, true) then
        io.write(string.format("    PASS  %s\n", label))
        pass_count = pass_count + 1
    else
        io.write(string.format("    FAIL  %s\n", label))
        io.write(string.format("          substring: %s\n", tostring(substring)))
        io.write(string.format("          got:       %s\n", tostring(got)))
        fail_count = fail_count + 1
    end
end

local function check_not_contains(label, got, substring)
    if type(got) ~= "string" or not string.find(got, substring, 1, true) then
        io.write(string.format("    PASS  %s\n", label))
        pass_count = pass_count + 1
    else
        io.write(string.format("    FAIL  %s\n", label))
        io.write(string.format("          should NOT contain: %s\n", tostring(substring)))
        io.write(string.format("          got:               %s\n", tostring(got)))
        fail_count = fail_count + 1
    end
end

-- Reset all mutable state, then call on_game_start() to re-initialize _last_spoke
-- and register a fresh timer callback.  _game_sec = 7200 so that NPCs with no
-- prior bark history (last = 0, diff = 7200) pass the 1800-sec cooldown gate.
local function reset()
    _pda_calls        = {}
    _bark_count       = 0
    _game_sec         = 7200
    _campfire_enabled = true
    _dev_mode         = false
    _campfire_range   = 15
    _area_sentence    = nil
    _day_sentence     = nil
    _day_clock        = nil
    _day_hours        = nil
    _needs_sentence   = nil
    _forced_roll      = nil
    _server_npcs      = {}
    _npc_id_counter   = 0
    db.OnlineStalkers = {}
    db.storage        = {}
    db.actor          = make_actor()
    ap_api = { get_records = function() return {} end }
    on_game_start()
end

local function scan()
    assert(_timer_callback, "no timer callback — on_game_start not called yet")
    _timer_callback()
end

local function suite(title, fn)
    io.write(string.format("[%s]\n", title))
    fn()
    io.write("\n")
end

-- ============================================================
-- Suite 1: on_game_start guards
-- ============================================================

suite("1. on_game_start guards", function()
    _timer_callback = nil
    ap_api = nil
    on_game_start()
    check("ap_api nil → timer not created", _timer_callback, nil)

    _timer_callback = nil
    ap_api = {}  -- get_records absent
    on_game_start()
    check("ap_api.get_records nil → timer not created", _timer_callback, nil)

    _timer_callback = nil
    ap_api = { get_records = function() return {} end }
    on_game_start()
    check("both present → timer created", _timer_callback ~= nil, true)
end)

-- ============================================================
-- Suite 2: _poll_social_chatter early-exit guards
-- ============================================================

suite("2. _poll_social_chatter early-exit guards", function()
    -- Feature disabled
    reset()
    _campfire_enabled = false
    add_eligible_npc()
    _area_sentence = "Area event."
    scan()
    check("campfire_enabled false → no PDA", #_pda_calls, 0)

    -- ap_api nil set after on_game_start (scan-time check)
    reset()
    add_eligible_npc()
    _area_sentence = "Area event."
    ap_api = nil
    scan()
    check("ap_api nil at scan time → no PDA", #_pda_calls, 0)
    ap_api = { get_records = function() return {} end }

    -- db.actor nil
    reset()
    add_eligible_npc()
    _area_sentence = "Area event."
    db.actor = nil
    scan()
    check("db.actor nil → no PDA", #_pda_calls, 0)

    -- db.OnlineStalkers nil
    reset()
    _area_sentence = "Area event."
    db.OnlineStalkers = nil
    scan()
    check("OnlineStalkers nil → no PDA", #_pda_calls, 0)

    -- db.OnlineStalkers empty (the default after reset — just verify)
    reset()
    _area_sentence = "Area event."
    scan()
    check("OnlineStalkers empty → no PDA", #_pda_calls, 0)
end)

-- ============================================================
-- Suite 3: Candidate filtering
-- ============================================================

suite("3. Candidate filtering", function()
    -- Non-human faction
    reset()
    _area_sentence = "Event."
    add_eligible_npc({ faction = "dog" })
    scan()
    check("non-human faction → not selected", #_pda_calls, 0)

    -- Dead NPC
    reset()
    _area_sentence = "Event."
    add_eligible_npc({ alive = false })
    scan()
    check("dead NPC → not selected", #_pda_calls, 0)

    -- Wrong scheme
    reset()
    _area_sentence = "Event."
    add_eligible_npc({ scheme = "guard" })
    scan()
    check("guard scheme → not selected", #_pda_calls, 0)

    -- campfire_point scheme, in range → selected
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    add_eligible_npc({ scheme = "campfire_point", dist_sqr = 100 })  -- 100 <= 225 (15^2)
    scan()
    check("campfire_point in range → selected", #_pda_calls, 1)

    -- animpoint scheme, in range → selected
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    add_eligible_npc({ scheme = "animpoint", dist_sqr = 100 })
    scan()
    check("animpoint in range → selected", #_pda_calls, 1)

    -- Out of range, dev_mode off
    reset()
    _area_sentence = "Event."
    add_eligible_npc({ dist_sqr = 9999 })  -- 9999 > 225
    scan()
    check("out of range, dev_mode off → not selected", #_pda_calls, 0)

    -- Out of range, dev_mode on → selected anyway
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    _dev_mode = true
    add_eligible_npc({ dist_sqr = 9999 })
    scan()
    check("out of range, dev_mode on → selected", #_pda_calls, 1)

    -- On cooldown (spoke 100 sec ago; cooldown is 1800)
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    local npc = add_eligible_npc()
    scan()                       -- speaks at _game_sec=7200
    _pda_calls = {}
    _game_sec = 7200 + 100       -- 100 sec later, still on cooldown
    scan()
    check("on cooldown → not selected again", #_pda_calls, 0)

    -- Cooldown exactly expired
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    npc = add_eligible_npc()
    scan()                       -- speaks at _game_sec=7200
    _pda_calls = {}
    _game_sec = 7200 + 1800      -- exactly 1800 sec later → eligible again
    scan()
    check("cooldown expired → selected again", #_pda_calls, 1)

    -- db.storage entry nil for an id in OnlineStalkers
    reset()
    _area_sentence = "Event."
    db.OnlineStalkers[1] = 9999
    db.storage[9999] = nil
    scan()
    check("no storage entry → skipped, no crash", #_pda_calls, 0)

    -- db.storage entry has nil object
    reset()
    _area_sentence = "Event."
    db.OnlineStalkers[1] = 9998
    db.storage[9998] = { object = nil }
    scan()
    check("storage.object nil → skipped, no crash", #_pda_calls, 0)
end)

-- ============================================================
-- Suite 4: server_npc / group_id nil-safety
-- ============================================================

suite("4. server_npc / group_id nil-safety", function()
    -- alife():object() returns nil → npc_squad_id is nil → no crash
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    local npc = make_npc()
    add_npc(npc, false)  -- false = no server_npc entry; alife():object(id) returns nil
    scan()
    check("server_npc nil → no crash, PDA sent", #_pda_calls, 1)

    -- group_id == 65535 → treated as nil (unassigned sentinel)
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    npc = add_eligible_npc()
    _server_npcs[npc._id] = { group_id = 65535 }
    scan()
    check("group_id 65535 → no crash, PDA sent", #_pda_calls, 1)

    -- Valid group_id → no crash
    reset()
    _area_sentence = "Event."
    _forced_roll = 1
    npc = add_eligible_npc()
    _server_npcs[npc._id] = { group_id = 42 }
    scan()
    check("valid group_id → no crash, PDA sent", #_pda_calls, 1)
end)

-- ============================================================
-- Suite 5: Fallback chains
-- ============================================================

suite("5a. Fallback chains — roll 1 (area → day → needs)", function()
    -- area succeeds
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Area event."
    scan()
    check("roll 1: area succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 1: area sentence in message", _pda_calls[1].styled, "Area event.")
    end

    -- area nil, day succeeds
    reset(); _forced_roll = 1
    add_eligible_npc()
    _day_sentence = "Day event."
    scan()
    check("roll 1: area nil + day succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 1: day sentence in message", _pda_calls[1].styled, "Day event.")
    end

    -- area nil, day nil, needs succeeds
    reset(); _forced_roll = 1
    add_eligible_npc()
    _needs_sentence = "Needs bark."
    scan()
    check("roll 1: area+day nil + needs succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 1: needs sentence in message", _pda_calls[1].styled, "Needs bark.")
    end

    -- all nil → no PDA
    reset(); _forced_roll = 1
    add_eligible_npc()
    scan()
    check("roll 1: all nil → no PDA", #_pda_calls, 0)
end)

suite("5b. Fallback chains — roll 2 (day → needs → area)", function()
    -- day succeeds
    reset(); _forced_roll = 2
    add_eligible_npc()
    _day_sentence = "Day event."
    scan()
    check("roll 2: day succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 2: day sentence in message", _pda_calls[1].styled, "Day event.")
    end

    -- day nil, needs succeeds
    reset(); _forced_roll = 2
    add_eligible_npc()
    _needs_sentence = "Needs bark."
    scan()
    check("roll 2: day nil + needs succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 2: needs sentence in message", _pda_calls[1].styled, "Needs bark.")
    end

    -- day+needs nil, area succeeds
    reset(); _forced_roll = 2
    add_eligible_npc()
    _area_sentence = "Area event."
    scan()
    check("roll 2: day+needs nil + area succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 2: area sentence in message", _pda_calls[1].styled, "Area event.")
    end

    -- all nil → no PDA
    reset(); _forced_roll = 2
    add_eligible_npc()
    scan()
    check("roll 2: all nil → no PDA", #_pda_calls, 0)
end)

suite("5c. Fallback chains — roll 3 (needs → area → day)", function()
    -- needs succeeds
    reset(); _forced_roll = 3
    add_eligible_npc()
    _needs_sentence = "Needs bark."
    scan()
    check("roll 3: needs succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 3: needs sentence in message", _pda_calls[1].styled, "Needs bark.")
    end

    -- needs nil, area succeeds
    reset(); _forced_roll = 3
    add_eligible_npc()
    _area_sentence = "Area event."
    scan()
    check("roll 3: needs nil + area succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 3: area sentence in message", _pda_calls[1].styled, "Area event.")
    end

    -- needs+area nil, day succeeds
    reset(); _forced_roll = 3
    add_eligible_npc()
    _day_sentence = "Day event."
    scan()
    check("roll 3: needs+area nil + day succeeds → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("roll 3: day sentence in message", _pda_calls[1].styled, "Day event.")
    end

    -- all nil → no PDA
    reset(); _forced_roll = 3
    add_eligible_npc()
    scan()
    check("roll 3: all nil → no PDA", #_pda_calls, 0)
end)

-- ============================================================
-- Suite 6: Timestamp application in message assembly
-- ============================================================
-- _pick_area_event has the started_clock/game_hours return commented out, so
-- area events never carry a timestamp.  Only day events (via pick_day_event_line)
-- can return clock/hours and trigger _apply_stamp.

suite("6. Timestamp application", function()
    -- Day event with no clock/hours → raw sentence, no stamp
    reset(); _forced_roll = 1
    add_eligible_npc()
    _day_sentence = "Day event."
    _day_clock = nil; _day_hours = nil
    scan()
    check("no clock/hours → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("no clock/hours → raw sentence present", _pda_calls[1].styled, "Day event.")
        check_not_contains("no clock/hours → no clock stamp", _pda_calls[1].styled, "At 3:00")
        check_not_contains("no clock/hours → no ago stamp",   _pda_calls[1].styled, "hours ago")
    end

    -- Day event with started_clock → stamp prepended
    reset(); _forced_roll = 1
    add_eligible_npc()
    _day_sentence = "Day event."; _day_clock = "09:00"; _day_hours = nil
    scan()
    check("started_clock → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("started_clock → clock stamp in message", _pda_calls[1].styled, "At 3:00")
    end

    -- Day event with game_hours → stamp prepended
    reset(); _forced_roll = 1
    add_eligible_npc()
    _day_sentence = "Day event."; _day_clock = nil; _day_hours = 42
    scan()
    check("game_hours → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("game_hours → ago stamp in message", _pda_calls[1].styled, "hours ago")
    end

    -- Area event → no stamp (clock return is intentionally commented out in source)
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Area event."
    scan()
    check("area event → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_not_contains("area event → no clock stamp", _pda_calls[1].styled, "At 3:00")
        check_not_contains("area event → no ago stamp",   _pda_calls[1].styled, "hours ago")
    end

    -- Needs event → no stamp (needs path never returns clock/hours)
    reset(); _forced_roll = 3
    add_eligible_npc()
    _needs_sentence = "Needs bark."
    scan()
    check("needs event → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_not_contains("needs event → no clock stamp", _pda_calls[1].styled, "At 3:00")
        check_not_contains("needs event → no ago stamp",   _pda_calls[1].styled, "hours ago")
    end

    -- make_time_stamp returns "" → _apply_stamp falls back to raw sentence
    reset(); _forced_roll = 1
    add_eligible_npc()
    _day_sentence = "Day event."; _day_hours = 42
    local orig_stamp = wom_dialogue_helper.make_time_stamp
    wom_dialogue_helper.make_time_stamp = function() return "" end
    scan()
    check("make_time_stamp empty → PDA still sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("make_time_stamp empty → raw sentence used", _pda_calls[1].styled, "Day event.")
        check_not_contains("make_time_stamp empty → no stamp prefix", _pda_calls[1].styled, "hours ago")
    end
    wom_dialogue_helper.make_time_stamp = orig_stamp
end)

-- ============================================================
-- Suite 7: wom_bark.send_pda nil-safety
-- ============================================================

suite("7. wom_bark.send_pda nil-safety", function()
    -- db.actor nil → give_game_news not called, no crash
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Event."
    db.actor = nil
    scan()
    check("db.actor nil → no PDA, no crash", #_pda_calls, 0)

    -- xr_sound nil → give_game_news still called, no crash
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Event."
    xr_sound = nil
    scan()
    check("xr_sound nil → PDA still sent", #_pda_calls, 1)
    xr_sound = { set_sound_play = function() end }

    -- character_name() returns nil → fallback to "Stalker"
    reset(); _forced_roll = 1
    local npc = make_npc({ name = nil })
    add_npc(npc)
    _area_sentence = "Event."
    scan()
    check("character_name nil → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check("character_name nil → fallback name 'Stalker'", _pda_calls[1].name, "Stalker")
    end

    -- Normal: name comes from NPC
    reset(); _forced_roll = 1
    npc = make_npc({ name = "Sidorovich" })
    add_npc(npc)
    _area_sentence = "Event."
    scan()
    check("normal delivery → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check("normal delivery → name matches NPC", _pda_calls[1].name, "Sidorovich")
    end

    -- Styled string has amber color code, quotes, and default reset
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Event."
    scan()
    if _pda_calls[1] then
        check_contains("styled has amber color code",  _pda_calls[1].styled, "%c[255,220,190,100]")
        check_contains("styled has color reset",        _pda_calls[1].styled, "%c[default]")
        check_contains("styled quotes the message",     _pda_calls[1].styled, '"Event."')
    end

    -- Bark is played when a message is delivered
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "Event."
    scan()
    check("bark played on delivery", _bark_count, 1)

    -- No bark when no message
    reset()
    add_eligible_npc()  -- all content nil → no sentence → no message
    scan()
    check("no bark when no message", _bark_count, 0)
end)

-- ============================================================
-- Suite 8: shared cooldown table (wom_bark)
-- ============================================================
-- The cooldown table now lives in wom_bark and is purely time-based:
-- prune_cooldowns drops entries whose cooldown has already elapsed, so pruning
-- is a table-size concern only and never shortens or extends a live cooldown.
-- Range no longer takes part in it (the old campfire-local table pruned any NPC
-- that had left range, which handed them a free bark on return).

suite("8. shared cooldown table", function()
    -- Two speakers: leaving and re-entering range does not clear a live cooldown,
    -- and a never-spoken NPC is still free to speak on any tick.
    -- Tick 1 (7200): both eligible; one of them speaks.
    -- Tick 2 (7300): the speaker is on cooldown (diff 100 < 1800); the other speaks.
    -- Tick 3 (7400): both are within 1800 of their last bark → silence.
    reset(); _forced_roll = 1
    _area_sentence = "Event."
    local npc_a = add_eligible_npc({ scheme = "campfire_point" })
    local npc_b = add_eligible_npc({ scheme = "campfire_point" })
    scan()                   -- tick 1: first speaker marked at 7200
    _game_sec = 7300
    scan()                   -- tick 2: the other speaker
    _pda_calls = {}
    _game_sec = 7400
    scan()                   -- tick 3: both on cooldown
    check("both speakers on cooldown → silent tick", #_pda_calls, 0)

    -- Leaving range while on cooldown does not reset it: the NPC is still silent
    -- on return because only elapsed game time clears the entry.
    reset(); _forced_roll = 1
    _area_sentence = "Event."
    local npc = add_eligible_npc()
    scan()                   -- speaks at 7200

    npc._dist_sqr = 9999     -- leaves range; no other NPC → no candidate this tick
    _game_sec = 7300
    scan()

    npc._dist_sqr = 0        -- returns to range; diff = 7300-7200 = 100 < 1800
    _pda_calls = {}
    scan()
    check("out-of-range round trip → cooldown preserved", #_pda_calls, 0)

    -- NPC stays in range → cooldown enforced
    reset(); _forced_roll = 1
    _area_sentence = "Event."
    npc = add_eligible_npc()
    scan()              -- speaks at 7200
    _pda_calls = {}
    _game_sec = 7200 + 100
    scan()              -- still in range, diff=100 < 1800 → on cooldown
    check("NPC stays in range → cooldown enforced", #_pda_calls, 0)

    -- Two NPCs: first speaks tick 1; first leaves range, second enters range, second speaks tick 2
    reset(); _forced_roll = 1
    _area_sentence = "Event."
    npc_a = add_eligible_npc({ scheme = "campfire_point" })
    npc_b = add_eligible_npc({ scheme = "campfire_point", dist_sqr = 9999 })  -- B out of range initially
    scan()              -- only A is in range → A speaks at 7200
    _pda_calls = {}

    npc_a._dist_sqr = 9999  -- A leaves range
    npc_b._dist_sqr = 0     -- B enters range
    _game_sec = 7300         -- B: diff=7300>=1800 → eligible
    scan()
    check("second NPC (still in range) speaks after first leaves", #_pda_calls, 1)
end)

-- ============================================================
-- Suite 9: _pick_area_event nil-safety
-- ============================================================

suite("9. _pick_area_event nil-safety", function()
    -- collect_eligible_news returns nil → area path yields nil, no crash
    reset(); _forced_roll = 1
    add_eligible_npc()
    -- _area_sentence=nil → collect_eligible_news returns nil; day+needs also nil
    scan()
    check("collect_eligible_news nil → no PDA", #_pda_calls, 0)

    -- collect_eligible_news returns empty events table
    reset(); _forced_roll = 1
    add_eligible_npc()
    local orig_news = wom_recap_smart_terrain.collect_eligible_news
    wom_recap_smart_terrain.collect_eligible_news = function()
        return { events = {}, location_name = "test" }
    end
    scan()
    check("empty events → no PDA", #_pda_calls, 0)
    wom_recap_smart_terrain.collect_eligible_news = orig_news

    -- render_solo_event returns "" → area path yields nil
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = ""  -- truthy (event returned by collect), but render returns ""
    scan()
    check("render_solo_event empty → no PDA from area path", #_pda_calls, 0)

    -- Valid area sentence → PDA sent
    reset(); _forced_roll = 1
    add_eligible_npc()
    _area_sentence = "A thing happened."
    scan()
    check("valid area sentence → PDA sent", #_pda_calls, 1)
    if _pda_calls[1] then
        check_contains("sentence in message", _pda_calls[1].styled, "A thing happened.")
    end
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
