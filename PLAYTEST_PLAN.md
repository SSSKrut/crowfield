# Crowfield playability and the Valley benchmark

Crowfield should earn a second match in the first 90 seconds. A player spawns beside allies, reads the terrain, commits to a crossing, immediately understands the outcome of a fight, and sees the front move when a team wins ground. Valley is where we prove that loop. Ravenfield is the minimum comparison for enjoyment and readability.

## What the reference does well

Ravenfield gives a solo player an immediate role in a larger AI battle. Its published beta rules give captured flags an effect on both deployment and scoring. Its developer has also described authoring different routes and hints for AI to attack and defend them. The relevant lesson for Crowfield is that terrain, bots and objectives should produce situations together. The release comparison uses the current game on a recorded map and mode. The beta notes explain design intent and are a separate historical source. [Ravenfield on Steam](https://store.steampowered.com/app/636480/Ravenfield/) · [Developer's beta guide](https://steelraven7.itch.io/ravenfield) · [Map and AI update notes](https://store.steampowered.com/news/posts/?appids=636480&enddate=1526644132&feed=steam_community_announcements)

Crowfield has three river crossings, team colors, and an authoritative solo server. Held, uncontested objectives can provide safe forward reinforcement after death. The routes still need to earn their place in a human playtest. An earlier live M1 build recorded 16 FPS and a 194 ms frame while the process waited in the OpenGL driver. A short run near 60 FPS measured a different portion of the match and missed the failure.

## Preliminary gameplay comparison

| Game | What drives the match | What to compare in play |
| --- | --- | --- |
| Ravenfield | The player joins a team of AI soldiers. In the developer's historical Point Match rules, holding flags gives the team more spawn options and amplifies the value of kills. Use the current stock match to verify the rules and pace players actually experience. | How soon a new player sees where to join the fight, how allies shape the engagement, and what taking a flag changes about the next life. |
| Arma Reforger | Conflict is built around players working together to capture and hold strategic positions. Transport, logistics, and coordination can affect where a fight develops. | How stance changes, sights, sound, and movement through cover communicate what is happening in one infantry engagement. |
| Crowfield | Valley puts combat around three crossings. In five seeded 24-bot simulations on `28aca80`, the first flag was contested at 7.32–7.48 s and the first flag was taken at 12.92–13.08 s. The ford showed objective activity first in all five runs. | Whether a human player can join that fight, whether the bridge routes offer worthwhile choices, and whether taking ground changes where the player and bots fight next. |

The 2026 Ravenfield footage shows a player deploying alongside bots, moving with them toward smoke and cover, and later dying. That run uses **Battle** on New Island Preview, with mutator settings unverified. The Arma Reforger footage shows the player moving with a squad, aiming from cover, then regrouping to cross open terrain. This is stock **Conflict**, as identified by Bohemia. Both observations come from sampled video frames. Use them to pick scenarios, and use paired rounds to assess pace, combat feel and preference. [Ravenfield, 1:40–2:10](https://www.youtube.com/watch?v=ifK0pVyFkIk&t=100s) · [Arma Reforger, 3:10–4:30](https://www.youtube.com/watch?v=Ts1zpG2a4LQ&t=190s) · [Bohemia's mode identification](https://reforger.armaplatform.com/news/comrad-29)

Crowfield timings come from `tools/benchmark-valley-opening.gd` and use simulation time. [Ravenfield developer's beta rules](https://steelraven7.itch.io/ravenfield) · [Arma Reforger Conflict](https://reforger.armaplatform.com/game)

## The match to build

- **Deployment.** Start within sight of a readable route and of allies moving with purpose. Establish each crossing's tradeoff with cover and sightlines. The ford is quick and exposed, the village approach has close cover, and the ridge route trades time for a better view. Keep team access fair from either side.
- **First fight.** A player should be able to point to their next cover and tell allies from enemies before opening fire. At mid-range, shots need direction, damage needs a readable cause, and the first-person animation, camera and sound should convey the same timing. Use crouch, sight and movement tuning only where a playtest exposes a concrete problem.
- **The front moves.** Bots should commit in visible groups and react to which crossing is lost. Test safe forward reinforcement as a payoff for holding ground, with an explicit fallback when the location becomes unsafe. A death should invite a new route choice. A finished round should have a direct solo replay action.
- **Art in motion.** Fix team readability, visual boundaries between cover and decoration, and target contrast at combat distance using actual eye-level captures from both approaches. Prioritize the first-person weapon and silhouettes over isolated prop detail.

## Delivery order

1. Establish a repeatable frame-time comparison in a standalone Mac build. Give Apple Silicon players an immediate way to lower rendering cost. Improve the opening and give each flag a distance and direction cue.
2. Test the three approaches with fresh players. Tune the easiest route first, then make the flank and reserve route distinct. Give one friendly group a clear objective and verify that it can reach and contest it repeatedly.
3. Build the consequences of winning ground and tighten combat feedback around one weapon. Play complete rounds including a loss, a death during a push, and an immediate replay. Expand the second and third weapon only after the first one feels right.
4. Run the comparative gameplay acceptance test on the release candidate and verify the performance target on its shipping platforms.

## Readiness checks

| Area | How to measure | Initial target |
| --- | --- | --- |
| Frame time | Repeat a fixed 90-second camera or player route with 24 bots at recorded render size and settings. Include deployment, a busy crossing, combat effects and ragdolls. Warm up first and record p95, p99, plus frames over 33 and 50 ms. Repeat at an ordinary window and at the actual display size used in play. | On M1 at 1280×720 rendering, p95 at or below 22 ms and p99 at or below 33 ms. Investigate clusters of slow frames on larger displays instead of relying on average FPS. |
| Opening | Record time to a chosen route, first visible contact and first exchange. Use the same seeds and comparable starts for Crowfield before and after. Record spawn deaths separately. | A new player identifies an approach within 10 seconds and can reach a useful fight in the first 30 seconds without coaching. |
| Readability and feel | Observe a solo round once without explaining the controls. Ask the player how they identified a team and what caused their last death. Capture missed inputs separately from frame-time spikes. | Most players can explain their route, a capture and their last death. Use replay footage to locate failures. |
| Comparative gameplay | Run the hands-on scenarios and record the paired results below. | Meet the replay preference threshold and resolve any reproducible issue that prevents a player from completing the core loop. |

Automated tests protect rules and regressions. A scripted benchmark can compare rendering options, and a human comparison establishes whether the game clears the quality floor. Log the build, hardware, renderer, viewport pixels, bot count, seed, scenario, and preset with every result. [Godot GPU optimization guide](https://docs.godotengine.org/en/4.7/tutorials/performance/gpu_optimization.html)

## Comparative gameplay acceptance

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

## Run the renderer comparison

From Terminal on macOS, run the exported app at the same resolution and with both presets, one run at a time. The camera moves from the gate to the ford while the local server runs a seeded 24-bot round. Each run writes frame-time percentiles and the viewport configuration. The camera route measures renderer performance. Use a human round to evaluate input feel and player decisions.

```sh
app="$HOME/Applications/Crowfield.app/Contents/MacOS/Crowfield"
for preset in quality performance; do
  "$app" --windowed --resolution 3840x2160 -- client \
    -map=valley -bots=24 -seed=5 -max-fps=60 -volume=0 -config-dir= \
    "-graphics=$preset" -benchmark=90s -benchmark-warmup=6s \
    -benchmark-route=valley "-benchmark-path=/tmp/crowfield-$preset-4k.json"
done
```

For a 1280×720 comparison, change the window resolution and output filenames. Compare the report's actual viewport sizes and frame-time percentiles. The Performance preset caps the estimated 3D render area near 1600×900, with full-resolution HUD, no MSAA, and shorter directional shadows. [Godot resolution scaling](https://docs.godotengine.org/en/4.7/tutorials/3d/resolution_scaling.html)
