# Input and frame timing

Use the packaged app for macOS testing. Test 24 bots in Valley at the reported display mode. Use a recorded seed. For the current fullscreen report and acceptance notes see [issue #91](https://github.com/SSSKrut/crowfield/issues/91). Get approval before a foreground test and use a bounded runner that releases held inputs and closes its own game process.

## Live input

Run normal gameplay for at least 90 seconds through deployment and a contested objective. Test short and held W, releases, mouse look, firing, and Escape. Verify short inputs reach the game and that movement returns to neutral after release. Record stalls around the same events.

Use `tools/playtest-candidate.command [game path] [seed]` for a normal windowed match. For fullscreen, use the app executable and add `--fullscreen` before `--`. Pass an absolute `-dev-capture-dir` after `-- client`. Start from a private run directory. The game writes `gameplay.jsonl` with actions, command and server state, focus, and frame timing. F4 saves recent state and Shift+F4 adds a screenshot.

If posting OS events, verify that the game owns focus before each event. Compare the posted timestamps, macOS delivery when observed, game actions, command application, and motion. Record synthetic OS input as such. Use a physical-input run when evaluating the actual keyboard or a hardware-dependent issue. Capture only the test's events and keep raw traces private. A missing event at an observer does not identify the component that dropped it.

`python3 tools/analyze-playtest.py [run-directory]` summarizes local traces and estimates device-to-game timing when native monitor records are available. It defaults to the latest Mac development playtest. The exported app can write gameplay traces directly.

## Renderer comparison

Use the same map, seed, bot count, viewport, route revision when reported, renderer, and frame limit on both builds. The fixed route exercises rendering during a live bot match with a scripted camera. It does not capture player movement or OS input.

```sh
"$app" --fullscreen -- client -map=valley -bots=24 -seed=5 \
  -max-fps=60 -volume=0 -config-dir= -graphics=performance \
  -benchmark=90s -benchmark-warmup=6s -benchmark-route=valley \
  "-benchmark-path=$run_dir/benchmark.json"
```

For a matched 1280×720 window, replace `--fullscreen` with `--windowed --resolution 1280x720`. Record p95, p99, counts over 33 and 50 ms, and the actual viewport returned by the benchmark. The existing M1 check at 1280×720 rendering targets p95 at or below 22 ms and p99 at or below 33 ms. Verify fullscreen separately at the actual display size. Inspect groups of long frames rather than reporting average FPS alone.
