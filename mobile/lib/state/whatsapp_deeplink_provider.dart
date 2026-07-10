import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Sprint 10.0 — WhatsApp deep link helper.
///
/// `url_launcher` opens `whatsapp://send?text=<urlencoded-message>` on
/// Android. If WhatsApp is not installed, `canLaunchUrl` returns false
/// and the caller is expected to surface a fallback snackbar.
///
/// Audit gap S26 ensures this URI literal exists in
/// `lib/screens/whatsapp_task_detail_screen.dart` (the audit is a
/// forward-looking invariant for future sprints that may try to swap
/// the deep link for a different scheme).
class WhatsAppDeepLink {
  WhatsAppDeepLink._();

  static const String _scheme = 'whatsapp://send';
  static const String message =
      'Bu mesaj şifreleme bütünlüğü için test amacıyla gönderilmiştir.';

  /// Build the URI. Exposed so tests / audit can assert the exact
  /// `whatsapp://send?text=...` literal.
  static Uri buildUri() {
    return Uri.parse(
      '$_scheme?text=${Uri.encodeComponent(message)}',
    );
  }

  /// Try to open WhatsApp with the prepared message. Returns true if
  /// the platform handed the intent to WhatsApp. Caller is responsible
  /// for showing a fallback snackbar when this is false.
  static Future<bool> tryOpen() async {
    final uri = buildUri();
    if (!await canLaunchUrl(uri)) {
      return false;
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on PlatformException {
      return false;
    }
  }
}
