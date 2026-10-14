"""Encode the actual Godot showcase capture and extract frames for visual QA."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "temp/v3_showcase.avi"
OUT = ROOT / "docs/previews"
QA = ROOT / "temp/v3_qa"

try:
    import imageio_ffmpeg
except ImportError:
    sys.path.insert(0, str(ROOT / "temp/qa_packages"))
    import imageio_ffmpeg


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    QA.mkdir(parents=True, exist_ok=True)
    ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()
    subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(SOURCE),
                    "-c:v", "libx264", "-preset", "slow", "-crf", "19",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                    "-movflags", "+faststart", str(OUT / "combat_v3_showcase.mp4")], check=True)
    for frame in [80, 108, 128, 155, 220, 245, 280, 330, 375, 458, 500, 570]:
        subprocess.run([ffmpeg, "-y", "-v", "error", "-i", str(SOURCE),
                        "-vf", f"select=eq(n\\,{frame})", "-frames:v", "1",
                        str(QA / f"frame_{frame:03d}.png")], check=True)
    print(f"[VIDEO] {OUT / 'combat_v3_showcase.mp4'}")


if __name__ == "__main__":
    main()
