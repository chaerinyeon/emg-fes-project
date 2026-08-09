import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/local/session_store.dart';
import '../app_state.dart';
import '../charts/trend_chart.dart';
import '../refit_theme.dart';
import '../session_language.dart';

/// 세부 기록 — 그래프 · 분석 결과 · 원시 데이터.
///
/// **여기는 치료사·보호자의 화면이다.** 환자 화면의 규칙(퍼센트 금지 등)이
/// 적용되지 않는다. 대신 무엇이 판정의 근거이고 무엇이 관찰용인지 화면에서
/// 구분해 준다 — 섞이면 RMS 가 떨어졌다는 이유로 피로를 선언하게 된다.
class SessionDetailScreen extends StatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final SessionSummary session;

  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  List<BurstRow>? _rows;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await gApp.store.series(widget.session.id);
    if (mounted) setState(() => _rows = rows);
  }

  /// 피로 구간이 시작되는 지점(0~1). 없으면 음영도 없다.
  double? get _shadeFrom {
    final onset = widget.session.onsetS;
    final total = widget.session.durationS;
    if (onset == null || total <= 0) return null;
    return (onset / total).clamp(0.0, 1.0);
  }

  Future<void> _exportCsv({required bool share}) async {
    final rows = _rows ?? const <BurstRow>[];
    final s = widget.session;
    final buf = StringBuffer()
      ..writeln('# session_id,${s.id}')
      ..writeln('# patient_id,${s.patientId}')
      ..writeln('# started_at,${s.startedAt.toIso8601String()}')
      ..writeln('# end_reason,${s.endReason.code}')
      ..writeln('# stim_period_ms,${s.stimPeriodMs}')
      ..writeln('t_s,p2p,fatigue,rms,mdf,contraction_ok,valid');
    for (final r in rows) {
      buf.writeln('${r.tS.toStringAsFixed(3)},'
          '${r.p2p.toStringAsFixed(2)},'
          '${r.fatigue.toStringAsFixed(2)},'
          '${r.rms?.toStringAsFixed(2) ?? ''},'
          '${r.mdf?.toStringAsFixed(2) ?? ''},'
          '${r.contractionOk ? 1 : 0},'
          '${r.valid ? 1 : 0}');
    }

    final dir = await getTemporaryDirectory();
    final name =
        'refit_${s.startedAt.toIso8601String().replaceAll(RegExp(r'[:.]'), '')}'
        '.csv';
    final file = File('${dir.path}/$name');
    await file.writeAsString(buf.toString());

    if (!mounted) return;
    if (share) {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'RE-FIT 세션 기록'),
      );
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('내보냈어요 · ${file.path}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final rows = _rows;
    final t = s.startedAt;

    return Scaffold(
      body: RefitBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      color: RefitTheme.inkSoft,
                    ),
                    Expanded(
                      child: Text(
                        '${t.year}.${t.month}.${t.day} '
                        '${t.hour.toString().padLeft(2, '0')}:'
                        '${t.minute.toString().padLeft(2, '0')}',
                        style: RefitTheme.bodySmall.copyWith(
                          color: RefitTheme.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    RefitChip(
                      label: '신뢰도 ${s.reliabilityGrade}',
                      tone: switch (s.reliabilityGrade) {
                        'A' => RefitTheme.glow,
                        'B' => RefitTheme.caution,
                        _ => RefitTheme.tired,
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: rows == null
                    ? const Center(
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: RefitTheme.glow),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        children: [
                          _Summary(session: s),

                          const RefitSectionTitle('그래프'),
                          _Chart(
                            title: 'M-wave 진폭',
                            note: '★ 피로 판정의 근거',
                            color: RefitTheme.glow,
                            values: rows.map((r) => r.p2p).toList(),
                            shadeFrom: _shadeFrom,
                          ),
                          _Chart(
                            title: 'RMS',
                            note: '관찰용 — 판정에 쓰지 않는다',
                            color: RefitTheme.caution,
                            values: rows
                                .map((r) => r.rms)
                                .whereType<double>()
                                .toList(),
                            shadeFrom: _shadeFrom,
                          ),
                          _Chart(
                            title: 'MDF',
                            note: '관찰용 — 판정에 쓰지 않는다',
                            color: RefitTheme.tired,
                            values: rows
                                .map((r) => r.mdf)
                                .whereType<double>()
                                .toList(),
                            shadeFrom: _shadeFrom,
                          ),

                          const RefitSectionTitle('분석 결과'),
                          RefitCard(
                            child: Column(
                              children: [
                                _kv('종료 이유', endReasonLabel(s.endReason)),
                                _kv('최대 피로',
                                    '${s.maxFatigue.toStringAsFixed(1)}%'),
                                _kv('종료 시점 피로',
                                    '${s.endFatigue.toStringAsFixed(1)}%'),
                                _kv('피로 발생 시점',
                                    s.onsetS == null
                                        ? '없음'
                                        : formatDurationKo(
                                            s.onsetS!.round())),
                                _kv('레벨 변화 횟수', '${s.levelChangeCount}회'),
                                _kv('검출률', s.detectRate.toStringAsFixed(3)),
                                _kv(
                                    'events/burst 중앙값',
                                    s.eventsPerBurstMedian
                                        .toStringAsFixed(2)),
                                _kv('자극 주기 (실측)', '${s.stimPeriodMs} ms'),
                                _kv('강도 단계', '${s.intensityLevel}단계'),
                                _kv('앱 / 펌웨어',
                                    '${s.appVersion} / ${s.fwVersion}'),
                              ],
                            ),
                          ),

                          const RefitSectionTitle('원시 데이터'),
                          RefitCard(
                            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                            child: Column(
                              children: [
                                RefitTile(
                                  title: '버스트 시계열',
                                  subtitle: '${rows.length}행 · '
                                      '1kHz 파형은 저장하지 않습니다',
                                  leading: Icons.table_rows_outlined,
                                  trailing: Icon(
                                    _showRaw
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    color: RefitTheme.inkFaint,
                                  ),
                                  onTap: () =>
                                      setState(() => _showRaw = !_showRaw),
                                ),
                                if (_showRaw) _RawTable(rows: rows),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: RefitButton(
                                  label: 'CSV 내보내기',
                                  filled: false,
                                  onPressed: () => _exportCsv(share: false),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: RefitButton(
                                  label: '공유',
                                  filled: false,
                                  tone: RefitTheme.inkSoft,
                                  onPressed: () => _exportCsv(share: true),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(k, style: RefitTheme.bodySmall)),
            Text(
              v,
              style: RefitTheme.bodySmall.copyWith(
                color: RefitTheme.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.session});

  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final s = session;
    return RefitCard(
      child: Row(
        children: [
          Expanded(child: _cell('${s.repCount}', '번 쥐었어요')),
          Expanded(child: _cell(formatDurationKo(s.durationS), '운동 시간')),
          Expanded(child: _cell(successRatioLine(s.successRate), '수행 성공률')),
        ],
      ),
    );
  }

  Widget _cell(String v, String k) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(v,
              style: RefitTheme.bodySmall.copyWith(
                color: RefitTheme.ink,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              )),
          const SizedBox(height: 4),
          Text(k,
              style: RefitTheme.bodySmall
                  .copyWith(fontSize: 13, color: RefitTheme.inkFaint)),
        ],
      );
}

class _Chart extends StatelessWidget {
  const _Chart({
    required this.title,
    required this.note,
    required this.color,
    required this.values,
    required this.shadeFrom,
  });

  final String title;
  final String note;
  final Color color;
  final List<double> values;
  final double? shadeFrom;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: RefitCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: RefitTheme.bodySmall.copyWith(
                      color: RefitTheme.ink,
                      fontWeight: FontWeight.w600,
                    )),
                const Spacer(),
                Text(note,
                    style: RefitTheme.bodySmall
                        .copyWith(fontSize: 12, color: RefitTheme.inkFaint)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: TrendChart(
                values: values,
                color: color,
                shadeFrom: shadeFrom,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 버스트 시계열 표. 행이 수백 개라 스크롤 영역을 따로 준다.
class _RawTable extends StatelessWidget {
  const _RawTable({required this.rows});

  final List<BurstRow> rows;

  @override
  Widget build(BuildContext context) {
    const head = TextStyle(
        fontSize: 12, color: RefitTheme.inkFaint, fontWeight: FontWeight.w600);
    const cell = TextStyle(fontSize: 12, color: RefitTheme.inkSoft);

    Widget row(List<String> cells, TextStyle style) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Row(
            children: [
              for (final c in cells)
                Expanded(child: Text(c, style: style)),
            ],
          ),
        );

    return Column(
      children: [
        const Divider(height: 12, color: RefitTheme.hairline),
        row(const ['t(s)', 'p2p', '피로', 'RMS', 'MDF', '수축'], head),
        SizedBox(
          height: 240,
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, i) {
              final r = rows[i];
              return row([
                r.tS.toStringAsFixed(1),
                r.p2p.toStringAsFixed(0),
                r.fatigue.toStringAsFixed(0),
                r.rms?.toStringAsFixed(0) ?? '—',
                r.mdf?.toStringAsFixed(0) ?? '—',
                r.contractionOk ? 'O' : '·',
              ], cell);
            },
          ),
        ),
      ],
    );
  }
}
