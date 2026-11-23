#!/usr/bin/env python3
"""Regenerate ../danly-soldier.glb from the unmodified attributed source."""

import json
from pathlib import Path
import struct
from io import BytesIO

from PIL import Image
from outfit_atlas import PARTS, atlas_uv, build_atlas


# Each normalized texture tile used by a source mesh. Object_123 is the
# skinned result; the independently transformed eye mesh stays separate.
OUTFIT = {
    "Object_97": "Object_97", "Object_99": "Object_97",
    "Object_101": "Object_101", "Object_117": "Object_101",
    "Object_103": "Object_103", "Object_119": "Object_103", "Object_121": "Object_103",
    "Object_105": "Object_105", "Object_107": "Object_107", "Object_109": "Object_109",
    "Object_123": "Object_123", "Object_113": "Object_123", "Object_115": "Object_123",
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
    old_materials, old_textures, old_images = (model[key] for key in ("materials", "textures", "images"))
    model.update(bufferViews=[], accessors=[], meshes=[], materials=[], textures=[], images=[])
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
    outfit = by_name["Object_123"]
    for name in OUTFIT:
        other = by_name[name]
        if (nodes[outfit]["skin"] != nodes[other].get("skin")
                or parents[outfit] != parents[other]
                or any(nodes[outfit].get(key) != nodes[other].get(key)
                       for key in ("matrix", "rotation", "scale", "translation"))
                or nodes[other].get("children")):
            raise ValueError(f"{name} cannot share the same skinned mesh as Object_123")
    removed = {by_name[name] for name in OUTFIT if name != "Object_123"}
    removed.add(by_name["Object_111"])  # The source headset floats above the cap.

    def get_texture(index: int) -> bytes:
        source_image = old_textures[index]["extensions"]["EXT_texture_webp"]["source"]
        return view_data(old_images[source_image]["bufferView"])

    def load_texture(index: int) -> Image.Image:
        return Image.open(BytesIO(get_texture(index))).convert("RGB")

    def append_texture(payload: bytes) -> int:
        image = len(model["images"])
        model["images"].append({"bufferView": append_view(payload), "mimeType": "image/webp"})
        model["textures"].append({"sampler": 0, "extensions": {"EXT_texture_webp": {"source": image}}})
        return len(model["textures"]) - 1

    # Keep the rigid eyes on their original material and original texels.
    eye = json.loads(json.dumps(old_materials[0]))
    for texture_slot in (eye["normalTexture"], eye["pbrMetallicRoughness"]["baseColorTexture"],
                         eye["pbrMetallicRoughness"]["metallicRoughnessTexture"]):
        texture_slot["index"] = append_texture(get_texture(texture_slot["index"]))
    model["materials"].append(eye)

    tile_materials = [old_materials[old_meshes[nodes[by_name[part]]["mesh"]]["primitives"][0]["material"]]
                      for part in PARTS]
    color, normal, orm = (append_texture(payload) for payload in build_atlas(tile_materials, load_texture))
    model["materials"].append({
        "name": "OutfitAtlas", "doubleSided": True,
        "pbrMetallicRoughness": {"baseColorTexture": {"index": color},
                                "metallicRoughnessTexture": {"index": orm}},
        "normalTexture": {"index": normal}, "occlusionTexture": {"index": orm},
    })

    for i, node in enumerate(nodes):
        if "children" in node:
            node["children"] = [child for child in node["children"] if child not in removed]
        if "mesh" not in node or i in removed:
            continue
        mesh = old_meshes[node["mesh"]]
        names = list(OUTFIT) if i == outfit else [node["name"]]
        group = [old_meshes[nodes[by_name[name]]["mesh"]] for name in names]
        if any(len(part["primitives"]) != 1 for part in group):
            raise ValueError("Expected one primitive per source node")
        primitives = [part["primitives"][0] for part in group]
        first = primitives[0]
        if any(part.get("mode", 4) != 4 or part["attributes"].keys() != first["attributes"].keys()
               for part in primitives):
            raise ValueError(f"Incompatible surfaces on {node['name']}")
        attributes = {}
        for semantic in first["attributes"]:
            indices = [part["attributes"][semantic] for part in primitives]
            payloads = list(map(accessor_data, indices))
            if i == outfit and semantic == "TEXCOORD_0":
                mapped = [atlas_uv(OUTFIT[name], u, v) for name, payload in zip(names, payloads)
                          for u, v in struct.iter_unpack("<ff", payload)]
                data = b"".join(struct.pack("<ff", *uv) for uv in mapped)
                accessor = append_accessor(indices, data, 34962)
                model["accessors"][accessor].update(min=list(map(min, zip(*mapped))),
                                                   max=list(map(max, zip(*mapped))))
            else:
                accessor = append_accessor(indices, b"".join(payloads), 34962)
            attributes[semantic] = accessor

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
        primitive = dict(first, attributes=attributes, indices=index, material=int(i == outfit))
        node["mesh"] = len(model["meshes"])
        model["meshes"].append(dict(mesh, primitives=[primitive]))

    for i in removed:
        nodes[i].pop("mesh")
        nodes[i].pop("skin", None)
    for skin in model["skins"]:
        index = skin["inverseBindMatrices"]
        skin["inverseBindMatrices"] = append_accessor([index], accessor_data(index), None)

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
