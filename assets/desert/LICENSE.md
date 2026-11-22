# Desert asset sources

The desert map uses sourced models and textures only. Each model below was downloaded unmodified as glTF binary from its [Poly Pizza](https://poly.pizza) page on 22 November 2026. Crowfield does not change the files. Godot's importer writes the textures embedded in some models next to them (`*_Atlas.png`, `storage_tank_CHAHIN_SILO_TEXTURE.jpg`). These belong to the same assets and carry the same licenses. At runtime `DesertMap` scales and places each model and gives it invisible collision boxes, and `DesertScenery` recolours the houses (see "Changes").

## Models under CC BY 3.0

These need attribution in every distributed build. The license is [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/).

| File | Original asset | Author | Source |
| --- | --- | --- | --- |
| `models/pumpjack.glb` | Oil pump | Poly by Google | https://poly.pizza/m/fZykGFywa5D |
| `models/storage_tank.glb` | Silo | Poly by Google | https://poly.pizza/m/3MY8xY_m2Yz |

## Models under CC0 1.0

These are released into the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). The authors are credited although CC0 does not require it.

| File | Original asset | Author | Source |
| --- | --- | --- | --- |
| `models/house_low.glb` | Small Building | Kenney | https://poly.pizza/m/QjL4Fo9dU9 |
| `models/house_two_a.glb` | Small Building | Kenney | https://poly.pizza/m/t9j9Lof5ul |
| `models/house_two_b.glb` | Small Building | Kenney | https://poly.pizza/m/yLvnMqC9ZG |
| `models/house_three.glb` | Small Building | Kenney | https://poly.pizza/m/Rq572hdKEz |
| `models/house_wide.glb` | Large Building | Kenney | https://poly.pizza/m/sxXonOmtct |
| `models/house_tall.glb` | Large Building | Kenney | https://poly.pizza/m/JgGLJH2iXj |
| `models/water_tower.glb` | Water Tower | Quaternius | https://poly.pizza/m/tMK8bhapAK |
| `models/container_red.glb` | Container Red | Quaternius | https://poly.pizza/m/vzzCNUB6Zn |
| `models/container_green.glb` | Container Green | Quaternius | https://poly.pizza/m/h5RUr3vlcS |
| `models/palm_a.glb` | Palm Tree | Quaternius | https://poly.pizza/m/A6cKJYFsIb |
| `models/palm_b.glb` | Palm Tree | Quaternius | https://poly.pizza/m/DsrrAYmucG |
| `models/pipes.glb` | Pipes | Quaternius | https://poly.pizza/m/GB6AFkoiZb |
| `models/barrel.glb` | Barrel | Quaternius | https://poly.pizza/m/MraIiFnpAY |
| `models/rock_a.glb` | Rock | Quaternius | https://poly.pizza/m/HtpdTh3Ld6 |
| `models/rock_b.glb` | Rock Large | Quaternius | https://poly.pizza/m/li0YBlBEMz |
| `models/rock_pillar.glb` | Rock Large | Quaternius | https://poly.pizza/m/d2VWOdthtR |

## Textures

These are unmodified 1K diffuse maps from [Poly Haven](https://polyhaven.com/license), under CC0 1.0. The ground shader tints them and mixes them by wear and slope.

- `aerial_sand-diff.jpg`: [Aerial Sand](https://polyhaven.com/a/aerial_sand) by Rob Tuytel.
- `aerial_ground_rock-diff.jpg`: [Aerial Ground Rock](https://polyhaven.com/a/aerial_ground_rock) by Rob Tuytel.

The desert also reuses `assets/valley/rocky_terrain_02-diff.jpg` and `assets/valley/painted_plaster_wall-diff.jpg` (see `assets/valley/LICENSE.md`). The sky is listed in `assets/sky/LICENSE.md`.

## Changes

- **Scale and placement.** All models are scaled to metres and placed by `game/desert_map.gd`. The pumpjack is scaled by 1.8 × 10⁻⁵ from its original units, and the Kenney houses by 7.
- **Collision.** Every model gets invisible collision boxes in `DesertMap.MODELS`. The model files contain no collision.
- **House colours.** The Kenney houses are recoloured at runtime from grey and pale blue to plaster tones. Their walls also get the Poly Haven plaster grain (`client/desert_scenery.gd`).
