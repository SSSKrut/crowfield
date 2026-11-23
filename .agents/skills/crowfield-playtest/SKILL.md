---
name: crowfield-playtest
description: Verify Crowfield gameplay, macOS input and frame pacing, and similar full-round sessions against Ravenfield and Arma Reforger. Use for playtest design, lag reports, capture review, and release acceptance.
---

Read the GitHub issue for the current target and evidence. Use [native and renderer tests](references/diagnostics.md) for input loss, stalls, or benchmarks. Use [comparative acceptance](references/acceptance.md) for gameplay, visual, and audio review. Give participants the [participant kit](references/participant-kit.md) with the candidate build.

- Test an exact standalone revision. Record the map, seed, bots, resolution, fullscreen state, graphics preset, renderer, settings, and hardware in the linked issue or PR.
- Use actual gameplay with OS input for missed presses, movement after a release, collision, or a frozen menu. Match the user's display and input setup. Run through an active engagement as well as spawn. A camera benchmark measures frame pacing. Tests that inject events inside Godot verify the game code's input path.
- Record the checked scenario and evidence. Keep missing measurements or participant results open. Use footage, automated tests, and independent reviews to improve the build before inviting participants. The comparative release gate needs paired human rounds.
