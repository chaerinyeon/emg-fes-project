import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../core/subject_category.dart';
import '../data/local/hive_session_store.dart';
import '../data/local/session_store.dart';
import '../services/profile_service.dart';
import '../session/end_conditions.dart';
import 'session/session_orchestrator.dart';

/// 앱 전역 상태 — 저장소 · 설정 · 선택된 환자 · 살아 있는 세션.
///
/// [gProfileService] 와 같은 싱글톤 방식을 따른다. 이 앱에는 상태관리
/// 패키지가 없고, 여기 들어오는 것은 **화면 밖에서 살아야 하는 것**뿐이다 —
/// 훈련 중에 탭을 옮겨도 자극이 켜진 채로 남으면 안 되고, 기록은 화면이
/// 사라져도 남아야 한다.
class RefitAppState extends ChangeNotifier {
  late SessionStore store;
  late RefitSettings settings;

  /// 로컬에 확정된 세션 전부. 최신순.
  List<SessionSummary> sessions = const [];

  /// 지금 준비 중이거나 훈련 중인 세션. 없으면 null.
  ///
  /// TEST 화면의 **자극기 확인**이 이 값을 본다 — 실제 자극을 쏘려면 살아
  /// 있는 링크가 있어야 하고, 부착 확인을 통과한 상태여야 한다.
  SessionOrchestrator? live;

  /// 기록이 앱을 닫아도 남는가.
  ///
  /// false 면 저장소를 열지 못해 메모리로 돌고 있다는 뜻이다. 이걸 조용히
  /// 숨기면 "훈련은 됐는데 기록이 안 뜬다"가 되고, 원인을 화면 어디에서도
  /// 알 수 없다.
  bool storePersistent = true;

  Future<void> init() async {
    settings = await RefitSettings.open();
    try {
      store = await HiveSessionStore.open();
      storePersistent = true;
    } catch (e) {
      // 저장소가 안 열려도 훈련은 되어야 한다. 기록만 휘발된다.
      store = InMemorySessionStore();
      storePersistent = false;
      await settings.setLastError('로컬 저장소를 열지 못했어요 — '
          '이번 실행의 기록은 앱을 닫으면 사라집니다 ($e)');
    }
    await reloadSessions();
    await _alignPatientIdWithLegacyRecords();
  }

  Future<void> reloadSessions() async {
    final all = await store.allSessions();
    all.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    sessions = all;
    notifyListeners();
  }

  // ── 환자 ───────────────────────────────────────────────

  UserProfile? get patient => gProfileService.active;

  /// 훈련에 들어가도 되는 환자인가.
  ///
  /// 마비 유형이 비어 있으면 안 된다. 라벨이 아니라 **피로 판정에 어떤
  /// 지표를 쓸지 고르는 스위치**라, 비어 있는 채로 훈련하면 판정 자체가
  /// 틀린다. 그래서 이 값이 없으면 탭 바깥의 환자 화면이 먼저 뜬다.
  bool get patientReady => patient?.category != null;

  List<UserProfile> get patients => gProfileService.all();

  Future<void> selectPatient(String id) async {
    await gProfileService.setActive(id);
    notifyListeners();
  }

  Future<void> savePatient(UserProfile p) async {
    await gProfileService.save(p);
    if (gProfileService.activeId == null) {
      await gProfileService.setActive(p.id);
    }
    notifyListeners();
  }

  Future<void> deletePatient(String id) async {
    await gProfileService.delete(id);
    notifyListeners();
  }

  /// 선택된 환자의 세션만. 환자 간 비교·순위는 만들지 않는다(하드 제약 6).
  List<SessionSummary> get patientSessions {
    final id = patient?.id;
    if (id == null) return const [];
    return sessions.where((s) => s.patientId == id).toList();
  }

  /// 등록된 어느 환자에도 속하지 않는 기록.
  ///
  /// 앱에 환자 개념이 생기기 전 세션은 `patient_id = 'local'` 로 저장됐다.
  /// 그 기록들은 지금의 환자 id 와 맞지 않아 [patientSessions] 에서 통째로
  /// 빠진다 — 훈련은 했는데 기록 탭이 비어 보이는 원인이다.
  List<SessionSummary> get unassignedSessions {
    final known = patients.map((p) => p.id).toSet();
    return sessions.where((s) => !known.contains(s.patientId)).toList();
  }

  /// 지금 환자가 주인 없는 기록의 주인이라고 사람이 확인해 준 경우.
  ///
  /// 자동 정렬([_alignPatientIdWithLegacyRecords])이 환자가 여럿이라
  /// 움직이지 않았을 때 쓰는 수동 경로다. 하는 일은 같다 — **기록이 아니라
  /// 프로파일 id 를 옮긴다.** 이어받은 건수를 돌려준다.
  Future<int> claimUnassignedSessions() async {
    final me = patient;
    if (me == null) return 0;

    final orphans = unassignedSessions;
    final legacyIds = orphans.map((s) => s.patientId).toSet();
    if (legacyIds.length != 1) return 0;

    // 자기 id 로 된 기록이 있으면 옮기는 순간 그쪽이 주인을 잃는다.
    if (sessions.any((s) => s.patientId == me.id)) return 0;

    final moved = await gProfileService.rekey(me.id, legacyIds.single);
    if (moved == null) return 0;
    notifyListeners();
    return orphans.length;
  }

  /// 환자 프로파일의 id 를 옛 기록이 쓰던 id 에 맞춘다.
  ///
  /// **기록을 고치지 않는다.** `sessions.patient_id` 는 서버와 공유하는
  /// 값이고 이미 업로드됐을 수도 있다. 고쳐야 할 쪽은 앱 안에서만 쓰는
  /// 프로파일 키다 — 같은 사람을 가리키는 이름표를 기록에 맞추는 일이다.
  ///
  /// 세 조건을 모두 만족할 때만 움직인다:
  ///   1. 등록된 환자가 **한 명**이다 — 여럿이면 누구의 기록인지 모른다.
  ///   2. 주인 없는 기록의 patient_id 가 **한 종류**다.
  ///   3. 그 환자에게 자기 id 로 된 기록이 **아직 없다** — 있으면 id 를
  ///      옮기는 순간 그쪽이 주인을 잃는다.
  Future<void> _alignPatientIdWithLegacyRecords() async {
    final ps = patients;
    if (ps.length != 1) return;

    final legacyIds = unassignedSessions.map((s) => s.patientId).toSet();
    if (legacyIds.length != 1) return;

    final me = ps.single;
    if (sessions.any((s) => s.patientId == me.id)) return;

    await gProfileService.rekey(me.id, legacyIds.single);
    notifyListeners();
  }

  List<SessionSummary> sessionsOn(DateTime day) => patientSessions
      .where((s) => _sameDay(s.startedAt, day))
      .toList();

  /// 오늘의 상태 — 좋음 · 주의 · 피로.
  ///
  /// **퍼센트를 내보내지 않는다.** 3단계 상태로만 말한다.
  ///
  /// 판정 근거는 종료 사유와 수행 성공률이다. 적응형 피로 게이지
  /// (`fatigue`) 를 직접 문턱으로 쓰지 않는 이유는 `kFatigueThresholdPct` 가
  /// 아직 확정되지 않아 절대 기준이 없기 때문이다 — 확정되면 여기가
  /// 첫 번째로 바뀔 자리다.
  DailyStatus get todayStatus {
    final today = sessionsOn(DateTime.now());
    if (today.isEmpty) return DailyStatus.none;

    final tired = today.any((s) =>
        s.endReason == SessionEndReason.fatigueThreshold ||
        s.endReason == SessionEndReason.successRateDrop);
    if (tired) return DailyStatus.tired;

    final last = today.first;
    if (today.length >= 2 || last.successRate < 0.6) {
      return DailyStatus.caution;
    }
    return DailyStatus.good;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// 홈이 보여 주는 3단계 상태. 숫자는 여기에 들어오지 않는다.
enum DailyStatus {
  none('아직 기록이 없어요'),
  good('좋음'),
  caution('주의'),
  tired('피로');

  const DailyStatus(this.label);
  final String label;
}

/// 앱 설정 — Hive 한 상자.
///
/// 값이 적고 형태가 단순해서 별도 모델을 만들지 않았다. 늘어나면
/// [SessionStore] 처럼 인터페이스를 앞에 세우는 게 맞다.
class RefitSettings {
  RefitSettings._(this._box);

  static const _boxName = 'refit_settings';
  final Box<dynamic> _box;

  static Future<RefitSettings> open() async =>
      RefitSettings._(await Hive.openBox<dynamic>(_boxName));

  /// 다음 세션이 시작할 강도 단계(1~10).
  ///
  /// 세션 중 하향은 여기 저장하지 않는다 — 그날 몸 상태로 내린 것이지
  /// 기본값이 바뀐 게 아니다.
  int get defaultIntensity => (_box.get('default_intensity') as int?) ?? 3;
  Future<void> setDefaultIntensity(int v) =>
      _box.put('default_intensity', v.clamp(1, 10));

  /// 기기 없이 전 구간을 돌려 보는 개발 스위치.
  bool get syntheticMode => (_box.get('synthetic_mode') as bool?) ?? false;
  Future<void> setSyntheticMode(bool v) => _box.put('synthetic_mode', v);

  /// 마지막으로 붙은 기기 이름. 설정 화면에만 쓴다.
  String? get lastDeviceName => _box.get('last_device') as String?;
  Future<void> setLastDeviceName(String? v) =>
      v == null ? _box.delete('last_device') : _box.put('last_device', v);

  /// 마지막 연결 오류. **화면에서 지우지 않는다** — 원인이 남아 있어야
  /// 다음에 무엇을 할지 말할 수 있다.
  String? get lastError => _box.get('last_error') as String?;
  Future<void> setLastError(String? v) =>
      v == null ? _box.delete('last_error') : _box.put('last_error', v);
}

/// 마비 유형에 따라 피로 판정에 쓰는 지표가 갈린다.
///
/// 화면 문구를 한곳에서 만들기 위한 헬퍼다. 실제 계산 경로는 신호 엔진에
/// 있다(`signal/fatigue_engine.dart`).
String fatigueBasisFor(SubjectCategory? c) => switch (c) {
      SubjectCategory.complete => 'M-wave 진폭만 본다 (자발 EMG 없음)',
      SubjectCategory.incomplete => 'M-wave 진폭 + RMS·MDF 보조',
      _ => '마비 유형을 정해야 판정 경로가 정해진다',
    };

final RefitAppState gApp = RefitAppState();
