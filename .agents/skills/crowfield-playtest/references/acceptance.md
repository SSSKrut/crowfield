# Comparative gameplay, visuals, and sound

Use [acceptance issue #12](https://github.com/SSSKrut/crowfield/issues/12) for the decision and evidence. In uncoached solo play, check whether the player identifies a route within 10 seconds and reaches a useful fight within 30 seconds. Record first contact, capture, death, and replay. Separate missed input from stalls. Use the same seeds and starting conditions for before-and-after Crowfield runs.

Use the [participant guide and response sheet](participant-kit.md) to run the same procedure with each player.

Before accepting the solo infantry loop or calling it release-ready, run this test on the standalone Crowfield candidate. For a change to movement, combat, bots, map flow, capture rules, or the way a fight looks or sounds, include a hands-on before-and-after run of the affected scenario in its PR. Use the full comparison to decide whether the complete loop meets the quality bar.

1. Use Valley with 24 bots and a recorded seed. Compare it with an unmodded **Point Match** on a stock map in the current stable Ravenfield build. Choose a comparable infantry start and use the same players in both games. Alternate which game they play first, keep hardware and input settings comparable, and start each session without coaching. Use stock **Arma Reforger Conflict** as the reference for one infantry engagement near an objective. Record differences in map scale, player count, and whether the opponents are bots or people.
2. Play a full round each in Crowfield and Ravenfield. Note route choice, first visible enemy, and first exchange. Follow one attack through contention, capture and defense or loss. Observe one death and return to a useful fight, then reach the result and start another match. In Arma, follow a comparable approach, exchange and objective push. Use an uninterrupted segment or play it hands-on and record which.
3. In the paired hands-on rounds, compare input response through sprint, stop, jump, landing and aim. In all three games, assess what the player can see and hear during movement, aiming, shooting, taking damage and reloading. Note how bots or teammates help a push, what the player gains from control of a flag, and why they choose a particular route after respawning. Log time to the first exchange and time from death to the next useful exchange. Keep counts and qualitative observations tied to the actual scenario.
4. Ask five to eight players who played both Crowfield and Ravenfield, individually, which game they would choose for one more round and why. Pass when a strict majority of all participants choose **Crowfield** and cite a gameplay reason, and there is no reproducible issue blocking deployment, combat, capture, respawn, match completion, or replay. Ties and missing assessments leave the gate open. Arma provides a comparison for movement, feedback, and use of cover. Ravenfield sets the replay preference threshold.
5. Attach the versions, mode, map, settings, run timings, anonymized votes and reasons, timestamped recordings or traces, and the pass or fail decision to the acceptance issue or release PR. Screenshots, edited highlights, scripted traces and automated tests can document specific findings. The paired human rounds and votes are required for a pass.

### Visual and sound quality

Use the same participants and stock references. Compare first-person scenes during deployment, movement through cover, a firefight, and capture or respawn. Use comparable display conditions and the same audio output at similar listening levels. For recorded evidence, use uninterrupted gameplay with game audio and record the display and audio settings.

| Area | What players compare |
| --- | --- |
| Visual quality | Character and weapon models, environment materials and lighting, animation quality during movement and weapon handling, readability of team silhouettes and effects at combat distance, and how much of the fight the HUD covers. |
| Sound quality | How convincing and distinct gunshots, impacts, footsteps, reloads and ambience sound. Whether direction and distance are apparent, and whether important sounds stay clear when several things happen at once. |

Ask each player to rate Crowfield separately for visuals and sound as **below**, **on par with**, or **above** Ravenfield. Record one concrete example for each rating. Each category passes when a strict majority rates it **on par with** or **above** Ravenfield. Both categories must pass alongside the gameplay test. Compare with Arma Reforger for grounded animation, environmental detail, and spatial audio. Record the visual and sound votes and examples alongside the replay votes in the acceptance issue or release PR.
