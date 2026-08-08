---
name: wom-dialogue-templates
description: Word of Mouth's spoken-dialogue template system - the #slot# placeholder vocabulary, pronoun and location-preposition tokens, empty-slot filtering, the st_wom_event_stamp_* time-of-day tokens and their gated_tokens filtering, sequential connectors, and the table of ALifePlus consequences that still lack authored recap lines. Read before authoring or editing any st_wom_*.xml dialogue pool.
---
## Template System

Spoken-dialogue templates live in the `configs/text/eng/` XML files:
`st_wom_recap_smart_terrain.xml`, `st_wom_recap_day.xml`, `st_wom_shared.xml`,
`st_wom_status.xml`, `st_wom_campfire.xml`, `st_wom_chatter.xml`, `st_wom_chatter_pda.xml`, `st_wom_reaction.xml`,
`st_wom_current_action.xml`, `st_wom_territory.xml`.

```xml
<string id="st_wom_event_massacre_inv_001"><text>#other_some# slaughtered a whole crew there. #subject_some# were sent to check it out.</text></string>
```

The `#slot#` placeholders match keys in the slot table built by `wom_dialogue_helper`. Common slots:
`#subject#`, `#subject_some#`, `#subject_squad#`, `#subject_a#`, `#subject_count#`,
`#other#`, `#other_some#`, `#other_squad#`, `#other_a#`, `#other_count#`, `#a_other#`,
`#location#`, `#kills#`, `#losses#`.
Recap templates additionally use pronoun tokens (`#I_We_u#`, `#I_we_l#`, `#my_our_l#`, `#me_us_l#`, `#Im_Were_u#`, `#Ive_Weve_u#`, `#Iwas#`, `#I_we_blank_l#`) and location-preposition tokens (`#at_location#`, `#to_location#`, `#near_location#`, `#in_location#`, `#from_location#`, `#by_location#`, `#around_location#`, `#toward_location#`).

Templates that reference a `#placeholder#` whose slot is empty are **filtered out** before random selection. This prevents sentences like "null wiped them." Always provide at least one template per consequence that uses only widely-available slots (e.g. `#location#`, `#subject_some#`) so there's always a fallback.

### Event-stamp tokens (`st_wom_event_stamp_*`)

Both recaps section events by time-of-day. Each section is introduced by a randomly-picked `st_wom_event_stamp_*` variant. The available tokens in those variants are:

| Token | Example value | Source |
|---|---|---|
| `#Period#` | "This morning" | random `st_wom_ask_recap_tod_<period>` pick |
| `#period#` | "this morning" | same, lowercased |
| `#clock#`  | "3:45"         | `format_clock(started_clock)` — 12h, 15-min rounded |
| `#Ago#`    | "About 6 hours ago" | `get_ago_phrase(game_hours, now_game_hours)` |

Stamp variants that reference `#clock#` or `#Ago#` when those values are empty are **filtered out** by `pick_dialogue_variant`'s `gated_tokens` mechanism — this is the implicit "noclock fallback" (no separate `_noclock` pool needed). When all authored stamps are filtered, `make_time_stamp` falls back to the plain period phrase (e.g. "This morning").

Subsequent events within a section are introduced by a `st_wom_ask_recap_seq_mid_*` connector ("After that", "Then", etc.) — unless the previous and current events started within 5 in-game minutes of each other (`wom_dialogue_helper.is_same_time`, comparing `started_clock` values; typically two ALifePlus consequences dispatched off the same cause), in which case a `st_wom_ask_recap_seq_same_time_*` connector ("At the same time", "Meanwhile", etc.) is used instead. AP records document a `cause_id` sibling-consequence correlator, but no live dispatcher populates it, so time proximity is the only usable signal.

## Consequence Types with Templates

Consequence-specific templates are keyed `st_wom_event_<consequence_suffix>_NNN` (area recap) and `st_wom_ask_recap_<consequence_suffix>_NNNa/b/c...` (NPC daily recap). The authoritative list of authored suffixes is the set of `st_wom_event_*` and `st_wom_ask_recap_*` keys in `configs/text/eng/`. The full ALifePlus consequence universe is in `../ALifePlus/gamedata/scripts/ap_core_const.script` under `CONSEQUENCE = { ... }`.

An unauthored consequence is **not** a crash — it falls through to the `st_wom_ask_recap_generic` pool. The cost is a bland line, so the gap is worth closing as ALifePlus adds causes. Outstanding as of ALifePlus 1.8.6, for consequences human squads actually reach:

| Consequence | Gap |
|---|---|
| ~~`barter`, `barter_offmap`~~ | **Done** — 7 + 6 lines in `st_wom_recap_day.xml` (eng + rus). See the notes above each pool: needs-family records carry no second party, so no other-party slot may be used, and the off-map pool deliberately keeps location in an `#at_location#` tail rather than a `#to_location#` motion frame so the "nearby" substitution stays grammatical. |
| `supply_trader_offmap`, `job_explore_offmap`, `social_offmap` | Only the on-map variants are authored. Follow the `barter_offmap` pool's framing for the off-map ones. |
| `harvest_haunt` | Area-recap line exists; no daily-recap line. |
| `alpha_promote`, `alphakill_targeted` | Area-recap lines exist; no daily-recap lines. |

The mutant-instinct consequences (`feed`, `slumber_*`, `pack`, `scatter`) and `area_swarm` / `area_infest` belong to mutant squads, which never speak, so they need daily-recap lines only if a human squad can ever be their subject.

Separately, `wom_reaction.REACTION_CAUSES` omits `cause:area_swarm` and `cause:area_infest`. In 1.8.4 both are full territory takeovers (a pack seizing a smart; an alpha turning a den into a nest) and are as high-signal as `cause:area_conquer`, which is already in the list.
