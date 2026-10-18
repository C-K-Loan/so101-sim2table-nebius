# so101-sim2table-nebius

Sim-to-real pick-and-place on an SO-101 arm for the NVIDIA x Nebius AI Builders Hackathon, Berlin, 2026-10-18
(Physical AI track, "Sim to Table"). Solo entry by Christian Kasim Loan.

Pipeline: Isaac Sim scripted-expert data on a Nebius RTX PRO 6000 VM, NVIDIA Cosmos Transfer 2.5 for sim-to-real
appearance, Cosmos Reason2 for episode curation, GR00T N1.7-3B post-training, ZMQ policy serving, plus a full
SO-101 teleop toolchain for macOS written on the day. This README reports what worked, what did not, and the
hardware findings that cost most of the afternoon. Numbers below are the ones in the submitted form
(`docs/SUBMISSION.txt`).

## Results, honestly

| Item | Result |
|---|---|
| Sim episodes (Isaac Sim 6.1, Isaac Lab HEAD, scripted expert) | 100 episodes, 99/107 attempts succeeded (92.5 %), 40 min, 2 cameras, 30 Hz |
| Cosmos Transfer 2.5 (NIM, edge-conditioned) | 7 front-cam episodes re-rendered; qualitative sim-to-real look is convincing (`docs/cosmos_samples/`) |
| Cosmos Reason2 curation (NIM) | post-deadline re-run with real scores: kept 5/7 Cosmos episodes, 10/10 sim probes; JSON in `docs/` |
| Real teleop episodes in training | 0 (see hardware findings) |
| Policy | GR00T N1.7-3B, visual + projector + diffusion head tuned, LLM frozen, 1500 steps @ batch 16, loss 0.1605 -> 0.1296 in 878 s |
| Closed-loop sim eval | 0/10 successes, ~140 ms/step inference; all episodes timed out at 600 steps |
| Real-arm judge trials | not reached |

Why 0/10 in sim: the eval log shows `Failed to find rigid body .../Robot/joints/gripper`, so the gripper
command likely never actuated in the eval scene; and 1500 steps on a 3B model with 100 episodes is thin
(NVIDIA's recipe uses 4000). We chose the shorter run to make the deadline after losing time to the upstream
setup issues listed in `patches/NOTES.md`. The sim was also trained on a red cube while the real station
used a blue one.

The 8.5 GB full bundle (checkpoint shards, all data, 10 eval videos, logs) was served from the training VM at
submission time; see `docs/FULL_BUNDLE_URL.txt` for the URL and md5. That host is temporary. The small bundle
contents (README, manifests, metrics, checkpoint configs, two Cosmos samples, two eval clips) are in `docs/`.

## Repository layout

```
pipeline/    Cosmos Transfer wrapper, Cosmos Reason curator, NIM lifecycle, dataset merge, training launcher,
             ACT fallback, submission packaging
teleop/      macOS SO-101 toolchain: calibration/record/replay wrapper, browser recorder (+ backend with
             calibrated leader->follower mirroring), servo health and repair scripts
dashboard/   live hack-day dashboard (pipeline stage dots, dev diary); events.jsonl is the real diary
patches/     diffs against the starter repo and the workaround list for Isaac Lab HEAD
docs/        challenge spec, stack notes, submission text, manifests, Reason scores, eval metrics and log,
             checkpoint configs, Cosmos before/after samples
```

Starter repo (dependency, not vendored): https://github.com/ddiddi/so101-sim-pickplace-gr00t

## Reproduce

Prerequisites: a Nebius AI Cloud project with the `gpu-rtx6000-a` platform (Isaac Sim needs RT cores; H100/H200
do not work), a Hugging Face token with access to `nvidia/GR00T-N1.7-3B` and `nvidia/Cosmos-Reason2-2B`, and an
NGC API key for the Cosmos NIM containers. Keep all three in environment variables; nothing in this repo embeds them.

```bash
# 1. VM (from the starter repo)
NAME=so101-sim PLATFORM=gpu-rtx6000-a PRESET=1gpu-24vcpu-218gb DISK_GB=300 ./nebius/create_vm.sh
# 2. on the VM
bash nebius/setup_vm.sh            # then apply patches/ and the dep list in patches/NOTES.md
source env.sh && NUM_EPISODES=100 ./collect.sh
# 3. Cosmos (sequential: Transfer needs ~65 GB VRAM, Reason ~24 GB)
NGC_API_KEY=... ./pipeline/cosmos_nim_setup.sh login && ./pipeline/cosmos_nim_setup.sh pull
./pipeline/cosmos_run_pipeline.sh ~/datasets/local/so101_sim_pickplace
# 4. (optional) merge real teleop, then train
./pipeline/merge_real_teleop.sh <real_ds> <sim_ds> cosmos_reason_scores.json
./pipeline/train_launcher.sh main      # MAX_STEPS=1500 as submitted; 4000 is the recommended recipe
./start_server.sh && ./eval.sh --num_episodes 10
```

Teleop on a Mac (lerobot 0.4.4 with the `feetech` extra; see `patches/NOTES.md` for the two one-line lerobot
patches):

```bash
bash teleop/so101_run.sh calibrate <leader_port> <follower_port>   # type c at both prompts
bash teleop/so101_run.sh gapcheck     # read-only: pose gap, temps, fault flags, READY / NOT READY
bash teleop/so101_run.sh test         # 6 s lerobot self-test, PASS / FAIL
bash teleop/so101_run.sh record 10    # appends; -> next, <- redo, Esc stop and save
bash teleop/so101_run.sh ui           # browser recorder fallback (localhost only; camera via getUserMedia)
```

## Hardware findings: SO-101 / Feetech STS3215

Most of the hack day went into the follower arm dying under teleop with
`Failed to sync read 'Present_Position' ... There is no status packet!` while calibration (torque off) always
worked. Measured on two borrowed arm pairs with the scripts in `teleop/`. Treat the register numbers as what we
observed on these units, not as a datasheet.

1. **Our own mistake: register 19 (Unloading Condition).** A pre-record helper that was meant to "clear fault
   flags" wrote 0 to register 19 on every motor of both arms. On the STS3215 that register is the mask of
   conditions on which the servo cuts torque to protect itself (temperature, current, overload; factory 44).
   Writing 0 disabled that protection, and it is EEPROM, so it followed the arms when they were returned to the
   pool. One shoulder servo then ran to 95 C without unloading. `teleop/restore_protection.py` writes 44 back
   (and 70 C to register 13). Lesson in one line: read a servo register and cite its meaning before writing it.
2. **Wrist-roll multi-turn overflow.** The follower's wrist_roll reported position 33916 (later 33996) on a
   0..4095 encoder: accumulated turns. Calibration deliberately skips wrist_roll, so the leader and follower roll
   zeros were unrelated and lerobot's first goal write asked the roll to spin several turns at full current.
   Writing 128 to Torque_Enable (register 40) re-zeroes the motor at its current position and clears the
   accumulation (`teleop/fix_roll.py`). After that, both rolls read 2048 and the roll homing offsets in the
   calibration files were set to 0.
3. **Rail sag under simultaneous moves.** Follower bus voltage read 11.8 V idle, 9.6 V during an all-joint jump
   to the leader pose, 4.4 V during the wrist-roll jump alone. At 4.4 V the servo MCUs drop off the bus, which
   is the "no status packet" failure.
4. **Bus errors depended on which motor was driven.** Pair 1 follower: driving joints 1,3,4,5,6 gave 0/462 read
   errors; driving only joint 2 (shoulder_lift, the one that had overheated) gave 40/318; all six gave 17/384.
   Pair 2 follower, cold: 0/480 driving joint 2 and 0/456 driving all six. So a hot or stressed servo corrupts
   the shared bus, and a cold arm does not.
5. **What stayed unresolved.** With protection restored (44) the first lerobot step still tripped a servo
   (Overload / Overheat flag, then silence) whenever the leader and follower poses differed by hundreds of
   counts, even with `max_relative_target=30`. We did not get to measure whether 4 (temperature only) or 0 is
   the right setting for these rigs; a late attempt with 0 also failed, but that arm turned out to answer on zero
   motors (no motor power after a replug), so it does not count as evidence either way. The practical recipe
   that worked: calibrate both arms in the same pose so the first step is tiny, keep episodes short, let the
   follower rest between episodes, and check `gapcheck` before every session.
6. **Also real:** a shared 12 V supply across two arms, and a leader with a jammed, cable-wrapped wrist, both
   produce the same symptom.

Scripts: `teleop/restore_protection.py` (reg 19 and 13), `teleop/set_reg19.py` (experiment helper),
`teleop/fix_roll.py` (roll re-zero), `teleop/gapcheck.py` (pose gap, temps, flags), `teleop/prelaunch_align.py`
(gentle ramp onto the leader pose), `teleop/fix_arms.sh` (restore + health in one go).

## Nebius and NVIDIA usage

- Nebius AI Cloud: one `gpu-rtx6000-a / 1gpu-24vcpu-218gb` VM (RTX PRO 6000 Blackwell, 96 GB) in uk-south2 for
  Isaac Sim collection, both Cosmos NIM containers, GR00T post-training and policy serving.
- Nebius Object Storage: the bucket existed, but no S3 access key could be issued to the federated identity in
  time, so the bundle was served over HTTP from the VM and mirrored locally.
- NVIDIA: Isaac Sim 6.1 + Isaac Lab, Cosmos Transfer 2.5 and Cosmos Reason2 via NIM, GR00T N1.7-3B.

## Credits

Starter repo and challenge design by Dhruv Diddi (NVIDIA). Thanks to the NVIDIA and Nebius crews at the venue,
and to the team that lent a second arm pair.
