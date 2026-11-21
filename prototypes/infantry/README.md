# Valley infantry rig proof

This scene compares the deployed Crowfield soldier with an imported skinned model in the same Valley lighting and eye-level camera. It renders at 8 m in an idle and an armed run pose, 30 m from behind in motion, and 3.5 m for inspecting the kit. The script saves the matched captures and a two-second running sequence into the ignored export directory.

Run the renderer from the project directory with a local or private display.

```sh
godot --path . --rendering-method gl_compatibility --resolution 960x540 \
  --script prototypes/infantry/preview.gd
```

`soldier.glb` is the original **Soldier** by [vinish.dev](https://vinish.dev/free-3d-models/people/#soldier), used under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The author distributes it at [models.vinish.dev](https://models.vinish.dev/people/soldier.glb). The source binary is pinned by SHA-256 `0bb9641b9cd9b8c545a55e06e7ca46032627a36d0e307e816f0e8e0afda5b1dc`. It has a 17-bone skin, 15,884 triangles, and original Idle, Walk and Run clips. Crowfield adds a chest-relative rifle pose with coupled hand contacts, uniform tinting, gloves, carrier, helmet accessories, leg protection, pack and red/blue patches at runtime.

The proof is a separate SceneTree entry point. Before using it in matches, verify hand deformation and planted feet through speed changes, tune the kit and patches against the agreed style at 30 m, reduce the material and accessory draw calls, and align the new model with the existing hitboxes and ragdoll.

The first review favored the existing body at matched 8 m views. The candidate demonstrates the independent skin and low-ready run, but the original source has rigid open hands. They do not close over the rifle, despite the wrist targets. Both bodies still need a distance test for easy team recognition at 30 m.
