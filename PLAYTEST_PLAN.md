# Crowfield playability and the Valley benchmark

Crowfield should earn a second match in the first 90 seconds. A player spawns beside allies, reads the terrain, commits to a crossing, immediately understands the outcome of a fight, and sees the front move when a team wins ground. Valley is where we prove that loop. Ravenfield is the minimum comparison for enjoyment and readability.

## What the reference does well

Ravenfield gives a solo player an immediate role in a larger AI battle. Its published beta rules give captured flags an effect on both deployment and scoring. Its developer has also described authoring different routes and hints for AI to attack and defend them. The relevant lesson for Crowfield is that terrain, bots and objectives should produce situations together. The release comparison uses the current game on a recorded map and mode. The beta notes explain design intent and are a separate historical source. [Ravenfield on Steam](https://store.steampowered.com/app/636480/Ravenfield/) · [Developer's beta guide](https://steelraven7.itch.io/ravenfield) · [Map and AI update notes](https://store.steampowered.com/news/posts/?appids=636480&enddate=1526644132&feed=steam_community_announcements)

Crowfield already has a full round, three river crossings, team colors, and an authoritative solo server. Its flag ownership mostly changes the scoreboard. The routes need reasons to choose between them, a player's first run can feel like empty travel, and independent bot choices rarely communicate a team plan. At the same time the live M1 build recorded 16 FPS and a 194 ms frame while the process waited in the OpenGL driver. The earlier short run of ~60 FPS measured a different portion of the match and missed the failure.

## The match to build

- **Deployment.** Start within sight of a readable route and of allies moving with purpose. Establish each crossing's tradeoff with cover and sightlines. The ford is quick and exposed, the village approach has close cover, and the ridge route trades time for a better view. Keep team access fair from either side.
- **First fight.** A player should be able to point to their next cover and tell allies from enemies before opening fire. At mid-range, shots need direction, damage needs a readable cause, and the first-person animation, camera and sound should convey the same timing. Use crouch, sight and movement tuning only where a playtest exposes a concrete problem.
- **The front moves.** Bots should commit in visible groups and react to which crossing is lost. Test safe forward reinforcement as a payoff for holding ground, with an explicit fallback when the location becomes unsafe. A death should invite a new route choice. A finished round should have a direct solo replay action.
- **Art in motion.** Fix team readability, visual boundaries between cover and decoration, and target contrast at combat distance using actual eye-level captures from both approaches. Prioritize the first-person weapon and silhouettes over isolated prop detail.

## Delivery order

1. Establish a repeatable frame-time comparison in a standalone Mac build. Give Apple Silicon players an immediate way to lower rendering cost. Improve the opening and give each flag a distance and direction cue.
2. Test the three approaches with fresh players. Tune the easiest route first, then make the flank and reserve route distinct. Give one friendly group a clear objective and verify that it can reach and contest it repeatedly.
3. Build the consequences of winning ground and tighten combat feedback around one weapon. Play complete rounds including a loss, a death during a push, and an immediate replay. Expand the second and third weapon only after the first one feels right.
4. Repeat the reference comparison. A release candidate must win the playtest and sustain its performance target on the platforms it will ship on.

## Readiness checks

| Area | How to measure | Initial target |
| --- | --- | --- |
| Frame time | Repeat a fixed 90-second camera or player route with 24 bots at recorded render size and settings. Include deployment, a busy crossing, combat effects and ragdolls. Warm up first and record p95, p99, plus frames over 33 and 50 ms. Repeat at an ordinary window and at the actual display size used in play. | On M1 at 1280×720 rendering, p95 at or below 22 ms and p99 at or below 33 ms. Investigate clusters of slow frames on larger displays instead of relying on average FPS. |
| Opening | Record time to a chosen route, first visible contact and first exchange. Use the same seeds and comparable starts for Crowfield before and after. Record spawn deaths separately. | A new player identifies an approach within 10 seconds and can reach a useful fight in the first 30 seconds without coaching. |
| Readability and feel | Observe a solo round once without explaining the controls. Ask the player how they identified a team and what caused their last death. Capture missed inputs separately from frame-time spikes. | Most players can explain their route, a capture and their last death. Use replay footage to locate failures. |
| Preference | Use five to eight players. Alternate the order of unlabeled Crowfield builds, and compare Ravenfield in its own logged session. Ask which game they would play again and why. | A majority prefer Crowfield overall and can name a reason tied to playing the match. Keep separate notes for navigation, combat feel and presentation. |

Automated tests protect rules and regressions. A scripted benchmark can compare rendering options, and a human comparison establishes whether the game clears the quality floor. Log the build, hardware, renderer, viewport pixels, bot count, seed, scenario, and preset with every result. [Godot GPU optimization guide](https://docs.godotengine.org/en/4.7/tutorials/performance/gpu_optimization.html)

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
