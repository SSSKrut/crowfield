"""Builds the game-ready CF-27 tank from its source model.

Run with Blender:

    blender -b --python tools/build-tank.py -- assets/vehicles/source/tank_CF-27.glb assets/vehicles/tank_cf27.glb

The source has 62 meshes on two pivots: the turret turns on Turret_Pivot and
the gun rises on Gun_Pivot. The game model keeps those pivots and joins the
meshes into three, the hull, the turret and the gun, each with its materials
as surfaces. Its 2K textures are scaled down to 1K. Nothing else changes.
"""

import sys

import bpy
from mathutils import Matrix

source, target = sys.argv[sys.argv.index("--") + 1:][:2]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=source)

objects = bpy.data.objects
root = objects["CF27_ROOT"]
pivots = {"turret": objects["Turret_Pivot"], "gun": objects["Gun_Pivot"]}
names = {"hull": "Hull", "turret": "Turret", "gun": "Gun"}


def group_of(obj):
    at = obj.parent
    while at is not None:
        if at == pivots["gun"]:
            return "gun"
        if at == pivots["turret"]:
            return "turret"
        at = at.parent
    return "hull"


groups = {"hull": [], "turret": [], "gun": []}
for obj in list(objects):
    if obj.type == "MESH":
        groups[group_of(obj)].append(obj)

for group, members in groups.items():
    bpy.ops.object.select_all(action="DESELECT")
    for member in members:
        member.select_set(True)
    joined = members[0]
    bpy.context.view_layer.objects.active = joined
    bpy.ops.object.join()
    # Bake the mesh into world space, then into the space of its pivot, so
    # the part turns about the pivot with an identity transform of its own.
    pivot = pivots.get(group, root)
    joined.data.transform(joined.matrix_world)
    joined.parent = None
    joined.data.transform(pivot.matrix_world.inverted())
    joined.parent = pivot
    joined.matrix_parent_inverse = Matrix.Identity(4)
    joined.matrix_basis = Matrix.Identity(4)
    joined.name = names[group]
    joined.data.name = names[group]
    triangles = sum(len(polygon.vertices) - 2 for polygon in joined.data.polygons)
    print("%s: %d members, %d triangles, %d materials" % (names[group], len(members), triangles, len(joined.data.materials)))

for image in bpy.data.images:
    if image.size[0] > 1024:
        image.scale(1024, 1024)
        image.pack()
        print("image %s scaled to 1024" % image.name)

bpy.ops.export_scene.gltf(filepath=target, export_format="GLB", export_yup=True, export_apply=True)
