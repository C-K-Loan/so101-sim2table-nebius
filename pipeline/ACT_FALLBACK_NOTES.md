# ACT Fallback Notes

**Purpose**: Switch target from GR00T N1.7-3B to ACT if GR00T access or VRAM is blocked.
**Trigger**: either (a) HF access to `nvidia/GR00T-N1.7-3B` not granted in 30 min, (b) `nvidia/Cosmos-Reason2-2B` gate blocks GR00T startup, (c) OOM on L40S during GR00T fine-tune (unlikely at 48 GB but possible).

## ACT in one paragraph

**Action Chunking Transformer** (Tony Zhao et al. 2023, Aloha paper). An encoder-decoder transformer with a VAE latent prior that predicts a *chunk* of future actions from a short observation window. Each camera gets a ResNet18 encoder, images+state are concatenated as transformer tokens, the decoder outputs `chunk_size` future actions as a single tensor. At inference time you can either consume the whole chunk and re-query the policy every `n_action_steps`, or run temporal ensembling.

## Param count delta vs GR00T N1.7-3B

| Model | Params | Size on disk | Train VRAM (batch 8, chunk 16) |
|---|---|---|---|
| ACT (ResNet18 + 4e/1d transformer + VAE) | ~35-50M | ~200 MB | ~6-10 GB |
| GR00T N1.7-3B | ~3B | ~6 GB | ~25-40 GB (bf16, grad ckpt) |

- **~60-85x smaller**
- **~5-10x faster per step** (smaller model + no VLM backbone forward)
- **No HF gating** (public weights, Apache 2.0)
- **Fits on 3090 (24 GB)** if we ever need to bail out to CKL's home box

## What ACT loses

- Language conditioning (GR00T uses `annotation.human.task_description`; ACT doesn't natively consume text)
- Pre-training on NVIDIA's humanoid data (GR00T has a generalist prior; ACT trains from scratch per task)
- Larger model = better interpolation across unseen cube positions (for 300 episodes it may not matter)

For this challenge's single task (pick 30mm cube, place on green pad), the generalist prior is a nice-to-have, not a need-to-have. ACT is competitive.

## Dataset compat — zero changes needed

Starter's `so101_pickplace.lerobot_writer.LeRobotV21Writer` emits standard LeRobot v2.1 format:
- `meta/info.json` (codebase_version=v2.1, fps=30, video_keys=["observation.images.front", "observation.images.wrist"])
- `data/chunk-000/episode_XXXXXX.parquet` (joint state + action + timestamps)
- `videos/chunk-000/observation.images.<cam>/episode_XXXXXX.mp4`

ACT via `lerobot-train` reads this directly (no conversion). The GR00T modality config at `starter/gr00t/so101_sim_config.py` is GR00T-specific and ignored by ACT.

## Config knobs we match

- `chunk_size=16` to match GR00T's `ACTION_HORIZON=16` (ACT default is 100; too long for our 30 Hz, ~20 s episodes)
- `n_action_steps=16` consume full chunk between re-queries (same policy)
- `vision_backbone=resnet18` default, imagenet-pretrained
- `batch_size=8` safe on L40S with 2 cameras @ 256x256
- `steps=20000` typical for ACT on ~300 episodes, less if we overfit; `save_freq=5000`

## Install path on the Nebius VM

```bash
cd ~/nebius-arm-robot/lerobot
python3.11 -m venv .venv && source .venv/bin/activate
pip install -e ".[feetech,kinematics,dataset]"
# ACT needs no extra extras; the base install is enough
```

Does NOT need Isaac Teleop or CloudXR. Does NOT need huggingface auth.

## Switch procedure

1. Day-master (or CKL) says "pivot to ACT".
2. I run `act_fallback_train.sh` with `DATASET_ROOT` pointing to the actual collected sim+cosmos+real dataset.
3. Checkpoints land at `~/nebius-arm-robot/checkpoints/act/last/pretrained_model/`.
4. Serve with `lerobot-policy-server --policy.path=... --host=0.0.0.0 --port=5555`.
5. Eval against sim via starter's `eval.sh` adapted, OR use `lerobot-eval` directly against the sim env, OR deploy to real SO-101.

## Ensemble angle (free creativity pts)

Challenge rubric: 15 pts for "ensemble of models used."

- **If both GR00T AND ACT train**: run both at inference, vote on actions (median or weighted mean), submit that as main.
- **If only ACT trains**: run with vs without temporal ensembling (`temporal_ensemble_coeff=0.01`) and submit the better one as main.
- Either way: 15 pts eligible with 1 extra flag in the submission README.

## Risks

- `lerobot-train` CLI arg shape may have changed between versions — our script targets current main (commit cloned 2026-10-18). If args fail, consult `lerobot-train --help` on the VM.
- Local path dataset loading needs `--dataset.root=$PATH` AND `--dataset.repo_id=$PATH` (both set to the same local path per lerobot convention — tested in `lerobot/examples/`).
- First training step may stall briefly downloading ResNet18 ImageNet weights (~45 MB).

## File refs

- Train script: `act_fallback_train.sh` (adjacent)
- ACT config source: `lerobot/src/lerobot/policies/act/configuration_act.py`
- ACT model source: `lerobot/src/lerobot/policies/act/modeling_act.py`
- SO-101 example from LeRobot: `lerobot/examples/isaac_teleop_to_so101/README.md`
