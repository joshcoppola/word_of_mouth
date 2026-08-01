-- tests/test_wom_dialogue_helper.lua
-- Standalone Lua 5.1 tests for wom_dialogue_helper.script.
--
-- Run from the repository root:  lua tests/test_wom_dialogue_helper.lua
-- Run from tests/:               lua test_wom_dialogue_helper.lua
--
-- Covers: decapitalize_clause, make_pronoun_slots, group_into_paragraphs,
-- pick_dialogue_variant (exercises substitute + clean_output),
-- pick_indexed_dialogue_variant, get_nothing_text, make_time_stamp,
-- and render_event slot passthrough for the new multi-faction slots.

-- ============================================================
-- Mutable mock string table (reset between suites)
-- ============================================================

local mock_strings = {}

-- ============================================================
-- STALKER global stubs
-- ============================================================

-- Returns mock text when registered; returns the key itself (the "not found"
-- sentinel that load_variants checks for) otherwise.
game = {
    translate_string = function(key)
        return mock_strings[key] or key
    end,
}

-- Always returns the first item so tests are deterministic.
wom_utils = {
    pick_random_item = function(t)
        if type(t) ~= "table" or #t == 0 then return nil end
        return t[1]
    end,
    join_list = function(parts)
        if not parts or #parts == 0 then return "" end
        if #parts == 1 then return parts[1] end
        if #parts == 2 then return parts[1] .. " and " .. parts[2] end
        local buf = {}
        for i = 1, #parts - 1 do buf[#buf + 1] = parts[i] .. ", " end
        buf[#buf + 1] = "and " .. parts[#parts]
        return table.concat(buf)
    end,
}

wom_terminology_helper = {
    extract_community_key = function(faction_key, species_key)
        if species_key then
            local s = string.match(species_key, "^st_ap_macros_species_(.+)$")
            if s then return s end
        end
        return faction_key
    end,
    get_faction_members_plural = function(k) return k and (k .. "s") or "" end,
    get_faction_identity       = function(k) return k and (k .. "_id") or "" end,
    get_some_faction    = function(k) return k and ("some " .. k) or "" end,
    get_a_faction_squad = function(k) return k and ("a " .. k .. " squad") or "" end,
    get_a_faction       = function(k) return k and ("a " .. k) or "" end,
    get_count_faction   = function(k, n) return tostring(n or "?") .. " " .. (k or "") end,
    get_party_name      = function(fk, sk) return fk or sk or "" end,
    -- Returns "3:00" for any non-nil clock input; "" when nil.
    format_clock        = function(c) return c and "3:00" or "" end,
    -- Returns a placeholder ago phrase when game_hours is non-nil.
    get_ago_phrase      = function(gh, now) return gh and "2 hours ago" or "" end,
    number_word         = function(n) return n and tostring(n) or "" end,
    get_period_key      = function(h, y) return (y and "yesterday_" or "") .. "morning" end,
    get_event_hour      = function() return 9 end,
    get_now_context     = function() return 100, 9 end,
    get_unknown_member  = function() return "someone" end,
    get_unknown_some    = function() return "some people" end,
    get_unknown_squad   = function() return "a crew" end,
    get_unknown_plural  = function() return "people" end,
    -- Bare (article-less) fallbacks used by #squad_*#/#member_*# slots.
    get_unknown_squad_bare  = function() return "group" end,
    get_unknown_member_bare = function() return "individual" end,
    get_faction_squad_bare        = function(k) return k and (k .. " squad") or "" end,
    get_faction_member_singular   = function(k) return k and (k .. " member") or "" end,
    -- Squad-level self-reference (only reached when npc_squad_id matches the event squad).
    get_squad_self_squad_phrase = function(k) return "our squad" end,
    get_squad_self_a_member     = function() return "one of our guys" end,
    get_stamped_period_key      = function() return "morning" end,
}

-- ============================================================
-- Load the module under test
-- ============================================================

local script_dir  = (arg and arg[0] and arg[0]:match("^(.+)[/\\][^/\\]+$")) or "."
local script_path = script_dir .. "/../gamedata/scripts/wom_dialogue_helper.script"
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

-- Exact substring match (not a Lua pattern; plain literal search).
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

local function suite(title, fn)
    io.write(string.format("[%s]\n", title))
    mock_strings = {}   -- fresh mock table for each suite
    fn()
    io.write("\n")
end

-- ============================================================
-- Suite 1: decapitalize_clause
-- ============================================================

suite("1. decapitalize_clause", function()
    check("regular word",              decapitalize_clause("Hello world"),    "hello world")
    check("already lowercase",         decapitalize_clause("hello world"),    "hello world")
    check("empty string",              decapitalize_clause(""),               "")
    check("single uppercase",          decapitalize_clause("A"),              "a")
    check("single I preserved",        decapitalize_clause("I"),              "I")
    -- "I" followed by space → not lowercase → preserved
    check("I + space preserved",       decapitalize_clause("I went there"),   "I went there")
    -- "I" followed by apostrophe → not lowercase → preserved
    check("I've preserved",            decapitalize_clause("I've been"),      "I've been")
    check("I'm preserved",             decapitalize_clause("I'm going"),      "I'm going")
    -- "I" followed by lowercase letter → decapitalized ("It" → "it", "Isn't" → "isn't")
    check("It-word decapitalized",     decapitalize_clause("It was fine"),    "it was fine")
    check("Isn't decapitalized",       decapitalize_clause("Isn't that"),     "isn't that")
    -- Leading space: decapitalize_clause is not a trimmer; space sub(1,1) lowercases to space
    check("leading space unchanged",   decapitalize_clause(" went out"),      " went out")
end)

-- ============================================================
-- Suite 2: make_pronoun_slots
-- ============================================================

suite("2. make_pronoun_slots", function()
    -- Pronoun wording lives in st_wom_terminology.xml (st_wom_term_pronoun_sg_*/_pl_*);
    -- make_pronoun_slots only translates and capitalises. Mock values mirror the
    -- shipped English strings.
    mock_strings["st_wom_term_pronoun_sg_i_we"]       = "I"
    mock_strings["st_wom_term_pronoun_sg_my_our"]     = "my"
    mock_strings["st_wom_term_pronoun_sg_me_us"]      = "me"
    mock_strings["st_wom_term_pronoun_sg_im_were"]    = "I'm"
    mock_strings["st_wom_term_pronoun_sg_ive_weve"]   = "I've"
    mock_strings["st_wom_term_pronoun_sg_iwas_wewere"] = "I was"
    mock_strings["st_wom_term_pronoun_pl_i_we"]       = "we"
    mock_strings["st_wom_term_pronoun_pl_my_our"]     = "our"
    mock_strings["st_wom_term_pronoun_pl_me_us"]      = "us"
    mock_strings["st_wom_term_pronoun_pl_im_were"]    = "we're"
    mock_strings["st_wom_term_pronoun_pl_ive_weve"]   = "we've"
    mock_strings["st_wom_term_pronoun_pl_iwas_wewere"] = "we were"

    local s = make_pronoun_slots(false)
    check("singular I_We_u",      s.I_We_u,     "I")
    check("singular I_we_l",      s.I_we_l,     "I")
    check("singular my_our_l",    s.my_our_l,   "my")
    check("singular me_us_l",     s.me_us_l,    "me")
    check("singular Im_Were_u",   s.Im_Were_u,  "I'm")
    check("singular Ive_Weve_u",  s.Ive_Weve_u, "I've")
    check("singular Iwas",        s.Iwas,       "I was")

    local p = make_pronoun_slots(true)
    check("plural I_We_u",        p.I_We_u,     "We")
    check("plural I_we_l",        p.I_we_l,     "we")
    check("plural my_our_l",      p.my_our_l,   "our")
    check("plural me_us_l",       p.me_us_l,    "us")
    check("plural Im_Were_u",     p.Im_Were_u,  "We're")
    check("plural Ive_Weve_u",    p.Ive_Weve_u, "We've")
    check("plural Iwas",          p.Iwas,       "we were")
end)

-- ============================================================
-- Suite 3: group_into_paragraphs
-- ============================================================

suite("3. group_into_paragraphs", function()
    local function period(e) return e.p or "morning" end
    local function emit(e)   return "ev" .. e.id    end

    -- Empty input
    local r = group_into_paragraphs({}, period, emit)
    check("empty input → 0 paragraphs", #r, 0)

    -- Single event
    r = group_into_paragraphs({{ id=1 }}, period, emit, " ")
    check("single event → 1 paragraph", #r, 1)
    check("single event text",          r[1], "ev1")

    -- Two events, same period → joined in one paragraph
    r = group_into_paragraphs({{ id=1 }, { id=2 }}, period, emit, " ")
    check("same period → 1 paragraph",  #r, 1)
    check("same period space-joined",   r[1], "ev1 ev2")

    -- Two events, different periods → two separate paragraphs
    r = group_into_paragraphs(
        {{ id=1, p="morning" }, { id=2, p="evening" }},
        period, emit, " ")
    check("different periods → 2 paragraphs", #r, 2)
    check("first paragraph",              r[1], "ev1")
    check("second paragraph",             r[2], "ev2")

    -- Three events: 2 morning + 1 evening → two paragraphs, first has two events
    r = group_into_paragraphs(
        {{ id=1, p="morning" }, { id=2, p="morning" }, { id=3, p="evening" }},
        period, emit, " ")
    check("3 events 2+1 → 2 paragraphs",   #r, 2)
    check("first paragraph two events",    r[1], "ev1 ev2")
    check("second paragraph one event",    r[2], "ev3")

    -- nil return from emit → sentence skipped
    r = group_into_paragraphs(
        {{ id=1 }, { id=2 }}, period,
        function(e) if e.id == 1 then return nil end; return "kept" end, " ")
    check("nil emit → skipped, 1 paragraph", #r, 1)
    check("nil emit → kept text",            r[1], "kept")

    -- "" return from emit → sentence skipped
    r = group_into_paragraphs(
        {{ id=1 }, { id=2 }}, period,
        function(e) return e.id == 1 and "" or "kept" end, " ")
    check("empty emit → skipped", r[1], "kept")

    -- is_block_lead: true for first event of each new period, false for continuations
    local lead_flags = {}
    group_into_paragraphs(
        {{ id=1, p="morning" }, { id=2, p="morning" }, { id=3, p="evening" }},
        period,
        function(e, is_lead) lead_flags[e.id] = is_lead; return "x" end)
    check("event 1 is block lead",          lead_flags[1], true)
    check("event 2 same period not lead",   lead_flags[2], false)
    check("event 3 new period is lead",     lead_flags[3], true)

    -- Custom join_char
    r = group_into_paragraphs({{ id=1 }, { id=2 }}, period, emit, "|")
    check("custom join_char", r[1], "ev1|ev2")
end)

-- ============================================================
-- Suite 4: pick_dialogue_variant (exercises substitute + clean_output)
-- ============================================================

suite("4. pick_dialogue_variant", function()
    -- Unknown prefix → ""
    check("unknown prefix → empty",
        pick_dialogue_variant("st_wom_not_real_xyzzy_test", {}), "")

    -- Single variant, no slots → returned as-is (first letter capitalised)
    mock_strings["st_dv_001"] = "hello there"
    check("single variant",
        pick_dialogue_variant("st_dv", {}), "Hello there")

    -- Slot substitution
    mock_strings["st_sub_001"] = "#faction# moved to #place#"
    check("slot substitution",
        pick_dialogue_variant("st_sub", { faction = "Duty", place = "the base" }),
        "Duty moved to the base")

    -- Unknown slot → resolves to "", double space collapsed, result re-capitalised
    mock_strings["st_ms_001"] = "saw #missing# go by"
    check("missing slot → gap cleaned",
        pick_dialogue_variant("st_ms", {}), "Saw go by")

    -- Multiple variants: mock always returns first
    mock_strings["st_mv_001"] = "First"
    mock_strings["st_mv_002"] = "Second"
    check("multiple variants → first picked",
        pick_dialogue_variant("st_mv", {}), "First")

    -- Gated token: template uses token, value empty → variant excluded → ""
    mock_strings["st_gt_001"] = "At #clock# this morning"
    check("gated token empty → excluded",
        pick_dialogue_variant("st_gt", { clock = "" }, { "clock" }), "")

    -- Gated token: template uses token, value filled → variant kept
    mock_strings["st_gt2_001"] = "At #clock# this morning"
    check("gated token filled → kept",
        pick_dialogue_variant("st_gt2", { clock = "3:00" }, { "clock" }),
        "At 3:00 this morning")

    -- Gated token: template does NOT reference the token → always kept
    mock_strings["st_ngt_001"] = "Simple text"
    check("gated token absent from template → always kept",
        pick_dialogue_variant("st_ngt", { clock = "" }, { "clock" }),
        "Simple text")

    -- All gated variants excluded → ""
    mock_strings["st_allgt_001"] = "At #clock# now"
    mock_strings["st_allgt_002"] = "About #Ago#"
    check("all gated variants excluded → empty",
        pick_dialogue_variant("st_allgt", {}, { "clock", "Ago" }), "")

    -- clean_output: double spaces collapsed (empty slot leaves gap)
    mock_strings["st_ws_001"] = "saw  two  spaces"
    check("double spaces collapsed",
        pick_dialogue_variant("st_ws", {}), "Saw two spaces")

    -- clean_output: leading/trailing whitespace trimmed
    mock_strings["st_trim_001"] = "  trimmed  "
    check("leading/trailing whitespace trimmed",
        pick_dialogue_variant("st_trim", {}), "Trimmed")

    -- clean_output: space before punctuation removed
    mock_strings["st_sp_001"] = "word , then . end"
    check("space before punctuation removed",
        pick_dialogue_variant("st_sp", {}), "Word, then. end")

    -- clean_output: em-dash before period (empty slot leaves dangling dash)
    mock_strings["st_em_001"] = "fired #other# —."
    check("em-dash before period cleaned",
        pick_dialogue_variant("st_em", { other = "" }), "Fired.")

    -- clean_output: dangling em-dash at end of string
    mock_strings["st_em2_001"] = "moved out #other# —"
    check("dangling em-dash at end cleaned",
        pick_dialogue_variant("st_em2", { other = "" }), "Moved out")
end)

-- ============================================================
-- Suite 5: pick_indexed_dialogue_variant
-- ============================================================

suite("5. pick_indexed_dialogue_variant", function()
    -- No _001a authored → ""
    check("no authored variants → empty",
        pick_indexed_dialogue_variant("st_idx_none_xyzzy", 1, {}), "")

    -- Single occurrence pool (_001a only)
    mock_strings["st_idx_001a"] = "First time"
    check("occurrence 1 → _001a",
        pick_indexed_dialogue_variant("st_idx", 1, {}), "First time")

    -- Occurrence beyond max → clamped to last authored
    check("occurrence 5 clamped to 1",
        pick_indexed_dialogue_variant("st_idx", 5, {}), "First time")

    -- Two occurrence levels: _001a and _002a
    mock_strings["st_idx2_001a"] = "First"
    mock_strings["st_idx2_002a"] = "Second"
    check("occurrence 1 → First",
        pick_indexed_dialogue_variant("st_idx2", 1, {}), "First")
    check("occurrence 2 → Second",
        pick_indexed_dialogue_variant("st_idx2", 2, {}), "Second")
    check("occurrence 3 → clamped to Second",
        pick_indexed_dialogue_variant("st_idx2", 3, {}), "Second")

    -- Lettered sub-variants: mock always returns first (a)
    mock_strings["st_lt_001a"] = "Variant a"
    mock_strings["st_lt_001b"] = "Variant b"
    mock_strings["st_lt_001c"] = "Variant c"
    check("lettered sub-variants → first (a) picked",
        pick_indexed_dialogue_variant("st_lt", 1, {}), "Variant a")

    -- Slot substitution inside indexed variant
    mock_strings["st_si_001a"] = "#who# did #what#"
    check("slot substitution",
        pick_indexed_dialogue_variant("st_si", 1, { who = "Loners", what = "it" }),
        "Loners did it")

    -- Gated token empty → variant excluded → ""
    mock_strings["st_gi_001a"] = "At #clock# it happened"
    check("gated token empty → excluded",
        pick_indexed_dialogue_variant("st_gi", 1, { clock = "" }, { "clock" }), "")

    -- Gated token filled → variant kept
    mock_strings["st_gi2_001a"] = "At #clock# it happened"
    check("gated token filled → kept",
        pick_indexed_dialogue_variant("st_gi2", 1, { clock = "3:00" }, { "clock" }),
        "At 3:00 it happened")

    -- Gated token not in template → always kept even when value empty
    mock_strings["st_gni_001a"] = "Plain text"
    check("gated token absent from template → always kept",
        pick_indexed_dialogue_variant("st_gni", 1, { clock = "" }, { "clock" }),
        "Plain text")
end)

-- ============================================================
-- Suite 6: get_nothing_text
-- ============================================================

suite("6. get_nothing_text", function()
    -- No XML entries → "". The hardcoded English fallback was removed when the
    -- string moved to st_wom_no_news_001 in st_wom_recap_smart_terrain.xml; the
    -- pool ships with the mod, so an empty pool only happens if XML is missing.
    check("no entries → empty",
        get_nothing_text(), "")

    -- XML entry present → returned
    mock_strings["st_wom_no_news_001"] = "All quiet out there."
    check("with entry → returns it",
        get_nothing_text(), "All quiet out there.")
end)

-- ============================================================
-- Suite 7: make_time_stamp
-- ============================================================

suite("7. make_time_stamp", function()
    -- No tod pool, no stamp → "Earlier" hardcoded fallback
    check("no tod pool → Earlier fallback",
        make_time_stamp("morning", nil, nil, 100), "Earlier")

    -- Tod pool, no stamp variants → tod phrase returned
    mock_strings["st_wom_ask_recap_tod_morning_001"] = "This morning"
    check("tod phrase only, no stamp → tod phrase",
        make_time_stamp("morning", nil, nil, 100), "This morning")

    -- Stamp variant with no gated tokens → used; trailing comma stripped by make_time_stamp
    mock_strings["st_wom_event_stamp_001"] = "#Period#,"
    check("stamp trailing comma stripped",
        make_time_stamp("morning", nil, nil, 100), "This morning")

    -- Stamp gated on clock, no clock → filtered out → falls back to tod phrase
    mock_strings["st_wom_event_stamp_001"] = "At #clock# #period#"
    check("stamp gated on clock, no clock → tod fallback",
        make_time_stamp("morning", nil, nil, 100), "This morning")

    -- Stamp gated on clock, clock present → used
    -- format_clock mock returns "3:00" for any non-nil input
    mock_strings["st_wom_event_stamp_001"] = "At #clock# #period#"
    check("stamp gated on clock, clock present → used",
        make_time_stamp("morning", "09:00", nil, 100), "At 3:00 this morning")

    -- Stamp with no gated tokens → always used regardless of clock availability
    mock_strings["st_wom_event_stamp_001"] = "#Period# things happened"
    check("stamp with no gated tokens → always used",
        make_time_stamp("morning", nil, nil, 100), "This morning things happened")
end)

-- ============================================================
-- Suite 8: render_event — multi-faction slot passthrough
-- ============================================================

suite("8. render_event — multi-faction slot passthrough", function()
    -- #participant_list# is passed from event record into the slot table and substituted
    mock_strings["st_wom_event_combat_multi_001"] = "#participant_list# all fought here."
    check("participant_list slot populated",
        render_event(
            { category = "combat_multi", participant_list = "two Duty units, a Clear Sky unit" },
            "the checkpoint", nil),
        "Two Duty units, a Clear Sky unit all fought here.")

    -- #enemy_list# slot passthrough
    mock_strings["st_wom_event_combat_multi_001"] = "#enemy_list# were the enemies."
    check("enemy_list slot populated",
        render_event(
            { category = "combat_multi", enemy_list = "a Clear Sky unit and a Psy-Dog pack" },
            "the checkpoint", nil),
        "A Clear Sky unit and a Psy-Dog pack were the enemies.")

    -- #top_faction_identity# slot passthrough
    mock_strings["st_wom_event_combat_multi_001"] = "#top_faction_identity# won."
    check("top_faction_identity slot populated",
        render_event(
            { category = "combat_multi", top_faction_identity = "Duty" },
            "the checkpoint", nil),
        "Duty won.")

    -- Empty top_faction_identity: the token is in GATED_EVENT_TOKENS, so the only
    -- variant referencing it is filtered out and the pool renders nothing rather
    -- than emitting a subject-less "Won."
    mock_strings["st_wom_event_combat_multi_001"] = "#top_faction_identity# won."
    check("empty top_faction_identity → gated variant filtered out",
        render_event(
            { category = "combat_multi", top_faction_identity = "" },
            "the checkpoint", nil),
        "")

    -- #subject_identity# and #other_identity# slots: derived from community key via get_faction_identity mock
    mock_strings["st_wom_event_combat_multi_001"] = "#subject_identity# vs #other_identity#."
    check("subject_identity and other_identity slots populated",
        render_event(
            { category = "combat_multi",
              subject_faction_key = "dolg", other_faction_key = "stalker" },
            "the checkpoint", nil),
        "Dolg_id vs stalker_id.")

    -- Consequence-specific pool takes priority over category pool
    mock_strings["st_wom_event_combat_multi_001"]  = "Category pool"
    mock_strings["st_wom_event_specific_evt_001"]   = "Consequence pool"
    check("consequence-specific pool wins over category",
        render_event(
            { category = "combat_multi", consequence_key = "consequence:specific_evt" },
            "the checkpoint", nil),
        "Consequence pool")

    -- Falls back to category pool when consequence pool is absent
    mock_strings["st_wom_event_combat_multi_001"] = "Category fallback"
    check("falls back to category pool when consequence pool absent",
        render_event(
            { category = "combat_multi", consequence_key = "consequence:no_pool_xyzzy" },
            "the checkpoint", nil),
        "Category fallback")

    -- npc_faction flows through render_event → build_event_slots → get_some_faction;
    -- the mock always returns "some <key>" so this confirms the plumbing, not the
    -- first-person-vs-third-person logic (which lives in wom_terminology_helper).
    mock_strings["st_wom_event_combat_001"] = "#some_members_subject# attacked."
    check("npc_faction flows through to some_members_subject slot",
        render_event(
            { category = "combat", subject_faction_key = "dolg" },
            "the checkpoint", "dolg"),
        "Some dolg attacked.")
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("Results: %d passed, %d failed\n", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
