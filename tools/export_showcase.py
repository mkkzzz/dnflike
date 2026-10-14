"""Encode the actual Godot showcase capture and extract frames for visual QA."""
from pathlib import Path
import subprocess
import sys
import argparse

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs/previews"

try:
    import imageio_ffmpeg
except ImportError:
    sys.path.insert(0, str(ROOT / "temp/qa_packages"))
    import imageio_ffmpeg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=["v3", "v4", "v6"], default="v4")
    version = parser.parse_args().version
    source = ROOT / "temp" / f"{version}_showcase.avi"
    qa = ROOT / "temp" / f"{version}_qa"
    OUT.mkdir(parents=True, exist_ok=True)
    qa.mkdir(parents=True, exist_ok=True)
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(source),
                    "-c:v", "libx264", "-preset", "slow", "-crf", "19",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                    "-movflags", "+faststart", str(OUT / f"combat_{version}_showcase.mp4")], check=True)
    frames = ([80, 108, 128, 155, 220, 245, 280, 330, 375, 458, 500, 570] if version == "v3"
              else [100, 125, 150, 220, 244, 273, 350, 370, 442, 527, 540, 610, 670, 759, 789, 874])
    if version == "v6":
        frames = [52, 55, 114, 184, 189, 265, 270, 330, 333]
    for frame in frames:
        subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(source),
                        "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1",
                        str(qa / f"frame_{frame:03d}.png")], check=True)
    print(f"[VIDEO] {OUT / f'combat_{version}_showcase.mp4'}")


if __name__ == "__main__":
    main()
