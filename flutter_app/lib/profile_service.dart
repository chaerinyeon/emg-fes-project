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

/// 환자별 측정 프로파일.
/// 캘리브레이션 세션에서 MVC·resting·baseline 등을 채워 영구 저장.
class UserProfile {
  final String id; // UUID 또는 임의 슬러그
  String name; // 표시명 (예: "Subject A", "김환자")
  double? mvcRms; // 최대 수축 시 RMS (Maximum Voluntary Contraction)
  double? restingRms; // 휴식 시 평균 RMS (baseline)
  double? mdfBaseline; // 휴식 시 평균 MDF (Hz)
  int sessionCount; // 세션 누적 횟수
  String? lastSessionAt; // ISO 8601 timestamp
  List<double> recentFatigueRmsSlopes; // 직전 N개 세션의 피로 시점 RMS slope
  List<double> recentFatigueMdfSlopes; // 같은 방식 MDF slope

  UserProfile({
    required this.id,
    required this.name,
    this.mvcRms,
    this.restingRms,
    this.mdfBaseline,
    this.sessionCount = 0,
    this.lastSessionAt,
    List<double>? recentFatigueRmsSlopes,
    List<double>? recentFatigueMdfSlopes,
  }) : recentFatigueRmsSlopes = recentFatigueRmsSlopes ?? <double>[],
       recentFatigueMdfSlopes = recentFatigueMdfSlopes ?? <double>[];

  Map<String, dynamic> toJson() => {
    'name': name,
    'mvcRms': mvcRms,
    'restingRms': restingRms,
    'mdfBaseline': mdfBaseline,
    'sessionCount': sessionCount,
    'lastSessionAt': lastSessionAt,
    'recentFatigueRmsSlopes': recentFatigueRmsSlopes,
    'recentFatigueMdfSlopes': recentFatigueMdfSlopes,
  };

  factory UserProfile.fromJson(Map<String, dynamic> j, String id) {
    return UserProfile(
      id: id,
      name: (j['name'] as String?) ?? id,
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
    );
  }

  UserProfile copyWith({
    String? name,
    double? mvcRms,
    double? restingRms,
    double? mdfBaseline,
    int? sessionCount,
    String? lastSessionAt,
    List<double>? recentFatigueRmsSlopes,
    List<double>? recentFatigueMdfSlopes,
  }) {
    return UserProfile(
      id: id,
      name: name ?? this.name,
      mvcRms: mvcRms ?? this.mvcRms,
      restingRms: restingRms ?? this.restingRms,
      mdfBaseline: mdfBaseline ?? this.mdfBaseline,
      sessionCount: sessionCount ?? this.sessionCount,
      lastSessionAt: lastSessionAt ?? this.lastSessionAt,
      recentFatigueRmsSlopes:
          recentFatigueRmsSlopes ?? this.recentFatigueRmsSlopes,
      recentFatigueMdfSlopes:
          recentFatigueMdfSlopes ?? this.recentFatigueMdfSlopes,
    );
  }
}

class ProfileService {
  static const String _boxName = 'profiles';
  static const String _activeKey = '__active_profile_id';

  late Box<String> _box;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
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

    final updated = cur.copyWith(
      mvcRms: updatedMvc,
      restingRms: updatedRest,
      mdfBaseline: updatedMdf,
      sessionCount: cur.sessionCount + 1,
      lastSessionAt: DateTime.now().toIso8601String(),
      recentFatigueRmsSlopes: newRmsSlopes,
      recentFatigueMdfSlopes: newMdfSlopes,
    );
    await save(updated);
  }
}
