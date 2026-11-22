#!/usr/bin/env python3
"""Regenerate ../danly-soldier.glb from the unmodified attributed source."""

import json
from pathlib import Path
import struct


# Both the first-person preview and the tests refer to parts by node name.
# Keep the marked cap, vest, and jacket separate, along with the rigid eyes.
MERGES = {
    "Object_97": ("Object_99",),  # Face and hood.
    "Object_101": ("Object_117",),  # Elbow and knee pads.
    "Object_103": ("Object_119", "Object_121"),  # Pouches.
    "Object_123": ("Object_113", "Object_115"),  # Boots, trousers and gloves.
}
COMPONENT_BYTES = {5123: 2, 5126: 4}
COMPONENTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def merge_glb(data: bytes) -> bytes:
    if struct.unpack_from("<4sII", data) != (b"glTF", 2, len(data)):
        raise ValueError("Expected glTF 2 binary")
    json_size, json_tag = struct.unpack_from("<I4s", data, 12)
    binary_size, binary_tag = struct.unpack_from("<I4s", data, 20 + json_size)
    if json_tag != b"JSON" or binary_tag != b"BIN\x00" or len(data) != 28 + json_size + binary_size:
        raise ValueError("Expected one JSON chunk and one binary chunk")
    model = json.loads(data[20:20 + json_size])
    source = memoryview(data)[28 + json_size:]
    if len(model["buffers"]) != 1 or model.get("animations"):
        raise ValueError("Expected a single-buffer rig with no animation channels")

    old_views, old_accessors, old_meshes = (model[key] for key in ("bufferViews", "accessors", "meshes"))
    model.update(bufferViews=[], accessors=[], meshes=[])
    binary = bytearray()

    def append_view(payload: bytes, target: int | None = None) -> int:
        binary.extend(bytes(-len(binary) % 4))
        view = {"buffer": 0, "byteOffset": len(binary), "byteLength": len(payload)}
        if target is not None:
            view["target"] = target
        binary.extend(payload)
        model["bufferViews"].append(view)
        return len(model["bufferViews"]) - 1

    def view_data(index: int) -> bytes:
        view = old_views[index]
        offset = view.get("byteOffset", 0)
        return source[offset:offset + view["byteLength"]].tobytes()

    def accessor_data(index: int) -> bytes:
        acc = old_accessors[index]
        if "sparse" in acc:
            raise ValueError("Sparse mesh attributes are outside the source format")
        view = old_views[acc["bufferView"]]
        offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        width = COMPONENT_BYTES[acc["componentType"]] * COMPONENTS[acc["type"]]
        count = acc["count"]
        stride = view.get("byteStride", width)
        if stride == width:
            return source[offset:offset + count * width].tobytes()
        return b"".join(source[offset + row * stride:offset + row * stride + width] for row in range(count))

    def append_accessor(indices: list[int], payload: bytes, target: int | None) -> int:
        originals = [old_accessors[index] for index in indices]
        accessor = {key: value for key, value in originals[0].items() if key not in {"byteOffset", "bufferView"}}
        format_keys = ("componentType", "type", "normalized")
        if any(any(other.get(key) != accessor.get(key) for key in format_keys) for other in originals):
            raise ValueError("Merged accessors have different component formats")
        accessor["count"] = sum(other["count"] for other in originals)
        for key, reduce in (("min", min), ("max", max)):
            if key in accessor:
                accessor[key] = [reduce(values) for values in zip(*(other[key] for other in originals))]
        accessor["bufferView"] = append_view(payload, target)
        model["accessors"].append(accessor)
        return len(model["accessors"]) - 1

    nodes = model["nodes"]
    by_name = {node.get("name"): i for i, node in enumerate(nodes) if "mesh" in node}
    parents = {child: i for i, node in enumerate(nodes) for child in node.get("children", [])}
    removed = set()
    for name, joins in MERGES.items():
        first = by_name[name]
        for other_name in joins:
            other = by_name[other_name]
            if ("skin" not in nodes[first] or nodes[first]["skin"] != nodes[other].get("skin")
                    or parents[first] != parents[other]
                    or any(nodes[first].get(key) != nodes[other].get(key)
                           for key in ("matrix", "rotation", "scale", "translation"))
                    or nodes[other].get("children")):
                raise ValueError(f"{other_name} cannot share the same skinned mesh as {name}")
            removed.add(other)

    for i, node in enumerate(nodes):
        if "children" in node:
            node["children"] = [child for child in node["children"] if child not in removed]
        if "mesh" not in node or i in removed:
            continue
        mesh = old_meshes[node["mesh"]]
        group = [mesh] + [old_meshes[nodes[by_name[name]]["mesh"]] for name in MERGES.get(node["name"], ())]
        if any(len(part["primitives"]) != 1 for part in group):
            raise ValueError("Expected one primitive per source node")
        primitives = [part["primitives"][0] for part in group]
        first = primitives[0]
        if any(part.get("material") != first.get("material")
               or part.get("mode", 4) != 4 or part["attributes"].keys() != first["attributes"].keys()
               for part in primitives):
            raise ValueError(f"Incompatible surfaces on {node['name']}")
        attributes = {}
        for semantic in first["attributes"]:
            indices = [part["attributes"][semantic] for part in primitives]
            attributes[semantic] = append_accessor(indices, b"".join(map(accessor_data, indices)), 34962)

        merged_indices = []
        vertex_offset = 0
        for part in primitives:
            index = part["indices"]
            if old_accessors[index]["componentType"] != 5123:
                raise ValueError("Expected 16-bit source indices")
            merged_indices.extend(vertex_offset + value[0] for value in struct.iter_unpack("<H", accessor_data(index)))
            vertex_offset += old_accessors[part["attributes"]["POSITION"]]["count"]
        indices = [part["indices"] for part in primitives]
        index = append_accessor(indices, struct.pack(f"<{len(merged_indices)}H", *merged_indices), 34963)
        model["accessors"][index].update(min=[min(merged_indices)], max=[max(merged_indices)])
        primitive = dict(first, attributes=attributes, indices=index)
        node["mesh"] = len(model["meshes"])
        model["meshes"].append(dict(mesh, primitives=[primitive]))

    for i in removed:
        nodes[i].pop("mesh")
        nodes[i].pop("skin")
    for skin in model["skins"]:
        index = skin["inverseBindMatrices"]
        skin["inverseBindMatrices"] = append_accessor([index], accessor_data(index), None)
    for image in model["images"]:
        image["bufferView"] = append_view(view_data(image["bufferView"]))

    binary.extend(bytes(-len(binary) % 4))
    model["buffers"] = [{"byteLength": len(binary)}]
    header = json.dumps(model, separators=(",", ":"), ensure_ascii=False).encode()
    header += b" " * (-len(header) % 4)
    return (
        struct.pack("<4sII", b"glTF", 2, 28 + len(header) + len(binary))
        + struct.pack("<I4s", len(header), b"JSON") + header
        + struct.pack("<I4s", len(binary), b"BIN\x00") + binary
    )


if __name__ == "__main__":
    here = Path(__file__).resolve().parent
    name = "danly-soldier.glb"
    (here.parent / name).write_bytes(merge_glb((here / name).read_bytes()))
