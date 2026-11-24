# Vehicle sources

## Sourced models under CC BY 3.0

These need attribution in every distributed build. The license is [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/). Each source was downloaded unmodified as glTF binary from its [Poly Pizza](https://poly.pizza) page on 24 November 2026 and is kept under `source/`.

| File | Source file | Original asset | Author | Source |
| --- | --- | --- | --- | --- |
| `jeep.glb` | `source/jeep.glb` | Jeep | Zsky | https://poly.pizza/m/AcSdGGrgYP |
| `truck.glb` | `source/truck.glb` | Truck | Zsky | https://poly.pizza/m/EWp0hGvZPV |
| `helicopter.glb` | `source/helicopter.glb` | Helicopter | Zsky | https://poly.pizza/m/hG2Qr0A3zR |
| `boat.glb` | `source/boat.glb` | Military Boat | Zsky | https://poly.pizza/m/wouBxOe3CD |

The SHA-256 of the sources:

- `source/jeep.glb`: `edb8d57bb7ec61358a34d53d2e484fa9fcdfb8f9b90ddecd576ed272b48a1e50`
- `source/truck.glb`: `6404000da8683e9f0bc3adeffe92151d223e0b78ad6b823e52aa9da9a702f616`
- `source/helicopter.glb`: `08894cd4be8a628420657ad5c7fbceaa75a658450c33a757018c06a99c6fb4ae`
- `source/boat.glb`: `9ecd83a706781ae61f2760c612604cb01a644ba97be41e2ff7598737209165b1`

### Changes

`tools/build-vehicles.py` builds the four game models from the sources in Blender. Each source is one mesh in the artist's own units. The script scales it to metres, moves its origin to the ground under the point the vehicle turns about, and cuts the parts that move out as meshes of their own. The geometry, normals and materials are the artist's. Like the tank, a model looks along +Z, so its left side is on +X.

| Model | Scale | Size (width × height × length) | Origin | Parts |
| --- | --- | --- | --- | --- |
| `jeep.glb` | 0.9 | 1.84 × 2.10 × 4.10 m | Midway between the axles | `Body`; `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR` at (±0.72, 0.42, ±1.20), 0.83 m across |
| `truck.glb` | 1.2 | 2.32 × 2.67 × 5.32 m | Midway between the axles | `Body`; `Wheel_FL`, `Wheel_FR`, `Wheel_RL`, `Wheel_RR` at (±0.82, 0.56, ±1.63), 1.11 m across |
| `helicopter.glb` | 0.4 | 2.92 × 4.57 × 15.30 m, rotor 16.5 m across | Under the rotor mast, where the wheels stand | `Body`; `Rotor_Main` at (0, 4.45, 0) |
| `boat.glb` | 0.27 | 2.70 × 1.70 × 7.14 m | Under the middle of the hull, at the keel | `Body`; `Gun` under `Gun_Pivot` at (−0.04, 1.57, −2.22) |

A wheel has its origin on its axle and turns about X. The rotor turns about Y. The boat's gun stands on a post at the stern and turns about `Gun_Pivot`. The jeep's steering wheel is on the right, as the artist made it.

No game code drives these four yet. `tests/test_vehicles.gd` checks that each model stands on the ground and has its parts.

## Generated models

| File | Asset | Made with | Source | License |
| --- | --- | --- | --- | --- |
| `source/tank_CF-27.glb` | CF-27 tank | The Kimi 3.1 AI model, exported from Blender | Generated for Crowfield and added by the project owner on 22 November 2026 | No third-party source or license |

The tank is not sourced, artist-authored art. It is an exception to the rule in `AGENTS.md`, made at the project owner's request. Replace it if an artist-authored tank is adopted.

`tank_cf27.glb` is built from the source by `tools/build-tank.py` in Blender. The script joins the 62 meshes into three: the hull, the turret on `Turret_Pivot` and the gun on `Gun_Pivot`. It scales the three 2K textures (base colour, normal, occlusion-roughness-metal) down to 1K. It changes nothing else. The importer writes the textures next to the model. Their names keep "2K" from the source.

The tank's collision is two boxes, the hull and the turret, in `game/vehicle.gd`. Its engine sound is synthesized in `client/vehicle_views.gd`.
