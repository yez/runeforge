#!/usr/bin/env python3
"""Builds the war camp dashboard's art from the sources in art/ (see CREDITS.md).

Writes WebP images and assets.json to lib/runeforge/web/warcamp/assets/. Re-run it after
changing anything in art/ or the tables below. Needs Pillow and NumPy.

    python3 script/build_warcamp_assets.py
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / "art"
OUT = ROOT / "lib" / "runeforge" / "web" / "warcamp" / "assets"
QUALITY = 82

# FLARE sheets: 8 rows (directions W, NW, N, NE, E, SE, S, SW), 32 columns of 128x128 frames.
ORC_FRAME = 128
# Source columns per animation; block (16-17) and die (20-23) aren't used.
ORC_ANIMS = {
    "stance": range(0, 4),
    "run": range(4, 12),
    "swing": range(12, 16),
    "hit": range(18, 20),
    "cast": range(24, 28),
    "shoot": range(28, 32),
}
ORCS = {
    "regular": "orc_regular_0.png",
    "elite": "orc_elite_0.png",
    "heavy": "orc_heavy_1.png",
    "archer": "orc_archer_0.png",
}

# Props cut from the Grassland Tileset: name -> (x0, y0, x1, y1, anchor_y as a fraction).
GRASSLAND_PROPS = {
    "bonfire": (391, 266, 443, 318, 0.75),
    "anvil": (454, 272, 504, 320, 0.80),
    "woodpile_a": (265, 280, 312, 316, 0.75),
    "woodpile_b": (329, 280, 376, 317, 0.75),
    "crate_a": (203, 278, 252, 318, 0.78),
    "crate_b": (139, 280, 185, 318, 0.78),
    "chest": (10, 281, 55, 316, 0.78),
    "signpost": (648, 385, 706, 470, 0.88),
    "stump": (515, 440, 575, 486, 0.75),
    "rock_a": (2, 441, 48, 475, 0.75),
    "rock_b": (144, 443, 184, 477, 0.75),
    "bush_a": (11, 343, 59, 381, 0.80),
    "bush_b": (256, 345, 314, 380, 0.80),
    "bush_c": (326, 345, 381, 383, 0.80),
    "bush_d": (588, 340, 642, 382, 0.80),
    "bush_e": (652, 345, 697, 382, 0.80),
    "bush_f": (906, 340, 958, 379, 0.80),
    "tuft_a": (135, 335, 185, 379, 0.85),
    "tuft_b": (201, 332, 251, 379, 0.85),
    "pine_a": (265, 1150, 386, 1337, 0.93),
    "pine_b": (132, 1152, 254, 1341, 0.93),
    "pine_c": (394, 1162, 514, 1341, 0.93),
    "pine_d": (4, 1163, 125, 1344, 0.93),
    "oak_a": (517, 1193, 642, 1343, 0.93),
    "oak_b": (771, 1197, 898, 1330, 0.93),
    "oak_c": (910, 1197, 1024, 1341, 0.93),
    "oak_d": (646, 1198, 767, 1341, 0.93),
    "dead_a": (917, 966, 1013, 1169, 0.95),
    "dead_b": (655, 967, 770, 1166, 0.95),
    "dead_c": (793, 977, 898, 1168, 0.95),
}

# Tents are stored as two slices each: (box, offset) pairs joined into one image.
TENTS = {
    "tent_a": [((511, 170, 579, 262), (0, 8)), ((605, 170, 641, 262), (60, 0))],
    "tent_b": [((640, 170, 676, 262), (0, 0)), ((701, 170, 770, 258), (30, 8))],
}

# Buildings (feudalwars, CC0): name -> (file, scale, anchor_y as a fraction of the cropped height).
BUILDINGS = {
    "great_hall": ("watchtower_lvl2-exp_full_size.png", 0.30, 0.90),
    "watchtower": ("watchtower_wooden_full_size.png", 0.26, 0.90),
    "forge": ("blacksmith.png", 0.95, 0.80),
    "stable": ("stable.png", 0.95, 0.78),
}


def save(image, name):
    path = OUT / name
    image.save(path, "WEBP", quality=QUALITY, method=6)
    return name


def trimmed(image):
    return image.crop(image.getbbox())


def build_orcs():
    meta = {}
    columns = [c for frames in ORC_ANIMS.values() for c in frames]
    for kind, filename in ORCS.items():
        sheet = Image.open(ART / "orcs" / filename).convert("RGBA")
        alpha = np.array(sheet)[:, :, 3]
        # One crop box for every frame, so the anchor is the same everywhere.
        x0 = y0 = ORC_FRAME
        x1 = y1 = 0
        for row in range(8):
            for col in columns:
                cell = alpha[row * ORC_FRAME:(row + 1) * ORC_FRAME, col * ORC_FRAME:(col + 1) * ORC_FRAME]
                ys, xs = np.nonzero(cell)
                if len(xs):
                    x0, y0 = min(x0, xs.min()), min(y0, ys.min())
                    x1, y1 = max(x1, xs.max() + 1), max(y1, ys.max() + 1)
        # The feet: lowest solid (not shadow) pixel of the south-facing stance frames.
        feet = []
        for col in ORC_ANIMS["stance"]:
            cell = alpha[6 * ORC_FRAME:7 * ORC_FRAME, col * ORC_FRAME:(col + 1) * ORC_FRAME]
            ys, xs = np.nonzero(cell > 230)
            feet.append(ys.max())
        fw, fh = int(x1 - x0), int(y1 - y0)
        out = Image.new("RGBA", (fw * len(columns), fh * 8))
        for row in range(8):
            for index, col in enumerate(columns):
                box = (col * ORC_FRAME + x0, row * ORC_FRAME + y0, col * ORC_FRAME + x1, row * ORC_FRAME + y1)
                out.paste(sheet.crop(box), (index * fw, row * fh))
        anims, start = {}, 0
        for name, frames in ORC_ANIMS.items():
            anims[name] = [start, len(frames)]
            start += len(frames)
        meta[kind] = {
            "src": save(out, f"orc_{kind}.webp"), "fw": fw, "fh": fh,
            # The standing point sits a little above the lowest toe and right of the frame centre.
            "ax": int(ORC_FRAME // 2 + 4 - x0), "ay": int(max(feet) - 6 - y0), "anims": anims,
        }
    return meta


def build_props():
    sheet = Image.open(ART / "grassland" / "grassland_tiles.png").convert("RGBA")
    meta = {}
    for name, (x0, y0, x1, y1, ay) in GRASSLAND_PROPS.items():
        image = sheet.crop((x0, y0, x1, y1))
        box = image.getbbox()
        image = image.crop(box)
        meta[name] = {"src": save(image, f"prop_{name}.webp"), "w": image.width, "h": image.height,
                      "ax": image.width // 2, "ay": int(image.height * ay)}
    for name, parts in TENTS.items():
        canvas = Image.new("RGBA", (140, 110))
        for box, offset in parts:
            canvas.alpha_composite(sheet.crop(box), offset)
        image = trimmed(canvas)
        meta[name] = {"src": save(image, f"prop_{name}.webp"), "w": image.width, "h": image.height,
                      "ax": image.width // 2, "ay": int(image.height * 0.85)}
    # Ground: 16 grass and 16 cobblestone diamonds, 64x32 each, as two strips.
    meta["ground"] = {"grass": save(sheet.crop((0, 0, 1024, 32)), "ground_grass.webp"),
                      "path": save(sheet.crop((0, 32, 1024, 64)), "ground_path.webp"),
                      "tw": 64, "th": 32, "count": 16}
    return meta


def build_buildings():
    meta = {}
    for name, (filename, scale, ay) in BUILDINGS.items():
        image = trimmed(Image.open(ART / "buildings" / filename).convert("RGBA"))
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.LANCZOS)
        meta[name] = {"src": save(image, f"building_{name}.webp"), "w": image.width, "h": image.height,
                      "ax": image.width // 2, "ay": int(image.height * ay)}
    return meta


def shift_hue(image, target_hue, saturation=1.0):
    """Recolours an image to another hue, keeping lightness (the blue button made orc red)."""
    rgba = np.array(image.convert("RGBA")).astype(np.float32) / 255
    rgb = rgba[:, :, :3]
    high, low = rgb.max(axis=2), rgb.min(axis=2)
    lightness = (high + low) / 2
    chroma = high - low
    sat = np.where(chroma == 0, 0, chroma / (1 - np.abs(2 * lightness - 1) + 1e-6))
    sat = np.clip(sat * saturation, 0, 1)
    out = np.empty_like(rgb)
    # HLS -> RGB for one hue across the whole image, vectorised.
    q = np.where(lightness < 0.5, lightness * (1 + sat), lightness + sat - lightness * sat)
    p = 2 * lightness - q

    def channel(t):
        t = t % 1
        return np.where(t < 1 / 6, p + (q - p) * 6 * t,
                        np.where(t < 1 / 2, q, np.where(t < 2 / 3, p + (q - p) * (2 / 3 - t) * 6, p)))

    out[:, :, 0] = channel(target_hue + 1 / 3)
    out[:, :, 1] = channel(np.full_like(lightness, target_hue))
    out[:, :, 2] = channel(target_hue - 1 / 3)
    rgba[:, :, :3] = out
    return Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8))


def build_ui():
    meta = {}
    for name in ("card-bg", "dropdown-menu-bg", "button-bg-sm"):
        image = Image.open(ART / "warcraftcn" / f"{name}.webp")
        meta[name] = save(image, f"ui_{name}.webp")
    button = Image.open(ART / "warcraftcn" / "button-bg.webp").convert("RGBA")
    small = button.resize((button.width // 2, button.height // 2), Image.LANCZOS)
    meta["button-orc"] = save(shift_hue(small, 0.0, 1.1), "ui_button-orc.webp")
    return meta


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.webp"):
        old.unlink()
    meta = {"orcs": build_orcs(), "props": build_props(), "buildings": build_buildings(), "ui": build_ui()}
    (OUT / "assets.json").write_text(json.dumps(meta, indent=1) + "\n")
    total = sum(path.stat().st_size for path in OUT.iterdir())
    print(f"wrote {len(list(OUT.iterdir()))} files, {total / 1024:.0f} KB, to {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
