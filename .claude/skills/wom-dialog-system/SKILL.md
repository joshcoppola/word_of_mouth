---
name: wom-dialog-system
description: How Word of Mouth's dialog topics are wired into the vanilla "I want to ask you something." menu - the dialog_manager.init_new_dialog wrap, why the topics carry no preconditions, the removed is_ordinary_stalker precondition and each branch's failure, why the modxml_ filename is kept, and the topic chain layout. Read before touching modxml_wom_dialog.script, dialog phrase ids, preconditions, or SetScriptText callbacks.
---
## How the Dialog System Works

The WoM topics live inside the vanilla **"I want to ask you something."** menu — `dm_universal_dialog` and `dm_universal_dialog2`, both built at runtime by `dialog_manager.init_new_dialog` (a script-built phrase tree, not a static XML phrase list). `modxml_wom_dialog.on_game_start` wraps that function: while the original builds the vanilla tree (root actor phrase `0` → NPC "What do you want to know?" reply `1` → the job/anomalies/information/tips topics), the wrapper temporarily intercepts `dialog_manager.add_dialog` (resolved through the module environment at call time) and calls `add_wom_topics` just before the vanilla "Never mind" phrase (`dm_universal_actor_exit`) is added — the dialog UI lists answers in insertion order, so this places the WoM topic chains above "Never mind". Topics are added under phrase `1` with `wom_utils.add_phrase` (`dialog:AddPhrase(text, id, parent, goodwill)`); if the exit phrase is never seen (renamed/removed by another mod), the topics are appended after the tree instead. Phrase ids are prefixed strings (`wom_news_q` etc.) so they cannot collide with `dialog_manager`'s numeric `get_id()` counter. The wrap chains cleanly with other mods that patch the same function, and the engine resolves `init_func` by name at dialog-construction time, so patching the module field in `on_game_start` is early enough.

**The menu's own existence is the entire gate.** The topics carry **no preconditions**. If an NPC can open "I want to ask you something." they get all four; if they cannot, the phrases are unreachable and nothing happens. Everything that should be excluded already is, for free:
- Special/unique NPCs (traders, faction leaders, mechanics, medics, named quest givers) use their own dialog lists that don't include `character_dialogs.xml`, so they never show the menu at all. Verified: Ashot's profile (`character_desc_jupiter.xml:5`) declares exactly `dm_init_trader` + `actor_break_dialog`; only 3 of 22 named Jupiter profiles pull in `character_dialogs.xml`.
- Companions are excluded by the dialog's `dialogs_axr_companion.is_not_actor_companion` precondition.
- Zombied and Monolith NPCs are excluded by `dialog_manager.uni_dialog_precond` (`dialog_manager.script:1128`).

A per-NPC precondition (`is_ordinary_stalker`) used to sit on top of this and was **removed** — it caused the "~30% of NPCs have no topics in an existing save, all of them do in a new game" report. Do not reintroduce it. Every branch was redundant or wrong:

| Removed branch | Why |
|---|---|
| `character_community() == "monolith"` | Duplicated `dialog_manager.uni_dialog_precond`. |
| `xcreature.is_unscriptable` | Duplicated the profile gate for named/story NPCs. Its `npcx_is_companion` signal actively misfired: Anomaly is known to leave that info portion on NPCs dismissed offline or cross-level, permanently silencing every ex-companion. |
| `xsmart.get_npc_roles` non-empty | **Could never detect what it was added for.** `xcreature.make_trader` (`xcreature.script:416`) only calls `trade_manager.trade_init`, which writes to trade_manager's own id-keyed table (`_unpacked/scripts/trade_manager.script:25`) — leaving community, clsid, section and the logic block's `trade =` field, i.e. all four signals `get_npc_roles` reads, untouched. It caught unrelated NPCs instead, through `_trade_cat_role`'s catch-all `return "trader"` (`xsmart.script:172`) for any bound logic declaring any `trade =`. |
| `ap_api and ap_api.get_records` | Not per-NPC. Hoisted into `on_game_start`: with ALifePlus absent the topics are never added rather than added and hidden. |

The role branch is also where the save-vs-new-game asymmetry came from: `_trade_cat_role` requires `db.storage[id].section_logic`, and `get_npc_roles` deliberately does not cache an empty pre-bind result (`xsmart.script:240`). So an NPC was eligible while its logic was unbound and dropped out the moment it bound smart-terrain logic — fine in a fresh game, patchy in a settled save.

**ALifePlus outpost service NPCs can therefore use these topics.** That is the accepted trade-off (and was already true in practice, since the role check never caught them). If they ever need excluding, test the NPC's squad section against `^ap_service_(%a+)_(%a+)$` — ALifePlus's own `_service_section` naming, and how `wom_outpost` already finds them — not a role heuristic.

**Why the `modxml_` filename is still kept:** GAMMA's `dxml_core.script` scans `$game_scripts$` for files matching `modxml_*.script` and calls each one's `on_xml_read()` at startup. WoM no longer injects any dialog XML, so `on_xml_read` is a no-op stub — but the filename stays so dxml_core's call has a target, and because every `SetScriptText`/`AddPrecondition` string references `modxml_wom_dialog.*` (renaming the file requires updating them all). Historical context: WoM previously injected standalone dialogs via DXML (`wom_utils.inject_dialogs`/`attach_dialogs`, both kept but unused); with that approach a wrongly-named file crashed with `CPhraseDialog::GetById item not found` because attachment ran without registration.

Rules that still apply when building phrases:

1. **Dynamic text**: `phrase:GetPhraseScript():SetScriptText("modxml_wom_dialog.get_news_text")` on the **NPC reply** phrase. The engine calls it at display time. NEVER put SetScriptText on an actor phrase evaluated during dialog-list building — it crashes with a nil first_speaker.

2. **Preconditions**: WoM adds none. If one is ever needed, note it is called as `fn(first_speaker, second_speaker)` where a speaker may be **nil** during list building — resolve the NPC with the nil-safe `npc_speaker`, never `dialogs.who_is_npc` (it indexes first_speaker and errors on nil), and a raise inside a precondition takes down the entire dialog menu.

`ap_api` is checked once in `on_game_start` and gates whether the topics are added at all. This script no longer touches xlibs (`xcreature`/`xsmart`) — those calls left with `is_ordinary_stalker`.

**Topic chains appended under the universal dialog's NPC reply (phrase `1`)**:
```
[0] Actor  dm_universal_actor_start        "I want to ask you something."
  [1] NPC  dm_universal_npc_start_N        (vanilla topics + WoM topics below)
    [wom_news_q]   Actor st_st_wom_ask_news    (no precondition)
      [wom_news_a]   NPC <dynamic>             text: get_news_text
        [wom_news_t]   Actor st_wom_actor_thanks  (leaf)
    [wom_recap_q]  Actor st_wom_ask_recap      (no precondition)
      [wom_recap_a]  NPC <dynamic>             text: get_recap_text
        [wom_recap_t]  Actor st_wom_actor_thanks  (leaf)
    [wom_status_q] Actor st_wom_ask_status     (no precondition)
      [wom_status_a] NPC <dynamic>             text: get_status_text
        [wom_status_t] Actor st_wom_actor_thanks  (leaf)
    [wom_territory_q] Actor st_wom_ask_territory  (no precondition)
      [wom_territory_a] NPC <dynamic>              text: get_territory_text
        [wom_territory_t] Actor st_wom_actor_thanks  (leaf)
```
`get_news_text` calls `wom_recap_smart_terrain.collect_eligible_news()`; nil → `get_nothing_text()`, else `render_report()`.
`get_recap_text` calls `wom_recap_npc.render_recap(npc)`.
`get_status_text` calls `wom_npc_status.render_status(npc)`.
`get_territory_text` calls `wom_territory.render_territory(npc)`.

