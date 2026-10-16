#!/usr/bin/env python3
"""One local, offline S4b pose probe; never starts or installs ComfyUI.

Start the local server separately using machine-only settings in .workspace.
Then use --submit once and --collect to fetch the completed image.  This is an
exploration script, not a general actor exporter or an acceptance test.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "art/animations/players/swordsman/v7/sources/comfy_probe"
BASE_URL = "http://127.0.0.1:8188"
SEED = 73150415
SIZE = (768, 1024)
CHECKPOINT = "NoobAI-XL-v1.0.safetensors"
CONTROLNET = "diffusion_pytorch_model_promax.safetensors"

# COCO/OpenPose body-18 indexes, original OpenPose RGB limb palette.  Anatomical
# right is the camera-facing/near leg and trails; anatomical left leads screen
# right.  This deliberately differs from the repeated C1/C2 half-step.
POINTS = [
    (420, 170), (380, 270), (337, 280), (295, 400), (270, 510),
    (400, 280), (450, 390), (478, 465), (352, 558), (290, 730),
    (220, 882), (389, 558), (455, 728), (535, 900), (410, 157),
    (425, 157), (386, 170), None,
]
LIMBS = [(2, 3), (2, 6), (3, 4), (4, 5), (6, 7), (7, 8),
         (2, 9), (9, 10), (10, 11), (2, 12), (12, 13), (13, 14),
         (2, 1), (1, 15), (15, 17), (1, 16), (16, 18)]
COLORS = [(255, 0, 0), (255, 85, 0), (255, 170, 0), (255, 255, 0),
          (170, 255, 0), (85, 255, 0), (0, 255, 0), (0, 255, 85),
          (0, 255, 170), (0, 255, 255), (0, 170, 255), (0, 85, 255),
          (0, 0, 255), (85, 0, 255), (170, 0, 255), (255, 0, 255),
          (255, 0, 170), (255, 0, 85)]

POSITIVE = (
    "masterpiece, best quality, very aesthetic, solo, 1boy, adult male, full body, "
    "three-quarter side view, facing right, looking right, walking, contrapposto, "
    "left leg forward, right leg back, left heel touching ground in front, "
    "right foot behind on tiptoe, long legs, lean athletic build, "
    "silver spiky hair, dark red hair streak, grey eyes, serious face, "
    "black high collar shirt, black leather long coat, dark crimson coat lining, "
    "two horizontal chest straps with silver buckles, black belt, black pants, "
    "dark steel knee guards, shin armor, black boots, dark red bandages on both "
    "forearms and hands, bare fingers, holding one katana in right hand low at "
    "side, left hand open, shallow curved steel blade, black scabbard on left hip, "
    "hand painted anime action game character, crisp dark outlines, cel shading, "
    "clean detail, plain neutral grey background, no floor shadow"
)
NEGATIVE = (
    "worst quality, low quality, blurry, text, watermark, logo, multiple views, "
    "multiple people, sprite sheet, cropped, out of frame, deformed, bad anatomy, "
    "extra limbs, extra legs, missing hands, fused legs, running, jumping, both "
    "feet airborne, right leg forward, left leg back, metal forearm armor, fire, "
    "glow, motion blur, slash effects, two swords, two handed grip, photo, 3d"
)


def settings() -> dict[str, str]:
    return dict(line.split("=", 1) for line in
                (ROOT / ".workspace").read_text(encoding="utf-8-sig").splitlines()
                if "=" in line and not line.lstrip().startswith("#"))


def sanitized(value):
    text = json.dumps(value, ensure_ascii=False)
    local = settings()
    for key in ("comfyui_core_root", "comfyui_python", "comfyui_path"):
        path = local.get(key)
        if path:
            for form in {path, path.replace("/", "\\"), path.replace("\\", "/")}:
                text = text.replace(json.dumps(form)[1:-1], "<local-install>")
    return json.loads(text)


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(sanitized(value), ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8", newline="\n")


def api(route: str, payload=None):
    request = urllib.request.Request(BASE_URL + route)
    if payload is not None:
        request = urllib.request.Request(BASE_URL + route,
                                         json.dumps(payload).encode(),
                                         {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def upload(path: Path):
    boundary = "pose-probe-" + uuid.uuid4().hex
    pieces = []
    for name, value in (("type", "input"), ("overwrite", "false"),
                        ("subfolder", "dnflike_v7_probe")):
        pieces.append((f"--{boundary}\r\nContent-Disposition: form-data; "
                       f'name="{name}"\r\n\r\n{value}\r\n').encode())
    pieces.append((f"--{boundary}\r\nContent-Disposition: form-data; "
                   f'name="image"; filename="{path.name}"\r\n'
                   "Content-Type: image/png\r\n\r\n").encode())
    pieces.extend((path.read_bytes(), f"\r\n--{boundary}--\r\n".encode()))
    request = urllib.request.Request(
        BASE_URL + "/upload/image", b"".join(pieces),
        {"Content-Type": "multipart/form-data; boundary=" + boundary})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def prepare_inputs():
    folder = OUT / "input"
    folder.mkdir(parents=True, exist_ok=True)
    source = ROOT / "art/concepts/characters/players/swordsman/standard_v1/sheet_pose_head_c2.png"
    # Source RGB sheet, not the old transparent cutout with noisy hidden RGB.
    reference = Image.open(source).convert("RGB").crop((0, 20, 610, 760))
    reference.thumbnail((748, 748), Image.Resampling.LANCZOS)
    padded = Image.new("RGB", (768, 768), (208, 208, 208))
    padded.paste(reference, ((768-reference.width)//2, (768-reference.height)//2))
    padded.save(folder / "standard_a2_reference.png")
    pose = Image.new("RGB", SIZE, "black")
    draw = ImageDraw.Draw(pose)
    for (a, b), color in zip(LIMBS, COLORS):
        p, q = POINTS[a-1], POINTS[b-1]
        if p is None or q is None:
            continue
        length = math.dist(p, q)
        angle = math.atan2(q[1]-p[1], q[0]-p[0])
        cx, cy = (p[0]+q[0])/2, (p[1]+q[1])/2
        polygon = []
        for degree in range(0, 360, 5):
            t = math.radians(degree)
            x, y = length/2*math.cos(t), 5*math.sin(t)
            polygon.append((cx+x*math.cos(angle)-y*math.sin(angle),
                            cy+x*math.sin(angle)+y*math.cos(angle)))
        draw.polygon(polygon, fill=tuple(int(c*.6) for c in color))
    for point, color in zip(POINTS, COLORS):
        if point:
            x, y = point
            draw.ellipse((x-5, y-5, x+5, y+5), fill=color)
    pose.save(folder / "walk_opposite_openpose.png")
    write_json(folder / "pose.json", {
        "format": "OpenPose COCO body-18", "canvas": SIZE,
        "keypoints_pixel_xy": POINTS, "limbs_one_based": LIMBS,
        "color_reference": "installed controlnet_aux open_pose/util.py draw_bodypose",
        "target": "anatomical left/far leg forward, right/near leg trailing",
        "reference_source": source.relative_to(ROOT).as_posix(),
        "reference_crop_ltrb": [0, 20, 610, 760],
        "reference_processing": "RGB crop, contain-resize and neutral square padding",
        "pose_processing": "hand-authored canonical body-18 RGB limbs; no detector/download",
    })
    return folder / "standard_a2_reference.png", folder / "walk_opposite_openpose.png"


def workflow(reference_name: str, pose_name: str):
    return {
        "1": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": CHECKPOINT}},
        "2": {"class_type": "CLIPTextEncode", "inputs": {"text": POSITIVE, "clip": ["1", 1]}},
        "3": {"class_type": "CLIPTextEncode", "inputs": {"text": NEGATIVE, "clip": ["1", 1]}},
        "4": {"class_type": "LoadImage", "inputs": {"image": reference_name}},
        "5": {"class_type": "IPAdapterUnifiedLoader", "inputs": {"model": ["1", 0], "preset": "PLUS (high strength)"}},
        "6": {"class_type": "IPAdapterAdvanced", "inputs": {"model": ["5", 0], "ipadapter": ["5", 1], "image": ["4", 0], "weight": 0.55, "weight_type": "linear", "combine_embeds": "concat", "start_at": 0.0, "end_at": 0.85, "embeds_scaling": "V only"}},
        "7": {"class_type": "ControlNetLoader", "inputs": {"control_net_name": CONTROLNET}},
        "8": {"class_type": "SetUnionControlNetType", "inputs": {"control_net": ["7", 0], "type": "openpose"}},
        "9": {"class_type": "LoadImage", "inputs": {"image": pose_name}},
        "10": {"class_type": "ControlNetApplyAdvanced", "inputs": {"positive": ["2", 0], "negative": ["3", 0], "control_net": ["8", 0], "image": ["9", 0], "strength": 1.1, "start_percent": 0.0, "end_percent": 1.0, "vae": ["1", 2]}},
        "11": {"class_type": "EmptyLatentImage", "inputs": {"width": SIZE[0], "height": SIZE[1], "batch_size": 1}},
        "12": {"class_type": "KSampler", "inputs": {"model": ["6", 0], "seed": SEED, "steps": 24, "cfg": 5.5, "sampler_name": "euler_ancestral", "scheduler": "normal", "positive": ["10", 0], "negative": ["10", 1], "latent_image": ["11", 0], "denoise": 1.0}},
        "13": {"class_type": "VAEDecode", "inputs": {"samples": ["12", 0], "vae": ["1", 2]}},
        "14": {"class_type": "SaveImage", "inputs": {"images": ["13", 0], "filename_prefix": "dnflike_v7_probe/walk_opposite_s4b"}},
    }


def submit():
    result_path = OUT / "result.json"
    if result_path.exists():
        raise RuntimeError("result.json already exists; refusing accidental repeated/batch generation")
    reference, pose = prepare_inputs()
    stats = api("/system_stats")
    info = api("/object_info")
    required = {node["class_type"] for node in workflow("", "").values()}
    missing = sorted(required-info.keys())
    if missing:
        raise RuntimeError("Missing loaded nodes: " + ", ".join(missing))
    write_json(OUT / "capabilities.json", {
        "comfyui_version": stats["system"]["comfyui_version"],
        "python_version": stats["system"]["python_version"].splitlines()[0],
        "pytorch_version": stats["system"]["pytorch_version"],
        "devices": stats["devices"], "required_nodes_present": sorted(required),
        "checkpoint_listed": CHECKPOINT in info["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0],
        "controlnet_listed": CONTROLNET in info["ControlNetLoader"]["input"]["required"]["control_net_name"][0],
        "offline_start": True, "actual_inference_validated": False,
    })
    uploads = [upload(reference), upload(pose)]
    names = [str(Path(u.get("subfolder", ""))/u["name"]).replace("\\", "/") for u in uploads]
    prompt = workflow(*names)
    write_json(OUT / "workflow_api.json", prompt)
    write_json(OUT / "upload_receipts.json", [
        {"local_file": p.relative_to(ROOT).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "api_receipt": receipt}
        for p, receipt in zip((reference, pose), uploads)])
    request = {"prompt": prompt, "client_id": "dnflike-v7-single-pose"}
    try:
        receipt = api("/prompt", request)
    except urllib.error.HTTPError as exc:
        write_json(result_path, {"status": "validation_error", "response": json.loads(exc.read())})
        raise
    result = {"status": "submitted", "submitted_utc": datetime.now(timezone.utc).isoformat(),
              "prompt_id": receipt["prompt_id"], "receipt": receipt,
              "scope": "one single-pose S4b feasibility probe, no game integration",
              "transparency": "RGB generation; no transparent-background promise",
              "checkpoint": CHECKPOINT, "controlnet": CONTROLNET, "seed": SEED}
    write_json(result_path, result)
    print(json.dumps(result, ensure_ascii=False))


def retry_vpred():
    """One explicit sampling hypothesis test; preserve the failed EPS attempt."""
    result_path = OUT / "result_vpred.json"
    if result_path.exists():
        raise RuntimeError("The single v-prediction retry already exists; refusing further attempts")
    original = json.loads((OUT / "result.json").read_text(encoding="utf-8"))
    if original["status"] != "completed":
        raise RuntimeError("Collect and review the initial attempt before the one retry")
    prompt = json.loads((OUT / "workflow_api.json").read_text(encoding="utf-8"))
    prompt["15"] = {"class_type": "ModelSamplingDiscrete", "inputs": {
        "model": ["1", 0], "sampling": "v_prediction", "zsnr": True}}
    prompt["5"]["inputs"]["model"] = ["15", 0]
    prompt["14"]["inputs"]["filename_prefix"] = "dnflike_v7_probe/walk_opposite_s4b_vpred"
    write_json(OUT / "workflow_api_vpred.json", prompt)
    receipt = api("/prompt", {"prompt": prompt, "client_id": "dnflike-v7-single-pose-vpred"})
    result = {"status": "submitted", "prompt_id": receipt["prompt_id"], "receipt": receipt,
              "submitted_utc": datetime.now(timezone.utc).isoformat(),
              "scope": "one sampling-configuration hypothesis retry; not a batch",
              "hypothesis": "initial EPS output is severely geometric; test v_prediction + zero terminal SNR",
              "evidence_limit": "checkpoint has no prediction metadata; exact model variant remains unconfirmed",
              "only_changed": ["ModelSamplingDiscrete(v_prediction,zsnr=true)", "output filename prefix"],
              "same_seed": SEED, "same_inputs": "upload_receipts.json",
              "transparency": "RGB generation; no transparent-background promise"}
    write_json(result_path, result)
    print(json.dumps(result, ensure_ascii=False))


def collect(vpred=False):
    suffix = "_vpred" if vpred else ""
    result_path = OUT / ("result" + suffix + ".json")
    result = json.loads(result_path.read_text(encoding="utf-8"))
    identifier = result["prompt_id"]
    history = api("/history/" + identifier)
    if identifier not in history:
        queue = api("/queue")
        print(json.dumps({"status": "running_or_queued", "running_count": len(queue["queue_running"]), "pending_count": len(queue["queue_pending"])}))
        return
    record = history[identifier]
    write_json(OUT / ("history" + suffix + ".json"), record)
    status = record.get("status", {})
    result["status"] = "completed" if status.get("status_str") == "success" else "execution_error"
    result["execution_status"] = status
    result["outputs"] = []
    for output in record.get("outputs", {}).values():
        for image in output.get("images", []):
            if image.get("type") != "output":
                continue
            destination = OUT / "output" / image["filename"]
            destination.parent.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(BASE_URL + "/view?" + urllib.parse.urlencode(image), timeout=30) as response:
                destination.write_bytes(response.read())
            result["outputs"].append(destination.relative_to(ROOT).as_posix())
    result["completed_utc"] = datetime.now(timezone.utc).isoformat()
    write_json(result_path, result)
    print(json.dumps(sanitized(result), ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--submit", action="store_true")
    parser.add_argument("--collect", action="store_true")
    parser.add_argument("--retry-vpred", action="store_true")
    parser.add_argument("--vpred", action="store_true", help="collect the one sampling retry")
    args = parser.parse_args()
    if args.prepare:
        prepare_inputs()
    if args.submit:
        submit()
    if args.retry_vpred:
        retry_vpred()
    if args.collect:
        collect(args.vpred)
    if not any((args.prepare, args.submit, args.collect, args.retry_vpred)):
        parser.print_help()


if __name__ == "__main__":
    main()
