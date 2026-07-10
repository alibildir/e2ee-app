import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bilgilendirme (consent) acceptance flag.
///
/// Sprint 10.0 — this is a mock, in-memory flag only. Persisted consent
/// arrives in Sprint 10.1+. On the very first run, the value is `false`
/// and the app routes the user to `/bilgilendirme` first.
final isAcceptedProvider = StateProvider<bool>((ref) => false);
