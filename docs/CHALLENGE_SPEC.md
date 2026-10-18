# Sim to Table - Official Challenge Spec

**Event**: NVIDIA × NEBIUS AI Builders Hackathon, Berlin, 2026-10-18
**Challenge**: Physical AI - train in sim, bridge with Cosmos, teleop on real SO-101 arms, evaluate in real world

## Task

| Task | Robot | Scored on |
|---|---|---|
| Pick the 30 mm cube, place it on the pad | SO-101 arm | 3 autonomous trials on your arm, run by a judge |

## The 5-stage pipeline

| Stage | Where | What | Output |
|---|---|---|---|
| 1. Simulate | Isaac Sim (Nebius VM) | Scripted expert collects pick-and-place episodes at scale | 100s of sim episodes |
| 2. Transfer | Cosmos Transfer 2.5 + Cosmos 3 Reasoner | Re-render sim clips to real-world appearance (structure-preserving, actions unchanged). Reason scores + curates | Cosmos-augmented episodes + curation JSON |
| 3. Teleop | Your SO-101 leader/follower pair | Record real demonstrations with the leader arm | Few real episodes |
| 4. Train | Nebius GPU VM | Train one ACT or GR00T policy on mixed sim + Cosmos + real + an ablation without Cosmos | Two checkpoints |
| 5. Evaluate | Real SO-101 | Self-evaluate both checkpoints. Judges run the main checkpoint on the same arm | Real-world success count |

## Why this shape

Sim alone fails on hardware (one light, one table, one renderer). Real data alone is starved. Cosmos is the bridge: turns sim data into data that looks like reality so sim episodes actually help the real policy. Rules are set so the BRIDGE, not raw teleop volume, decides the leaderboard.

## Data rules

- Real teleop capped at **50 episodes**
- Main checkpoint MUST include sim-derived data (raw sim and/or Cosmos-augmented)
- Dataset manifest MUST list episode counts per source
- Total dataset cap: **300 episodes**
- Policy: **ACT or GR00T**

## Judging (100 pts)

Every team has a dedicated station: SO-101 leader/follower pair, camera on standard mount, lamp, 30 mm cube, green pad, 9-spot cube grid taped to table. Judges control ONE thing: cube placement - they place it on grid spots in a fixed sequence identical for every team, revealed only at eval time. A policy that only learned one spot will fail most of them.

| Criterion | Pts | How scored |
|---|---|---|
| Accuracy (real-world success) | 30 | 3 judge-run trials on real SO-101, 2 min cap each. 10 pts per success. Success = cube released + at rest on green pad. Leaderboard shows x / 3. |
| Cosmos - meaningful use | 20 | 10 for Reason: called on your own sim/real videos, JSON saved, one stated curation decision made from it. 10 for Transfer: structure-preserving augmentation of sim data toward real look. |
| Nebius | 20 | Usage of Nebius Cloud for training |
| Technical competence | 15 | Be able to deploy on the robot IRL |
| Creativity | 15 | Ensemble of models used |

## How Cosmos + Nebius should be used

**Cosmos Transfer 2.5**: bridge. Re-render sim episodes so lighting/table/textures look like real world while geometry + motion stay fixed, so recorded actions remain valid. Use **edge conditioning** - preserves structure, keeps actions aligned. Target the look of your real station.

**Cosmos 3 Reason**: curator. Point it at sim + real episode MP4s to score (did the grasp succeed, was the motion clean). Drop bad episodes before training.

**Nebius Object Storage**: submission channel at `https://storage.<region>.nebius.cloud`. Your folder lands there by the cutoff or it doesn't exist.

## Submission

- 17:30 submission cutoff (data + manifest + checkpoints + README to Nebius Object Storage)
- 18:30 extended for video
- Global Devpost dual-submit deadline: Oct 30 ($20K grand prize pool)

## References

- Starter repo: https://github.com/ddiddi/so101-sim-pickplace-gr00t
- Train an SO-101 Robot From Sim-to-Real With NVIDIA Isaac
- Calibrating the SO-101
- Nebius Token Factory quickstart
- NVIDIA Skills: https://github.com/NVIDIA/skills
