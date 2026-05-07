"""
emg_live_plot.py
────────────────────────────────────────────────────────────
EMG 실시간 그래프 + CSV 저장
- ESP32 WebSocket 서버(포트 81)에 접속
- emg_raw, RMS, MDF를 실시간 그래프로 표시
- 동시에 CSV 파일로 저장 (data/ 폴더)

사용법:
  1. ESP32_IP 를 본인 환경에 맞게 수정
  2. pip install websocket-client matplotlib numpy
  3. python emg_live_plot.py
  4. 창 닫으면 자동 저장 종료

펌웨어가 1초에 1번 메시지를 보냅니다 (raw, rms, mdf 모두 1 Hz).
"""

import csv
import json
import threading
import time
from collections import deque
from datetime import datetime
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import websocket  # websocket-client


# ───────────────────────────────────────────────────────────
# 설정
# ───────────────────────────────────────────────────────────
ESP32_IP   = "172.20.10.11"   # 시리얼 모니터에서 확인한 IP
                                # mDNS는 macOS Python에서 잘 안 풀려서 IP 권장
ESP32_PORT = 81
WS_URL     = f"ws://{ESP32_IP}:{ESP32_PORT}"

# 표시할 시간 윈도우 (초). 펌웨어가 1 Hz로 보내므로 이 값 = 점 개수.
PLOT_WINDOW_SEC = 60

# CSV 저장 경로 (스크립트 위치 기준)
DATA_DIR = Path(__file__).resolve().parent / "data"
DATA_DIR.mkdir(exist_ok=True)
CSV_PATH = DATA_DIR / f"emg_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"


# ───────────────────────────────────────────────────────────
# 공유 버퍼 (WebSocket 스레드 ↔ 그래프 스레드)
# ───────────────────────────────────────────────────────────
t_buf   = deque(maxlen=PLOT_WINDOW_SEC)
env_buf = deque(maxlen=PLOT_WINDOW_SEC)
rms_buf = deque(maxlen=PLOT_WINDOW_SEC)
mdf_buf = deque(maxlen=PLOT_WINDOW_SEC)

status = {
    "is_running": False,
    "is_stimulating": False,
    "fatigue_detected": False,
    "rms_slope": 0.0,
    "mdf_slope": 0.0,
}

stop_flag = threading.Event()

# 메인 스레드(키 입력)에서 ws 인스턴스에 접근하기 위한 홀더
ws_holder: dict = {"ws": None}


# ───────────────────────────────────────────────────────────
# WebSocket 수신 스레드
# ───────────────────────────────────────────────────────────
def ws_thread():
    csv_file = open(CSV_PATH, "w", newline="")
    writer = csv.writer(csv_file)
    writer.writerow([
        "wall_time", "timestamp_ms", "emg_raw", "emg_env", "rms", "mdf",
        "rms_slope", "mdf_slope", "fatigue_detected",
        "is_running", "is_stimulating",
        "baseline_rms", "rms_ratio", "muscle_state",
    ])
    csv_file.flush()
    csv_lock = threading.Lock()

    def on_message(_ws, message):
        try:
            data = json.loads(message)
        except json.JSONDecodeError:
            print(f"[parse error] non-JSON: {message[:80]!r}")
            return

        if data.get("type") != "data":
            print(f"[info] {data}")
            return

        ts  = data.get("timestamp_ms")
        raw = data.get("emg_raw")
        env = data.get("emg_env")
        rms = data.get("rms")
        mdf = data.get("mdf")

        if ts is None:
            return

        t_buf.append(ts / 1000.0)
        env_buf.append(env if env is not None else raw)
        if rms is not None:
            rms_buf.append(rms)
        if mdf is not None:
            mdf_buf.append(mdf)

        for key in status:
            if key in data:
                status[key] = data[key]

        with csv_lock:
            writer.writerow([
                datetime.now().isoformat(timespec="milliseconds"),
                ts, raw, env, rms, mdf,
                data.get("rms_slope"), data.get("mdf_slope"),
                data.get("fatigue_detected"),
                data.get("is_running"), data.get("is_stimulating"),
                data.get("baseline_rms"), data.get("rms_ratio"),
                data.get("muscle_state"),
            ])
            csv_file.flush()

    def on_error(_ws, error):
        print(f"[ws error] {error}")

    def on_close(_ws, code, msg):
        print(f"[ws closed] {code} {msg}")

    def on_open(ws):
        ws_holder["ws"] = ws
        print(f"[ws open] connected to {WS_URL}")
        print(f"[csv]    saving to {CSV_PATH}")

    while not stop_flag.is_set():
        try:
            ws = websocket.WebSocketApp(
                WS_URL,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close,
            )
            ws.run_forever()
        except Exception as e:
            print(f"[reconnect] {e}")

        ws_holder["ws"] = None
        if stop_flag.is_set():
            break
        time.sleep(2)

    csv_file.close()


def send_cmd(payload: dict) -> None:
    ws = ws_holder["ws"]
    if ws is None:
        print("[cmd] ws not connected")
        return
    try:
        ws.send(json.dumps(payload))
        print(f"→ sent {payload}")
    except Exception as e:
        print(f"[cmd error] {e}")


# ───────────────────────────────────────────────────────────
# 메인: matplotlib 라이브 플롯
# ───────────────────────────────────────────────────────────
def main():
    th = threading.Thread(target=ws_thread, daemon=True)
    th.start()

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 7.5), sharex=True)
    fig.suptitle(f"EMG Live  ({WS_URL})", fontsize=12)
    fig.text(
        0.5, 0.005,
        "[s]start  [x]stop  [e]emergency  [c]calibrate  "
        "[1]marker:easy  [2]:medium  [3]:hard  [q]quit",
        ha="center", fontsize=9, color="#475569",
    )

    line_env, = ax1.plot([], [], lw=1.2, marker=".", color="#2563eb")
    ax1.set_ylabel("EMG envelope")
    ax1.set_ylim(0, 4095)
    ax1.grid(alpha=0.3)

    line_rms, = ax2.plot([], [], lw=1.5, marker=".", color="#16a34a")
    ax2.set_ylabel("RMS")
    ax2.grid(alpha=0.3)

    line_mdf, = ax3.plot([], [], lw=1.5, marker=".", color="#dc2626")
    ax3.set_ylabel("MDF (Hz)")
    ax3.set_xlabel("time (s)")
    ax3.grid(alpha=0.3)

    plt.tight_layout()

    def update():
        if not t_buf:
            return
        t_arr = np.array(t_buf)
        t0 = t_arr[-1] - PLOT_WINDOW_SEC

        def fit(ax, line, ydeq, ymin=None, ymax=None):
            if not ydeq:
                return
            n = min(len(t_arr), len(ydeq))
            x = t_arr[-n:]
            y = np.array(list(ydeq)[-n:])
            line.set_data(x, y)
            ax.set_xlim(t0, t_arr[-1] + 0.5)
            if ymin is None:
                lo, hi = float(y.min()), float(y.max())
                pad = max((hi - lo) * 0.15, 1e-3)
                ax.set_ylim(lo - pad, hi + pad)
            else:
                ax.set_ylim(ymin, ymax)

        fit(ax1, line_env, env_buf, ymin=0, ymax=4095)
        fit(ax2, line_rms, rms_buf)
        fit(ax3, line_mdf, mdf_buf)

        flags = []
        if status["is_running"]:
            flags.append("RUN")
        if status["is_stimulating"]:
            flags.append("STIM")
        if status["fatigue_detected"]:
            flags.append(
                f"FATIGUE rms+{status['rms_slope']:.1f}% mdf{status['mdf_slope']:+.1f}%"
            )
        title = f"EMG Live  ({WS_URL})"
        if flags:
            title += "   " + "  ".join(flags)
        fig.suptitle(title, fontsize=12)

        fig.canvas.draw_idle()

    timer = fig.canvas.new_timer(interval=200)  # 5 fps (펌웨어가 1 Hz)
    timer.add_callback(update)
    timer.start()

    key_to_cmd = {
        "s": {"cmd": "start"},
        "x": {"cmd": "stop"},
        "e": {"cmd": "emergency"},
        "c": {"cmd": "calibrate"},
        "1": {"cmd": "marker", "label": "easy"},
        "2": {"cmd": "marker", "label": "medium"},
        "3": {"cmd": "marker", "label": "hard"},
    }

    def on_key(event):
        if event.key == "q":
            plt.close(event.canvas.figure)
            return
        cmd = key_to_cmd.get(event.key)
        if cmd is not None:
            send_cmd(cmd)

    fig.canvas.mpl_connect("key_press_event", on_key)

    try:
        plt.show()
    finally:
        stop_flag.set()
        ws = ws_holder["ws"]
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass
        print("[main] stopped, csv saved.")


if __name__ == "__main__":
    main()
