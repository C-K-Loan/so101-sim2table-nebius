#!/bin/bash
# Merge a real-teleop LeRobot v2.1 dataset into the curated sim+Cosmos dataset.
# Produces one unified LeRobot v2.1 dataset with per-source counts in dataset_manifest.json,
# then re-runs starter/prepare_dataset.sh for GR00T stats.
#
# Usage:
#   ./merge_real_teleop.sh <real_dataset_dir> <base_dataset_dir> [cosmos_scores.json]
#
# <real_dataset_dir>: LeRobot v2.1 dir with real teleop episodes
# <base_dataset_dir>: LeRobot v2.1 dir with sim_raw + cosmos_augmented episodes (output of
#                     cosmos_run_pipeline.sh after curation drop)
# <cosmos_scores.json>: path to cosmos_reason_scores.json for the curation decision + drop list
#
# Operates by Python helper that:
#   - reads base's meta/info.json, episodes.jsonl
#   - copies real episode videos+parquets with offset episode_index
#   - updates meta/info.json totals + meta/episodes.jsonl
#   - writes dataset_manifest.json with per-source counts
#   - calls prepare_dataset.sh for stats regen

set -euo pipefail

REAL_DS="${1:?usage: $0 <real_dataset_dir> <base_dataset_dir> [cosmos_scores.json]}"
BASE_DS="${2:?usage: $0 <real_dataset_dir> <base_dataset_dir> [cosmos_scores.json]}"
COSMOS_SCORES="${3:-}"
STARTER_DIR="${STARTER_DIR:-/home/ubuntu/work/IsaacLab/so101_sim_pickplace}"

[[ -d "$REAL_DS" ]] || { echo "ERROR: real dataset $REAL_DS not found" >&2; exit 1; }
[[ -d "$BASE_DS" ]] || { echo "ERROR: base dataset $BASE_DS not found" >&2; exit 1; }

MERGED_DS="${BASE_DS%.cosmos}.merged"
echo "=== merge target: $MERGED_DS ==="
rm -rf "$MERGED_DS"
cp -r "$BASE_DS" "$MERGED_DS"

echo "=== Python merge (append real episodes with offset) ==="
python3 <<PY
import json, pathlib, shutil, re

real = pathlib.Path("$REAL_DS")
base = pathlib.Path("$MERGED_DS")
scores_path = pathlib.Path("$COSMOS_SCORES") if "$COSMOS_SCORES" else None

# --- load base info ---
info_path = base / "meta" / "info.json"
info = json.load(info_path.open())
total_before = info.get("total_episodes", 0)
offset = total_before
print(f"base episodes: {total_before}")

# --- apply cosmos curation drop if scores provided ---
dropped_eps = set()
if scores_path and scores_path.exists():
    s = json.load(scores_path.open())
    for ep_id in s.get("dropped", []):
        # ep_id like "observation.images.front/episode_000003" - grab the trailing index
        m = re.search(r"episode_(\d+)", ep_id)
        if m:
            dropped_eps.add(int(m.group(1)))
    print(f"curation drops (base indices): {sorted(dropped_eps)}")

# --- walk real episodes ---
real_eps = sorted(real.rglob("episode_*.mp4"))
real_eps_ids = sorted({int(re.search(r"episode_(\d+)", p.stem).group(1)) for p in real_eps if re.search(r"episode_(\d+)", p.stem)})
print(f"real episodes to merge: {len(real_eps_ids)}")

# --- copy real episodes with new indices ---
new_idx = offset
mapping = {}
for old_idx in real_eps_ids:
    new = f"episode_{new_idx:06d}"
    old = f"episode_{old_idx:06d}"
    mapping[old_idx] = new_idx
    # copy videos (front, wrist)
    for src in real.rglob(f"{old}.mp4"):
        rel = src.relative_to(real)
        dst = base / rel.parent / f"{new}.mp4"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, dst)
    # copy parquet
    for src in real.rglob(f"{old}.parquet"):
        rel = src.relative_to(real)
        dst = base / rel.parent / f"{new}.parquet"
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, dst)
    new_idx += 1

# --- update meta/episodes.jsonl ---
real_eps_jsonl = real / "meta" / "episodes.jsonl"
base_eps_jsonl = base / "meta" / "episodes.jsonl"
if real_eps_jsonl.exists() and base_eps_jsonl.exists():
    with real_eps_jsonl.open() as f, base_eps_jsonl.open("a") as g:
        for line in f:
            d = json.loads(line)
            old_i = d.get("episode_index")
            if old_i in mapping:
                d["episode_index"] = mapping[old_i]
                g.write(json.dumps(d) + "\n")

# --- apply drops: remove dropped base episodes from episodes.jsonl ---
# Note: We leave the parquet/mp4 files on disk; the training loader indexes via episodes.jsonl.
if dropped_eps:
    tmp = base / "meta" / "episodes.jsonl.tmp"
    with base_eps_jsonl.open() as f, tmp.open("w") as g:
        for line in f:
            d = json.loads(line)
            if d.get("episode_index") not in dropped_eps:
                g.write(line)
    tmp.replace(base_eps_jsonl)

# --- update meta/info.json totals ---
total_after = sum(1 for _ in base_eps_jsonl.open())
info["total_episodes"] = total_after
json.dump(info, info_path.open("w"), indent=2)
print(f"total episodes after merge+drop: {total_after}")

# --- write dataset_manifest.json with per-source counts ---
manifest = {
    "sim_raw_count": total_before - len(dropped_eps),  # approximation; refine with meta if sim had subcategories
    "cosmos_augmented_count": 0,  # already overwrote sim videos in-place during Cosmos Transfer; count rolled into sim_raw
    "real_teleop_count": len(real_eps_ids),
    "cosmos_curation_dropped": len(dropped_eps),
    "total_episodes": total_after,
    "notes": "sim_raw count includes Cosmos-augmented re-renders (motion/actions preserved, appearance only). Drops applied via meta/episodes.jsonl removal; parquet/mp4 files remain on disk for recovery.",
}
if scores_path and scores_path.exists():
    s = json.load(scores_path.open())
    manifest["stated_curation_decision"] = s.get("stated_curation_decision", "")
    manifest["cosmos_reason_model"] = s.get("model", "")
(base / "dataset_manifest.json").write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
PY

echo ""
echo "=== re-run prepare_dataset.sh for stats regen ==="
cd "$STARTER_DIR"
export DATASET_ROOT="$MERGED_DS"
./prepare_dataset.sh 2>&1 | tail -20

echo ""
echo "=== DONE ==="
echo "merged dataset:   $MERGED_DS"
echo "manifest:         $MERGED_DS/dataset_manifest.json"
