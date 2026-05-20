#!/usr/bin/env python3
"""
EMG WebSocket 데이터 수집기

ESP32에서 WebSocket으로 받는 데이터를 CSV로 저장.
세션마다 자동으로 새 파일 생성.
"""

import asyncio
import websockets
import csv
import json
import datetime
import os
import sys
from pathlib import Path

# ===== 설정 =====
ESP32_IP = os.getenv("ESP32_IP", "172.20.10.11")    # 환경변수 또는 기본값
ESP32_PORT = 81

SUBJECT = os.getenv("SUBJECT", "A")
DATA_DIR = Path(__file__).parent.parent / "data" / f"subject_{SUBJECT}"

CSV_COLUMNS = [
    'timestamp_ms', 'emg_raw', 'rms', 'mdf',
    'rms_slope', 'mdf_slope', 'fatigue_detected',
    'is_running', 'is_stimulating', 'marker'
]


def make_session_filename():
    now = datetime.datetime.now()
    timestamp = now.strftime("%Y%m%d_%H%M%S")
    return DATA_DIR / f"S_{timestamp}.csv"


def make_notes_filename(csv_path):
    return csv_path.with_suffix('.md')


def write_notes_template(notes_path):
    template = f"""# Session Notes

- **Session ID**: {notes_path.stem}
- **Subject**: {SUBJECT}
- **Date**: {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
- **Muscle**: 좌측 전완 FDS (Flexor Digitorum Superficialis)
- **Task**: Repetitive hand grip (1Hz)
- **External load**: (악력기 사용 시 기록)

## Timeline

- 00:00 측정 시작
- 00:30 캘리브레이션 시작
- 01:00 피로 유발 시작
- ??:?? "여기서부터 힘들다" 신호
- ??:?? 한계점

## Subjective

- 최대 피로도: ?/10

## Notes

(특이사항)
"""
    notes_path.write_text(template, encoding='utf-8')


async def receive_and_log():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    
    csv_path = make_session_filename()
    notes_path = make_notes_filename(csv_path)
    
    write_notes_template(notes_path)
    
    print(f"📁 데이터 저장: {csv_path}")
    print(f"📝 메모 템플릿: {notes_path}")
    print(f"🔗 ESP32 연결 중: ws://{ESP32_IP}:{ESP32_PORT}")
    
    uri = f"ws://{ESP32_IP}:{ESP32_PORT}"
    
    try:
        async with websockets.connect(uri) as ws:
            print("✅ 연결 성공! 데이터 수신 시작 (Ctrl+C로 종료)\n")
            
            with open(csv_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
                writer.writeheader()
                
                count = 0
                async for message in ws:
                    try:
                        data = json.loads(message)
                        if data.get('type') != 'data':
                            continue
                        
                        row = {col: data.get(col, '') for col in CSV_COLUMNS}
                        writer.writerow(row)
                        f.flush()
                        
                        count += 1
                        if count % 5 == 0:
                            print(f"\r수신: {count} | "
                                  f"RMS: {data.get('rms', 0):.1f} | "
                                  f"MDF: {data.get('mdf', 0):.1f}Hz | "
                                  f"FI: RMS{data.get('rms_slope', 0):+.1f}% / "
                                  f"MDF{data.get('mdf_slope', 0):+.1f}%",
                                  end='', flush=True)
                    
                    except json.JSONDecodeError:
                        print(f"⚠️ JSON 파싱 실패")
                    except Exception as e:
                        print(f"⚠️ 에러: {e}")
    
    except KeyboardInterrupt:
        print("\n\n⏹  사용자 중단")
    except Exception as e:
        print(f"\n❌ 연결 에러: {e}")
        sys.exit(1)
    
    print(f"\n✅ 저장 완료: {csv_path}")
    print(f"📝 메모 작성: {notes_path}")


if __name__ == "__main__":
    asyncio.run(receive_and_log())