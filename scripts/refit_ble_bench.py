#!/usr/bin/env python3
"""
refit_ble_bench.py — RE:FIT Phase 1 BLE 벤치 테스트 도구
==========================================================
펌웨어(firmware/emg_fes_controller/emg_fes_controller.ino)의 바이너리 프로토콜 v0.2 를
그대로 구현. 계약 원문은 docs/RE-FIT_BLE_Protocol_v0.2.md.
UP(notify) 패킷을 디코드해 콘솔에 찍고, DOWN(write)으로 세션제어/JUDGMENT/HEARTBEAT 주입.
이 스크립트가 펌웨어와 붙으면 바이트 레이아웃 계약이 자동 검증된다.

설치:  pip install bleak
사용:
  python refit_ble_bench.py monitor              # UP 패킷 실시간 디코드
  python refit_ble_bench.py start                # 기록 시작 → EPOCH 흐르기 시작
  python refit_ble_bench.py stim-on              # 자극 투입(레벨 0에서 전원 on)
  python refit_ble_bench.py stim-off             # 자극 차단
  python refit_ble_bench.py hb                   # 500ms 하트비트만 (watchdog 살림)
  python refit_ble_bench.py judge --action decrease --level 2
  python refit_ble_bench.py judge --action increase --level 5 --rel low   # 게이트 테스트
  python refit_ble_bench.py stop
  python refit_ble_bench.py watchdog-test        # start→stim-on 후 하트비트 끊어 SAFE_HOLD 유도
주의: --address 로 MAC 지정 가능(미지정 시 이름 REFIT-FES-01 스캔).

v0.2 변경: EPOCH 에 sample_index 추가, t_ms 가 실제 millis() 로 바뀜(구버전은 샘플카운터
  합성값이었다), JUDGMENT 최소 길이 19B 로 확정. 버전 바이트 0x01 → 0x02.
"""
import argparse, asyncio, struct, time, sys
try:
    from bleak import BleakScanner, BleakClient
except ImportError:
    sys.exit("pip install bleak 필요")

SVC  = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
UP   = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"   # notify (MCU→Phone)
DOWN = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   # write  (Phone→MCU)
NAME = "REFIT-FES-01"
VER  = 0x02

MSG = {0x01:"EPOCH",0x02:"STATUS",0x03:"EVENT"}
STATE = {0:"IDLE",1:"CALIB",2:"RUNNING",3:"SAFE_HOLD",4:"STIM_OFF",5:"FAULT"}
EV = {1:"SESSION_START",2:"REST_END",3:"SESSION_STOP",4:"FAULT",5:"CALIB_DONE"}
ACT = {"hold":0,"decrease":1,"increase":2,"stop":3}
REL = {"high":0,"med":1,"low":2}
# SESSION_CONTROL cmd
SC_START, SC_STOP, SC_STIM_ON, SC_STIM_OFF = 1, 2, 3, 4

def crc8(b):
    c=0
    for x in b:
        c^=x
        for _ in range(8):
            c=((c<<1)^0x07)&0xFF if c&0x80 else (c<<1)&0xFF
    return c

# ---- 다운링크 패킷 빌드 (펌웨어 레이아웃과 동일) ----
_seq=0
def _hdr(mtype, session=0):
    global _seq
    h=struct.pack("<BBHH", VER, mtype, _seq & 0xFFFF, session); _seq+=1
    return h
def build_judgment(action, target, stage=0, rel=0, t_ref=0, stim_ref=0, session=0):
    body=_hdr(0x11,session)+struct.pack("<IIBBBB", t_ref, stim_ref, stage, ACT[action] if isinstance(action,str) else action, target, rel)
    return body+bytes([crc8(body)])
def build_heartbeat(session=0):
    body=_hdr(0x12,session)+struct.pack("<I", int(time.time()*1000)&0xFFFFFFFF)
    return body+bytes([crc8(body)])
def build_session_control(cmd, session=0):
    body=_hdr(0x14,session)+struct.pack("<B",cmd)
    return body+bytes([crc8(body)])

# ---- 업링크 디코드 + 계약 검증 ----
# 세션 t0(EV_SESSION_START 의 t_ms)와 fs(STATUS)를 기억해야 EPOCH 의 두 시계를 비교할 수 있다.
_ctx={"idx":None,"t0":None,"fs":None,"drift0":None}
def decode(data: bytearray):
    if len(data)<7: return f"[짧은 패킷 {len(data)}B]"
    ver,mtype,seq,sess = struct.unpack("<BBHH", data[:6])
    crc_ok = (crc8(data[:-1])==data[-1])
    tag=MSG.get(mtype,f"0x{mtype:02x}")
    warn=""
    if ver!=VER: warn+=f" ⚠VER불일치(0x{ver:02x}≠0x{VER:02x})"
    if not crc_ok: warn+=" ⚠CRC실패"
    if mtype==0x01:  # EPOCH
        stim_idx,t_ms,samp_idx = struct.unpack("<III", data[6:18])
        spike,p2p = struct.unpack("<hh", data[18:22])
        flags,n = data[22],data[23]
        samp = struct.unpack("<%dh"%n, data[24:24+2*n]) if 24+2*n<=len(data)-1 else ()
        # stim_index 연속성 검사 — 결번은 에폭 유실이다
        cont=""
        if _ctx["idx"] is not None:
            d=stim_idx-_ctx["idx"]
            if d!=1: cont=f" ⚠stim_index 점프 +{d}"
        _ctx["idx"]=stim_idx
        # 두 시계 드리프트: 벽시계 경과 − 샘플수로 환산한 경과.
        # 단조 증가하면 샘플링 태스크가 밀리는 중 = 샘플 기준 시간축이 실제보다 압축됨.
        drift=""
        if _ctx["t0"] is not None and _ctx["fs"]:
            d_ms=(t_ms-_ctx["t0"])-samp_idx*1000.0/_ctx["fs"]
            if _ctx["drift0"] is None: _ctx["drift0"]=d_ms
            drift=f" drift={d_ms-_ctx['drift0']:+.0f}ms"
        # R = 면적÷스파이크 (정규화된 피로 지표). 스파이크가 0이면 계산 불가.
        rtxt=""
        if samp and spike:
            area=sum(abs(v) for v in samp)
            rtxt=f" R={area/abs(spike):.2f}"
        valid = "valid" if flags&1 else "INVALID"
        # 포화: 값이 ADC 레일에서 잘렸다. sat_spike 는 R 의 분모를 상수로 만들어 정규화를
        # 무력화하므로 특히 위험하다 — 추세에서 빼야 한다.
        sat = "".join([" ⚠SAT_WIN" if flags&2 else "", " ⚠SAT_SPIKE" if flags&4 else ""])
        return (f"EPOCH seq{seq} sess{sess} stim#{stim_idx}@{t_ms}ms s#{samp_idx} "
                f"spike={spike} p2p={p2p}{rtxt} {valid} n={n}{drift}{cont}{sat}{warn}")
    if mtype==0x02:  # STATUS
        t_ms, = struct.unpack("<I", data[6:10])
        st,lvl,relay,health = data[10],data[11],data[12],data[13]
        ack,fs = struct.unpack("<HH", data[14:18])
        ws,we = struct.unpack("<bb", data[18:20]); mx=data[20]
        _ctx["fs"]=fs or None
        hbits=[n for b,n in [(1,"WD"),(2,"HLIM"),(4,"BATT"),(8,"SENSOR")] if health&b]
        return (f"STATUS {STATE.get(st,st)} lvl={lvl}/{mx} relay={'ON' if relay&1 else 'off'} "
                f"ack={ack} fs={fs} win={ws}~{we}ms health={hbits}{warn}")
    if mtype==0x03:  # EVENT
        t_ms,=struct.unpack("<I",data[6:10]); ev,detail=data[10],data[11]
        if ev==1:  # SESSION_START — 이 t_ms 가 세션 t0. 드리프트 기준도 새로 잡는다.
            _ctx["t0"]=t_ms; _ctx["idx"]=None; _ctx["drift0"]=None
        extra=f" dcOffset≈{detail<<4}" if ev==5 else ""
        return f"EVENT {EV.get(ev,ev)} detail={detail}{extra} @{t_ms}ms{warn}"
    return f"{tag} seq{seq}{warn}"

async def find(addr):
    if addr: return addr
    print(f"스캔 중... (name={NAME} 또는 svc={SVC})")
    # macOS는 광고에 이름이 안 실릴 때가 있어 이름+서비스UUID 둘 다로 매칭한다.
    def _match(d, adv):
        nm = (d.name or getattr(adv, "local_name", "") or "").upper()
        uuids = [u.lower() for u in getattr(adv, "service_uuids", [])]
        return NAME.upper() in nm or SVC.lower() in uuids
    d=await BleakScanner.find_device_by_filter(_match, timeout=12)
    if not d: sys.exit("장치 못 찾음. --address 로 MAC 지정하거나 광고 확인.")
    print(f"발견: {d.name or '(이름없음)'} {d.address}")
    return d   # device 객체 그대로 반환 (macOS에서 재스캔 없이 연결이 안정적)

async def run(args):
    addr=await find(args.address)
    async with BleakClient(addr, timeout=25) as cli:
        print("연결됨. MTU:", getattr(cli,"mtu_size","?"))
        seen={"EPOCH":0,"STATUS":0,"EVENT":0}
        def on_up(_,data):
            msg=decode(bytearray(data))
            for k in seen:
                if msg.startswith(k): seen[k]+=1
            # EPOCH 는 너무 잦으면 20개마다 하나만
            if msg.startswith("EPOCH") and seen["EPOCH"]%20!=1: return
            print(f"  ← {msg}")
        await cli.start_notify(UP, on_up)

        async def heartbeat_loop(stop_evt, period=0.5):
            while not stop_evt.is_set():
                await cli.write_gatt_char(DOWN, build_heartbeat(), response=True)
                await asyncio.sleep(period)

        async def sc(cmd, label, wait=3.0):
            pkt=build_session_control(cmd)
            print(f"{label} 송신({len(pkt)}B): {pkt.hex()}")
            await cli.write_gatt_char(DOWN, pkt, response=True)
            await asyncio.sleep(wait)

        if args.mode=="monitor":
            print("모니터링 (Ctrl-C 종료). STATUS는 5Hz, EPOCH는 자극 시 20개당 1개 표시.")
            print("※ 세션이 시작돼 있지 않으면 EPOCH 는 나오지 않는다 — 먼저 `start` 를 쓸 것.")
            await asyncio.sleep(args.seconds)
        elif args.mode=="start":
            await sc(SC_START, "START(기록 시작, 자극 안 켬)", 1.0)
            print(f"DC 캘리브 3초 대기 → CALIB_DONE 후 RUNNING. {args.seconds}초 관찰...")
            await asyncio.sleep(args.seconds)
        elif args.mode=="stim-on":
            await sc(SC_STIM_ON, "STIM_ENABLE(레벨 0에서 전원 on)")
        elif args.mode=="stim-off":
            await sc(SC_STIM_OFF, "STIM_DISABLE")
        elif args.mode=="hb":
            print("하트비트 500ms 송신 중 (watchdog 유지). Ctrl-C 종료.")
            stop=asyncio.Event()
            await heartbeat_loop(stop, 0.5)
        elif args.mode=="judge":
            print(f"JUDGMENT 송신: action={args.action} level={args.level} rel={args.rel}")
            pkt=build_judgment(args.action, args.level, rel=REL[args.rel])
            print(f"    보낸 바이트({len(pkt)}B): {pkt.hex()}   (계약상 19B)")
            await cli.write_gatt_char(DOWN, pkt, response=True)
            await asyncio.sleep(3)   # STATUS 로 ack/level 변화 관찰
            print(f"    수신 요약: {seen}")
            print("    ※ level 이 안 변했으면 INCREASE 게이트에서 거부된 것 — 계약 문서 §5 참조.")
        elif args.mode=="stop":
            await sc(SC_STOP, "STOP")
        elif args.mode=="watchdog-test":
            # 워치독은 stimOn 일 때만 격상한다(로그 전용 세션은 끊을 자극이 없다).
            # 그래서 start → stim-on 까지 해두지 않으면 아무 일도 관측되지 않는다.
            await sc(SC_START, "① START", 4.0)          # DC 캘리브 3초 + 여유
            await sc(SC_STIM_ON, "② STIM_ENABLE", 1.0)
            print("③ 하트비트 3초 송신(RUNNING 유지)")
            stop=asyncio.Event(); t=asyncio.create_task(heartbeat_loop(stop,0.5))
            await asyncio.sleep(3); stop.set(); await t
            print("④ 하트비트 중단 → 2초 후 SAFE_HOLD, 8초 후 STIM_OFF 관찰(10초 대기)")
            await asyncio.sleep(10)
        await cli.stop_notify(UP)
        print("완료. 수신 요약:", seen)

if __name__=="__main__":
    ap=argparse.ArgumentParser()
    ap.add_argument("mode", choices=["monitor","start","stim-on","stim-off",
                                     "hb","judge","stop","watchdog-test"])
    ap.add_argument("--address", default=None)
    ap.add_argument("--action", default="hold", choices=list(ACT.keys()))
    ap.add_argument("--level", type=int, default=0)
    ap.add_argument("--rel", default="high", choices=list(REL.keys()))
    ap.add_argument("--seconds", type=float, default=30)
    args=ap.parse_args()
    try: asyncio.run(run(args))
    except KeyboardInterrupt: print("\n중단")
