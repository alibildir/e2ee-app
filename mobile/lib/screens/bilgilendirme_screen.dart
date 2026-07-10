import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/is_accepted_provider.dart';
import '../theme/app_theme.dart';

/// Sprint 10.0 — Bilgilendirme (formerly Consent).
///
/// The screen renders a deep-teal hero (linear gradient #2F6F5E →
/// #1F4D40), a shield icon, the "Ağ Güvenliği Aracı" tag, and the
/// updated copy that promises NO phone number, device info, or IP
/// leaves the device. The user taps "Anladım, Devam Et" to mark
/// `isAcceptedProvider = true` and route to `/home`.
///
/// S25 invariant: no "v-p-n" framing in the UI; the Ağ Güvenliği
/// Aracı copy replaces it. See `docs/SPRINT-10-SCOPE.md` and
/// `sprint10-wireframes.html` frame 1.
class BilgilendirmeScreen extends ConsumerWidget {
  const BilgilendirmeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppTheme.surface,
      body: SafeArea(
        child: Column(
          children: [
            // Hero — gradient + shield + tag + heading.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppTheme.primary, AppTheme.primaryDark],
                ),
              ),
              child: Column(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(
                      Icons.shield_outlined,
                      size: 32,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'AĞ GÜVENLİĞİ ARACI',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Bilgilendirme',
                    style: TextStyle(
                      fontSize: 22,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            // Body — exact wireframe text.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 24,
                ),
                child: Center(
                  child: Text(
                    'OpenE2EE için gönüllü olduğunuz için teşekkürler. '
                    'Taahhütümüzün arkasındayız, kesinlikle telefon '
                    'numaranız, cihaz bilgileriniz, ip adresiniz '
                    'telefonunuzdan dışarıya çıkmamaktadır.',
                    textAlign: TextAlign.start,
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTheme.text.withValues(alpha: 0.85),
                      height: 1.65,
                    ),
                  ),
                ),
              ),
            ),
            // Action — primary button.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    ref.read(isAcceptedProvider.notifier).state = true;
                    context.go('/home');
                  },
                  child: const Text('Anladım, Devam Et'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
