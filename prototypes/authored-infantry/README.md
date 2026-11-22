# Authored infantry evaluation

Valley capture fixture for [issue #82](https://github.com/SSSKrut/crowfield/issues/82). It uses the real Valley map, terrain contacts, character animation clips, lighting and held carbine. The existing character rig drives the imported body in this fixture. The model retains its own proportions, garment weights, equipment and finger joints.

## Capture on the Linux development host

Use the project's pinned Godot executable as `godot` in the following commands. Run from the repository root with a graphical renderer available for the captures.

```sh
godot --headless --path . --import
godot --path . --resolution 1030x720 --script prototypes/authored-infantry/capture.gd -- export/authored-infantry/candidate motion
godot --path . --resolution 1030x720 --script prototypes/authored-infantry/capture.gd -- export/authored-infantry/baseline baseline motion
godot --path . --resolution 1030x720 --script prototypes/authored-infantry/capture.gd -- export/authored-infantry/distance distance
godot --path . --resolution 1030x720 --script prototypes/authored-infantry/capture.gd -- export/authored-infantry/distance-baseline distance baseline
```

The fixture saves standing aim, crouched aim from two directions, sprint and both team colors from matched cameras. The distance pass captures both colors from behind at 30 m. The optional motion pass writes 168 raw RGB8 frames at 30 Hz. Apply the branch containing the revised combat crouch before comparing its posture with the older deep squat. Run both captures on the same revision and renderer.

## Source and attribution

**Military tactical suit (LowPolyGameReady)** by DanlyVostok, licensed under Creative Commons Attribution 4.0 International. The author permits commercial use with attribution. [Original model](https://sketchfab.com/3d-models/military-tactical-suit-lowpolygameready-ef698ce36b1545a78ce592dd3db4c7ed) · [Author profile](https://sketchfab.com/1799danly) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)

The unchanged GLB is a byte-for-byte copy of a glTF-Transform repack that retains the original author, model and license metadata. SHA-256 `fe02bc307077d7a5a74069d085893988d93751495871c84082256e60bf9bfc9e`. Use this attribution and identify Crowfield's changes in release credits if the asset is selected. [Pinned source copy](https://github.com/cktang88/3d-fps/blob/a5b4da6c87f54278755fc31b372934a1b3e56b00/public/assets/models/characters/soldier_tac.glb)

Crowfield scales and recenters the imported scene, hides the floating headset, and tints the existing sleeve and vest patches through their original UVs. The copy contains an 88-bone skinned rig and no animation clips. The artist's listing reports 31,771 faces with all equipment. The preview uses Godot's Basis Universal texture embedding.

## Integration checks

Review the hand silhouettes from both sides during the stance changes and compare red and blue at 30 m. The pose adapter currently targets the carbine and puts the support hand farther back along its handguard. The next runtime stage needs contact calibration per weapon, the final crouch on sloped terrain, and visual checks for aim pitch and recoil. Retarget after the gameplay pose modifiers and copy the finalized pose through the existing fall and freeze lifecycle. Profile full matches before selecting mesh consolidation, bone reduction, or distant LODs. The source has 14 visible mesh instances per character after hiding the headset.
