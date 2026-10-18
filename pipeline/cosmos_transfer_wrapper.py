"""Cosmos Transfer 2.5 wrapper for sim-to-real appearance bridging.

Endpoint: NVIDIA NIM container cosmos-transfer2.5-2b:1.2.0 running locally on the Nebius VM.
Default URL: http://localhost:8000/v1/infer
Requires 65.4 GB VRAM. Run SEQUENTIALLY with Reason (kill one before starting the other).

Modes:
  COSMOS_STUB=1   -> copies input to output, no API call (smoke-test file walk)
  default         -> real NIM call to COSMOS_TRANSFER_ENDPOINT
"""

from __future__ import annotations

import base64
import json
import os
import pathlib
import subprocess
import sys
import time

COSMOS_ENDPOINT = os.environ.get("COSMOS_TRANSFER_ENDPOINT", "http://localhost:8000/v1/infer")
TARGET_LOOK_PROMPT = os.environ.get("COSMOS_TARGET_PROMPT",
    "SO-101 arm on a lab table with soft overhead lighting, "
    "matte off-white table surface, 30mm red cube, green pad, "
    "camera mounted at standard height"
)
RESOLUTION = os.environ.get("COSMOS_RESOLUTION", "480")
CONTROL_WEIGHT = float(os.environ.get("COSMOS_EDGE_WEIGHT", "1.0"))
REQUEST_TIMEOUT = int(os.environ.get("COSMOS_TIMEOUT", "900"))

# NIM gotcha: 93-480 frames @ 1280x720 required. ffmpeg-pads/crops as needed.
NIM_WIDTH = 1280
NIM_HEIGHT = 720
NIM_MIN_FRAMES = 93
NIM_MAX_FRAMES = 480


def normalize_video(src: str, dst: str, fps: int = 30) -> int:
    """Resize + frame-cap input to NIM constraints. Returns frame count."""
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-count_packets", "-show_entries", "stream=nb_read_packets",
         "-of", "csv=p=0", src], capture_output=True, text=True, check=True)
    try:
        frames = int(probe.stdout.strip())
    except ValueError:
        frames = 0

    # Cap frames; pad short clips with last frame via tpad
    vf_filters = [
        f"scale={NIM_WIDTH}:{NIM_HEIGHT}:force_original_aspect_ratio=decrease",
        f"pad={NIM_WIDTH}:{NIM_HEIGHT}:(ow-iw)/2:(oh-ih)/2:color=black",
    ]
    if frames < NIM_MIN_FRAMES:
        pad = NIM_MIN_FRAMES - frames + 1
        vf_filters.append(f"tpad=stop_mode=clone:stop_duration={pad / fps:.3f}")
    cmd = [
        "ffmpeg", "-y", "-i", src,
        "-vf", ",".join(vf_filters),
        "-frames:v", str(min(NIM_MAX_FRAMES, max(NIM_MIN_FRAMES, frames))),
        "-r", str(fps),
        "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
        dst,
    ]
    subprocess.run(cmd, check=True, capture_output=True)
    return min(NIM_MAX_FRAMES, max(NIM_MIN_FRAMES, frames))


def extract_edge_canny(video_path: str, out_path: str) -> None:
    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-vf", "edgedetect=low=0.1:high=0.4",
        "-c:v", "libx264", "-preset", "fast", "-pix_fmt", "yuv420p",
        out_path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def _b64(path: str) -> str:
    return base64.b64encode(pathlib.Path(path).read_bytes()).decode("ascii")


def call_cosmos_transfer(sim_video: str, edge_video: str, out_video: str, prompt: str = TARGET_LOOK_PROMPT) -> dict:
    t0 = time.time()
    if os.environ.get("COSMOS_STUB") == "1":
        pathlib.Path(out_video).parent.mkdir(parents=True, exist_ok=True)
        import shutil
        shutil.copy(sim_video, out_video)
        return {"output_path": out_video, "duration_s": time.time() - t0, "stub": True}

    import requests  # imported lazily so stub mode has no dep
    payload = {
        "prompt": prompt,
        "video": "data:video/mp4;base64," + _b64(sim_video),
        "resolution": RESOLUTION,
        "edge": {
            "control_weight": CONTROL_WEIGHT,
            "control": "data:video/mp4;base64," + _b64(edge_video),
        },
    }
    r = requests.post(COSMOS_ENDPOINT, json=payload, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    body = r.json()
    b64_out = body.get("b64_video") or body.get("video") or ""
    if not b64_out:
        raise RuntimeError(f"NIM returned no video in response: {list(body.keys())}")
    if b64_out.startswith("data:"):
        b64_out = b64_out.split(",", 1)[1]
    pathlib.Path(out_video).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(out_video).write_bytes(base64.b64decode(b64_out))
    return {
        "output_path": out_video,
        "duration_s": time.time() - t0,
        "resolution": RESOLUTION,
        "endpoint": COSMOS_ENDPOINT,
    }


def batch_transfer(dataset_root: str, output_root: str, limit: int | None = None) -> list[dict]:
    """Walk a LeRobot v2.1 dataset, normalize + re-render each episode's camera videos.
    Writes results next to originals under output_root/<episode_id>/.
    """
    results = []
    dataset = pathlib.Path(dataset_root)
    output = pathlib.Path(output_root)
    output.mkdir(parents=True, exist_ok=True)
    videos = sorted(v for v in dataset.rglob("*.mp4") if ".edge" not in v.stem and ".norm" not in v.stem)
    if limit:
        videos = videos[:limit]
    for i, video in enumerate(videos):
        print(f"[{i+1}/{len(videos)}] {video.relative_to(dataset)}")
        rel = video.relative_to(dataset)
        norm_tmp = output / rel.with_suffix(".norm.mp4")
        edge_tmp = output / rel.with_suffix(".edge.mp4")
        out = output / rel
        norm_tmp.parent.mkdir(parents=True, exist_ok=True)
        try:
            if os.environ.get("COSMOS_STUB") != "1":
                normalize_video(str(video), str(norm_tmp))
                extract_edge_canny(str(norm_tmp), str(edge_tmp))
                src = str(norm_tmp)
            else:
                extract_edge_canny(str(video), str(edge_tmp))
                src = str(video)
            res = call_cosmos_transfer(src, str(edge_tmp), str(out))
            results.append({"source": str(video), **res})
        except Exception as e:
            print(f"  FAIL: {e}")
            results.append({"source": str(video), "error": str(e)})
    (output / "transfer_manifest.json").write_text(json.dumps(results, indent=2))
    return results


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: cosmos_transfer_wrapper.py <sim_dataset_root> [output_root] [limit]")
        print("  if output_root omitted, defaults to <sim_dataset_root>.cosmos")
        sys.exit(1)
    sim_ds = sys.argv[1].rstrip("/")
    out_ds = sys.argv[2].rstrip("/") if len(sys.argv) > 2 else f"{sim_ds}.cosmos"
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else None
    if pathlib.Path(sim_ds).resolve() == pathlib.Path(out_ds).resolve():
        print(f"REFUSED: output_root == sim_dataset_root ({sim_ds}) - would overwrite source", file=sys.stderr)
        sys.exit(2)
    print(f"sim:    {sim_ds}")
    print(f"cosmos: {out_ds}")
    batch_transfer(sim_ds, out_ds, limit=limit)
