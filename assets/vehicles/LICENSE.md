# Vehicle sources

| File | Asset | Made with | Source | License |
| --- | --- | --- | --- | --- |
| `source/tank_CF-27.glb` | CF-27 tank | The Kimi 3.1 AI model, exported from Blender | Generated for Crowfield and added by the project owner on 22 November 2026 | No third-party source or license |

The tank is not sourced, artist-authored art. It is an exception to the rule in `AGENTS.md`, made at the project owner's request. Replace it if an artist-authored tank is adopted.

`tank_cf27.glb` is built from the source by `tools/build-tank.py` in Blender. The script joins the 62 meshes into three: the hull, the turret on `Turret_Pivot` and the gun on `Gun_Pivot`. It scales the three 2K textures (base colour, normal, occlusion-roughness-metal) down to 1K. It changes nothing else. The importer writes the textures next to the model. Their names keep "2K" from the source.

The tank's collision is two boxes, the hull and the turret, in `game/vehicle.gd`. Its engine sound is synthesized in `client/vehicle_views.gd`.
