"""Builds the game-ready jeep, truck, helicopter and boat from their sources.

Run with Blender from the repository root:

    blender -b --python tools/build-vehicles.py -- assets/vehicles/source assets/vehicles

Each source is one mesh in the artist's own units. The game model is in
metres and keeps the artist's geometry, normals and materials. Its origin is
on the ground under the point the vehicle turns about, and it looks along +Z
like the tank, with its left side on +X. The parts that move are cut out as
meshes of their own, each with its origin on its axis: wheels turn about X,
the main rotor about Y, and the boat's gun about Gun_Pivot. Nothing else
changes.
"""

import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

source_dir, target_dir = sys.argv[sys.argv.index("--") + 1:][:2]

# Positions are in the source's units as Blender imports it: Z up, the front
# of the vehicle along -Y and its left side along +X. A part is every loose
# piece whose middle lies within `reach` of `at`; `pivot` is where its origin
# goes, the middle of the pieces when left out.
VEHICLES = {
    "jeep": {
        "source": "jeep.glb", "root": "Jeep", "scale": 0.9,
        # Midway between the axles, under the wheels.
        "origin": Vector((0.05, -0.395, -0.993)),
        "parts": {
            "Wheel_FL": {"at": Vector((0.85, -1.73, -0.53)), "reach": 0.1},
            "Wheel_FR": {"at": Vector((-0.75, -1.73, -0.53)), "reach": 0.1},
            "Wheel_RL": {"at": Vector((0.86, 0.94, -0.53)), "reach": 0.1},
            "Wheel_RR": {"at": Vector((-0.76, 0.94, -0.53)), "reach": 0.1},
        },
    },
    "truck": {
        "source": "truck.glb", "root": "Truck", "scale": 1.2,
        "origin": Vector((0.0, 0.43, -0.865)),
        "parts": {
            "Wheel_FL": {"at": Vector((0.68, -0.93, -0.40)), "reach": 0.1},
            "Wheel_FR": {"at": Vector((-0.68, -0.93, -0.40)), "reach": 0.1},
            "Wheel_RL": {"at": Vector((0.68, 1.79, -0.40)), "reach": 0.1},
            "Wheel_RR": {"at": Vector((-0.68, 1.79, -0.40)), "reach": 0.1},
        },
    },
    "helicopter": {
        "source": "helicopter.glb", "root": "Helicopter", "scale": 0.4,
        # Under the rotor mast, where the wheels stand.
        "origin": Vector((-0.02, -1.53, -5.76)),
        "parts": {
            # Four blades and the mast they sit on.
            "Rotor_Main": {
                "at": [Vector((-0.02, -12.04, 5.36)), Vector((-0.02, 8.99, 5.36)), Vector((10.49, -1.53, 5.36)),
                    Vector((-10.54, -1.53, 5.36)), Vector((-0.02, -1.53, 4.60))],
                "reach": 0.3, "pivot": Vector((-0.02, -1.53, 5.36)),
            },
        },
    },
    "boat": {
        "source": "boat.glb", "root": "Boat", "scale": 0.27,
        # Under the middle of the hull, at the keel.
        "origin": Vector((-0.22, -2.22, -3.57)),
        "parts": {
            # The machine gun on its post at the stern, with its grip.
            "Gun": {
                "at": [Vector((-0.36, 5.99, 2.23)), Vector((0.02, 4.78, 2.62))],
                "reach": 0.3, "pivot": Vector((-0.36, 5.99, 2.23)), "under": "Gun_Pivot",
            },
        },
    },
}


def pieces_of(mesh):
    """The loose pieces of a mesh as lists of face indices. The importer
    splits vertices at hard edges, so faces count as joined where their
    corners coincide."""
    parent = {}

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    keys = []
    for vertex in mesh.vertices:
        key = (round(vertex.co.x, 4), round(vertex.co.y, 4), round(vertex.co.z, 4))
        parent.setdefault(key, key)
        keys.append(key)
    for polygon in mesh.polygons:
        first = find(keys[polygon.vertices[0]])
        for index in polygon.vertices[1:]:
            parent[find(keys[index])] = first
    found = {}
    for polygon in mesh.polygons:
        found.setdefault(find(keys[polygon.vertices[0]]), []).append(polygon.index)
    return list(found.values())


def middle_of(mesh, faces):
    points = [mesh.vertices[index].co for face in faces for index in mesh.polygons[face].vertices]
    low = Vector((min(p.x for p in points), min(p.y for p in points), min(p.z for p in points)))
    high = Vector((max(p.x for p in points), max(p.y for p in points), max(p.z for p in points)))
    return (low + high) / 2, low, high


def cut(source, faces, name):
    """A copy of the source object with only these faces."""
    part = source.copy()
    part.data = source.data.copy()
    part.name = name
    part.data.name = name
    bpy.context.scene.collection.objects.link(part)
    keep = set(faces)
    mesh = bmesh.new()
    mesh.from_mesh(part.data)
    bmesh.ops.delete(mesh, geom=[face for face in mesh.faces if face.index not in keep], context="FACES")
    mesh.to_mesh(part.data)
    mesh.free()
    return part


def build(name, spec):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath="%s/%s" % (source_dir, spec["source"]))
    meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
    assert len(meshes) == 1, "%s: expected one mesh, found %d" % (name, len(meshes))
    source = meshes[0]
    source.name = "Source"
    # Bake the importer's transform into the mesh, so positions are those of
    # the table above.
    source.data.transform(source.matrix_world)
    for obj in bpy.data.objects:
        obj.parent = None
        obj.matrix_world = Matrix.Identity(4)

    taken = {}
    pivots = {}
    for part_name, part in spec["parts"].items():
        targets = part["at"] if isinstance(part["at"], list) else [part["at"]]
        faces = []
        hits = 0
        for piece in pieces_of(source.data):
            middle, _, _ = middle_of(source.data, piece)
            if any((middle - target).length <= part["reach"] for target in targets):
                faces += piece
                hits += 1
        assert hits >= len(targets), "%s: %s matched %d pieces, expected at least %d" % (name, part_name, hits, len(targets))
        assert not (set(faces) & set(sum(taken.values(), []))), "%s: %s overlaps another part" % (name, part_name)
        taken[part_name] = faces
        pivots[part_name] = part.get("pivot") or middle_of(source.data, faces)[0]
    moving = set(sum(taken.values(), []))
    body_faces = [polygon.index for polygon in source.data.polygons if polygon.index not in moving]

    root = bpy.data.objects.new(spec["root"], None)
    bpy.context.scene.collection.objects.link(root)
    scale = spec["scale"]
    origin = spec["origin"]
    made = {"Body": cut(source, body_faces, "Body")}
    pivots["Body"] = origin
    for part_name, faces in taken.items():
        made[part_name] = cut(source, faces, part_name)
    bpy.data.objects.remove(source)

    for part_name, obj in made.items():
        pivot = pivots[part_name]
        obj.data.transform(Matrix.Translation(-pivot))
        obj.data.transform(Matrix.Scale(scale, 4))
        at = (pivot - origin) * scale
        under = spec["parts"].get(part_name, {}).get("under")
        if under is not None:
            holder = bpy.data.objects.new(under, None)
            bpy.context.scene.collection.objects.link(holder)
            holder.parent = root
            holder.location = at
            obj.parent = holder
            obj.location = Vector((0, 0, 0))
        else:
            obj.parent = root
            obj.location = at
        triangles = sum(len(polygon.vertices) - 2 for polygon in obj.data.polygons)
        _, low, high = middle_of(obj.data, range(len(obj.data.polygons)))
        size = high - low
        # Reported in game axes: X to the left of the model, Y up, Z forward.
        print("%s %-10s at (%6.2f, %5.2f, %6.2f) size (%5.2f, %5.2f, %5.2f) %4d triangles" % (
            name, part_name, at.x, at.z, -at.y, size.x, size.z, size.y, triangles))

    for datablock in list(bpy.data.objects):
        if datablock.type == "EMPTY" and datablock.name not in (spec["root"],) and not datablock.children:
            bpy.data.objects.remove(datablock)
    bpy.ops.export_scene.gltf(filepath="%s/%s.glb" % (target_dir, name), export_format="GLB", export_yup=True, export_apply=True)


for vehicle_name, vehicle_spec in VEHICLES.items():
    build(vehicle_name, vehicle_spec)
