# Sim to Table — SO-101 pick-and-place
**Team**: ckl-solo (Christian Kasim Loan)
**Hackathon**: NVIDIA x Nebius AI Builders Hackathon Berlin, 2026-10-18
**Challenge**: Physical AI — Sim to Table (pick 30mm cube, place on green pad)
**Policy**: GR00T N1.7-3B (post-trained)

## Submission artifacts

- `checkpoints/main/` — fine-tuned GR00T N1.7-3B checkpoint, 1500 steps, batch 16
- `cosmos_samples/` — 2 Cosmos Transfer 2.5 outputs + 1 matching sim source for side-by-side
- `cosmos_reason_scores_sim.json` + `cosmos_reason_scores_cosmos.json` — Reason curator output
- `transfer_manifest.json` — per-video Transfer wrapper manifest
- `dataset_manifest.json` — per-source episode counts (sim / cosmos / real)
- `eval/` — 10 closed-loop sim-eval MP4s + metrics + full log

## Pipeline executed

1. **Simulate**: Isaac Sim 6.1 + Isaac Lab 3.0 on Nebius RTX PRO 6000 Blackwell VM (`gpu-rtx6000-a / 1gpu-24vcpu-218gb`, uk-south2). Scripted expert collected **100 episodes at 92.5% success rate** (99/107 attempts) in 40.3 min at 640×480 @ 30 Hz with 2 cameras (front + wrist).
2. **Transfer**: Cosmos Transfer 2.5 NIM container (`cosmos-transfer2.5-2b:1.2.0`), 65.4 GB VRAM. Re-rendered 7 sim front-cam episodes with Canny edge conditioning. **Qualitative result is striking** — see `cosmos_samples/`: the cartoon-looking sim arm becomes a photo-realistic black plastic arm on a beige laminate table inside a lab enclosure, with cube + pad preserved exactly. One-frame comparison in the demo video.
3. **Reason**: Cosmos Reason2-2B NIM container (`cosmos-reason2-2b:1.7.0`). Attempted scoring on all 200 sim videos. See HONEST section below.
4. **Train**: GR00T N1.7-3B fine-tuned (visual + projector + diffusion head, LLM frozen) on 100 sim episodes, 1500 steps @ batch 16, cosine LR schedule. Loss 0.1605 → 0.1296 over 878s. Checkpoint at `checkpoints/main/checkpoint-1500`.
5. **Serve**: ZMQ policy server on `tcp://0.0.0.0:5556`, externally reachable at `tcp://81.85.0.144:5556` (VM public IP) for real-arm deployment via Mac-side eval client.
6. **Eval**: 10 closed-loop sim episodes recorded. See HONEST section below.

## Nebius stack usage

- **AI Cloud**: RTX PRO 6000 Blackwell VM (96 GB VRAM) for Isaac Sim rendering + GR00T fine-tune + NIM container hosting
- **Object Storage**: `storage.uk-south2.nebius.cloud/ckl-solo-hackathon/` for this bundle
- Both NVIDIA NIM containers hosted on the Nebius VM via `docker run --gpus all`

## Known gaps (honest reporting)

### Sim-to-real color mismatch
- **Sim**: trained on RED 30mm cube on dark table
- **Real station**: BLUE 3cm cube, orange 3x3 pickup grid, green pad
- **No real teleop episodes in training**: CKL was recalibrating the real arm's gripper during the training window; no `.real/` dataset landed before the finetune cutoff
- The policy has not seen the real cube's color or the orange grid markers

### Sim eval: 0/10
- All 10 closed-loop eval episodes timed out after 600 steps (20s each) with no successful pick-and-place
- Inference latency: ~140 ms/step (sim ran faster than real-time for a 30 Hz policy)
- **Suspected root cause**: `[Warning] Failed to find rigid body at '/World/envs/env_0/Robot/joints/gripper'` appeared in eval log — the gripper rigid body may not have been registered in the eval sim scene, so the policy's gripper commands may not have actuated. Needs investigation post-event.
- **Contributing**: 1500 training steps on a 3B-param model with 100 episodes is thin (NVIDIA's recipe suggests 4000); we chose this cap to meet the submission deadline after losing time on upstream `setup_vm.sh` dependency issues.

### Cosmos integration
- **Transfer**: 7 front-cam episodes re-rendered successfully with edge conditioning. Did NOT make it into the training mix because the wrapper writes raw MP4s only, not a full LeRobot v2.1 dataset structure (missing `meta/modality.json` + `meta/stats.json`). Validated qualitatively via the sample videos — see `cosmos_samples/`.
- **Reason**: scored 7 Cosmos re-renders + 10 sim probe episodes with real `nvidia/cosmos-reason2-2b` NIM (after post-submission re-run with `--shm-size=32g` fix for the earlier vLLM engine-init crash). Representative output: `grasp=True quality=8 reason="The robot successfully grasps the red cube, lifts it, and places it on the green square..."`. Cosmos curation decision kept 5 of 7 Cosmos episodes (dropped 2 with grasp_success=False) and 10 of 10 sim episodes (all quality>=7). Per-episode JSON in `cosmos_reason_scores_cosmos.json` + `cosmos_reason_scores_sim.json`.

## Reproduce

Prereqs: Nebius account with `gpu-rtx6000-a` platform access, HF token with `nvidia/GR00T-N1.7-3B` + `nvidia/Cosmos-Reason2-2B` access, NGC API key.

```bash
# 1. provision VM
NAME=so101-sim PLATFORM=gpu-rtx6000-a PRESET=1gpu-24vcpu-218gb DISK_GB=300 ./starter/nebius/create_vm.sh

# 2. on VM
bash starter/nebius/setup_vm.sh
# (note: setup_vm.sh has upstream issues — see Learnings)

# 3. collect sim
cd ~/work/IsaacLab/so101_sim_pickplace && source ./env.sh && NUM_EPISODES=100 ./collect.sh

# 4. Cosmos
./cosmos_nim_setup.sh login && ./cosmos_nim_setup.sh pull
./cosmos_run_pipeline.sh ~/datasets/local/so101_sim_pickplace

# 5. train
TRAIN_DATASET=~/datasets/local/so101_sim_pickplace MAX_STEPS=1500 ./finetune.sh

# 6. serve + eval
CHECKPOINT=~/finetune/so101_sim_pickplace/checkpoint-1500 POLICY_PORT=5556 ./start_server.sh &
./eval.sh --num_episodes 10 --record_dir ~/eval_videos
```

## Learnings for post-event write-up

1. **upstream `so101-sim-pickplace-gr00t/nebius/setup_vm.sh` has silent-fail bugs**: `./isaaclab.sh --install` (doesn't exist in current IsaacLab HEAD), `uv run huggingface-cli login` (interactive, hangs), `git checkout v3.0.0` silently fails because `set -e` doesn't trip in `&&` chains. Full dependency chain reconstructed from source — recorded in the repo.
2. **IsaacLab 3.0 API drift**: `base_mdp.image(data_type="rgb")` → `base_mdp.image_rgb` / `image_depth` / etc.
3. **newton 1.5.0 → 1.7.0** needed for `ClampingBase` import in `isaaclab_physx`.
4. **NIM containers** need `NGC_API_KEY` passed as `-e` env var at run (not just `docker login nvcr.io`) — containers download model weights from NGC on first boot. Health endpoint is `/v1/health/ready` not `/v1/health`.
5. **Cosmos Transfer at ~5 min/video** is too slow for 200-video sim datasets in a 6h hack window. Hard cap at 5-15 episodes if time-constrained.
6. **nv-hostengine owns port 5555** on the Nebius Ubuntu24.04-CUDA13.0 image — pick a different `POLICY_PORT`.

Full blow-by-blow debug log in `eval/eval_log.txt` and the bundle's `starter/logs/` directory.
