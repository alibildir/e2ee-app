import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sprint 10.0 — Aktif Nöbet (Active Pool) mock state.
///
/// Three stats are surfaced on the active pool screen (see
/// `sprint10-wireframes.html` frame 4):
///   - `paketSayisi`   : number of packets observed in the local sample
///   - `gonulluSayisi` : number of connected volunteers
///   - `testEdilenler` : which transports have been verified in this
///                       session (subset of `{rcs, whatsapp}`)
///
/// All values are mock — Sprint 10.1+ wires these to the local Go
/// aggregator. The pool toggle (`isAlici`) is local UI state; the
/// mock numbers do NOT change when the toggle is flipped (UI only).
class PoolState {
  const PoolState({
    required this.isAlici,
    required this.paketSayisi,
    required this.gonulluSayisi,
    required this.testEdilenler,
  });

  final bool isAlici;
  final int paketSayisi;
  final int gonulluSayisi;
  final Set<String> testEdilenler;

  PoolState copyWith({
    bool? isAlici,
    int? paketSayisi,
    int? gonulluSayisi,
    Set<String>? testEdilenler,
  }) {
    return PoolState(
      isAlici: isAlici ?? this.isAlici,
      paketSayisi: paketSayisi ?? this.paketSayisi,
      gonulluSayisi: gonulluSayisi ?? this.gonulluSayisi,
      testEdilenler: testEdilenler ?? this.testEdilenler,
    );
  }
}

class PoolNotifier extends StateNotifier<PoolState> {
  PoolNotifier()
      : super(const PoolState(
          isAlici: true,
          paketSayisi: 247,
          gonulluSayisi: 3,
          testEdilenler: {'rcs', 'whatsapp'},
        ));

  void toggleAlici() {
    state = state.copyWith(isAlici: !state.isAlici);
  }
}

final poolProvider = StateNotifierProvider<PoolNotifier, PoolState>(
  (ref) => PoolNotifier(),
);
