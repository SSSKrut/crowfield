# Infantry model

**Military tactical suit (LowPolyGameReady)** by DanlyVostok, licensed under
[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).
[Original model](https://sketchfab.com/3d-models/military-tactical-suit-lowpolygameready-ef698ce36b1545a78ce592dd3db4c7ed)
and [author profile](https://sketchfab.com/1799danly).

Crowfield scales and recenters the model, hides the floating headset, tints
the helmet cover, sleeve and vest markings, and retargets the original skeleton to its
gameplay animations and held weapons. The imported copy packs the original material textures into a shared atlas.
The skinned outfit uses one mesh with remapped UVs and the original geometry
and bone weights.

The GLB under `source/` is the unchanged [glTF-Transform repack](https://github.com/cktang88/3d-fps/blob/a5b4da6c87f54278755fc31b372934a1b3e56b00/public/assets/models/characters/soldier_tac.glb)
with the original attribution and license metadata. Its SHA-256 is
`fe02bc307077d7a5a74069d085893988d93751495871c84082256e60bf9bfc9e`.

Regenerate the imported copy from the repository root with Python 3 and
Pillow 12.3.0. Run `python3 -B assets/infantry/source/build_render_mesh.py`.
