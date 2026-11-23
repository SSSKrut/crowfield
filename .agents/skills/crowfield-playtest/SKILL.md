---
name: crowfield-playtest
description: Verify Crowfield gameplay, macOS input and frame pacing, and compare gameplay, visuals, and sound with Ravenfield and Arma Reforger. Use for playtest design, lag reports, and comparative review.
---

Use the relevant issue or PR for the current target and evidence. Use [native and renderer tests](references/diagnostics.md) for input loss, stalls, or benchmarks. Use [comparative review](references/acceptance.md) when a change affects how the game plays, looks, or sounds.

- Test an exact standalone revision. Record the map, seed, bots, resolution, fullscreen state, graphics preset, renderer, settings, and hardware in the linked issue or PR.
- Use actual gameplay with OS input for missed presses, movement after a release, collision, or a frozen menu. Match the user's display and input setup. Run through an active engagement as well as spawn. A camera benchmark measures frame pacing. Tests that inject events inside Godot verify the game code's input path.
- Automate the checks and repeatable captures you can. Record what the evidence covers and what remains unverified. Verify routine features with applicable automated checks before publishing. Collect player feedback in normal play after delivery. Use the [participant kit](references/participant-kit.md) if a paired human study is useful and participants are available.
