#!/usr/bin/env python3
"""Minimal recording backend for SO-101 teleop sessions.
Polls servos, saves parquet + webm (converted to mp4) via browser upload.
Listens on 127.0.0.1:8779."""
import json, pathlib, subprocess, threading, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

try:
    from scservo_sdk import PortHandler, PacketHandler
except ImportError:
    PortHandler = PacketHandler = None

LEADER_PORT = "/dev/tty.usbmodem5C821100701"
FOLLOWER_PORT = "/dev/tty.usbmodem5C821087081"
DATASET_ROOT = pathlib.Path.home() / ".cache/huggingface/lerobot/local/so101_realteleop_ui"
VIDEOS_DIR = DATASET_ROOT / "videos/chunk-000/observation.images.top"
DATA_DIR = DATASET_ROOT / "data/chunk-000"
META_DIR = DATASET_ROOT / "meta"
for d in (VIDEOS_DIR, DATA_DIR, META_DIR):
    d.mkdir(parents=True, exist_ok=True)

state_lock = threading.Lock()
cached_state = {
    "leader_positions": [None]*6, "follower_positions": [None]*6,
    "leader_torques": [None]*6, "follower_torques": [None]*6,
    "leader_ok": False, "follower_ok": False,
    "status": "idle", "episode_idx": 0, "episode_count": 0,
    "last_frame_ts": 0, "poll_errors": 0, "mirror": False,
}
record_lock = threading.Lock()
record_buffer = []
serial_lock = threading.Lock()
CAL_L = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration/teleoperators/so_leader/orange_teleop.json"
CAL_F = pathlib.Path.home() / ".cache/huggingface/lerobot/calibration/robots/so_follower/orange_robot.json"
def _load_ranges(path):
    d = json.loads(pathlib.Path(path).read_text())
    mn, mx = [0]*6, [4095]*6
    for name, m in d.items():
        i = int(m["id"]) - 1
        mn[i], mx[i] = int(m["range_min"]), int(m["range_max"])
    return mn, mx
try:
    LMIN, LMAX = _load_ranges(CAL_L); FMIN, FMAX = _load_ranges(CAL_F); CAL_OK = True
except Exception as _e:
    print(f"calibration load failed: {_e}"); LMIN, LMAX, FMIN, FMAX, CAL_OK = [0]*6, [4095]*6, [0]*6, [4095]*6, False
mirror_on = False
OVERRIDE = pathlib.Path.home() / ".so101_leader_override.json"
if OVERRIDE.exists():
    for k, (mn, mx) in json.loads(OVERRIDE.read_text()).items():
        LMIN[int(k)-1], LMAX[int(k)-1] = int(mn), int(mx)
print("leader ranges:", list(zip(LMIN, LMAX)))
def leader_to_follower(lpos):
    goals = []
    for i, lp in enumerate(lpos):
        if lp is None: goals.append(None); continue
        span = max(1, LMAX[i] - LMIN[i])
        n = min(1.0, max(0.0, (lp - LMIN[i]) / span))
        g = int(round(FMIN[i] + n * (FMAX[i] - FMIN[i])))
        goals.append(max(FMIN[i], min(FMAX[i], g)))
    return goals
def set_mirror(on):
    global mirror_on
    if follower_ph is None: return False
    with serial_lock:
        for sid in range(1, 7):
            pk.write1ByteTxRx(follower_ph, sid, 40, 1 if on else 0)
    mirror_on = bool(on)
    with state_lock: cached_state["mirror"] = mirror_on
    return True


leader_ph = follower_ph = pk = None

def init_serial():
    global leader_ph, follower_ph, pk
    if PortHandler is None:
        return False
    try:
        pk = PacketHandler(0)
        leader_ph = PortHandler(LEADER_PORT); leader_ph.openPort(); leader_ph.setBaudRate(1000000)
        follower_ph = PortHandler(FOLLOWER_PORT); follower_ph.openPort(); follower_ph.setBaudRate(1000000)
        return True
    except Exception as e:
        print(f"serial init: {e}")
        return False

_cycle = 0
def read_all(ph, with_torque=False):
    positions, torques, ok = [None]*6, [None]*6, True
    try:
        from scservo_sdk import GroupSyncRead
        gsr = GroupSyncRead(ph, pk, 56, 2)
        for sid in range(1, 7): gsr.addParam(sid)
        if gsr.txRxPacket() != 0: ok = False
        for sid in range(1, 7):
            if gsr.isAvailable(sid, 56, 2): positions[sid-1] = gsr.getData(sid, 56, 2)
            else: ok = False
        gsr.clearParam()
        if with_torque:
            for sid in range(1, 7):
                te, r2, _ = pk.read1ByteTxRx(ph, sid, 40)
                torques[sid-1] = te if r2 == 0 else None
    except Exception:
        ok = False
    return positions, torques, ok

def poller():
    while True:
        if not leader_ph or not follower_ph:
            time.sleep(1); continue
        try:
            global _cycle
            _cycle += 1
            slow = (_cycle % 15 == 0)
            with serial_lock:
                l_pos, l_torq, l_ok = read_all(leader_ph, with_torque=slow)
                if mirror_on and l_ok:
                    try:
                        from scservo_sdk import GroupSyncWrite
                        gsw = GroupSyncWrite(follower_ph, pk, 42, 2)
                        goals = leader_to_follower(l_pos)
                        last = globals().setdefault("_last_goals", [None]*6)
                        for i, g in enumerate(goals):
                            if g is None: continue
                            if last[i] is not None and abs(g - last[i]) < 4:
                                continue  # deadband: ignore leader jitter
                            last[i] = g
                            gsw.addParam(i + 1, [g & 0xFF, (g >> 8) & 0xFF])
                        gsw.txPacket()
                    except Exception:
                        for i, g in enumerate(leader_to_follower(l_pos)):
                            if g is not None:
                                pk.write2ByteTxRx(follower_ph, i + 1, 42, g)
                f_pos, f_torq, f_ok = read_all(follower_ph, with_torque=slow)
                if mirror_on and slow:
                    for sid in (2, 3):
                        tmp, rt, _ = pk.read1ByteTxRx(follower_ph, sid, 63)
                        if rt == 0 and tmp >= 90:
                            for k in range(1, 7): pk.write1ByteTxRx(follower_ph, k, 40, 0)
                            globals()["mirror_on"] = False
                            with state_lock: cached_state["mirror"] = False; cached_state["temp_trip"] = f"motor{sid}={tmp}C"
                            print(f"TEMP GUARD: motor {sid} at {tmp}C, torque cut")
            now = time.time()
            with state_lock:
                cached_state["leader_positions"] = l_pos
                cached_state["follower_positions"] = f_pos
                if slow:
                    cached_state["leader_torques"] = l_torq
                    cached_state["follower_torques"] = f_torq
                cached_state["leader_ok"] = l_ok
                cached_state["follower_ok"] = f_ok
                cached_state["last_frame_ts"] = now
                rec = cached_state["status"] == "recording"
            if rec:
                with record_lock:
                    record_buffer.append({"ts": now, "leader": l_pos, "follower": f_pos})
                time.sleep(1/30.0)
            else:
                time.sleep(1/30.0 if mirror_on else 0.1)
        except Exception:
            with state_lock:
                cached_state["poll_errors"] += 1
            time.sleep(0.2)

def count_existing_episodes():
    if not DATA_DIR.exists(): return 0
    return len(list(DATA_DIR.glob("episode_*.parquet")))

def write_episode_parquet(idx, buf):
    try:
        import pyarrow as pa, pyarrow.parquet as pq
    except ImportError:
        return False
    if not buf: return False
    t0 = buf[0]["ts"]
    rows = [{"episode_index": idx, "frame_index": i, "timestamp": b["ts"]-t0,
             "observation.state": b["follower"], "action": b["leader"],
             "task_index": 0, "index": i} for i, b in enumerate(buf)]
    pq.write_table(pa.Table.from_pylist(rows), DATA_DIR / f"episode_{idx:06d}.parquet")
    return True

def convert_webm_to_mp4(webm, mp4):
    try:
        subprocess.run(["ffmpeg","-y","-i",str(webm),"-c:v","libx264","-preset","veryfast","-pix_fmt","yuv420p",str(mp4)], check=True, capture_output=True, timeout=90)
        return True
    except Exception as e:
        print(f"ffmpeg fail: {e}")
        return False

def write_meta():
    count = count_existing_episodes()
    info = {
        "codebase_version": "v2.1", "robot_type": "so101_follower",
        "total_episodes": count, "fps": 30, "chunks_size": 1000,
        "features": {
            "observation.state": {"dtype": "float32", "shape": [6]},
            "action": {"dtype": "float32", "shape": [6]},
            "observation.images.top": {"dtype": "video", "shape": [480, 640, 3]},
        },
        "robot_source": "record-ui backend v0.1",
    }
    (META_DIR / "info.json").write_text(json.dumps(info, indent=2))
    (META_DIR / "tasks.jsonl").write_text(
        json.dumps({"task_index": 0, "task": "pick up the blue cube and place it on the green pad"}) + "\n"
    )

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()
        if isinstance(body, str): body = body.encode()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(200, "")

    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/state":
            with state_lock: st = dict(cached_state)
            self._send(200, json.dumps(st))
        elif p == "/dataset_info":
            self._send(200, json.dumps({
                "dataset_path": str(DATASET_ROOT),
                "episode_count": count_existing_episodes(),
                "videos_dir": str(VIDEOS_DIR),
                "data_dir": str(DATA_DIR),
            }))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", 0))
        if parsed.path == "/start_episode":
            with state_lock:
                if cached_state["status"] == "recording":
                    return self._send(400, json.dumps({"error": "already recording"}))
                idx = count_existing_episodes()
                cached_state["status"] = "recording"
                cached_state["episode_idx"] = idx
            with record_lock: record_buffer.clear()
            set_mirror(True)
            self._send(200, json.dumps({"episode_idx": idx, "mirror": mirror_on}))
        elif parsed.path == "/stop_episode":
            with state_lock:
                if cached_state["status"] != "recording":
                    return self._send(400, json.dumps({"error": "not recording"}))
                cached_state["status"] = "idle"
                idx = cached_state["episode_idx"]
            with record_lock: buf = list(record_buffer)
            ok = write_episode_parquet(idx, buf)
            write_meta()
            set_mirror(False)
            self._send(200, json.dumps({"episode_idx": idx, "frames": len(buf), "parquet_ok": ok}))
        elif parsed.path == "/mirror":
            q = parse_qs(parsed.query)
            on = q.get("on", ["1"])[0] in ("1", "true", "on")
            ok = set_mirror(on)
            self._send(200, json.dumps({"mirror": mirror_on, "ok": ok, "cal_ok": CAL_OK}))
        elif parsed.path == "/jog":
            q = parse_qs(parsed.query)
            arm = q.get("arm", ["follower"])[0]
            delta = int(q.get("delta", ["150"])[0])
            joints = [int(j) for j in q.get("joints", ["2,3"])[0].split(",")]
            hold = float(q.get("hold", ["0.6"])[0])
            ph = follower_ph if arm == "follower" else leader_ph
            if ph is None:
                return self._send(500, json.dumps({"error": "serial unavailable"}))
            delta = max(-300, min(300, delta))
            before, after = {}, {}
            with serial_lock:
                for sid in joints:
                    pos, r, _ = pk.read2ByteTxRx(ph, sid, 56)
                    if r != 0: continue
                    before[sid] = pos
                    pk.write1ByteTxRx(ph, sid, 40, 1)
                    pk.write2ByteTxRx(ph, sid, 42, max(0, min(4095, pos + delta)))
                time.sleep(hold)
                for sid, pos in before.items():
                    pk.write2ByteTxRx(ph, sid, 42, pos)
                time.sleep(hold)
                for sid in before:
                    p2, r, _ = pk.read2ByteTxRx(ph, sid, 56)
                    after[sid] = p2 if r == 0 else None
                    pk.write1ByteTxRx(ph, sid, 40, 0)
            self._send(200, json.dumps({"arm": arm, "delta": delta, "before": before, "after": after}))
        elif parsed.path == "/upload_video":
            q = parse_qs(parsed.query)
            idx = int(q.get("idx", ["0"])[0])
            webm = VIDEOS_DIR / f"episode_{idx:06d}.webm"
            mp4 = VIDEOS_DIR / f"episode_{idx:06d}.mp4"
            with open(webm, "wb") as f:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(1024*1024, remaining))
                    if not chunk: break
                    f.write(chunk); remaining -= len(chunk)
            ok_mp4 = convert_webm_to_mp4(webm, mp4)
            self._send(200, json.dumps({"webm_size": webm.stat().st_size, "mp4_ok": ok_mp4}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *a, **k): pass

def main():
    if not init_serial():
        print("WARN: serial unavailable, running state-less")
    threading.Thread(target=poller, daemon=True).start()
    httpd = HTTPServer(("127.0.0.1", 8779), H)
    print("record_backend listening on http://127.0.0.1:8779")
    httpd.serve_forever()

if __name__ == "__main__":
    main()
