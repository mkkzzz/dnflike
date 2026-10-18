"""Build honest, downscaled review media from the unmodified generated source."""
from pathlib import Path
import hashlib
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[4]
PACKAGE = Path(__file__).resolve().parent
SOURCE = PACKAGE / "candidates/c1/source.png"
PREVIEW = ROOT / "docs/previews/hud_reference_v2"


def main():
    PREVIEW.mkdir(parents=True, exist_ok=True)
    with Image.open(SOURCE) as image:
        image.load()
        width, height = image.size
        # No enlargement. This is 75% of the ACTUAL sample, not a 1080p export.
        small = image.resize((round(width * .75), round(height * .75)), Image.Resampling.LANCZOS)
        small.save(PREVIEW / "c1_actual_075.png")
        # A native-pixel review crop; never publish this as separated game artwork.
        image.crop((0, 690, width, height)).save(PREVIEW / "c1_bottom_detail.png")
        report = {
            "source": SOURCE.relative_to(ROOT).as_posix(),
            "source_size": [width, height],
            "source_mode": image.mode,
            "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
            "requested_size": [2560, 1440],
            "native_2k": image.size == (2560, 1440),
            "upscaled": False,
            "actual_075_size": list(small.size),
            "bottom_crop_xyxy": [0, 690, width, height],
            "production_exports": [],
            "runtime_integrated": False,
            "visual_approval": "pending",
            "checks": {
                "source_decodes": True,
                "source_matches_recorded_dimensions": image.size == (1672, 941),
                "source_matches_recorded_hash": hashlib.sha256(SOURCE.read_bytes()).hexdigest() == "8000185395437d94f77b99fe659f9a1873547c1cc3a697a4cd9e856d034d7695",
                "preview_only_downscales": small.width <= width and small.height <= height,
            },
        }
    if not all(report["checks"].values()):
        raise ValueError("Review source changed; re-inspect and update provenance.")
    (PACKAGE / "validation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
