"""Composite existing exported HUD artwork over untouched Godot screenshots.

No image generation, inpainting, scene replacement, screenshot enlargement or
game code change. Uses the same exported PNG files and alpha compositor as the
approved resource-batch review. New HUD is still a visual overlay, not integrated.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
from PIL import Image, ImageChops, ImageDraw

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
CAPTURES = ROOT / "docs/screenshots/hud_environment"
OUTPUT = ROOT / "docs/previews/hud_reference_v2/current_game"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    spec = importlib.util.spec_from_file_location("hud_batch_compositor", HERE / "build_pack.py")
    compositor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(compositor)
    pack = json.loads((HERE / "manifest.json").read_text(encoding="utf-8"))
    layout = json.loads((HERE / "layout.json").read_text(encoding="utf-8"))
    states = json.loads((CAPTURES / "capture_state.json").read_text(encoding="utf-8"))
    runtime = json.loads((ROOT / "game/data/runtime.json").read_text(encoding="utf-8"))
    for name, record in pack["textures"].items():
        path = HERE / record["file"]
        if sha(path) != record["export_sha256"]:
            raise ValueError("Texture changed since batch validation: " + name)
        compositor.TEXTURES[name] = Image.open(path).convert("RGBA")
        compositor.RECORDS[name] = record
    OUTPUT.mkdir(parents=True, exist_ok=True)
    records = []
    for state in states:
        source_path = CAPTURES / (state["label"] + "_clean.png")
        scene = Image.open(source_path).convert("RGBA")
        if scene.size != (1920, 1080):
            raise ValueError("Expected current native 1920x1080 capture")
        ui = Image.new("RGBA", (2560, 1440))
        tile = compositor.texture("fascia_tile")
        x0, y0, width, _ = layout["bottom_fascia"]
        for index, x in enumerate(range(x0, x0 + width, tile.width)):
            part = tile if index % 2 == 0 else tile.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
            ui.alpha_composite(part, (x, y0))
        compositor.place(ui, "exp_frame", layout["exp"][:2])
        compositor.text(ui, (325, 1238), "Lv." + str(runtime["world"]["player_level"]), 27, anchor="mm", bold=True)
        for index, name in enumerate(compositor.ITEMS):
            x, y = layout["items"]["start"]
            # Item artwork/keys are a layout preview; no invented stack counts.
            compositor.draw_slot(ui, (x + index * layout["items"]["pitch"], y), str(index + 1), name)
        for row, keys in enumerate(layout["skills"]["keys"]):
            for col, key in enumerate(keys):
                x, y = layout["skills"]["start"]
                pitch_x, pitch_y = layout["skills"]["pitch"]
                icon = compositor.SKILLS[col] if row == 1 and col < 2 and state["player_job"] == 2 else None
                compositor.draw_slot(ui, (x + col * pitch_x, y + row * pitch_y), key, icon)
        compositor.place(ui, "wheel", layout["wheel"][:2])
        for prefix, fraction in [("hp", state["player_hp"] / state["player_hp_max"]),
                                 ("mp", state["player_mp"] / state["player_mp_max"])]:
            position = layout[prefix][:2]
            compositor.place(ui, prefix + "_shell", position)
            ui.alpha_composite(compositor.clip_liquid(prefix + "_liquid", fraction), position)
            compositor.place(ui, prefix + "_glass", position)
        if state["target"]:
            target = state["target"]
            compositor.place(ui, "target_frame", layout["target"][:2])
            compositor.place(ui, "target_portrait", (30, 118))
            compositor.text(ui, (155, 114), target["name"], 27, bold=True)
            compositor.runtime_bar(ui, layout["target_hp_fill"], target["hp"] / target["max_hp"],
                                   ((246, 90, 70), (210, 22, 24), (102, 5, 13)))
        compositor.place(ui, "title_plate", layout["dungeon_title"][:2])
        title = state["dungeon_name"] + " · " + str(state["room_number"]) + "/" + str(state["room_count"])
        compositor.text(ui, (2538, 32), title, 31, anchor="rm", bold=True)
        compositor.place(ui, "minimap_frame", layout["minimap"][:2])
        compositor.text(ui, (2438, 103), "地图", 27, anchor="mm", bold=True)
        # Current 10001-A config is a linear sequence of five right/left links.
        # This remains an offline map-style preview, not a new map game system.
        draw = ImageDraw.Draw(ui)
        for i in range(state["room_count"]):
            x, y = 2350 + 32 * i, 215
            if i:
                draw.line((x - 7, y + 13, x, y + 13), fill="#69623b", width=4)
            fill = "#4c5430" if i < state["room_index"] else "#292d1b"
            draw.rounded_rectangle((x, y, x + 26, y + 26), radius=3, fill=fill, outline="#85805a", width=2)
            if i == state["room_index"]:
                draw.polygon([(x + 13, y + 4), (x + 6, y + 13), (x + 13, y + 22), (x + 20, y + 13)], fill="#49c5e9")
        overlay = compositor.reduce_rgba(ui, scene.size)
        result = Image.alpha_composite(scene, overlay)
        result_path = OUTPUT / (state["label"] + "_new_hud_1920.png")
        result.convert("RGB").save(result_path)
        untouched_mask = overlay.getchannel("A").point(lambda value: 255 if value == 0 else 0)
        unchanged = ImageChops.difference(scene.convert("RGB"), result.convert("RGB"))
        unchanged = ImageChops.multiply(unchanged, untouched_mask.convert("RGB"))
        if unchanged.getbbox() is not None:
            raise ValueError("Unexpected scene pixel changes outside HUD")
        records.append({"room": state["module"], "source": source_path.relative_to(ROOT).as_posix(),
                        "source_sha256": sha(source_path), "output": result_path.relative_to(ROOT).as_posix(),
                        "output_sha256": sha(result_path), "size": list(scene.size), "hud_scale": .75,
                        "screenshot_upscaled": False, "scene_pixels_outside_hud_unchanged": True,
                        "game_hud_integrated": False, "overlay_textures": len(pack["textures"]),
                        "notes": "Real Godot capture + existing HUD texture overlay; item keys and minimap are visual preview."})
    (OUTPUT / "validation.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"outputs": len(records), "size": [1920, 1080], "scene_pixels_preserved": True,
                      "new_image_generation": False, "game_hud_integrated": False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
