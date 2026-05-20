"""
EMG-FES 데이터 로거

ESP32 WebSocket 서버(port 81)에 연결해 EMG 데이터를 CSV로 저장합니다.
키보드로 start/stop/marker 등 명령 전송도 가능합니다.

사용 예:
    python emg_logger.py --host 172.20.10.5 --subject A
    python emg_logger.py --host 172.20.10.5 --subject A --session rest_day1

명령 (실행 중 stdin):
    s   → start (자극 시작)
    x   → stop
    e   → emergency
    c   → calibrate
    m <label> → 마커 추가 (예: "m hard")
    q   → 종료
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import base64
import json
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path

import websockets


GITHUB_REPO = "chaerinyeon/emg-fes-project"


def upload_to_github(csv_path: Path, subject: str, repo_path: str) -> None:
    """CSV를 gh API로 GitHub에 직접 업로드. 로컬엔 안 남김."""
    if not csv_path.exists() or csv_path.stat().st_size <= 200:
        print(f"[gh] skip — CSV가 비어 있음: {csv_path.name}")
        return
    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    msg = f"data: subject {subject} session {csv_path.stem} ({stamp})"
    content_b64 = base64.b64encode(csv_path.read_bytes()).decode()
    try:
        subprocess.run(
            [
                "gh", "api",
                f"repos/{GITHUB_REPO}/contents/{repo_path}",
                "--method", "PUT",
                "-f", f"message={msg}",
                "-f", f"content={content_b64}",
            ],
            check=True,
            capture_output=True,
        )
        print(f"[gh] ✅ uploaded to {GITHUB_REPO}:{repo_path}")
    except subprocess.CalledProcessError as e:
        err = e.stderr.decode() if e.stderr else str(e)
        print(f"[gh] ⚠️ 업로드 실패: {err}", file=sys.stderr)
    finally:
        try:
            csv_path.unlink()
            print(f"[gh] 🗑️ 로컬 임시 파일 삭제: {csv_path}")
        except OSError:
            pass

FIELDS = [
    "wall_time",
    "timestamp_ms",
    "emg_raw",
    "rms",
    "mdf",
    "rms_slope",
    "mdf_slope",
    "fatigue_detected",
    "is_running",
    "is_stimulating",
    "history_count",
    "marker",
]


def make_csv_path(subject: str, session: str | None) -> tuple[Path, str]:
    """임시 CSV 경로(/tmp)와 GitHub 리포 내 상대 경로를 반환."""
    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    name = f"{stamp}_{session}.csv" if session else f"{stamp}.csv"
    tmp_dir = Path(tempfile.gettempdir())
    local_path = tmp_dir / f"emg_{subject}_{name}"
    repo_path = f"data/subject_{subject}/{name}"
    return local_path, repo_path


async def receive_loop(ws, writer, csv_file) -> None:
    async for raw in ws:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError:
            print(f"[warn] non-JSON: {raw!r}", file=sys.stderr)
            continue

        if msg.get("type") != "data":
            print(f"[info] {msg}")
            continue

        row = {k: msg.get(k, "") for k in FIELDS}
        row["wall_time"] = datetime.now().isoformat(timespec="milliseconds")
        writer.writerow(row)
        csv_file.flush()

        if msg.get("fatigue_detected"):
            print(
                f"⚠️  fatigue! rms_slope=+{msg['rms_slope']:.1f}%  "
                f"mdf_slope={msg['mdf_slope']:.1f}%"
            )


async def stdin_loop(ws) -> None:
    loop = asyncio.get_running_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue

        cmd = None
        if line == "s":
            cmd = {"cmd": "start"}
        elif line == "x":
            cmd = {"cmd": "stop"}
        elif line == "e":
            cmd = {"cmd": "emergency"}
        elif line == "c":
            cmd = {"cmd": "calibrate"}
        elif line.startswith("m "):
            cmd = {"cmd": "marker", "label": line[2:].strip()}
        elif line == "q":
            await ws.close()
            return
        else:
            print(f"[?] unknown: {line}")
            continue

        await ws.send(json.dumps(cmd))
        print(f"→ sent {cmd}")


async def run(host: str, port: int, subject: str, session: str | None) -> None:
    uri = f"ws://{host}:{port}"
    csv_path, repo_path = make_csv_path(subject, session)
    print(f"connecting to {uri}")
    print(f"buffering to {csv_path} (임시)")
    print(f"will upload to {GITHUB_REPO}:{repo_path}")
    print("commands: s=start  x=stop  e=emergency  c=calibrate  m <label>=marker  q=quit")

    try:
        with csv_path.open("w", newline="") as csv_file:
            writer = csv.DictWriter(csv_file, fieldnames=FIELDS)
            writer.writeheader()

            async with websockets.connect(uri, ping_interval=20) as ws:
                print("✅ connected")
                recv_task = asyncio.create_task(receive_loop(ws, writer, csv_file))
                input_task = asyncio.create_task(stdin_loop(ws))
                done, pending = await asyncio.wait(
                    {recv_task, input_task}, return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                for task in done:
                    exc = task.exception()
                    if exc:
                        raise exc
    finally:
        upload_to_github(csv_path, subject, repo_path)


def main() -> None:
    ap = argparse.ArgumentParser(description="EMG-FES WebSocket logger")
    ap.add_argument("--host", required=True, help="ESP32 IP address")
    ap.add_argument("--port", type=int, default=81)
    ap.add_argument("--subject", required=True, help="피험자 ID (A, B, C ...)")
    ap.add_argument("--session", default=None, help="세션 라벨 (파일명에 추가)")
    args = ap.parse_args()

    try:
        asyncio.run(run(args.host, args.port, args.subject, args.session))
    except KeyboardInterrupt:
        print("\n중단됨")


if __name__ == "__main__":
    main()
