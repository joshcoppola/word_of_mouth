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