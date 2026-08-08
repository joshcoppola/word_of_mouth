1.5.0
* Faction wire chatter: squads working on a goal you've marked secret in MCM are no longer picked to answer the wire. Previously a secret goal could go out over the radio as a deflection ("can't say what we're up to"), or be reported honestly when the squad shared your faction — neither made sense for a broadcast anyone can overhear. Another squad answers instead.
* Russian: fixed the "what have you been up to?" closing lines rendering as rows of question marks. The file had been saved in the wrong encoding, which destroyed every Cyrillic character in it. Also added the missing Russian lines for bartering.
* Faction wire chatter: the stalker asking over the PDA can now mention where they're sitting ("Sitting here at the bus stop in Cordon. What's going on?"). Those lines were authored but unreachable.
* Faction wire chatter: fixed the wire never firing at all when playing as a faction the feature didn't recognise, such as Monolith.
* Faction wire chatter: turning the feature off in MCM while a reply is owed now drops that reply instead of holding it. Previously it would arrive on your PDA the moment you turned the feature back on, hours later and with no question attached.
* Fixed a stray dash in place names for locations whose name is written "Region - Place", which read as "on our way to the - Yanov station in Jupiter". Now reads "the Yanov station in Jupiter".
* PDA messages now always name the region a place is in, even when it's on the map you're standing on — "the bus stop in Cordon" rather than just "the bus stop". Applies to faction wire replies and event reactions, where you can't see who's talking and had no way to tell which map they meant. Stalkers you're talking to face to face are unchanged and still say "the bus stop".
* Faction wire chatter: the answering squad now opens with a short acknowledgement ("Reporting in.", "Hey hey.", "Copy that.") before saying who they are and what they're doing, so the reply reads like someone picking up the radio rather than starting mid-sentence.
* Faction wire chatter: new MCM setting, "Required PDA quiet period". The wire now waits until your PDA has been silent for a set number of real seconds before starting a new exchange, so idle radio traffic stays out of the way when something is actually happening. Any PDA message counts — Word of Mouth's own campfire chatter, squad chatter and event reactions, and also messages from the base game and other addons — but only the wire waits; nothing else is delayed. A reply that is already owed still goes out, so a question is never left unanswered. Defaults to 20 seconds; set to 0 for the old behaviour.
* Faction wire chatter: fixed the exchange going silent after the first one. The answering squad was picked one at a time and gated on the proximity-bark cooldown (~3-5 real minutes), so with few eligible squads the same squad was re-picked and rejected every time. Several candidates are now considered, and the wire uses its own much shorter cooldown.
* Faction wire chatter: the question and the reply now share a single timer instead of the reply registering its own, which could disturb other mods' timed events.
* New feature: faction wire chatter. Every so often a stalker holed up on another map asks over the PDA what's going on out there, and a squad out in the field answers with who they are and what they're doing. This is radio traffic you overhear rather than a conversation in front of you — the one asking is never on your map, and names their location with its region ("the bar in Rostok"). Configurable in MCM: on/off, interval (15-180s), reply delay, and whose traffic you hear (faction only / faction and allies / faction, allies and neutral).

1.4.4
* Speculative fix for reports of new dialogue options sometimmes not appearing 

1.4.3
* Add v1.3 of RUS translation by chibidock

1.4.2
* Speculative fix for busy hands issue
* Fix for crash when killing mutants in labs

1.4.1
* Improved Russian translation from chibidock on the GAMMA discord.

1.4.0
* NPCs will now mention bartering with NPCs in their daily recap (requires ALifePlus 1.8.4 or higher).
* Added a new dialogue topic, "Who's holding ground around here?" (requires ALifePlus 1.8.4 or higher). Stalkers name conquests (including mutants) and will also mention if there are any special NPCs. 

1.3.3
* Fix remaining English "a"/"and" leaking into Russian participant lists (the engine falls back to English strings for ids omitted from a locale)

1.3.2
* Fix English articles leaking into Russian
* Improve some English area recaps

1.3.1
* Fixed Russian translation crashing

1.3.0
* Added Russian translation
* Stalkers with military-rank names (Duty, Military, etc.) are no longer addressed by a piece of their rank ("Senior"), instead rank words are skipped so they're addressed by first name or surname instead. English localization only, other languages always use the full name.
* Stalkers in your faction can now message the PDA channel when ALifePlus records a massacre, base attack, territory claim, stash loot, or mutant sighting involving your faction or its allies. Configurable in MCM (on/off, and whether it covers your faction only or your faction and allies).
* Recent events (within the last game hour) are now described as "Just now" or "Less than an hour ago" instead of an exact time stamp
* Campfire chatter and event reaction barks now share a per-NPC cooldown, so the same stalker won't double up on both kinds of barks in a short window

1.2.0
* Stalkers on the move outside of ALifePlus' control will say their destination when asked to recap their day
* Squads already inside the control of smart terrain will not announce new goals if the new goal is located at the same terrain. This prevents cases where ALifePlus assigns NPCs a new goal, but nothing visibly changes. 
* Add lines for combats which weren't able to be assigned a specific location
* Improve combat recap lines for multi-way fights so as to not imply a single squad got all of the kills reported
* Stalkers now mention squadmates in daily recaps
* Alpha mutants are always referred to in the singular
* Mutant infestations in area recaps no longer appear with an exact time stamp 

1.1.2
* Fix a crash that could occur for campfire chatter

1.1.1
* When recapping areas, stalkers will indicate if their own squad participated in any area events
* Fixes for some cases of dialogue with wrong grammar
* Reword some awkwardly-worded dialogue.
* Move more dialogue texts to XML to support translations

1.1
* Local gossip now shows in an amber color, plays a short chirp, and has quotation marks to indicate it's "spoken", which should help distinguish it from messages sent over PDA.
* Some ALifePlus goals can be "secret" (configurable in MCM), so stalkers will not gossip about these or mention them in their daily recaps. There is also an optional toggle to hide these from location recaps.
* Some refactoring behind the scenes to make some of the variables more resilient.
* Expose some dialogue texts to XML to support translations

1.0
Initial release