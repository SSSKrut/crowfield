"""Pack the supplied model's seven outfit materials without painting new art."""

from io import BytesIO
from PIL import Image


# Tile order must match team_marks.gdshader. The jacket and lower uniform
# share source art but occupy separate tiles so only the jacket takes a tint.
PARTS = ("Object_97", "Object_101", "Object_103", "Object_105", "Object_107",
         "Object_109", "Object_123")
COLUMNS, ROWS = 4, 2
PADDING = 1 / 64


def atlas_uv(part: str, u: float, v: float) -> tuple[float, float]:
    if not (0 <= u <= 1 and 0 <= v <= 1):
        raise ValueError("Expected an unwrapped source UV inside its texture")
    column = PARTS.index(part) % COLUMNS
    row = PARTS.index(part) // COLUMNS
    content = 1 - 2 * PADDING
    return ((column + PADDING + u * content) / COLUMNS,
            (row + PADDING + v * content) / ROWS)


def build_atlas(materials: list[dict], texture) -> tuple[bytes, bytes, bytes]:
    colors, normals, properties = [], [], []
    for material in materials:
        pbr = material["pbrMetallicRoughness"]
        colors.append(texture(pbr["baseColorTexture"]["index"]))
        normals.append(texture(material["normalTexture"]["index"]))

        ao = Image.new("L", (512, 512), 255)
        if "occlusionTexture" in material:
            ao = texture(material["occlusionTexture"]["index"]).getchannel("R")
        if "metallicRoughnessTexture" in pbr:
            orm = texture(pbr["metallicRoughnessTexture"]["index"])
            roughness, metallic = orm.getchannel("G"), orm.getchannel("B")
        else:
            roughness = metallic = Image.new("L", (512, 512), 255)
        roughness_factor = pbr.get("roughnessFactor", 1.0)
        metallic_factor = pbr.get("metallicFactor", 1.0)
        roughness = roughness.point(lambda value: round(value * roughness_factor))
        metallic = metallic.point(lambda value: round(value * metallic_factor))
        properties.append(Image.merge("RGB", (ao, roughness, metallic)))

    return (_pack(colors, 1024, (0, 0, 0)), _pack(normals, 512, (128, 128, 255)),
            _pack(properties, 512, (255, 255, 0)))


def _pack(images: list[Image.Image], cell: int, neutral: tuple[int, int, int]) -> bytes:
    output = Image.new("RGB", (COLUMNS * cell, ROWS * cell), neutral)
    padding = round(cell * PADDING)
    inner = cell - 2 * padding
    for i, source in enumerate(images):
        tile = source.resize((inner, inner), Image.Resampling.LANCZOS)
        x, y = (i % COLUMNS) * cell + padding, (i // COLUMNS) * cell + padding
        # Wrap edge pixels into the gutter so the mipmaps sample this tile
        # rather than a neighboring material.
        for dx in (-inner, 0, inner):
            for dy in (-inner, 0, inner):
                left, top = max(0, -padding - dx), max(0, -padding - dy)
                right, bottom = min(inner, inner + padding - dx), min(inner, inner + padding - dy)
                output.paste(tile.crop((left, top, right, bottom)), (x + dx + left, y + dy + top))
    result = BytesIO()
    output.save(result, "WEBP", lossless=True, method=6)
    return result.getvalue()
