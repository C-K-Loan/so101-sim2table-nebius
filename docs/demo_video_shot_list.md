# 2-Minute Demo Video Shot List

**Deadline**: 18:30 submission to Devpost / hackathon platform
**Length**: <=2 min (hackathon rule)
**Tool**: OBS screen cap on your laptop + phone cam for the real arm trial

## Shot sequence

| Time | Shot | What |
|---|---|---|
| 0:00-0:10 | Title card | "Sim to Table: GR00T N1.7 + Cosmos on Nebius L40S. Team: ckl-solo." |
| 0:10-0:25 | Isaac Sim window | Scripted expert picking cube, 5 fast cuts, "100 sim episodes in 20 min" overlay |
| 0:25-0:45 | Side-by-side | LEFT: raw sim video. RIGHT: Cosmos Transfer re-rendered. "Same motion, real look." |
| 0:45-1:00 | Cosmos Reason output | Terminal scroll of `cosmos_reason_scores.json`, highlight the one curation decision |
| 1:00-1:15 | Dataset manifest | Flash `dataset_manifest.json` — sim/cosmos/real counts, 300 cap |
| 1:15-1:30 | Nebius training | Nebius Cloud UI showing L40S VM, loss curve going down, "4000 steps, GR00T N1.7-3B" |
| 1:30-1:50 | REAL ARM TRIAL (phone cam) | 1 full pick-and-place attempt on the SO-101. Show cube at edge of grid for drama. Include ANY attempt, success optional. |
| 1:50-2:00 | Scoreboard + call to action | "Main vs ablation (no Cosmos) results side-by-side. Repo + checkpoints: github.com/..., HuggingFace: ..." |

## Capture now, edit later

- [ ] Record Isaac Sim scripted expert as soon as collect.sh runs
- [ ] Record terminal output of each pipeline stage
- [ ] Phone cam ready at SO-101 station — tape it to a water bottle for stability
- [ ] Grab 1 clean before/after Cosmos frame for the side-by-side
- [ ] Loss curve screenshot during finetune
- [ ] Submission folder tree screenshot

## Backup plan if real arm fails every attempt

Keep the real-arm shot even if cube drops. Overlay: "0/3 real success. Here's what went wrong, here's the ablation delta that proves Cosmos helps." Honesty > fake success.

## Tools

- OBS Studio (install `brew install --cask obs` or apt)
- Phone cam, portrait or landscape, YouTube Shorts tier
- CapCut mobile for 30-min edit after submission freeze
- Upload to YouTube unlisted, paste link in submission form
