// 환자 프로파일 시스템 — Hive Box<String> + JSON 직렬화 기반.
//
// 사용:
//   final svc = ProfileService();
//   await svc.init();
//   final list = svc.all();
//   await svc.save(profile);
//   await s
// vc.setActive(profile.id);
//   final active = svc.active;

import 'dart:convert';
import 'package:hive/hive.dart';

import '../core/subject_category.dart';

/// 환자별 측정 프로파일.
/// 캘리브레이션 세션에서 MVC·resting·baseline 등을 채워 영구 저장.
class UserProfile {
  final String id; // UUID 또는 임의 슬러그
  String name; // 표시명 (예: "Subject A", "김환자")
  int? age; // 나이. 환자 등록의 필수 항목이지만 레거시 데이터엔 없다.

  /// 마비 유형. **라벨이 아니라 분석 경로를 바꾸는 스위치다.**
  ///
  /// | 유형 | 피로 판정에 쓰는 지표 |
  /// |---|---|
  /// | 완전마비 | M-wave 진폭만. 자발 EMG 가 없어 RMS·MDF 는 자극 하모닉과 구분되지 않는다. |
  /// | 불완전마비 | M-wave 진폭 + RMS·MDF 보조 |
  ///
  /// 이 값이 틀리면 피로 판정 자체가 틀린다. 그래서 환자 등록에서 필수다.
  /// ([SubjectCategory.healthy] 는 레거시 모니터 앱의 대조군 측정용이고,
  /// RE-FIT Play 의 환자 등록 화면에서는 고를 수 없다.)
  SubjectCategory? category; // 분류 (A/B/C). 미지정 가능.
  String? note; // 자유 비고 (병변 부위, 수술 이력, 측정 조건 등)
  double? mvcRms; // 최대 수축 시 RMS (Maximum Voluntary Contraction)
  double? restingRms; // 휴식 시 평균 RMS (baseline)
  double? mdfBaseline; // 휴식 시 평균 MDF (Hz)
  int sessionCount; // 세션 누적 횟수
  String? lastSessionAt; // ISO 8601 timestamp
  List<double> recentFatigueRmsSlopes; // 직전 N개 세션의 피로 시점 RMS slope
  List<double> recentFatigueMdfSlopes; // 같은 방식 MDF slope
  List<double> recentTimeToFatigueSec; // 직전 N개 세션의 피로까지 걸린 시간(초)

  UserProfile({
    required this.id,
    required this.name,
    this.age,
    this.category,
    this.note,
    this.mvcRms,
    this.restingRms,
    this.mdfBaseline,
    this.sessionCount = 0,
    this.lastSessionAt,
    List<double>? recentFatigueRmsSlopes,
    List<double>? recentFatigueMdfSlopes,
    List<double>? recentTimeToFatigueSec,
  }) : recentFatigueRmsSlopes = recentFatigueRmsSlopes ?? <double>[],
       recentFatigueMdfSlopes = recentFatigueMdfSlopes ?? <double>[],
       recentTimeToFatigueSec = recentTimeToFatigueSec ?? <double>[];

  Map<String, dynamic> toJson() => {
    'name': name,
    'age': age,
    'category': category?.code,
    'note': note,
    'mvcRms': mvcRms,
    'restingRms': restingRms,
    'mdfBaseline': mdfBaseline,
    'sessionCount': sessionCount,
    'lastSessionAt': lastSessionAt,
    'recentFatigueRmsSlopes': recentFatigueRmsSlopes,
    'recentFatigueMdfSlopes': recentFatigueMdfSlopes,
    'recentTimeToFatigueSec': recentTimeToFatigueSec,
  };

  factory UserProfile.fromJson(Map<String, dynamic> j, String id) {
    return UserProfile(
      id: id,
      name: (j['name'] as String?) ?? id,
      age: (j['age'] as num?)?.toInt(),
      category: SubjectCategory.fromCode(j['category'] as String?),
      note: j['note'] as String?,
      mvcRms: (j['mvcRms'] as num?)?.toDouble(),
      restingRms: (j['restingRms'] as num?)?.toDouble(),
      mdfBaseline: (j['mdfBaseline'] as num?)?.toDouble(),
      sessionCount: (j['sessionCount'] as num?)?.toInt() ?? 0,
      lastSessionAt: j['lastSessionAt'] as String?,
      recentFatigueRmsSlopes:
          (j['recentFatigueRmsSlopes'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          <double>[],
      recentFatigueMdfSlopes:
          (j['recentFatigueMdfSlopes'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          <double>[],
      recentTimeToFatigueSec:
          (j['recentTimeToFatigueSec'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          <double>[],
    );
  }

  UserProfile copyWith({
    String? name,
    int? age,
    Object? category = _sentinel,
    Object? note = _sentinel,
    double? mvcRms,
    double? restingRms,
    double? mdfBaseline,
    int? sessionCount,
    String? lastSessionAt,
    List<double>? recentFatigueRmsSlopes,
    List<double>? recentFatigueMdfSlopes,
    List<double>? recentTimeToFatigueSec,
  }) {
    return UserProfile(
      id: id,
      name: name ?? this.name,
      age: age ?? this.age,
      category: identical(category, _sentinel)
          ? this.category
          : category as SubjectCategory?,
      note: identical(note, _sentinel) ? this.note : note as String?,
      mvcRms: mvcRms ?? this.mvcRms,
      restingRms: restingRms ?? this.restingRms,
      mdfBaseline: mdfBaseline ?? this.mdfBaseline,
      sessionCount: sessionCount ?? this.sessionCount,
      lastSessionAt: lastSessionAt ?? this.lastSessionAt,
      recentFatigueRmsSlopes:
          recentFatigueRmsSlopes ?? this.recentFatigueRmsSlopes,
      recentFatigueMdfSlopes:
          recentFatigueMdfSlopes ?? this.recentFatigueMdfSlopes,
      recentTimeToFatigueSec:
          recentTimeToFatigueSec ?? this.recentTimeToFatigueSec,
    );
  }
}

// copyWith에서 null 명시 전달과 미전달을 구분하기 위한 sentinel.
const Object _sentinel = Object();

class ProfileService {
  static const String _boxName = 'profiles';
  static const String _activeKey = '__active_profile_id';

  late Box<String> _box;
  bool _initialized = false;

  Future<void> init() async {
    // 상자가 닫혀 있으면 다시 연다. 한 번 init 했다는 플래그만 보고 넘기면,
    // Hive 가 닫힌 뒤(테스트 격리·저장소 재초기화) 모든 접근이
    // "Box has already been closed" 로 죽는다.
    if (_initialized && _box.isOpen) return;
    _box = await Hive.openBox<String>(_boxName);
    _initialized = true;
    // 최초 실행 시 기본 프로파일 생성
    if (all().isEmpty) {
      final p = UserProfile(id: 'subject_A', name: 'Subject A');
      await save(p);
      await setActive(p.id);
    }
  }

  /// 활성 프로파일 ID (UI에서 현재 선택된 환자).
  String? get activeId => _box.get(_activeKey);

  Future<void> setActive(String? id) async {
    if (id == null) {
      await _box.delete(_activeKey);
    } else {
      await _box.put(_activeKey, id);
    }
  }

  UserProfile? get active {
    final id = activeId;
    if (id == null) return null;
    return get(id);
  }

  /// 전체 프로파일 리스트.
  List<UserProfile> all() {
    return _box.keys
        .where((k) => k != _activeKey)
        .map((k) {
          final js = _box.get(k.toString());
          if (js == null) return null;
          try {
            final m = jsonDecode(js) as Map<String, dynamic>;
            return UserProfile.fromJson(m, k.toString());
          } catch (_) {
            return null;
          }
        })
        .whereType<UserProfile>()
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  UserProfile? get(String id) {
    final js = _box.get(id);
    if (js == null) return null;
    try {
      final m = jsonDecode(js) as Map<String, dynamic>;
      return UserProfile.fromJson(m, id);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(UserProfile p) async {
    await _box.put(p.id, jsonEncode(p.toJson()));
  }

  /// 프로파일의 id 를 [newId] 로 옮긴다. 성공하면 옮겨진 프로파일.
  ///
  /// **훈련 기록은 건드리지 않는다.** `sessions.patient_id` 는 서버와
  /// 공유하는 값이라, 이미 저장·업로드된 기록을 앱 사정으로 다시 쓰면
  /// 서버에 있는 것과 어긋난다. 대신 앱 안에서만 쓰는 프로파일 키를
  /// 기록 쪽에 맞춘다 — 같은 사람을 가리키는 이름표를 고치는 일이다.
  ///
  /// [newId] 가 이미 있으면 아무것도 하지 않는다. 두 사람을 합치는 것은
  /// 이 함수가 판단할 일이 아니다.
  Future<UserProfile?> rekey(String oldId, String newId) async {
    if (oldId == newId) return get(oldId);
    final p = get(oldId);
    if (p == null || _box.containsKey(newId)) return null;

    final moved = UserProfile(
      id: newId,
      name: p.name,
      age: p.age,
      category: p.category,
      note: p.note,
      mvcRms: p.mvcRms,
      restingRms: p.restingRms,
      mdfBaseline: p.mdfBaseline,
      sessionCount: p.sessionCount,
      lastSessionAt: p.lastSessionAt,
      recentFatigueRmsSlopes: p.recentFatigueRmsSlopes,
      recentFatigueMdfSlopes: p.recentFatigueMdfSlopes,
      recentTimeToFatigueSec: p.recentTimeToFatigueSec,
    );
    await save(moved);
    await _box.delete(oldId);
    if (activeId == oldId) await setActive(newId);
    return moved;
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
    if (activeId == id) {
      await setActive(null);
      // 남은 프로파일 중 첫 번째를 활성화
      final remaining = all();
      if (remaining.isNotEmpty) await setActive(remaining.first.id);
    }
  }

  /// 세션 종료 시 활성 프로파일 업데이트.
  /// baseline / mvc 값을 누적 평균으로 갱신.
  Future<void> recordSession({
    required double? baselineRms,
    required double? baselineMdf,
    required double? maxRms, // 세션 중 관찰된 최대 RMS (MVC 추정)
    double? fatigueRmsSlope, // 피로 트리거 시점의 slope (있으면)
    double? fatigueMdfSlope,
    double? timeToFatigueSec, // 세션 시작~피로 검출까지 걸린 시간(초)
  }) async {
    final cur = active;
    if (cur == null) return;

    double? updatedMvc = cur.mvcRms;
    if (maxRms != null && (cur.mvcRms == null || maxRms > cur.mvcRms!)) {
      updatedMvc = maxRms;
    }

    double? updatedRest = cur.restingRms;
    if (baselineRms != null) {
      updatedRest = cur.restingRms == null
          ? baselineRms
          : (cur.restingRms! * cur.sessionCount + baselineRms) /
                (cur.sessionCount + 1);
    }

    double? updatedMdf = cur.mdfBaseline;
    if (baselineMdf != null) {
      updatedMdf = cur.mdfBaseline == null
          ? baselineMdf
          : (cur.mdfBaseline! * cur.sessionCount + baselineMdf) /
                (cur.sessionCount + 1);
    }

    final newRmsSlopes = List<double>.from(cur.recentFatigueRmsSlopes);
    if (fatigueRmsSlope != null) {
      newRmsSlopes.add(fatigueRmsSlope);
      while (newRmsSlopes.length > 10) {
        newRmsSlopes.removeAt(0);
      }
    }
    final newMdfSlopes = List<double>.from(cur.recentFatigueMdfSlopes);
    if (fatigueMdfSlope != null) {
      newMdfSlopes.add(fatigueMdfSlope);
      while (newMdfSlopes.length > 10) {
        newMdfSlopes.removeAt(0);
      }
    }
    final newTimeToFatigue = List<double>.from(cur.recentTimeToFatigueSec);
    if (timeToFatigueSec != null) {
      newTimeToFatigue.add(timeToFatigueSec);
      while (newTimeToFatigue.length > 10) {
        newTimeToFatigue.removeAt(0);
      }
    }

    final updated = cur.copyWith(
      mvcRms: updatedMvc,
      restingRms: updatedRest,
      mdfBaseline: updatedMdf,
      sessionCount: cur.sessionCount + 1,
      lastSessionAt: DateTime.now().toIso8601String(),
      recentFatigueRmsSlopes: newRmsSlopes,
      recentFatigueMdfSlopes: newMdfSlopes,
      recentTimeToFatigueSec: newTimeToFatigue,
    );
    await save(updated);
  }
}

/// 앱 전역 ProfileService 싱글톤. main()에서 init() 호출 필요.
final ProfileService gProfileService = ProfileService();
