# Patches and workarounds applied on the Nebius VM (Isaac Lab HEAD, 2026-10-18)

The starter repo (`ddiddi/so101-sim-pickplace-gr00t`) was authored against an older Isaac Lab snapshot.
Running its `nebius/setup_vm.sh` on a fresh `ubuntu24.04-cuda13.0` VM with Isaac Lab HEAD needed the
following, in order. Each one surfaced as a crash of `collect.sh`.

1. `isaaclab.sh --install` does not exist on Isaac Lab HEAD. Install the editable packages instead:
   `pip install -e source/isaaclab source/isaaclab_assets source/isaaclab_tasks source/isaaclab_rl
   source/isaaclab_mimic source/isaaclab_teleop source/isaaclab_newton source/isaaclab_physx
   source/isaaclab_ov source/isaaclab_contrib source/isaaclab_experimental source/isaaclab_ppisp
   source/isaaclab_tasks_experimental source/isaaclab_visualizers` (14 subpackages).
2. Missing runtime deps after the editable installs: `lazy_loader rich pyyaml h5py matplotlib scipy
   pyperclip trimesh usd-core onnx opencv-python-headless onnxruntime hidapi warp-lang`.
3. Isaac Lab API drift: `base_mdp.image(data_type="rgb")` became `base_mdp.image_rgb`.
   See `0002-isaaclab-image-rgb-api-drift.patch`.
4. `newton` 1.5.0 -> 1.7.0 (`ClampingBase` import). isaacsim-core pins newton 1.5 but it is a warning only.
5. `env.sh` paths for a Nebius VM layout and the policy port: 5555 is taken by `nv-hostengine` on the
   Nebius image, so the ZMQ policy server moved to 5556. See `0001-env-sh-nebius-paths-and-port.patch`.
6. `setup_vm.sh` uses `&&` chains under `set -e`, so a failed `git checkout v3.0.0` did not stop the
   script; Isaac-GR00T and the task package ended up nested inside `IsaacLab/`. Functional, but check paths.
7. Cosmos NIM health endpoint is `/v1/health/ready` (and `/v1/health/live`), not `/v1/health`.
   `pipeline/cosmos_run_pipeline.sh` waits on the correct one.
8. Cosmos Reason NIM crashed on vLLM engine init once; `--shm-size=32g` fixed it.

## Mac-side lerobot patches (teleop host, macOS, lerobot 0.4.4)

- `lerobot/robots/so_follower/so_follower.py` and `lerobot/teleoperators/so_leader/so_leader.py`:
  `sync_read("Present_Position")` -> `sync_read("Present_Position", num_retry=5)`. One corrupt packet
  no longer ends a recording session.
- Workshop `so101_check_calibration.py` imports `lerobot.robots.so101_follower`; in 0.4.4 the module is
  `lerobot.robots.so_follower`. Calibration files land in `.../calibration/robots/so_follower/`; a symlink
  `so101_follower -> so_follower` keeps the checker happy.
- `scservo_sdk` `LATENCY_TIMER` 16 -> 60 was tried and reverted; it changed nothing.
