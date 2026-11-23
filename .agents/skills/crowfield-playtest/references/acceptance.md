# Comparative gameplay, visuals, and sound

Use these comparisons during internal review of the affected scenario. For a broader infantry review, run a standalone Crowfield build on Valley with 24 bots and a recorded seed. Use the same seed, start, and settings for Crowfield before-and-after runs.

## Compare representative situations

1. Use stock **Ravenfield Point Match** on a stock map as the reference for the infantry round. Use stock **Arma Reforger Conflict** as the reference for how an infantry engagement near an objective communicates movement, cover, and combat feedback. Record the build, mode, map, and relevant differences such as map scale, bot count, and whether opponents are people or bots.
2. Pick a comparable situation and keep the lead-in. For the infantry loop, cover deployment, first exchange, an objective push, death and return to the fight, and starting the next round. For a narrower feature, capture the affected sequence with enough context to understand it. Use uninterrupted gameplay with original audio when evaluating sound. Record display and audio settings and use similar listening levels.
3. Use hands-on runs where available. Automate repeatable Crowfield scenarios and collect timings, video, and traces when useful. A stock reference recording can cover an unavailable game. Label the evidence and its limits, including missing scenarios, audio, or input observations. Report any unverified claim as pending evidence.

## Quality rubric

Crowfield should meet or exceed Ravenfield in gameplay, visuals, and sound, with Arma Reforger as a reference.

| Area | What to look for |
| --- | --- |
| Gameplay | An uncoached player can identify a route in roughly 10 seconds and reach a useful fight in roughly 30 seconds. Compare input response during sprint, stop, jump, landing, and aim. Note how bots or teammates help a push, what taking an objective changes, and why a player picks a route after respawn. Record time to first exchange and time from death to the next useful fight. Check for blockers in deployment, combat, capture, respawn, match completion, and replay. Separate missed input from stalls. |
| Visual quality | Compare character and weapon models, environment materials and lighting, movement and handling animations, readability of teams and effects at combat distance, and how much of the fight the HUD covers. |
| Sound quality | Compare gunshots, impacts, footsteps, reloads, and ambience for distinctness, direction, distance, and clarity when several things happen at once. |

Record concrete examples with timestamps or trace references in the related issue or PR. Include strengths, gaps, and actionable findings. Use applicable automated checks for feature delivery and collect qualitative player feedback during normal play.

## Optional paired human study

If a paired study would help and participants are available, give them the [participant kit](participant-kit.md) with the candidate build. Use the same people in Crowfield and Ravenfield, alternate game order, and start without coaching. Record anonymized choices for which game they would replay and the gameplay reasons. Record visual and sound ratings separately with concrete examples. Report sample size, conditions, and missing results.
