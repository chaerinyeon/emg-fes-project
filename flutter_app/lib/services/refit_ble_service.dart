// RE:FIT v0.2 BLE 전송 계층 — 스캔·연결·세션제어·하트비트·에포크 수집.
//
// 구펌웨어용 home_page 경로(EMG-FES-01 · JSON)와 완전히 분리돼 있다. 서비스 UUID 는
// 두 펌웨어가 같아서 스캔만으로는 구분되지 않는다 → 광고 이름으로 가른다.
//
// 판정(면적·running-max·인과 시그마)은 아직 넣지 않았다. 지금은 로그 전용:
// 자극은 SC_STIM_ENABLE 을 명시적으로 보낼 때만 켜지고, 기본은 기록만 한다.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/constants.dart';
import '../core/refit_protocol.dart';
import 'epoch_logger.dart';

enum RefitConn {
  idle,
  unsupported,
  scanning,
  connecting,
  connected,
  disconnected,
  error,
}

class RefitBleService extends ChangeNotifier {
  // ---- 연결 상태 ----
  RefitConn conn = RefitConn.idle;
  String? lastError;
  String deviceLabel = kRefitDeviceName;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _downChar;
  StreamSubscription? _scanSub, _connSub, _upSub;
  Timer? _hbTimer, _flushTimer;

  // ---- 프로토콜 상태 ----
  int _seq = 0;
  int sessionId = 0;
  StatusMsg? status;
  String? lastEvent;

  // ---- 세션/에포크 상태 ----
  bool sessionActive = false;
  int? _t0Ms; // EV_SESSION_START 의 t_ms — 두 시계 정렬의 기준
  int epochCount = 0;
  int droppedEpochs = 0; // stim_index 결번 합계
  int saturatedEpochs = 0; // 레일 클리핑으로 추세에서 뺀 에폭 수
  int? _lastStimIndex;
  double driftMs = 0;
  EpochMsg? lastEpoch;

  /// 최근 R 값 추이 (차트용). 오래된 것부터.
  final List<double> rHistory = [];
  static const int _kRHistoryMax = 600;

  final EpochLogRecorder recorder = EpochLogRecorder();
  String? csvPath;
  String? _subjectId; // 저장 디렉터리 data/<subjectId>/
  String _categoryTag = 'unknown'; // 파일명 태그 A_healthy 등 — 분석 스크립트가 읽는다
  String _pendingMarker = '';

  /// 디코드에 실패한 업링크 패킷 수. 구펌웨어(v0.1·JSON)에 붙으면 여기만 올라간다.
  int undecodable = 0;

  bool get isConnected => conn == RefitConn.connected;
  bool get stimOn => status?.stimOn ?? false;
  int get sampleRate => status?.sampleRate ?? 1000;

  // ================= 연결 =================

  Future<void> init() async {
    if (kIsWeb) {
      conn = RefitConn.unsupported;
      lastError = '웹 브라우저에서는 BLE 미지원. iOS/Android에서 실행하세요.';
      notifyListeners();
      return;
    }
    if (!await FlutterBluePlus.isSupported) {
      conn = RefitConn.unsupported;
      lastError = '이 기기는 BLE를 지원하지 않습니다.';
      notifyListeners();
    }
  }

  Future<void> scanAndConnect() async {
    if (conn == RefitConn.scanning ||
        conn == RefitConn.connecting ||
        conn == RefitConn.connected ||
        conn == RefitConn.unsupported) {
      return;
    }
    conn = RefitConn.scanning;
    lastError = null;
    notifyListeners();

    try {
      await FlutterBluePlus.stopScan();
      await _scanSub?.cancel();

      ScanResult? found;
      _scanSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final name = r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName;
          // 서비스 UUID 는 구펌웨어와 동일하므로 이름으로 가른다. macOS/iOS 는 광고에
          // 이름이 안 실릴 때가 있어, 이름이 비었으면 후보로만 잡고 계속 찾는다.
          if (name == kRefitDeviceName) {
            found = r;
            break;
          }
          found ??= name.isEmpty ? r : found;
        }
        if (found != null && (found!.device.platformName == kRefitDeviceName)) {
          FlutterBluePlus.stopScan();
        }
      });

      await FlutterBluePlus.startScan(
        withServices: [Guid(kServiceUuid)],
        timeout: const Duration(seconds: 10),
      );
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      await _scanSub?.cancel();
      _scanSub = null;

      if (found == null) {
        conn = RefitConn.error;
        lastError =
            '$kRefitDeviceName 을(를) 찾지 못함. 보드 전원과 BLE 광고를 확인하세요.';
        notifyListeners();
        return;
      }

      conn = RefitConn.connecting;
      notifyListeners();

      final device = found!.device;
      await _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected) {
          _onDisconnected();
        }
      });

      await device.connect(
        license: License.free,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );
      try {
        await device.requestMtu(247); // iOS 자동, Android 명시
      } catch (_) {}

      BluetoothCharacteristic? upChar, downChar;
      for (final s in await device.discoverServices()) {
        if (s.uuid.toString().toLowerCase() != kServiceUuid) continue;
        for (final c in s.characteristics) {
          final u = c.uuid.toString().toLowerCase();
          if (u == kDataCharUuid) upChar = c;
          if (u == kCmdCharUuid) downChar = c;
        }
      }
      if (upChar == null || downChar == null) {
        await device.disconnect();
        conn = RefitConn.error;
        lastError = '필요한 characteristic 을 찾지 못함.';
        notifyListeners();
        return;
      }

      await upChar.setNotifyValue(true);
      await _upSub?.cancel();
      _upSub = upChar.lastValueStream.listen(_onUpPacket);

      _device = device;
      _downChar = downChar;
      deviceLabel = device.platformName.isNotEmpty
          ? device.platformName
          : kRefitDeviceName;
      conn = RefitConn.connected;
      notifyListeners();
    } catch (e) {
      conn = RefitConn.error;
      lastError = '연결 실패: $e';
      notifyListeners();
    }
  }

  void _onDisconnected() {
    conn = RefitConn.disconnected;
    _device = null;
    _downChar = null;
    _hbTimer?.cancel();
    _hbTimer = null;
    // 보드가 재시작하면 sessionId 가 0부터 다시 센다. 우리가 옛 값을 계속 보내면
    // 세션 불일치로 모든 다운링크가 폐기된다 — 와일드카드(0)로 되돌린다.
    sessionId = 0;
    undecodable = 0;
    // 끊김은 세션이 비정상 종료될 신호다 — 다음 주기 flush 를 기다리지 않고 즉시 쓴다.
    if (sessionActive) unawaited(_flush());
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _upSub?.cancel();
    await _connSub?.cancel();
    _hbTimer?.cancel();
    _flushTimer?.cancel();
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _downChar = null;
    conn = RefitConn.idle;
    notifyListeners();
  }

  // ================= 수신 =================

  void _onUpPacket(List<int> bytes) {
    if (bytes.isEmpty) return;
    final msg = decodeRefit(bytes);
    if (msg == null) {
      // 계약 위반 — 폐기. 다만 '전부' 걸리면 그건 잡음이 아니라 잘못된 펌웨어다.
      // 서비스 UUID 가 구·신 동일해서 구펌웨어(EMG-FES-01·JSON)에도 붙어버릴 수 있는데,
      // 그때 증상은 '연결됨인데 아무것도 안 나옴'이라 원인을 알기 어렵다. 명시적으로 알린다.
      undecodable++;
      if (undecodable == 20) {
        lastError =
            'v0.2 패킷이 하나도 오지 않는다 ($undecodable개 폐기). 보드에 구펌웨어가 '
            '올라가 있을 수 있다 — firmware/emg_fes_controller/ 를 다시 업로드하세요.';
        notifyListeners();
      }
      return;
    }

    switch (msg) {
      case StatusMsg s:
        status = s;
        sessionId = s.sessionId;
        notifyListeners();

      case EventMsg e:
        lastEvent = '${e.name}${e.detail != 0 ? ' (${e.detail})' : ''}';
        sessionId = e.sessionId;
        if (e.eventId == kEvSessionStart) {
          // 이 t_ms 가 세션 t0 — 에포크의 두 시계를 여기에 맞춘다.
          _t0Ms = e.tMs;
          _lastStimIndex = null;
          epochCount = 0;
          droppedEpochs = 0;
          driftMs = 0;
          saturatedEpochs = 0;
          rHistory.clear();
          sessionActive = true;
          recorder.start(filenameTag: _categoryTag);
          _startTimers();
        } else if (e.eventId == kEvSessionStop) {
          sessionActive = false;
          recorder.stop();
          unawaited(_flush());
        }
        notifyListeners();

      case EpochMsg ep:
        _onEpoch(ep);
    }
  }

  void _onEpoch(EpochMsg ep) {
    lastEpoch = ep;
    epochCount++;

    // stim_index 결번 = 에포크 유실. 세면 유실률을 사후에 알 수 있다.
    if (_lastStimIndex != null && ep.stimIndex > _lastStimIndex! + 1) {
      droppedEpochs += ep.stimIndex - _lastStimIndex! - 1;
    }
    _lastStimIndex = ep.stimIndex;

    // 두 시계 드리프트: 벽시계 경과 − 표본수로 환산한 경과.
    // 단조 증가하면 샘플링이 벽시계 대비 밀리는 중 = 표본 기준 시간축이 압축돼 있다.
    final t0 = _t0Ms;
    final tRel = t0 == null ? ep.tMs : ep.tMs - t0;
    driftMs = tRel - ep.sampleIndex * 1000.0 / sampleRate;

    // 포화 에폭은 추세에서 뺀다 — 값이 잘려 있어 R 이 물리량이 아니다.
    // 세는 건 계속한다: 포화율이 높으면 게인·전극을 손봐야 한다는 신호다.
    if (ep.saturated) saturatedEpochs++;
    if (ep.usableForTrend) {
      rHistory.add(ep.r);
      if (rHistory.length > _kRHistoryMax) rHistory.removeAt(0);
    }

    recorder.add(
      tRelMs: tRel,
      stimIndex: ep.stimIndex,
      sampleIndex: ep.sampleIndex,
      driftMs: driftMs,
      spike: ep.spike,
      p2p: ep.p2p,
      area: ep.area,
      r: ep.r,
      valid: ep.valid,
      satWindow: ep.windowSaturated,
      satSpike: ep.spikeSaturated,
      mcuState: status?.stateName ?? '?',
      level: status?.level ?? 0,
      samples: ep.samples,
      marker: _pendingMarker,
    );
    _pendingMarker = '';
    notifyListeners();
  }

  // ================= 송신 =================

  Future<bool> _send(List<int> pkt, String label) async {
    final c = _downChar;
    if (c == null) {
      lastError = '연결 안 됨 — 먼저 Connect 하세요';
      notifyListeners();
      return false;
    }
    try {
      await c.write(pkt, withoutResponse: false);
      return true;
    } catch (e) {
      lastError = '$label 전송 실패: $e';
      notifyListeners();
      return false;
    }
  }

  Future<bool> _sendSessionControl(int cmd, String label) => _send(
    buildSessionControl(cmd, seq: _seq++, sessionId: sessionId),
    label,
  );

  /// 기록 시작. 자극은 켜지 않는다 — 자극 투입은 [enableStim] 으로만.
  /// 세션 상태는 EV_SESSION_START 를 받았을 때 확정된다(요청 ≠ 시작).
  ///
  /// [subjectId] 는 저장 디렉터리, [categoryTag] 는 파일명에 들어가는 분류
  /// (A_healthy/B_incomplete/C_complete). 분석 스크립트가 파일명으로 군을 가른다.
  Future<bool> startSession({String? subjectId, String categoryTag = 'unknown'}) {
    _subjectId = subjectId;
    _categoryTag = categoryTag;
    return _sendSessionControl(kScRequestStart, 'START');
  }

  Future<bool> stopSession() => _sendSessionControl(kScRequestStop, 'STOP');

  Future<bool> enableStim() => _sendSessionControl(kScStimEnable, 'STIM_ENABLE');

  Future<bool> disableStim() =>
      _sendSessionControl(kScStimDisable, 'STIM_DISABLE');

  /// 다음 에포크 행에 붙일 마커.
  void markNext(String label) {
    _pendingMarker = label;
    notifyListeners();
  }

  void _startTimers() {
    _hbTimer?.cancel();
    // 워치독은 자극이 켜져 있을 때만 격상하지만, 하트비트는 항상 보낸다 —
    // 자극을 켜는 순간부터 유효해야 하고, 끊기면 그때 늦다.
    _hbTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_downChar != null) {
        unawaited(
          _send(buildHeartbeat(seq: _seq++, sessionId: sessionId), 'HB'),
        );
      }
    });
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(_flush());
    });
  }

  Future<void> _flush() async {
    final p = await recorder.flush(subjectId: _subjectId);
    if (p != null && p != csvPath) {
      csvPath = p;
      notifyListeners();
    }
  }

  /// 세션 종료 후 CSV 확정 저장. 경로 반환.
  Future<String?> saveCsv() async {
    final p = await recorder.save(subjectId: _subjectId);
    if (p != null) {
      csvPath = p;
      notifyListeners();
    }
    return p;
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _upSub?.cancel();
    _hbTimer?.cancel();
    _flushTimer?.cancel();
    try {
      _device?.disconnect();
    } catch (_) {}
    super.dispose();
  }
}
