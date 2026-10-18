"""Generate a dummy LeRobot v2.1-ish dataset to smoke-test Cosmos wrappers before the real sim runs.

Not valid LeRobot structure, just enough MP4 files that cosmos_transfer_wrapper.py
and cosmos_reason_curator.py can walk them without erroring.

Usage: python gen_dummy_dataset.py <out_dir> [num_episodes]
"""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import time


def gen_dummy_mp4(path: str, duration: int = 10, color: str = "red") -> None:
    """ffmpeg: synth short color-moving video."""
    cmd = [
        "ffmpeg", "-y",
        "-f", "lavfi",
        "-i", f"testsrc=duration={duration}:size=256x256:rate=30",
        "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p",
        path,
    ]
    subprocess.run(cmd, check=True, capture_output=True)


def main(out_dir: str, num: int = 3) -> None:
    root = pathlib.Path(out_dir)
    (root / "videos/chunk-000/observation.images.front").mkdir(parents=True, exist_ok=True)
    (root / "videos/chunk-000/observation.images.wrist").mkdir(parents=True, exist_ok=True)
    (root / "data/chunk-000").mkdir(parents=True, exist_ok=True)
    (root / "meta").mkdir(parents=True, exist_ok=True)

    for i in range(num):
        ep = f"episode_{i:06d}.mp4"
        front = root / "videos/chunk-000/observation.images.front" / ep
        wrist = root / "videos/chunk-000/observation.images.wrist" / ep
        print(f"[{i+1}/{num}] generating {ep}")
        gen_dummy_mp4(str(front))
        gen_dummy_mp4(str(wrist))

    (root / "meta/info.json").write_text(json.dumps({
        "codebase_version": "v2.1",
        "robot_type": "so101",
        "total_episodes": num,
        "total_frames": num * 300,
        "fps": 30,
        "chunks_size": 1000,
        "video_keys": ["observation.images.front", "observation.images.wrist"],
        "dummy": True,
        "generated_at": time.time(),
    }, indent=2))

    (root / "meta/tasks.jsonl").write_text(
        json.dumps({"task_index": 0, "task": "pick up the red block and place it on the green pad"}) + "\n"
    )

    print(f"\nDone. {num*2} dummy MP4s written under {root}")
    print(f"Smoke-test:")
    print(f"  python cosmos_transfer_wrapper.py {root} {root}.cosmos 3")
    print(f"  python cosmos_reason_curator.py {root} /tmp/scores.json")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/dummy_dataset", int(sys.argv[2]) if len(sys.argv) > 2 else 3)
