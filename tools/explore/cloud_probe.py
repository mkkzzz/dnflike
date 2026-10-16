"""E1 探针：云端生图的参考图（ContentImage）能否锁住身份 / 跟随人偶姿势。

复用多模态技能自带的客户端（签名与代理），只在请求体里多传官方文档列出的 ContentImage 参数。
本机无 requests 时用 urllib 垫片代替，不安装任何依赖。
凭证从环境变量 BUDDY_CLOUD_TOKEN 读取，不写入任何文件。输出到 temp/explore/cloud/。

  python tools/explore/cloud_probe.py p1_identity p2_pose_t9 ...
"""
from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import os
import sys
import time
import types
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "temp" / "explore" / "cloud"
SKILL = Path(os.environ.get(
    "BUDDY_SKILL_SCRIPT",
    r"d:\CodeBuddy CN\resources\app\extensions\genie\out\extension\builtin\buddy-multimodal-generation\scripts\buddy-cloud.py"))

IDENTITY = ("银白色刺猬短发带一缕红色挑染、左眼有竖向刀疤、红色瞳孔的冷峻青年剑士；黑色高领长款皮风衣，血红色内衬，"
            "银色扣带与皮带；左前臂缠满红色绷带并冒出暗红色火焰；黑色长裤、黑色皮靴；黑柄长刀")
STYLE = "韩式横版动作网游角色手绘风，高清，清晰深色描边，赛璐璐明暗加柔和渐变，全身完整入画，纯浅灰色背景，无文字"
NEG = "多人，多个角色，文字，水印，畸形手，多余手指，断刀，背景杂物，写实照片，3D渲染"
EXP = ROOT / "temp" / "explore"

PROBES = {
    "p1_identity": {
        "image": ROOT / 'art/concepts/characters/players/swordsman/legacy/hero_cool.png', "res": "768:1024",
        "prompt": "保持参考图中角色的身份、发型、脸部与服装细节完全一致，改画为全身侧身站姿（面朝画面右侧），"
                  "右手持黑柄长刀、刀尖斜指前下方。" + IDENTITY + "。" + STYLE,
    },
    "p2_pose_t9": {
        "image": EXP / "probe_pose_t9.png", "res": "1024:768",
        "prompt": "严格按照参考图人偶的姿势、朝向、四肢位置、武器角度与构图重绘，人偶只是姿势参考，把它画成真实角色：" + IDENTITY
                  + "。右手单手持刀向前水平斩出。" + STYLE,
    },
    "p2_pose_t6": {
        "image": EXP / "probe_pose_t6.png", "res": "1024:768",
        "prompt": "严格按照参考图人偶的姿势、朝向、四肢位置、武器角度与构图重绘，人偶只是姿势参考，把它画成真实角色：" + IDENTITY
                  + "。右手单手持刀向身后蓄力。" + STYLE,
    },
    "p3_combo_t9": {
        "image": EXP / "probe_combo_t9.png", "res": "1024:768",
        "prompt": "参考图左侧是角色设定，右侧是姿势人偶。生成一张只有一个角色的全身图：左侧这个角色摆出右侧人偶的姿势"
                  "（面朝右，右手单手持刀向前水平斩出），发型、脸、服装、配色与左侧完全一致。" + STYLE,
    },
}


class _Resp:
    def __init__(self, status, body):
        self.status_code, self._body = status, body

    def json(self):
        return json.loads(self._body.decode("utf-8"))


def _post(url, headers=None, data=None, timeout=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return _Resp(r.status, r.read())
    except urllib.error.HTTPError as e:
        return _Resp(e.code, e.read())


def load_client():
    if "requests" not in sys.modules:
        shim = types.ModuleType("requests")
        shim.post = _post
        sys.modules["requests"] = shim
    spec = importlib.util.spec_from_file_location("buddy_cloud", SKILL)
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stderr(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


def run(mod, name, token):
    pr = PROBES[name]
    cfg = mod._PROVIDER_MAP["image"]
    b64 = base64.b64encode(pr["image"].read_bytes()).decode()
    body = {"Prompt": pr["prompt"], "NegativePrompt": NEG, "Resolution": pr["res"], "Num": 1, "LogoAdd": 0,
            "ContentImage": {"ImageBase64": b64}}
    t0 = time.time()
    sub = mod._call_api(mod._DEFAULT_ENDPOINT, cfg["provider"], cfg["service"], cfg["version"],
                        cfg["submit_action"], body, token)
    job = sub.get("JobId")
    res = mod._poll_job(mod._DEFAULT_ENDPOINT, cfg["provider"], cfg["service"], cfg["version"],
                        cfg["query_action"], job, token, 5, 600)
    urls = res.get("ResultImage") or []
    OUT.mkdir(parents=True, exist_ok=True)
    files = []
    for k, u in enumerate(urls):
        path = OUT / f"{name}_{k}.png"
        with urllib.request.urlopen(u, timeout=120) as r:
            path.write_bytes(r.read())
        files.append(path.name)
    log = {"probe": name, "input": str(pr["image"].relative_to(ROOT)), "resolution": pr["res"],
           "prompt": pr["prompt"], "negative": NEG, "revised_prompt": res.get("RevisedPrompt"),
           "details": res.get("ResultDetails"), "files": files, "seconds": round(time.time() - t0, 1),
           "request_id": res.get("RequestId")}
    (OUT / f"{name}.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), "utf-8")
    print(f"[OK] {name}: {files} ({log['seconds']}s)")


def run_3d(mod, token, image, faces=40000):
    """E4：标杆立绘 → 3D 模型（obj/glb），下载到 temp/explore/cloud/hero3d/。"""
    cfg = mod._PROVIDER_MAP["3d"]
    b64 = base64.b64encode(image.read_bytes()).decode()
    body = {"ImageBase64": b64, "Model": "3.1", "FaceCount": faces, "EnablePBR": False}
    t0 = time.time()
    sub = mod._call_api(mod._DEFAULT_ENDPOINT, cfg["provider"], cfg["service"], cfg["version"],
                        cfg["submit_action"], body, token)
    job = sub.get("JobId")
    res = mod._poll_job(mod._DEFAULT_ENDPOINT, cfg["provider"], cfg["service"], cfg["version"],
                        cfg["query_action"], job, token, 10, 900)
    out = OUT / "hero3d"
    out.mkdir(parents=True, exist_ok=True)
    files = []
    for k, f in enumerate(res.get("ResultFile3Ds") or []):
        for key, suffix in (("Url", ""), ("PreviewImageUrl", "_preview")):
            u = f.get(key)
            if not u:
                continue
            ext = Path(u.split("?")[0]).suffix or ".bin"
            path = out / f"{k}_{(f.get('Type') or 'file').lower()}{suffix}{ext}"
            with urllib.request.urlopen(u, timeout=300) as r:
                path.write_bytes(r.read())
            files.append(path.name)
    log = {"input": str(image.relative_to(ROOT)), "face_count": faces, "files": files,
           "seconds": round(time.time() - t0, 1), "request_id": res.get("RequestId")}
    (out / "job.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), "utf-8")
    print(f"[OK] 3d: {files} ({log['seconds']}s)")


def make_v6_ref():
    """V6 forehand 第 1 帧（READY）裁出单人，绿幕换成浅灰，作为标准身份参考图。"""
    from PIL import Image
    import numpy as np
    src = ROOT / 'art/animations/players/swordsman/v6/sources/forehand/Production_2D_action_RPG_anima_2026-10-14T08-17-58.png'
    a = np.asarray(Image.open(src).convert("RGB").crop((10, 40, 370, 450)), np.float32)
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    green = (g > 150) & (g > r * 1.35) & (g > b * 1.35)
    a[green] = (226, 226, 230)
    out = EXP / "probe_v6_ref.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(a.astype(np.uint8)).save(out)
    return out


def run_v3(mod, token, image_mode="b64"):
    """E5：混元生图 3.0（SubmitTextToImageJob）的 Images 参考图能否经代理调用、能否保持身份。"""
    ref = make_v6_ref()
    b64 = base64.b64encode(ref.read_bytes()).decode()
    img = {"b64": b64, "datauri": "data:image/png;base64," + b64}[image_mode]
    prompt = ("参考图中的角色，保持其发型、脸、服装、配色与绷带完全一致。画成同一角色的标准设定图："
              "正面站立，双臂自然下垂略张开（A 字站姿），不拿武器，全身完整，纯浅灰背景，无文字。"
              "韩式横版动作网游手绘风，清晰深色描边，赛璐璐明暗。")
    body = {"Prompt": prompt, "Images": [img], "Resolution": "768:1024", "LogoAdd": 0, "Revise": 0}
    provider = mod._PROVIDER_MAP["image"]["provider"]
    t0 = time.time()
    sub = mod._call_api(mod._DEFAULT_ENDPOINT, provider, "aiart", "2022-12-29", "SubmitTextToImageJob", body, token)
    job = sub.get("JobId")
    print("[INFO] submitted", job)
    res = mod._poll_job(mod._DEFAULT_ENDPOINT, provider, "aiart", "2022-12-29", "QueryTextToImageJob", job, token,
                        5, 600)
    urls = res.get("ResultImage") or []
    OUT.mkdir(parents=True, exist_ok=True)
    files = []
    for k, u in enumerate(urls if isinstance(urls, list) else [urls]):
        path = OUT / f"p5_v3_ref_{k}.png"
        with urllib.request.urlopen(u, timeout=120) as r:
            path.write_bytes(r.read())
        files.append(path.name)
    log = {"probe": "p5_v3_ref", "api": "aiart/SubmitTextToImageJob", "input": str(ref.relative_to(ROOT)),
           "image_mode": image_mode, "prompt": prompt, "revised_prompt": res.get("RevisedPrompt"),
           "files": files, "seconds": round(time.time() - t0, 1), "request_id": res.get("RequestId")}
    (OUT / "p5_v3_ref.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), "utf-8")
    print(f"[OK] p5_v3_ref: {files} ({log['seconds']}s)")


def main():
    token = os.environ.get("BUDDY_CLOUD_TOKEN", "")
    if not token:
        sys.exit("BUDDY_CLOUD_TOKEN missing")
    mod = load_client()
    names = sys.argv[1:] or list(PROBES)
    for name in names:
        try:
            if name == "hero3d":
                run_3d(mod, token, ROOT / 'art/concepts/characters/players/swordsman/legacy/hero_cool.png')
            elif name.startswith("v3ref"):
                run_v3(mod, token, "datauri" if name.endswith("_uri") else "b64")
            else:
                run(mod, name, token)
        except SystemExit:
            print(f"[FAIL] {name}（详见上方错误 JSON）")


if __name__ == "__main__":
    main()
