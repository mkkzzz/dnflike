"""Rebuild the tracked demo environment from the project's approved art sources."""
from pathlib import Path

from PIL import Image, ImageEnhance

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "game/assets/demo"


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with Image.open(ROOT / "art/concepts/scenes/dungeon/legacy/dungeon_hall.png") as source:
        width, height = source.size
        top = round(height * 0.08)
        frame = source.convert("RGB").crop((0, top, width, min(height, top + round(width * 9 / 16))))
        frame = frame.resize((1280, 720), Image.Resampling.LANCZOS)
        frame = ImageEnhance.Brightness(frame).enhance(1.08)
        frame.save(OUT / "bg_dungeon.png", optimize=True)
    with Image.open(ROOT / "art/ui/hud/portraits/portrait_hero.png") as source:
        portrait = source.convert("RGBA").resize((128, 128), Image.Resampling.LANCZOS)
        portrait.save(OUT / "portrait.png", optimize=True)
    print("[ART] demo environment + portrait rebuilt")


if __name__ == "__main__":
    main()
