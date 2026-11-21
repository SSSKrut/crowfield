# Authored gait on Crowfield's current soldier

This experiment applies the pelvis and leg rotations from Quaternius to the current body. The game’s standing and weapon poses still drive the upper body. The candidate adds distance-driven phase and a bounded boot lock during stance. The fixture runs a matched start, walk, sprint and stop path. It uses terrain height at each boot for contact measurements. It does not move a physics-controlled soldier or test a ragdoll handoff.

The [Universal Animation Library](https://quaternius.com/packs/universalanimationlibrary.html) is by Quaternius under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Use the unchanged, in-place Unreal/Godot edition from the author's Standard download. The asset-only [archive mirror](https://github.com/WaviestSun/atelier-packs) also publishes the original binary. Its SHA-256 is `69591853d817488edaa8fd9bf8fc1d821eaeaf789f8627b3cd23b41c4ed67997`.

Place the binary at `export/motion-source/UAL1_Standard.glb`. Run the Godot renderer at 864 × 504. Drop `--slope` for the rolling road route. Add `--metrics` and run headlessly to skip image capture.

```sh
godot --path . --rendering-method gl_compatibility --resolution 864x504 \
  --script prototypes/infantry-gait/compare.gd -- --slope
```

The fixture writes frame-by-frame planar speed, gait and both sole positions with ground clearance to `export/motion-source/`. There are 174 frames per run at 30 fps. Frames with consecutive same-foot clearances of at most 3.5 cm contribute to the contact-adjacent drift measure. This measure includes sink-through and late toe-off. It describes this fixture, not all ground contacts in the game.

| Route and gait | Current median boot drift | Authored + lock median boot drift |
| --- | ---: | ---: |
| Road walk | 1.62 m/s | 0.84 m/s |
| Road sprint | 3.05 m/s | 4.32 m/s |
| Slope walk | 1.69 m/s | 0.95 m/s |
| Slope sprint | 3.18 m/s | 4.87 m/s |

On the hill route the lowest boot position during sprint improved from 25.6 to 4.0 cm below the terrain. That correction came with worse sprint drift and occasional floating steps. The foot windows and simple transfer require more work to fit the game's sprint. Use the existing gait as the control for a targeted slope-contact fix before revisiting a full authored locomotion replacement.
