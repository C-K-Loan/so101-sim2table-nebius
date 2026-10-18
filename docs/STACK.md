# Robot Arm Challenge — Stack Explained

**Date**: 2026-10-18 (today, hack day)
**Challenge**: Sim to Table — SO-101 pick 30mm cube, place on green pad
**Scored on**: 3 judge-run real-arm trials (10 pts each) + Cosmos use (20) + Nebius Cloud use (20) + tech (15) + creativity ensemble (15) = 100

## The 5 pieces of the stack

### 1. Isaac Sim (NVIDIA simulator)
Virtual robot in a virtual room. You run a hardcoded "scripted expert" policy that knows how to pick-and-place, and record thousands of (camera frames, joint angles, action) tuples = "episodes." Cheap and infinite data. Looks fake though — one light, one table, one renderer.

### 2. Cosmos Transfer 2.5 (NVIDIA video model)
Re-renders your sim videos to look like the real world. Takes the sim video + edge/structure conditioning → outputs same geometry/motion but with real lighting, real-looking table, real textures. Actions stay valid because geometry is preserved. **This is the sim-to-real bridge.**

### 3. Cosmos 3 Reasoner (NVIDIA vision-language model)
Watches your videos and scores them. "Did the grasp succeed? Was the motion clean?" Outputs JSON. You use it to drop bad episodes before training.

### 4. SO-101 arm (TheRobotStudio open hardware)
Physical 6-DOF robot arm, ~$300 open-source. Comes as a **leader + follower pair**: you move the leader by hand, the follower mimics in real-time, cameras record. Dataset entry per timestep = (front cam, wrist cam, joint positions, gripper state). Real but data-limited (max 50 teleop episodes per challenge rule).

### 5. GR00T N1.7-3B (NVIDIA foundation model)
3B-param robot foundation model pre-trained by NVIDIA. You post-train (fine-tune) it on your mixed sim + Cosmos + real dataset. 4000 steps @ batch 16. Alternative: ACT (lighter, faster). Challenge rules allow either. **Starter repo uses GR00T.**

## The pipeline (what the starter does)

```
Isaac Sim scripted expert
  → 50-300 sim episodes (LeRobot v2.1 format)
     → Cosmos Transfer 2.5 (re-render to real-look)
        → Cosmos 3 Reasoner (curate, drop bad)
           → mix with 10-50 real teleop episodes
              → finetune GR00T N1.7-3B (4000 steps)
                 → ZeroMQ policy server
                    → closed-loop eval in sim
                       → deploy to real SO-101 for judge trial
```

**Starter repo**: `https://github.com/ddiddi/so101-sim-pickplace-gr00t` (Dhruv Diddi, Physical AI workshop lead = challenge author)
**Already cloned**: `~/nebius-arm-robot/starter/`
**Nebius provisioner included**: `starter/nebius/create_vm.sh` + `setup_vm.sh`

## Nebius VM requirements (CRITICAL)

- **GPU**: L40S or RTX PRO 6000 (RT cores required for Isaac Sim rendering)
- **NOT**: H100 / H200 (no RT cores, Isaac Sim renders wrong)
- **Preset**: `1gpu-16vcpu-96gb`
- **Disk**: 300 GB SSD (Isaac Sim ~150 GB install)
- **Image**: `ubuntu24.04-cuda13.0`
- **Region**: eu-north1 for L40S-d (closest to Berlin)
- **VRAM**: ≥48 GB to finetune GR00T N1.7-3B comfortably

## Credits burn plan (don't spend own money)

- Challenge award: $1000 Cloud + $1000 TF credits
- Nebius dedicated tenant: incoming from CKL (sponsor-provisioned)
- L40S hourly cost: expect ~$1-3/hr → full 6h run = well under $100
- Cosmos API cost: unclear, ask SA
- **Rule**: all compute goes on hackathon credits. New profile only. Zero charges to the old `nebius-sa` serviceaccount tenant.

## Gated model access needed

- `nvidia/GR00T-N1.7-3B` weights (HF)
- `nvidia/Cosmos-Reason2-2B` backbone (gated HF)
- Need `huggingface-cli login` on the VM

## Judging-point mapping (100 pts)

| Pts | What | How to earn |
|---|---|---|
| 30 | Real-world success | 3 trials × 10 pts, success = cube on pad |
| 10 | Cosmos Reason | Call it on your videos, save JSON, state 1 curation decision |
| 10 | Cosmos Transfer | Augment sim data with edge-conditioned re-render |
| 20 | Nebius Cloud | Train on Nebius VM, documented |
| 15 | Tech competence | Deploy on real arm |
| 15 | Creativity | Ensemble of models (ACT + GR00T? sim + Cosmos-augmented + real?) |

**Realistic solo-6h target**: 20 (Cosmos) + 20 (Nebius) + 15 (deploy) + 15 (ensemble) + 0-10 (1 real success if lucky) = **70-80 pts out of 100 WITHOUT any real-arm success.** Not winning, but respectable finish.

## What's NOT in the starter (we add)

- Cosmos Transfer 2.5 integration — must build this
- Cosmos 3 Reasoner call + curation JSON — must build this
- Dataset manifest listing episode counts per source — must build
- ACT policy variant (if we want the ensemble) — must add

## Open questions for CKL / mentors

1. New Nebius tenant ID + API key — awaiting from CKL
2. Cosmos API access path — Token Factory? Dedicated endpoint? Ask Dhruv on-site
3. Station assignment — when does CKL get his SO-101 slot?
4. HF access to gated Cosmos-Reason2-2B — token confirmed?
5. Isaac Sim 6.1 license acceptance — handled in setup_vm.sh?
