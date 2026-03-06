import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:http/http.dart' as http;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:screenshot/screenshot.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'localization.dart';   // L.t("key") — all user-visible strings

// ══════════════════════════════════════════════════════════════
// NATIVE METHOD CHANNELS
// ══════════════════════════════════════════════════════════════

const MethodChannel _overlayChannel      = MethodChannel('overlay');
const MethodChannel _captureChannel      = MethodChannel('screen_capture');
const MethodChannel _callStateChannel    = MethodChannel('call_state');
const MethodChannel _notificationChannel = MethodChannel('notification_reader');

Future<void> _startOverlay()             async { try { await _overlayChannel.invokeMethod('startOverlay'); }             catch (e) { debugPrint('❌ [OVERLAY] $e'); } }
Future<void> _stopOverlay()              async { try { await _overlayChannel.invokeMethod('stopOverlay'); }              catch (e) { debugPrint('❌ [OVERLAY] $e'); } }
Future<void> _requestOverlayPermission() async { try { await _overlayChannel.invokeMethod('requestOverlayPermission'); } catch (e) { debugPrint('❌ [OVERLAY] $e'); } }
Future<bool> _hasOverlayPermission()     async { try { return await _overlayChannel.invokeMethod<bool>('hasOverlayPermission') ?? false; } catch (_) { return false; } }

Future<void> _showCallAlert(String number, String level, String message) async {
  try { await _overlayChannel.invokeMethod('showCallAlert', {'number': number, 'level': level, 'message': message}); }
  catch (e) { debugPrint('❌ [OVERLAY] showCallAlert: $e'); }
}

Future<void> _showScamOverlay(ScanResult result, {String source = 'Message'}) async {
  try {
    await _overlayChannel.invokeMethod('showScamAlert', {
      'source':        source,
      'probability':   result.scamProbability.toInt(),
      'riskLevel':     result.riskLevel.label,
      'fraudType':     result.fraudType.label,
      'fraudEmoji':    result.fraudType.emoji,
      'explanation':   result.explanation,
      'whatToDo':      result.whatToDo,
      'keywords':      result.suspiciousKeywords.take(4).join(', '),
      'helpline':      result.helpline,
      'showHelpline':  result.showFullWarning,
    });
  } catch (e) {
    debugPrint('❌ [OVERLAY] showScamAlert: $e');
  }
}

const _kOverlayEnabled       = 'overlay_enabled';
const _kNotificationEnabled  = 'notification_enabled';


// ══════════════════════════════════════════════════════════════
// THEME COLORS
// ══════════════════════════════════════════════════════════════

class _C {
  static const safe       = Color(0xFF2ED573);
  static const suspicious = Color(0xFFFF9F43);
  static const highRisk   = Color(0xFFFF4757);
  static const unknown    = Color(0xFF54A0FF);
  static const cardBg     = Color(0xFF1e1e2e);
}

// ══════════════════════════════════════════════════════════════
// ══════════════════════════════════════════════════════════════
// CONSTANTS
// ══════════════════════════════════════════════════════════════

const double _kScamWarningThreshold = 65.0;
const int    _kHistoryMax           = 50;
const int    _kOcrMaxChars          = 3000;
const int    _kContactsCacheMins    = 5;
const int    _kCallDebounceMsec     = 450;

// ══════════════════════════════════════════════════════════════
// PENDING SCREENSHOT ACCUMULATOR
// ══════════════════════════════════════════════════════════════

final List<String>       _pendingScreenshots      = [];
final ValueNotifier<int> _pendingScreenshotCount  = ValueNotifier(0);

// ══════════════════════════════════════════════════════════════
// ENTRY POINT
// ══════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load saved language before first frame
  final prefs = await SharedPreferences.getInstance();
  L.current = prefs.getString('lang') ?? 'te';
  runApp(const ScamShieldApp());
}

class ScamShieldApp extends StatelessWidget {
  const ScamShieldApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ScamShield',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1a1a2e), brightness: Brightness.dark),
      useMaterial3: true,
    ),
    home: const HomeScreen(),
  );
}

// ══════════════════════════════════════════════════════════════
// ENUMS
// ══════════════════════════════════════════════════════════════

enum RiskLevel { safe, suspicious, highRisk }
enum FraudType { upi, job, lottery, phishing, kyc, other, none }

extension RiskLevelExt on RiskLevel {
  String   get label => switch (this) { RiskLevel.safe => 'Safe', RiskLevel.suspicious => 'Suspicious', RiskLevel.highRisk => 'High Risk' };
  Color    get color => switch (this) { RiskLevel.safe => _C.safe, RiskLevel.suspicious => _C.suspicious, RiskLevel.highRisk => _C.highRisk };
  IconData get icon  => switch (this) { RiskLevel.safe => Icons.verified_user_rounded, RiskLevel.suspicious => Icons.warning_amber_rounded, RiskLevel.highRisk => Icons.gpp_bad_rounded };
  static RiskLevel fromString(String s) {
    final l = s.toLowerCase();
    if (l.contains('high')) return RiskLevel.highRisk;
    if (l.contains('susp')) return RiskLevel.suspicious;
    return RiskLevel.safe;
  }
}

extension FraudTypeExt on FraudType {
  String get label => switch (this) { FraudType.upi => 'UPI Fraud', FraudType.job => 'Job Scam', FraudType.lottery => 'Lottery Scam', FraudType.phishing => 'Phishing', FraudType.kyc => 'KYC Scam', FraudType.other => 'Other Scam', FraudType.none => 'Safe Message' };
  String get biLabel => switch (this) { FraudType.upi => L.t('fraud_upi'), FraudType.job => L.t('fraud_job'), FraudType.lottery => L.t('fraud_lottery'), FraudType.phishing => L.t('fraud_phishing'), FraudType.kyc => L.t('fraud_kyc'), FraudType.other => L.t('fraud_other'), FraudType.none => L.t('fraud_safe') };
  String get emoji => switch (this) { FraudType.upi => '💸', FraudType.job => '💼', FraudType.lottery => '🎰', FraudType.phishing => '🎣', FraudType.kyc => '🆔', FraudType.other => '⚠️', FraudType.none => '✅' };
  Color  get color => switch (this) { FraudType.upi => const Color(0xFF2196F3), FraudType.job => const Color(0xFFFF9800), FraudType.lottery => const Color(0xFF9C27B0), FraudType.phishing => const Color(0xFFF44336), FraudType.kyc => const Color(0xFFFF5722), FraudType.other => const Color(0xFF607D8B), FraudType.none => const Color(0xFF2ED573) };
  static FraudType fromString(String s) {
    final l = s.toLowerCase();
    if (l.contains('upi'))     return FraudType.upi;
    if (l.contains('job'))     return FraudType.job;
    if (l.contains('lottery')) return FraudType.lottery;
    if (l.contains('phish'))   return FraudType.phishing;
    if (l.contains('kyc'))     return FraudType.kyc;
    if (l.contains('safe') || l.contains('none')) return FraudType.none;
    return FraudType.other;
  }
}

// ══════════════════════════════════════════════════════════════
// MODELS
// ══════════════════════════════════════════════════════════════

class ScanResult {
  final double        scamProbability;
  final bool          isScam;
  final RiskLevel     riskLevel;
  final FraudType     fraudType;
  final List<String>  suspiciousKeywords;
  final String        explanation;
  final List<String>  preventionTips;
  final String        whatToDo;
  final String        helpline;
  final String        originalText;
  final DateTime      timestamp;

  const ScanResult({
    required this.scamProbability, required this.isScam,            required this.riskLevel,
    required this.fraudType,       required this.suspiciousKeywords, required this.explanation,
    required this.preventionTips,  required this.whatToDo,           required this.helpline,
    required this.originalText,    required this.timestamp,
  });

  bool get showFullWarning => scamProbability >= _kScamWarningThreshold;

  factory ScanResult.fromApiJson(Map<String, dynamic> j, String text) {
    final prob = (j['scam_probability'] as num? ?? 0).toDouble();
    return ScanResult(
      scamProbability:    prob, isScam: prob >= 50,
      riskLevel:          RiskLevelExt.fromString(j['risk_level']        as String? ?? ''),
      fraudType:          FraudTypeExt.fromString(j['fraud_type']        as String? ?? ''),
      suspiciousKeywords: List<String>.from(j['suspicious_keywords'] ?? []),
      explanation:        j['explanation']   as String? ?? '',
      preventionTips:     List<String>.from(j['prevention_tips'] ?? []),
      whatToDo:           j['what_to_do']    as String? ?? '',
      helpline:           j['helpline']      as String? ?? '1930',
      originalText: text, timestamp: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'scam_probability': scamProbability, 'is_scam': isScam,             'risk_level':  riskLevel.label,
    'fraud_type':       fraudType.label, 'keywords': suspiciousKeywords, 'explanation': explanation,
    'prevention_tips':  preventionTips,  'what_to_do': whatToDo,         'helpline':    helpline,
    'original_text':    originalText,    'timestamp': timestamp.toIso8601String(),
  };

  factory ScanResult.fromStoredJson(Map<String, dynamic> j) {
    final prob = (j['scam_probability'] as num? ?? 0).toDouble();
    return ScanResult(
      scamProbability:    prob, isScam: j['is_scam'] as bool? ?? prob >= 50,
      riskLevel:          RiskLevelExt.fromString(j['risk_level']  as String? ?? ''),
      fraudType:          FraudTypeExt.fromString(j['fraud_type']  as String? ?? ''),
      suspiciousKeywords: List<String>.from(j['keywords'] ?? []),
      explanation:        j['explanation']   as String? ?? '',
      preventionTips:     List<String>.from(j['prevention_tips'] ?? []),
      whatToDo:           j['what_to_do']    as String? ?? '',
      helpline:           j['helpline']      as String? ?? '1930',
      originalText:       j['original_text'] as String? ?? '',
      timestamp:          DateTime.parse(j['timestamp'] as String),
    );
  }
}

class NumberCheckResult {
  final String     number;
  final NumberRisk risk;
  final String     reason;
  final String     advice;
  const NumberCheckResult({required this.number, required this.risk, required this.reason, required this.advice});
}

enum NumberRisk { spam, suspicious, unknown }

extension NumberRiskExt on NumberRisk {
  Color  get color => switch (this) { NumberRisk.spam => _C.highRisk, NumberRisk.suspicious => _C.suspicious, NumberRisk.unknown => _C.unknown };
  String get emoji => switch (this) { NumberRisk.spam => '🚨', NumberRisk.suspicious => '⚠️', NumberRisk.unknown => 'ℹ️' };
  String get title => switch (this) { NumberRisk.spam => 'SPAM CALL DETECTED', NumberRisk.suspicious => 'SUSPICIOUS CALL', NumberRisk.unknown => 'UNKNOWN CALLER' };
}

// ══════════════════════════════════════════════════════════════
// NUMBER REPUTATION SERVICE
// ══════════════════════════════════════════════════════════════

class NumberReputationService {
  static const _apiKey = 'num_live_REEqr8r06XIDAC6D2rs5qrCFu4t6sKzWz4Vf2sEr';
  static const _base   = 'https://api.numlookupapi.com/v1/validate/';
  static final Map<String, NumberCheckResult> _cache = {};

  static Future<NumberCheckResult> check(String rawNumber) async {
    final number = normalise(rawNumber);
    if (number.isEmpty) return _unknown(rawNumber.isEmpty ? 'Unknown' : rawNumber);
    if (_cache.containsKey(number)) return _cache[number]!;
    try {
      final res = await http.get(Uri.parse('$_base$number?apikey=$_apiKey')).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final r = _parseApiResponse(number, jsonDecode(res.body) as Map<String, dynamic>);
        _cache[number] = r;
        return r;
      }
    } catch (e) { debugPrint('⚠️ [NUMBER] API failed: $e — using heuristics'); }
    final r = _localHeuristics(number);
    _cache[number] = r;
    return r;
  }

  static NumberCheckResult _parseApiResponse(String number, Map<String, dynamic> d) {
    final valid    = d['valid']         as bool?   ?? false;
    final lineType = (d['line_type']    as String? ?? '').toLowerCase();
    final country  = (d['country_code'] as String? ?? '').toUpperCase();
    if (!valid)
      return NumberCheckResult(number: number, risk: NumberRisk.suspicious,
          reason: 'ఈ నంబర్ invalid గా కనిపిస్తోంది.\nYe number invalid lag raha hai.',
          advice: 'జాగ్రత్తగా ఉండండి. Personal details share చేయకండి.');
    if (lineType == 'voip' || lineType == 'premium' || lineType == 'toll_free')
      return NumberCheckResult(number: number, risk: NumberRisk.suspicious,
          reason: '${lineType.toUpperCase()} నంబర్ — స్కామర్లు ఉపయోగిస్తారు.\nYe ${lineType.toUpperCase()} number hai — scammer use karte hain.',
          advice: L.t('dont_otp'));
    if (country == 'IN') return _localHeuristics(number);
    return NumberCheckResult(number: number, risk: NumberRisk.unknown,
        reason: 'ఈ నంబర్ verify చేయలేకపోయాం.\nIs number ko verify nahi kar sake.',
        advice: 'Personal details share చేయకండి.\nPersonal details share mat karo.');
  }

  static NumberCheckResult _localHeuristics(String number) {
    final clean = number.replaceAll(RegExp(r'\D'), '');
    if (clean.startsWith('92') && clean.length >= 11)
      return NumberCheckResult(number: number, risk: NumberRisk.spam,
          reason: 'Pakistan (+92) నుండి కాల్ — భారతీయులను target చేసే scam call.\nPakistan se call — Indian logo ko target karta hai.',
          advice: '${L.t('dont_otp')}\n${L.t('block_num')}');
    if (clean.startsWith('1') && clean.length == 11)
      return NumberCheckResult(number: number, risk: NumberRisk.suspicious,
          reason: 'USA/Canada నంబర్ — Indian banks/govt అని claim చేస్తే scam.\nUSA number — India bank/govt bolta hai toh SCAM hai.',
          advice: L.t('dont_otp'));
    if (clean.startsWith('140') || clean.startsWith('160'))
      return NumberCheckResult(number: number, risk: NumberRisk.suspicious,
          reason: 'Telemarketing నంబర్ — OTP అడిగితే scam.\nTelemarketing number — OTP maange toh SCAM.',
          advice: '${L.t('dont_otp')}\n${L.t('dont_pin')}');
    if (_isRepeatingPattern(clean))
      return NumberCheckResult(number: number, risk: NumberRisk.spam,
          reason: 'Suspicious repeating pattern — spoofed number.\nSandehaspada number — fake lag raha hai.',
          advice: '${L.t('dont_otp')}\n${L.t('block_num')}');
    if (clean.length < 8)
      return NumberCheckResult(number: number, risk: NumberRisk.suspicious,
          reason: 'చాలా చిన్న నంబర్ — అనుమానాస్పదం.\nBahut chhota number — sandehaspada.',
          advice: 'Caller identity verify చేయండి.');
    return NumberCheckResult(number: number, risk: NumberRisk.unknown,
        reason: 'ఈ నంబర్ contacts లో లేదు.\nYe number contacts mein nahi hai.',
        advice: 'OTP, Bank PIN, Aadhaar share చేయకండి.\nOTP, Bank PIN, Aadhaar mat batao.');
  }

  static bool   _isRepeatingPattern(String s) { if (s.length < 6) return false; final d = s.replaceAll(RegExp(r'^\+?[0-9]{1,3}'), ''); return d.isNotEmpty && d.split('').toSet().length <= 2; }

  static String normalise(String n) {
    if (n.trim().isEmpty) return '';
    var s = n.replaceAll(RegExp(r'[\s\-\(\.\)]+'), '');
    if (s.startsWith('0')) s = '+91${s.substring(1)}';
    if (!s.startsWith('+') && s.length == 10) s = '+91$s';
    return s;
  }

  static NumberCheckResult _unknown(String n) => NumberCheckResult(
      number: n, risk: NumberRisk.unknown,
      reason: 'ఈ నంబర్ identify చేయలేకపోయాం.',
      advice: 'Personal details share చేయకండి.');
}

// ══════════════════════════════════════════════════════════════
// NOTIFICATION SMART FILTER
// Aggressively suppresses authentic/known messages.
// Only scam-pattern messages pass through to AI.
// ══════════════════════════════════════════════════════════════

class _NotifFilter {
  // ── Definite-safe senders (regex on app name or title) ──────
  static final _safeSenders = RegExp(
    r'(HDFC|ICICI|SBI|Axis|Kotak|PNB|BOB|Canara|Union Bank|Paytm|PhonePe|GPay|Google Pay'
    r'|Amazon|Flipkart|Swiggy|Zomato|Uber|Ola|IRCTC|Jio|Airtel|BSNL|Vi |Vodafone'
    r'|NSDL|CDSL|Zerodha|Groww|CRED|MakeMyTrip|BookMyShow'
    r'|DM-|VK-|AX-|AD-|BK-|VM-|BP-|CP-|CP-|DL-|MH-|TN-|KA-|AP-|TS-)',
    caseSensitive: false,
  );

  // ── Message patterns that are 100% legitimate ───────────────
  static final _safePatterns = [
    // OTP — always legitimate bank/app generated
    RegExp(r'\b\d{4,8}\b.*\b(otp|one.?time|code)\b', caseSensitive: false),
    RegExp(r'\b(otp|code)\b.*\b\d{4,8}\b', caseSensitive: false),
    // Delivery / order confirmations
    RegExp(r'\b(delivered|out for delivery|shipped|dispatched|order.?placed|order.?confirmed)\b', caseSensitive: false),
    // Balance alerts / transaction confirmations from banks (contain Rs/INR amount)
    RegExp(r'\b(debited|credited|balance|available bal|txn|transaction).{0,40}(rs\.?|inr|₹)\s*\d', caseSensitive: false),
    RegExp(r'(rs\.?|inr|₹)\s*\d.{0,40}\b(debited|credited|received|paid|charged)\b', caseSensitive: false),
    // Recharge / bill payment success
    RegExp(r'\b(recharge|bill.?paid|payment.?success|payment.?received)\b', caseSensitive: false),
    // Promotional — offer/sale/discount from known retail patterns
    RegExp(r'\b(sale|offer|discount|cashback|coupon|promo)\b.{0,60}\b(shop|buy|get|avail)\b', caseSensitive: false),
    // Booking confirmations
    RegExp(r'\b(ticket|booking|reservation|confirmed|pnr|seat)\b', caseSensitive: false),
    // App notifications with action words that are generic
    RegExp(r'\b(liked your|commented|started following|sent you a message|accepted your)\b', caseSensitive: false),
  ];

  // ── Definite scam signal patterns (bypass AI, immediate flag) ─
  static final _instantScam = [
    // Suspicious shortened / custom URLs
    RegExp(r'https?://(bit\.ly|tinyurl|t\.me|wa\.me|goo\.gl|tiny\.cc|rb\.gy|shorte\.st|is\.gd)/', caseSensitive: false),
    RegExp(r'https?://[a-z0-9\-]+\.(xyz|top|club|online|site|info|live|win|buzz)\b', caseSensitive: false),
    // Credential harvest phrases
    RegExp(r'\b(verify.{0,15}account|confirm.{0,15}identity|update.{0,15}details|account.{0,10}(suspended|blocked|expired))\b', caseSensitive: false),
    RegExp(r'\b(click.{0,10}link|tap.{0,10}link|login.{0,10}link|reset.{0,10}password)\b', caseSensitive: false),
    // Remote access — highest risk
    RegExp(r'\b(anydesk|teamviewer|airdroid|remote.?access|screen.?share)\b', caseSensitive: false),
    // Fake govt/legal threat
    RegExp(r'\b(arrested|cyber.?crime|legal.?notice|case.?filed|court|police.{0,10}notice)\b', caseSensitive: false),
    // KYC / Aadhaar link scams
    RegExp(r'\b(kyc.{0,20}(link|update|expire|complete)|aadhaar.{0,10}(link|expire|block))\b', caseSensitive: false),
  ];

  // ── Telugu & Hindi scam phrases (instant flag) ───────────────
  static final _teluguHindiScam = [
    // Telugu
    RegExp(r'(OTP చెప్పండి|లింక్ క్లిక్|గెలిచారు|బహుమతి|ఖాతా బ్లాక్|KYC పూర్తి|లాటరీ|ఉద్యోగం)', caseSensitive: false),
    // Hindi
    RegExp(r'(OTP batao|link kholein|jeet gaye|inaam|account band|KYC karo|lottery|naukri)', caseSensitive: false),
  ];

  /// Returns true if this notification should be silently ignored.
  /// IMPORTANT: Call isInstantScam() BEFORE this — instant scam signals always win.
  static bool isSafe(String app, String title, String text) {
    // Only match safe-sender regex against the actual sender (app package + notification title),
    // NOT against the message body. This prevents contact names like "Mine Airtel" from
    // accidentally matching "Airtel" and causing scam messages to be skipped.
    final senderOnly = '$app $title';
    if (_safeSenders.hasMatch(senderOnly)) return true;
    // Safe message pattern → ignore (only if body has no scam signals)
    for (final p in _safePatterns) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }

  /// Returns true if this is an instant scam with no need to call AI.
  static bool isInstantScam(String text) {
    for (final p in _instantScam) {
      if (p.hasMatch(text)) return true;
    }
    for (final p in _teluguHindiScam) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }
}

// ══════════════════════════════════════════════════════════════
// OCR SERVICE
// ══════════════════════════════════════════════════════════════

class OcrService {
  static final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  static Future<String> extractFromPath(String path) async {
    try { return (await _recognizer.processImage(InputImage.fromFilePath(path))).text; }
    catch (e) { debugPrint('❌ [OCR] $e'); return ''; }
  }

  static Future<String> extractFromPaths(List<String> paths) async {
    if (paths.isEmpty) return '';
    try {
      final results = await Future.wait(paths.map(extractFromPath));
      final buf = StringBuffer();
      for (final t in results) { if (t.trim().isNotEmpty) buf.writeln(t.trim()); }
      final full = buf.toString().trim();
      return full.length > _kOcrMaxChars ? full.substring(0, _kOcrMaxChars) : full;
    } catch (e) { debugPrint('❌ [OCR] extractFromPaths: $e'); return ''; }
  }

  static void dispose() => _recognizer.close();
}

// ══════════════════════════════════════════════════════════════
// API SERVICE
// ══════════════════════════════════════════════════════════════

class ApiService {
  static const _base = 'https://42d5-157-50-86-86.ngrok-free.app';

  static Future<ScanResult> analyze(String text) async {
    try {
      final res = await http.post(
        Uri.parse('$_base/analyze'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'message': text}),
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) return ScanResult.fromApiJson(jsonDecode(res.body) as Map<String, dynamic>, text);
      throw Exception('HTTP ${res.statusCode}');
    } catch (e) {
      debugPrint('⚠️ [FALLBACK] $e');
      return _LocalEngine.detect(text);
    }
  }
}

// ══════════════════════════════════════════════════════════════
// WHATSAPP REPORT SERVICE
// ══════════════════════════════════════════════════════════════

class WhatsAppReporter {
  static Future<void> report(ScanResult r) async {
    final keywords = r.suspiciousKeywords.isNotEmpty ? r.suspiciousKeywords.join(', ') : 'None';
    final body = [
      '🚨 *SCAM ALERT — ScamShield*', '',
      '⚠️ Risk: ${r.riskLevel.label}  |  ${r.scamProbability.toInt()}%',
      '🏷 Type: ${r.fraudType.label}', '',
      '🔎 Keywords: $keywords', '',
      '📩 Message: ${r.originalText}', '',
      '🧠 Why dangerous: ${r.explanation}', '',
      L.t('dont_otp'),
      '— ScamShield',
    ].join('\n');
    final uri = Uri.parse('whatsapp://send?text=${Uri.encodeComponent(body)}');
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) debugPrint('⚠️ WhatsApp not installed');
    } catch (e) { debugPrint('⚠️ [REPORT] $e'); }
  }
}

// ══════════════════════════════════════════════════════════════
// LOCAL FALLBACK ENGINE  (English + Telugu + Hindi keywords)
// ══════════════════════════════════════════════════════════════

class _LocalEngine {
  static const _upi = [
    'upi','gpay','phonepe','paytm','vpa','payment link','qr code','scan qr','neft','imps','bank account number',
    // Telugu
    'bank details','పేమెంట్','బ్యాంక్ details','qr స్కాన్',
    // Hindi
    'bank ka number','paisa bhejo','payment karo','qr scan karo',
  ];
  static const _job = [
    'work from home','part time job','data entry','typing job','earn daily','guaranteed salary',
    'no experience required','registration fee','training fee','whatsapp job',
    // Telugu
    'ఇంట్లో పని','రోజూ సంపాదన','రిజిస్ట్రేషన్ ఫీ',
    // Hindi
    'ghar se kaam','roz kamaai','registration fee do','training fee',
  ];
  static const _lottery = [
    'lottery','lucky draw','prize winner','you have won','congratulations you','claim your reward',
    'lucky winner','processing fee','cash prize',
    // Telugu
    'లాటరీ','అదృష్టం','బహుమతి గెలుచుకున్నారు','ప్రాసెసింగ్ ఫీ',
    // Hindi
    'lottery jeeti','inaam mila','processing fee bhejo','lucky winner',
  ];
  static const _phish = [
    'click here to verify','verify your account','account suspended','account has been blocked',
    'update your details','login link','bit.ly','tinyurl','password reset link','confirm your identity',
    // Telugu
    'account బ్లాక్','లింక్ క్లిక్','verify చేయండి',
    // Hindi
    'account band','link kholo','verify karo',
  ];
  static const _kyc = [
    'kyc update','kyc expired','kyc pending','kyc verify','complete your kyc',
    'aadhaar link','pan card update','link your aadhaar',
    // Telugu
    'kyc పూర్తి','ఆధార్ లింక్','pan అప్‌డేట్',
    // Hindi
    'kyc karo','aadhaar link karo','pan update karo',
  ];
  static const _otp = [
    'otp','one time password','share otp','send otp','anydesk','teamviewer','remote access','screen share',
    // Telugu
    'otp చెప్పండి','స్క్రీన్ చూపించండి',
    // Hindi
    'otp batao','screen dikhao',
  ];
  static const _general = [
    'urgent action required','immediate action','account will expire','limited time offer',
    'act now or lose','do not ignore this',
    // Telugu
    'వెంటనే చర్య','అత్యవసరం',
    // Hindi
    'abhi karo','urgent hai','turant karo',
  ];

  static ScanResult detect(String text) {
    final lo     = text.toLowerCase();
    final scores = {
      FraudType.upi:      _hits(lo, _upi)     * 14,
      FraudType.job:      _hits(lo, _job)     * 13,
      FraudType.lottery:  _hits(lo, _lottery) * 13,
      FraudType.phishing: _hits(lo, _phish)   * 14,
      FraudType.kyc:      _hits(lo, _kyc)     * 16,
      FraudType.other:    _hits(lo, _otp)     * 16,
    };
    final extra = _hits(lo, _general) * 5;
    final top   = scores.entries.reduce((a, b) => a.value > b.value ? a : b);
    final raw   = (top.value + extra).clamp(0, 100).toDouble();
    final ft    = top.value == 0 ? FraudType.none : top.key;
    final all   = [..._upi, ..._job, ..._lottery, ..._phish, ..._kyc, ..._otp, ..._general];
    final found = all.where((w) => lo.contains(w.toLowerCase())).toSet().toList();
    final rl    = raw <= 30 ? RiskLevel.safe : raw <= 60 ? RiskLevel.suspicious : RiskLevel.highRisk;
    return ScanResult(
      scamProbability: raw, isScam: raw >= 50, riskLevel: rl, fraudType: ft,
      suspiciousKeywords: found, explanation: _explain(ft, raw), preventionTips: _tips(ft),
      whatToDo: rl == RiskLevel.safe ? L.t('wtd_safe') : rl == RiskLevel.suspicious ? L.t('wtd_susp') : L.t('wtd_high'),
      helpline: '1930', originalText: text, timestamp: DateTime.now(),
    );
  }

  static int _hits(String t, List<String> words) => words.where((w) => t.contains(w.toLowerCase())).length;

  static String _explain(FraudType ft, double score) {
    if (score < 15) return '${L.t('wtd_safe')}\nNo significant scam indicators found.';
    switch (ft) {
      case FraudType.upi:      return 'UPI మోసం గుర్తించబడింది!\nUPI fraud pakda gaya!\nPIN, OTP, QR share చేయకండి.';
      case FraudType.job:      return 'Job మోసం!\nJob scam hai!\nEmployer ఎప్పుడూ పైసలు అడగడు.';
      case FraudType.lottery:  return 'Lottery మోసం!\nLottery scam hai!\nEnter చేయని Lottery win అవదు.';
      case FraudType.phishing: return 'Phishing link!\nNaqli link hai!\nLinks click చేయకండి.';
      case FraudType.kyc:      return 'KYC మోసం!\nKYC scam hai!\nBank SMS లో KYC link పంపదు.';
      default:                 return 'Suspicious patterns detected.\nజాగ్రత్తగా ఉండండి!\nSaavdhan rahein!';
    }
  }

  static List<String> _tips(FraudType ft) {
    switch (ft) {
      case FraudType.upi:      return [L.t('tip_otp'), L.t('tip_qr'), 'Play Store నుండి మాత్రమే payment apps వాడండి.', 'Transfer చేయడానికి ముందు recipient పేరు చెక్ చేయండి.'];
      case FraudType.job:      return [L.t('tip_job'), 'Company LinkedIn లో verify చేయండి.', 'WhatsApp job offers unknown numbers నుండి వస్తే నమ్మకండి.', 'Naukri / NCS portal వాడండి.'];
      case FraudType.lottery:  return [L.t('tip_lottery'), 'Lottery prize కోసం పైసలు అడిగితే scam.', 'Aadhaar / Bank details share చేయకండి.', '1930 కి call చేయండి.'];
      case FraudType.phishing: return [L.t('tip_link'), 'Bank ఎప్పుడూ SMS లో password అడగదు.', 'URLs జాగ్రత్తగా చదవండి — sbi-secure.xyz అంటే fake.', 'Banking apps లో 2FA enable చేయండి.'];
      case FraudType.kyc:      return [L.t('tip_kyc'), 'KYC bank branch లో మాత్రమే చేయాలి.', 'SMS లో Aadhaar/PAN link పంపారు అంటే scam.', 'Official bank helpline కి call చేయండి.'];
      default:                 return [L.t('tip_link'), L.t('tip_otp'), '1930 కి call చేయండి.\n1930 pe call karein.', 'cybercrime.gov.in లో report చేయండి.'];
    }
  }
}

// ══════════════════════════════════════════════════════════════
// HISTORY SERVICE
// ══════════════════════════════════════════════════════════════

class HistoryService {
  static const _key = 'scan_history_v2';

  static Future<void> save(ScanResult r) async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(_key) ?? [];
      l.insert(0, jsonEncode(r.toJson()));
      if (l.length > _kHistoryMax) l.removeLast();
      await p.setStringList(_key, l);
    } catch (e) { debugPrint('❌ [HISTORY] save: $e'); }
  }

  static Future<List<ScanResult>> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getStringList(_key) ?? [];
      final o = <ScanResult>[];
      for (final s in l) { try { o.add(ScanResult.fromStoredJson(jsonDecode(s) as Map<String, dynamic>)); } catch (_) {} }
      return o;
    } catch (e) { debugPrint('❌ [HISTORY] load: $e'); return []; }
  }

  static Future<void> clear() async {
    try { (await SharedPreferences.getInstance()).remove(_key); } catch (e) { debugPrint('❌ [HISTORY] clear: $e'); }
  }
}

// ══════════════════════════════════════════════════════════════
// CONTACTS HELPER
// ══════════════════════════════════════════════════════════════

class ContactsHelper {
  static bool        _permGranted   = false;
  static Set<String> _cachedNumbers = {};
  static DateTime?   _cacheTime;

  static Future<bool> isNumberSaved(String rawNumber) async {
    if (rawNumber.trim().isEmpty) return false;
    final clean = rawNumber.replaceAll(RegExp(r'\D'), '');
    if (clean.isEmpty) return false;
    try {
      final now = DateTime.now();
      if (_cachedNumbers.isEmpty || _cacheTime == null || now.difference(_cacheTime!).inMinutes >= _kContactsCacheMins) {
        if (!_permGranted) _permGranted = await FlutterContacts.requestPermission();
        if (!_permGranted) return false;
        final contacts = await FlutterContacts.getContacts(withProperties: true, withPhoto: false);
        _cachedNumbers = {};
        for (final c in contacts) {
          for (final p in c.phones) {
            final pc = p.number.replaceAll(RegExp(r'\D'), '');
            if (pc.isNotEmpty) _cachedNumbers.add(pc);
          }
        }
        _cacheTime = now;
        debugPrint('📒 [CONTACTS] cached ${_cachedNumbers.length} numbers');
      }
      final suffix = clean.length > 10 ? clean.substring(clean.length - 10) : clean;
      return _cachedNumbers.any((pc) {
        final ps = pc.length > 10 ? pc.substring(pc.length - 10) : pc;
        return ps == suffix;
      });
    } catch (e) { debugPrint('❌ [CONTACTS] $e'); return false; }
  }

  static void invalidateCache() { _cachedNumbers = {}; _cacheTime = null; }
}

// ══════════════════════════════════════════════════════════════
// SHARED PIPELINE
// ══════════════════════════════════════════════════════════════

Future<ScanResult?> _runPipeline({
  required List<String>          imagePaths,
  required BuildContext          context,
  required void Function(String) setStatus,
  bool deleteTempAfter = false,
}) async {
  if (imagePaths.isEmpty) { setStatus('No images to analyze.'); return null; }
  setStatus(L.t('status_ocr'));
  final text = await OcrService.extractFromPaths(imagePaths);
  if (text.trim().isEmpty) { setStatus(L.t('no_text')); return null; }
  if (text.trim().length < 5) { setStatus('Text చదవలేదు. Sharp image try చేయండి.'); return null; }
  setStatus(L.t('status_ai'));
  final result = await ApiService.analyze(text);
  await HistoryService.save(result);
  if (deleteTempAfter) {
    for (final p in imagePaths) {
      if (p.contains('snap_')) { try { await File(p).delete(); } catch (_) {} }
    }
  }
  if (context.mounted) {
    setStatus(L.t('status_idle'));
    if (result.scamProbability >= 50) await _showScamOverlay(result, source: 'Screenshot');
    await showDialog<void>(context: context, builder: (_) => ScamAlertDialog(result: result));
  }
  return result;
}

// ══════════════════════════════════════════════════════════════
// ANIMATED SPAM CALL WARNING SCREEN
// Full-screen immersive warning for spam/suspicious calls.
// Telugu + Hindi + English text. Big, clear, rural-friendly.
// ══════════════════════════════════════════════════════════════

class SpamCallWarningScreen extends StatefulWidget {
  final NumberCheckResult result;
  const SpamCallWarningScreen({super.key, required this.result});
  @override State<SpamCallWarningScreen> createState() => _SpamCallWarningState();
}

class _SpamCallWarningState extends State<SpamCallWarningScreen>
    with TickerProviderStateMixin {

  late AnimationController _pulseCtrl;
  late AnimationController _shakeCtrl;
  late AnimationController _slideCtrl;
  late Animation<double>   _pulseAnim;
  late Animation<double>   _shakeAnim;
  late Animation<Offset>   _slideAnim;

  @override
  void initState() {
    super.initState();

    // Pulsing danger ring
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.18).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Shake animation for the warning icon
    _shakeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 400))
      ..repeat(reverse: true);
    _shakeAnim = Tween<double>(begin: -6.0, end: 6.0).animate(
        CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticIn));

    // Slide-in cards from bottom
    _slideCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _slideAnim = Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero).animate(
        CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutBack));
    _slideCtrl.forward();
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _shakeCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  bool get _isSpam => widget.result.risk == NumberRisk.spam;
  Color get _color => widget.result.risk.color;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isSpam ? const Color(0xFF1a0000) : const Color(0xFF1a1000),
      body: SafeArea(
        child: Column(children: [

          // ── Top bar with close ───────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('🛡️ ScamShield', style: TextStyle(color: Colors.white54, fontSize: 13)),
              TextButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded, color: Colors.white38, size: 18),
                label: Text(L.t('dismiss'), style: TextStyle(color: Colors.white38, fontSize: 12)),
              ),
            ]),
          ),

          Expanded(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(children: [

              // ── Animated warning icon ─────────────────────────
              AnimatedBuilder(
                animation: _shakeAnim,
                builder: (_, child) => Transform.translate(
                  offset: Offset(_shakeAnim.value, 0),
                  child: child,
                ),
                child: AnimatedBuilder(
                  animation: _pulseAnim,
                  builder: (_, child) => Transform.scale(
                    scale: _pulseAnim.value,
                    child: Container(
                      width: 120, height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _color.withOpacity(0.15),
                        border: Border.all(color: _color.withOpacity(0.7), width: 3),
                        boxShadow: [BoxShadow(color: _color.withOpacity(0.4), blurRadius: 30, spreadRadius: 10)],
                      ),
                      alignment: Alignment.center,
                      child: Text(widget.result.risk.emoji, style: const TextStyle(fontSize: 56)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // ── Main title ────────────────────────────────────
              Text(
                _isSpam ? L.t('spam_call') : L.t('susp_call'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _color, height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                widget.result.number,
                style: TextStyle(fontSize: 18, color: Colors.white, letterSpacing: 3, fontWeight: FontWeight.w300),
              ),
              const SizedBox(height: 20),

              // ── Reason card ───────────────────────────────────
              SlideTransition(
                position: _slideAnim,
                child: _WarningCard(
                  color: _color,
                  icon: Icons.info_outline_rounded,
                  title: 'ఎందుకు Warning? / Warning Kyun?',
                  body: widget.result.reason,
                ),
              ),
              const SizedBox(height: 12),

              // ── DO NOT share rules — big animated cards ───────
              SlideTransition(
                position: _slideAnim,
                child: Column(children: [
                  _DontCard(emoji: '🔢', mainKey: 'dont_otp',    hintKey: 'dont_otp_hint'),
                  const SizedBox(height: 8),
                  _DontCard(emoji: '🏦', mainKey: 'dont_pin',    hintKey: 'dont_pin_hint'),
                  const SizedBox(height: 8),
                  _DontCard(emoji: '🪪', mainKey: 'dont_aadhar', hintKey: 'dont_aadhar_hint'),
                  const SizedBox(height: 8),
                  _DontCard(emoji: '🔗', mainKey: 'dont_link',   hintKey: 'dont_link_hint'),
                  const SizedBox(height: 8),
                  _DontCard(emoji: '📱', mainKey: 'dont_app',    hintKey: 'dont_app_hint'),
                ]),
              ),
              const SizedBox(height: 16),

              // ── What to do ────────────────────────────────────
              _WarningCard(
                color: const Color(0xFF2ED573),
                icon: Icons.bolt_rounded,
                title: L.t('what_now'),
                body: _isSpam
                    ? '1️⃣ Phone కట్ చేయండి — Phone kaato!\n2️⃣ Number block చేయండి — Block karo!\n3️⃣ 1930 కి call చేయండి — 1930 pe call karo!'
                    : '1️⃣ Personal details share చేయకండి\n2️⃣ OTP, PIN, Aadhaar చెప్పకండి\n3️⃣ Bank అయితే official number కి call చేయండి',
              ),
              const SizedBox(height: 20),

              // ── Action buttons ────────────────────────────────
              if (_isSpam) ...[
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red, foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () async {
                    Navigator.pop(context);
                    try { await launchUrl(Uri.parse('tel:1930')); } catch (_) {}
                  },
                  icon: const Icon(Icons.call_rounded),
                  label: const Text('📞 1930 కి Call చేయండి\n1930 pe Call Karein',
                      textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
                const SizedBox(height: 10),
              ],
              Row(children: [
                Expanded(child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _color.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Dismiss\nసరే', textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
                )),
              ]),

            ]),
          )),
        ]),
      ),
    );
  }
}

// Sub-widgets for the warning screen
class _WarningCard extends StatelessWidget {
  final Color color; final IconData icon; final String title; final String body;
  const _WarningCard({required this.color, required this.icon, required this.title, required this.body});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(14),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, color: color, size: 18), const SizedBox(width: 8),
        Flexible(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)))]),
      const SizedBox(height: 10),
      Text(body, style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.6)),
    ]),
  );
}

class _DontCard extends StatelessWidget {
  final String emoji; final String mainKey; final String hintKey;
  const _DontCard({required this.emoji, required this.mainKey, required this.hintKey});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.red.withOpacity(0.12), borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.red.withOpacity(0.4)),
    ),
    child: Row(children: [
      Text(emoji, style: const TextStyle(fontSize: 28)),
      const SizedBox(width: 14),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(L.t(mainKey), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        Text(L.t(hintKey),  style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ])),
      const Icon(Icons.block_rounded, color: Colors.red, size: 22),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// CALL ALERT DIALOG  (in-app, for unknown calls — simplified)
// ══════════════════════════════════════════════════════════════

class CallAlertDialog extends StatelessWidget {
  final NumberCheckResult result;
  const CallAlertDialog({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final color = result.risk.color;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: _C.cardBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(shape: BoxShape.circle, color: color.withOpacity(0.15), border: Border.all(color: color.withOpacity(0.5), width: 2)),
            child: Text(result.risk.emoji, style: const TextStyle(fontSize: 40))),
        const SizedBox(height: 14),
        Text(result.risk.title, textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 6),
        Text(result.number, style: const TextStyle(fontSize: 16, color: Colors.white70, letterSpacing: 2)),
        const SizedBox(height: 18),
        _infoBox(color, Icons.info_outline_rounded, L.t('why_alert'), result.reason),
        const SizedBox(height: 12),
        _infoBox(Colors.redAccent, Icons.shield_rounded, L.t('stay_safe'), result.advice),
        const SizedBox(height: 16),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: Colors.red.shade900.withOpacity(0.3), borderRadius: BorderRadius.circular(10)),
            child: const Text('🚫 OTP • Bank PIN • Aadhaar\nఎవరికీ చెప్పకండి! Kisi ko mat batao!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, height: 1.5))),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: OutlinedButton(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: () => Navigator.pop(context),
            child: Text(L.t('dismiss')),
          )),
          const SizedBox(width: 10),
          Expanded(child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: () async { Navigator.pop(context); try { await launchUrl(Uri.parse('tel:1930')); } catch (_) {} },
            icon: const Icon(Icons.call_rounded, size: 16),
            label: const Text('Call 1930', style: TextStyle(fontWeight: FontWeight.bold)),
          )),
        ]),
      ])),
    );
  }

  Widget _infoBox(Color color, IconData icon, String title, String body) => Container(
    width: double.infinity, padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.3))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(icon, color: color, size: 16), const SizedBox(width: 8),
        Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13))]),
      const SizedBox(height: 8),
      Text(body, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// WIDGETS  (bilingual labels)
// ══════════════════════════════════════════════════════════════

class ProbabilityMeter extends StatelessWidget {
  final double probability; final RiskLevel riskLevel;
  const ProbabilityMeter({super.key, required this.probability, required this.riskLevel});
  @override
  Widget build(BuildContext context) {
    final color = riskLevel.color;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(L.t('risk_label'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: color.withOpacity(0.45))),
              child: Text(riskLevel.label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12))),
          const SizedBox(width: 8),
          Text('${probability.toInt()}%', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 22)),
        ]),
      ]),
      const SizedBox(height: 10),
      ClipRRect(borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: probability / 100, backgroundColor: Colors.white12, valueColor: AlwaysStoppedAnimation<Color>(color), minHeight: 16)),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(L.t('safe_label'),     style: const TextStyle(fontSize: 10, color: _C.safe)),
        const Text('Suspicious',    style: TextStyle(fontSize: 10, color: _C.suspicious)),
        Text(L.t('high_risk_label'),  style: const TextStyle(fontSize: 10, color: _C.highRisk)),
      ]),
    ]);
  }
}

class FraudTypeBadge extends StatelessWidget {
  final FraudType fraudType; final bool bilingual;
  const FraudTypeBadge({super.key, required this.fraudType, this.bilingual = false});
  @override
  Widget build(BuildContext context) {
    final c = fraudType.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withOpacity(0.45))),
      child: Text(bilingual ? fraudType.biLabel : '${fraudType.emoji} ${fraudType.label}',
          style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 13)),
    );
  }
}

class HighlightedText extends StatelessWidget {
  final String text; final List<String> highlightWords;
  const HighlightedText({super.key, required this.text, required this.highlightWords});
  @override
  Widget build(BuildContext context) {
    if (highlightWords.isEmpty || text.isEmpty) return Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5));
    final escaped = highlightWords.where((w) => w.trim().isNotEmpty).map(RegExp.escape).toList();
    if (escaped.isEmpty) return Text(text, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5));
    final regex = RegExp('(${escaped.join('|')})', caseSensitive: false);
    final spans = <TextSpan>[]; int last = 0;
    for (final m in regex.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start), style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5)));
      spans.add(TextSpan(text: m.group(0), style: const TextStyle(backgroundColor: Color(0xFFFFEB3B), color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 13, height: 1.5)));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last), style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5)));
    return RichText(text: TextSpan(children: spans));
  }
}

class PreventionTipsWidget extends StatelessWidget {
  final List<String> tips;
  const PreventionTipsWidget({super.key, required this.tips});
  static const _icons = ['🔒','🚫','✅','📞','🔍','⚠️'];
  @override
  Widget build(BuildContext context) {
    if (tips.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(L.t('prevention'), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: 10),
      ...tips.asMap().entries.map((e) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(8)), alignment: Alignment.center, child: Text(_icons[e.key % _icons.length], style: const TextStyle(fontSize: 16))),
          const SizedBox(width: 12),
          Expanded(child: Text(e.value, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5))),
        ]),
      )),
    ]);
  }
}

class WhatToDoWidget extends StatelessWidget {
  final String action; final RiskLevel riskLevel;
  const WhatToDoWidget({super.key, required this.action, required this.riskLevel});
  @override
  Widget build(BuildContext context) {
    if (action.isEmpty) return const SizedBox.shrink();
    final color = riskLevel.color;
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withOpacity(0.35))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.bolt_rounded, color: color, size: 20), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(L.t('what_now'), style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Text(action, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.6)),
        ])),
      ]),
    );
  }
}

class _CybercrimeHelplineBanner extends StatelessWidget {
  final ScanResult result;
  const _CybercrimeHelplineBanner({required this.result});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withOpacity(0.22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.shade700.withOpacity(0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.emergency_rounded, color: Colors.redAccent, size: 18), SizedBox(width: 8),
          Text('Cybercrime Helpline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.redAccent)),
        ]),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.center, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(result.helpline, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 4)),
            const SizedBox(height: 3),
            Text('24×7 Free  •  ఉచిత సేవ', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
            Text('cybercrime.gov.in', style: TextStyle(fontSize: 11, color: Colors.blue.shade300)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
              onPressed: () async { try { await launchUrl(Uri.parse('tel:${result.helpline}')); } catch (_) {} },
              icon: const Icon(Icons.call_rounded, size: 16),
              label: Text(L.t('helpline_call'), style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.green.shade400), foregroundColor: Colors.green.shade400, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
              onPressed: () => WhatsAppReporter.report(result),
              icon: const Icon(Icons.send_rounded, size: 14),
              label: const Text('WhatsApp Report', style: TextStyle(fontSize: 12)),
            ),
          ]),
        ]),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// SCAM ALERT DIALOG  (message scans)
// ══════════════════════════════════════════════════════════════

class ScamAlertDialog extends StatelessWidget {
  final ScanResult result;
  const ScamAlertDialog({super.key, required this.result});

  String get _title => switch (result.riskLevel) {
    RiskLevel.highRisk   => L.t('scam_found'),
    RiskLevel.suspicious => L.t('susp_found'),
    RiskLevel.safe       => L.t('safe_found'),
  };

  @override
  Widget build(BuildContext context) {
    final color    = result.riskLevel.color;
    final showFull = result.showFullWarning;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: _C.cardBg,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [

        Icon(result.riskLevel.icon, size: 64, color: color),
        const SizedBox(height: 8),
        Text(_title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color, height: 1.4)),
        const SizedBox(height: 10),
        FraudTypeBadge(fraudType: result.fraudType, bilingual: true),
        const SizedBox(height: 20),
        ProbabilityMeter(probability: result.scamProbability, riskLevel: result.riskLevel),
        const SizedBox(height: 20),

        if (result.suspiciousKeywords.isNotEmpty) ...[
          const _SL('🔎 Suspicious Words / అనుమానాస్పద పదాలు'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: result.suspiciousKeywords.map((kw) =>
              Chip(label: Text(kw, style: const TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: const Color(0xFFB71C1C), side: BorderSide.none,
                  padding: const EdgeInsets.symmetric(horizontal: 4), visualDensity: VisualDensity.compact)
          ).toList()),
          const SizedBox(height: 16),
        ],

        if (result.originalText.isNotEmpty) ...[
          const _SL('📩 Scanned Message / చదివిన సందేశం'),
          const SizedBox(height: 8),
          Container(
            width: double.infinity, constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white12)),
            child: SingleChildScrollView(child: HighlightedText(text: result.originalText, highlightWords: result.suspiciousKeywords)),
          ),
          const SizedBox(height: 16),
        ],

        Container(
          width: double.infinity, padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: color.withOpacity(0.07), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withOpacity(0.2))),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, color: color, size: 18), const SizedBox(width: 10),
            Expanded(child: Text(result.explanation, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5))),
          ]),
        ),
        const SizedBox(height: 18),

        WhatToDoWidget(action: result.whatToDo, riskLevel: result.riskLevel),

        if (showFull) ...[
          const SizedBox(height: 18),
          PreventionTipsWidget(tips: result.preventionTips),
          const SizedBox(height: 20),
          _CybercrimeHelplineBanner(result: result),
        ],

        const SizedBox(height: 20),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded), label: const Text('Dismiss / సరే')),
          if (showFull)
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade700, foregroundColor: Colors.white),
              onPressed: () { Navigator.pop(context); WhatsAppReporter.report(result); },
              icon: const Icon(Icons.send_rounded, size: 16), label: const Text('Report'),
            ),
        ]),
      ])),
    );
  }
}

class _SL extends StatelessWidget {
  final String text; const _SL(this.text);
  @override
  Widget build(BuildContext context) => Align(alignment: Alignment.centerLeft,
      child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)));
}

// ══════════════════════════════════════════════════════════════
// INCOMING CALL BANNER (in-app status bar)
// ══════════════════════════════════════════════════════════════

class _IncomingCallBanner extends StatelessWidget {
  final String number; final bool checking;
  const _IncomingCallBanner({required this.number, required this.checking});
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity, padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: Colors.blue.withOpacity(0.10), border: Border.all(color: Colors.blue.withOpacity(0.4)), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      const Icon(Icons.phone_in_talk_rounded, color: Colors.blue, size: 20), const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Incoming call…', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13)),
        if (number.isNotEmpty) Text(number, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ])),
      if (checking) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue)),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// HOME SCREEN
// ══════════════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool   _scanning            = false;
  String _status              = L.t('status_idle');
  bool   _overlayEnabled      = false;
  bool   _notificationEnabled = false;
  bool   _waitingForPerm      = false;

  bool   _incomingCall   = false;
  bool   _checkingNumber = false;
  String _incomingNumber = '';
  String _lastCallState  = '';
  String _lastCallNumber = '';

  bool   _callDialogOpen         = false;
  bool   _notificationDialogOpen = false;
  Timer? _callDebounce;
  bool   _picking                = false;

  final _screenshotCtrl = ScreenshotController();
  final _picker         = ImagePicker();

  bool    _cropScreenOpen  = false;
  String? _lastScreenshot;
  int     _lastCaptureTime = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadOverlayState();
    _loadNotificationState();
    _initCallChannel();
    _initNotificationListener();

    _captureChannel.setMethodCallHandler((call) async {
      if (call.method == 'onScreenCaptured' && mounted) {
        final path = call.arguments as String?;
        if (path == null || path.isEmpty) return;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_lastScreenshot == path) return;
        if (now - _lastCaptureTime < 800) { debugPrint('⚠️ Duplicate capture ignored'); return; }
        _lastScreenshot  = path;
        _lastCaptureTime = now;
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) _appendAndOpenCrop(path);
      }
    });
  }

  // ── Notification listener ─────────────────────────────────────

  void _initNotificationListener() {
    _notificationChannel.setMethodCallHandler((call) async {
      if (call.method != 'onNotificationMessage') return;

      final data  = Map<String, dynamic>.from(call.arguments as Map);
      final app   = data['app']   as String? ?? '';
      final title = data['title'] as String? ?? '';
      final text  = data['text']  as String? ?? '';

      debugPrint('📩 [$app] $title: $text');

      // ── Pre-filter: too short ────────────────────────────────
      if (text.length < 10) return;

      // ── INSTANT SCAM CHECK FIRST — always overrides safe-sender ─
      // Scam signals (bit.ly, account blocked, KYC link, etc.) must
      // be caught even if the notification appears to come from a
      // known sender name, because scammers spoof contact names.
      if (_NotifFilter.isInstantScam(text)) {
        debugPrint('🚨 [NOTIF] Instant scam signal detected — bypassing safe filter');
        final instant = ScanResult(
          scamProbability: 90, isScam: true, riskLevel: RiskLevel.highRisk,
          fraudType: FraudType.phishing,
          suspiciousKeywords: ['suspicious link / pattern'],
          explanation: 'Instant scam pattern detected.\nస్కామ్ pattern వెంటనే గుర్తించబడింది!',
          preventionTips: [L.t('tip_link'), L.t('tip_otp')],
          whatToDo: L.t('wtd_high'),
          helpline: '1930', originalText: text, timestamp: DateTime.now(),
        );
        await HistoryService.save(instant);
        await _showScamOverlay(instant, source: app.isNotEmpty ? app : 'Message');
        return;
      }

      // ── Pre-filter: known-safe sender / pattern ──────────────
      // Only runs AFTER instant scam check so real scams are never skipped
      if (_NotifFilter.isSafe(app, title, text)) {
        debugPrint('✅ [NOTIF] Safe — skipped');
        return;
      }

      // ── AI analysis ──────────────────────────────────────────
      final result = await ApiService.analyze(text);

      if (result.scamProbability >= 60 && !_notificationDialogOpen) {
        _notificationDialogOpen = true;
        await _showScamOverlay(result, source: app.isNotEmpty ? app : 'Message');
        _notificationDialogOpen = false;
      }
    });
  }

  Future<void> _loadNotificationState() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _notificationEnabled = prefs.getBool(_kNotificationEnabled) ?? false);
  }

  Future<void> _enableNotificationProtection() async {
    const platform = MethodChannel('notification_settings');
    try {
      await platform.invokeMethod('openNotificationAccess');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNotificationEnabled, true);
      if (mounted) setState(() => _notificationEnabled = true);
    } catch (e) {
      _showSnack(L.t('notif_settings'));
    }
  }

  /// Called when user picks a language in the toggle.
  Future<void> _setLanguage(String langCode) async {
    L.current = langCode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', langCode);
    if (mounted) setState(() => _status = L.t('status_idle'));
  }

  @override
  void dispose() {
    _callDebounce?.cancel();
    OcrService.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Call channel ──────────────────────────────────────────────

  void _initCallChannel() {
    _callStateChannel.setMethodCallHandler((call) async {
      if (call.method != 'onCallState') return;
      final args   = call.arguments is Map ? Map<String, dynamic>.from(call.arguments as Map) : <String, dynamic>{};
      final state  = (args['state']  as String? ?? '').trim();
      final number = NumberReputationService.normalise(args['number'] as String? ?? '');
      if (number.isEmpty && state != 'IDLE') return;
      if (state == _lastCallState && number == _lastCallNumber) return;

      _callDebounce?.cancel();
      _callDebounce = Timer(const Duration(milliseconds: _kCallDebounceMsec), () async {
        _lastCallState  = state;
        _lastCallNumber = number.isNotEmpty ? number : _lastCallNumber;
        switch (state) {
          case 'RINGING':
            final saved = await ContactsHelper.isNumberSaved(number);
            if (saved) { debugPrint('👤 Known contact — skipping'); return; }
            if (mounted) setState(() { _incomingCall = true; _incomingNumber = number; _checkingNumber = true; });
            await _checkIncomingNumber(number);
            break;
          case 'IDLE':
            _callDialogOpen = false;
            if (mounted) setState(() { _incomingCall = false; _incomingNumber = ''; _checkingNumber = false; });
            break;
          case 'OFFHOOK':
            if (!_incomingCall) {
              final en    = number.isNotEmpty ? number : _lastCallNumber;
              final saved = await ContactsHelper.isNumberSaved(en);
              if (saved) return;
              if (mounted) setState(() { _incomingCall = true; _incomingNumber = en; _checkingNumber = true; });
              await _checkIncomingNumber(en);
            }
            break;
        }
      });
    });
  }

  Future<void> _checkIncomingNumber(String number) async {
    if (_callDialogOpen) return;
    try {
      final result = await NumberReputationService.check(number);
      if (!mounted) return;
      setState(() => _checkingNumber = false);

      // ── UNKNOWN: only show native overlay banner, no full screen ──
      if (result.risk == NumberRisk.unknown) {
        await _showCallAlert(number, result.risk.name, result.reason);
        return;  // no in-app dialog for unknown — avoids annoying users
      }

      // ── SPAM / SUSPICIOUS: fire native overlay + full warning screen ──
      await _showCallAlert(number, result.risk.name, result.reason);

      _callDialogOpen = true;
      if (mounted) {
        // Push full-screen animated warning
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SpamCallWarningScreen(result: result)),
        );
      }
      _callDialogOpen = false;
    } catch (e) {
      _callDialogOpen = false;
      debugPrint('❌ [NUMBER CHECK] $e');
      if (mounted) setState(() => _checkingNumber = false);
    }
  }

  // ── Overlay ───────────────────────────────────────────────────

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (state == AppLifecycleState.resumed && _waitingForPerm && mounted) {
      _waitingForPerm = false;
      final granted = await _hasOverlayPermission();
      if (granted) {
        await _startOverlay();
        final p = await SharedPreferences.getInstance();
        await p.setBool(_kOverlayEnabled, true);
        if (mounted) setState(() => _overlayEnabled = true);
        _showSnack('✅ Floating button enable అయింది!');
      } else {
        _showSnack('Permission denied. Settings లో grant చేయండి.');
        if (mounted) {
          final open = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
            title: const Text('Permission కావాలి'),
            content: const Text('Settings లో "Display over other apps" allow చేయండి.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(context, true),  child: const Text('Open Settings')),
            ],
          ));
          if (open == true) await openAppSettings();
        }
      }
    }
  }

  Future<void> _loadOverlayState() async {
    final p = await SharedPreferences.getInstance();
    if (mounted) setState(() => _overlayEnabled = p.getBool(_kOverlayEnabled) ?? false);
  }

  Future<void> _toggleOverlay() async {
    if (_overlayEnabled) {
      await _stopOverlay();
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kOverlayEnabled, false);
      setState(() => _overlayEnabled = false);
      _showSnack('Floating button disabled.');
    } else {
      if (await _hasOverlayPermission()) {
        await _startOverlay();
        final p = await SharedPreferences.getInstance();
        await p.setBool(_kOverlayEnabled, true);
        setState(() => _overlayEnabled = true);
        _showSnack('✅ Floating button enable అయింది!');
      } else {
        _waitingForPerm = true;
        await _requestOverlayPermission();
      }
    }
  }

  // ── Screenshot helpers ────────────────────────────────────────

  Future<void> _scanScreen() async {
    setState(() { _scanning = true; _status = 'Screen capture అవుతోంది…'; });
    try {
      final bytes = await _screenshotCtrl.capture();
      if (bytes == null) { setState(() { _scanning = false; _status = 'Screenshot fail. Try again.'; }); return; }
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/snap_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);
      setState(() { _scanning = false; _status = L.t('status_idle'); });
      _pendingScreenshots.clear(); _cropScreenOpen = false;
      _openCropScreen([path], deleteTempAfter: true);
    } catch (e) {
      debugPrint('❌ [HOME] $e');
      setState(() { _scanning = false; _status = 'Error. Try again.'; });
    }
  }

  Future<void> _pickFromGallery() async {
    if (_picking) return; _picking = true;
    try {
      final picked = await _picker.pickMultiImage() ?? [];
      if (!mounted || picked.isEmpty) return;
      _pendingScreenshots.clear(); _cropScreenOpen = false;
      _openCropScreen(picked.map((x) => x.path).toList());
    } finally { _picking = false; }
  }

  void _appendAndOpenCrop(String path) {
    _pendingScreenshots.add(path);
    _pendingScreenshotCount.value = _pendingScreenshots.length;
    if (_cropScreenOpen) return;
    _openCropScreen(List.from(_pendingScreenshots), deleteTempAfter: true);
  }

  void _openCropScreen(List<String> paths, {bool deleteTempAfter = false}) {
    if (!mounted || _cropScreenOpen) return;
    _cropScreenOpen = true;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CropScreen(
        initialPaths: paths, deleteTempAfter: deleteTempAfter,
        onDone: () { _pendingScreenshots.clear(); _pendingScreenshotCount.value = 0; _cropScreenOpen = false; },
      ),
    ));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Screenshot(
      controller: _screenshotCtrl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('🛡️ ScamShield', style: TextStyle(fontWeight: FontWeight.bold)),
          centerTitle: true,
          actions: [
            IconButton(icon: const Icon(Icons.history_rounded), tooltip: 'History',
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()))),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(children: [

            if (_incomingCall) ...[
              _IncomingCallBanner(number: _incomingNumber, checking: _checkingNumber),
              const SizedBox(height: 16),
            ],

            // ── Hero icon ──────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(shape: BoxShape.circle,
                  color: Colors.blue.withOpacity(0.1), border: Border.all(color: Colors.blue.withOpacity(0.4), width: 2)),
              child: const Icon(Icons.security_rounded, size: 80, color: Colors.blue),
            ),
            const SizedBox(height: 14),
            const Text('🛡️ ScamShield', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('AI స్కామ్ రక్షణ • AI Scam Protection',
                style: TextStyle(color: Colors.white54, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(_status, style: const TextStyle(color: Colors.grey, fontSize: 13), textAlign: TextAlign.center),
            const SizedBox(height: 28),

            // ── Scan buttons ───────────────────────────────────
            if (_scanning)
              const Column(children: [CircularProgressIndicator(), SizedBox(height: 12)])
            else ...[
              ElevatedButton.icon(
                onPressed: _scanScreen,
                icon: const Icon(Icons.document_scanner_rounded, size: 22),
                label: Text(L.t('scan_now'), textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, height: 1.3)),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 60),
                    backgroundColor: Colors.blue, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _picking ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library_rounded, size: 22),
                label: Text(L.t('scan_gallery'), textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, height: 1.3)),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54),
                    backgroundColor: const Color(0xFF1565C0), foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              const SizedBox(height: 12),
              _FloatingButtonToggle(enabled: _overlayEnabled, onToggle: _toggleOverlay),
              const SizedBox(height: 12),
              _NotificationToggle(enabled: _notificationEnabled, onEnable: _enableNotificationProtection),
              const SizedBox(height: 12),
              _LanguageToggle(current: L.current, onSelect: _setLanguage),
            ],

            const SizedBox(height: 28),

            // ── Quick rules card ───────────────────────────────
            _QuickRulesCard(),

            const SizedBox(height: 20),
            const Align(alignment: Alignment.centerLeft,
                child: Text('ఇవి గుర్తిస్తుంది / Ye Pehchanta Hai:', style: TextStyle(color: Colors.grey, fontSize: 12))),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [FraudType.upi, FraudType.job, FraudType.lottery, FraudType.phishing, FraudType.kyc]
                .map((ft) => FraudTypeBadge(fraudType: ft, bilingual: true)).toList()),
            const SizedBox(height: 24),

            const _HomeHelplineBanner(),

            const SizedBox(height: 20),
            Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.center, children: const [
              _InfoChip(icon: Icons.phone_android_rounded,        label: 'On-device OCR'),
              _InfoChip(icon: Icons.lock_rounded,                 label: 'Privacy First'),
              _InfoChip(icon: Icons.bolt_rounded,                 label: 'AI Powered'),
              _InfoChip(icon: Icons.offline_bolt_rounded,         label: 'Offline Fallback'),
              _InfoChip(icon: Icons.phone_in_talk_rounded,        label: 'Call Guard'),
              _InfoChip(icon: Icons.notifications_active_rounded, label: 'Message Guard'),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// QUICK RULES CARD  (big, emoji-heavy, rural-friendly)
// ══════════════════════════════════════════════════════════════

class _QuickRulesCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Text(L.t('rules_title'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.amber)),
        ]),
        const SizedBox(height: 12),
        _rule('🔢', 'rule_1', 'rule_1_sub'),
        _rule('🏦', 'rule_2', 'rule_2_sub'),
        _rule('🔗', 'rule_3', 'rule_3_sub'),
        _rule('💸', 'rule_4', 'rule_4_sub'),
        _rule('📞', 'rule_5', 'rule_5_sub'),
      ]),
    );
  }

  Widget _rule(String emoji, String mainKey, String subKey) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(emoji, style: const TextStyle(fontSize: 20)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(L.t(mainKey), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        Text(L.t(subKey),  style: const TextStyle(color: Colors.white60, fontSize: 12)),
      ])),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// HOME HELPLINE BANNER
// ══════════════════════════════════════════════════════════════

class _HomeHelplineBanner extends StatelessWidget {
  const _HomeHelplineBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.red.shade900.withOpacity(0.22),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.red.shade700.withOpacity(0.5))),
      child: Row(children: [
        const Icon(Icons.emergency_rounded, color: Colors.redAccent, size: 32),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cybercrime Helpline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.redAccent)),
          const Text('1930', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 4)),
          Text('24×7 Free • ఉచితం • cybercrime.gov.in', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
        ])),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
          onPressed: () async { try { await launchUrl(Uri.parse('tel:1930')); } catch (_) {} },
          child: const Text('Call\nNow', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// TOGGLES
// ══════════════════════════════════════════════════════════════

class _FloatingButtonToggle extends StatelessWidget {
  final bool enabled; final VoidCallback onToggle;
  const _FloatingButtonToggle({required this.enabled, required this.onToggle});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    ElevatedButton.icon(
      onPressed: onToggle,
      icon: const Icon(Icons.bubble_chart_rounded, size: 22),
      label: Text(enabled ? L.t('float_off') : L.t('float_on'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52),
          backgroundColor: enabled ? const Color(0xFFB71C1C) : Colors.deepPurple,
          foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    const SizedBox(height: 5),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? _C.safe : Colors.grey)),
      const SizedBox(width: 6),
      Text(enabled ? 'Active — floating scan bubble visible' : 'Tap to enable floating scan bubble',
          style: TextStyle(fontSize: 11, color: enabled ? _C.safe : Colors.grey)),
    ]),
  ]);
}

class _NotificationToggle extends StatelessWidget {
  final bool enabled; final VoidCallback onEnable;
  const _NotificationToggle({required this.enabled, required this.onEnable});
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    ElevatedButton.icon(
      icon: Icon(enabled ? Icons.notifications_active_rounded : Icons.notifications_off_rounded, size: 22),
      label: Text(enabled ? L.t('notif_on') : L.t('notif_off'),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      onPressed: enabled ? null : onEnable,
      style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52),
          backgroundColor: enabled ? Colors.teal.shade700 : Colors.indigo,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.teal.shade800, disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    ),
    const SizedBox(height: 5),
    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? _C.safe : Colors.grey)),
      const SizedBox(width: 6),
      Text(enabled ? L.t('notif_on_hint') : L.t('notif_off_hint'),
          style: TextStyle(fontSize: 11, color: enabled ? _C.safe : Colors.grey)),
    ]),
  ]);
}

// ══════════════════════════════════════════════════════════════
// LANGUAGE TOGGLE  — Telugu / Hindi / English selector
// Displayed on home screen so rural users can switch language
// in one tap. Persisted in SharedPreferences across sessions.
// ══════════════════════════════════════════════════════════════

class _LanguageToggle extends StatelessWidget {
  final String current;
  final void Function(String) onSelect;
  const _LanguageToggle({required this.current, required this.onSelect});

  static const _langs = [
    ('te', '🇮🇳', 'తెలుగు',  'Telugu'),
    ('hi', '🇮🇳', 'हिंदी',    'Hindi'),
    ('en', '🇬🇧', 'English',  'English'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Header
      Row(children: [
        const Icon(Icons.language_rounded, color: Colors.amber, size: 18),
        const SizedBox(width: 8),
        Text(L.t('lang_btn'),
            style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold, fontSize: 14)),
      ]),
      const SizedBox(height: 8),
      // Three language buttons in a row
      Row(children: _langs.map((lang) {
        final code  = lang.$1;
        final flag  = lang.$2;
        final name  = lang.$3;
        final sub   = lang.$4;
        final sel   = current == code;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: GestureDetector(
              onTap: () => onSelect(code),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: sel ? Colors.amber.withOpacity(0.18) : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: sel ? Colors.amber : Colors.white24,
                    width: sel ? 2 : 1,
                  ),
                  boxShadow: sel
                      ? [BoxShadow(color: Colors.amber.withOpacity(0.25), blurRadius: 8)]
                      : [],
                ),
                child: Column(children: [
                  Text(flag, style: const TextStyle(fontSize: 22)),
                  const SizedBox(height: 4),
                  Text(name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: sel ? FontWeight.bold : FontWeight.normal,
                        color: sel ? Colors.amber : Colors.white70,
                      )),
                  if (code != 'en')
                    Text(sub,
                        style: TextStyle(
                          fontSize: 10,
                          color: sel ? Colors.amber.withOpacity(0.8) : Colors.white38,
                        )),
                  if (sel)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      width: 6, height: 6,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.amber,
                      ),
                    ),
                ]),
              ),
            ),
          ),
        );
      }).toList()),
      const SizedBox(height: 5),
      Center(
        child: Text(
          current == 'te'
              ? 'ప్రస్తుత భాష: తెలుగు'
              : current == 'hi'
              ? 'वर्तमान भाषा: हिंदी'
              : 'Current language: English',
          style: TextStyle(fontSize: 11, color: Colors.amber.withOpacity(0.7)),
        ),
      ),
    ]);
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon; final String label;
  const _InfoChip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white24)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: Colors.blue), const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// CROP SCREEN
// ══════════════════════════════════════════════════════════════

class CropScreen extends StatefulWidget {
  final List<String> initialPaths;
  final VoidCallback? onDone;
  final bool deleteTempAfter;
  const CropScreen({super.key, required this.initialPaths, this.onDone, this.deleteTempAfter = false});
  @override State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late List<String> _images;
  bool   _analyzing   = false;
  bool   _addingImage = false;
  String _status      = '';
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _images = widget.initialPaths;
    _pendingScreenshotCount.addListener(() {
      if (!mounted) return;
      if (_images.length != _pendingScreenshots.length && _pendingScreenshots.isNotEmpty) {
        setState(() { _images = List.from(_pendingScreenshots); });
      }
    });
  }

  @override void dispose() { super.dispose(); }
  void _finish() { widget.onDone?.call(); if (mounted) Navigator.pop(context); }

  Future<void> _crop(int i) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: _images[i],
      uiSettings: [AndroidUiSettings(
        toolbarTitle: 'Message area crop చేయండి', toolbarColor: Colors.black,
        toolbarWidgetColor: Colors.white, activeControlsWidgetColor: Colors.blue,
        lockAspectRatio: false, hideBottomControls: false,
        initAspectRatio: CropAspectRatioPreset.original,
        aspectRatioPresets: [CropAspectRatioPreset.original, CropAspectRatioPreset.square, CropAspectRatioPreset.ratio4x3, CropAspectRatioPreset.ratio16x9],
      )],
    );
    if (cropped != null && mounted) setState(() => _images[i] = cropped.path);
  }

  void _remove(int i) {
    if (_images.length == 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('కనీసం ఒక image కావాలి.'), duration: Duration(seconds: 2)));
      return;
    }
    setState(() => _images.removeAt(i));
  }

  Future<void> _addFromGallery() async {
    if (_addingImage) return; _addingImage = true;
    try {
      final p = await _picker.pickImage(source: ImageSource.gallery);
      if (p != null && mounted) setState(() => _images.add(p.path));
    } finally { _addingImage = false; }
  }

  Future<void> _analyze() async {
    if (_images.isEmpty) return;
    setState(() { _analyzing = true; _status = 'Starting…'; });
    try {
      final result = await _runPipeline(
        imagePaths: _images, context: context,
        setStatus: (s) { if (mounted) setState(() => _status = s); },
        deleteTempAfter: widget.deleteTempAfter,
      );
      if (result == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Text కనిపించలేదు. Message area దగ్గరగా crop చేయండి.')));
      }
      if (mounted) _finish();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Analysis failed: $e')));
    } finally {
      if (mounted) setState(() { _analyzing = false; _status = ''; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async { if (_analyzing) return false; _finish(); return false; },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Screenshot Review${_images.length > 1 ? " (${_images.length})" : ""}', style: const TextStyle(fontWeight: FontWeight.bold)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _analyzing ? null : _finish),
          actions: [IconButton(icon: const Icon(Icons.add_photo_alternate_rounded), onPressed: (_analyzing || _addingImage) ? null : _addFromGallery)],
        ),
        body: Column(children: [
          Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.blue.withOpacity(0.1),
            child: Text(
              _images.length == 1
                  ? L.t('crop_hint_1')
                  : '💡 ${_images.length} screenshots లోడ్ అయ్యాయి. Crop చేసి Analyze నొక్కండి.',
              style: const TextStyle(fontSize: 12, color: Colors.white70), textAlign: TextAlign.center,
            ),
          ),
          Expanded(child: _images.isEmpty
              ? const Center(child: Text('No images. Back వెళ్ళి try చేయండి.', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
            padding: const EdgeInsets.all(12), itemCount: _images.length,
            itemBuilder: (_, i) => Card(
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), clipBehavior: Clip.antiAlias,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (_images.length > 1)
                  Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), color: Colors.blue.withOpacity(0.15),
                      child: Text('Screenshot ${i + 1} of ${_images.length}', style: const TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold))),
                ConstrainedBox(constraints: const BoxConstraints(maxHeight: 280), child: Image.file(File(_images[i]), fit: BoxFit.contain)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      TextButton.icon(onPressed: _analyzing ? null : () => _crop(i), icon: const Icon(Icons.crop_rounded, size: 18), label: const Text('Crop')),
                      const SizedBox(width: 4),
                      TextButton.icon(onPressed: _analyzing ? null : () => _remove(i), icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.redAccent), label: const Text('Remove', style: TextStyle(color: Colors.redAccent))),
                      if (i == _images.length - 1)
                        TextButton.icon(onPressed: (_analyzing || _addingImage) ? null : _addFromGallery, icon: const Icon(Icons.add_rounded, size: 18, color: Colors.green), label: const Text('Add More', style: TextStyle(color: Colors.green))),
                    ])),
              ]),
            ),
          )),
          if (_status.isNotEmpty)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(_status, style: const TextStyle(color: Colors.blue, fontSize: 13), textAlign: TextAlign.center)),
          SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ElevatedButton.icon(
              onPressed: (_analyzing || _images.isEmpty) ? null : _analyze,
              icon: _analyzing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.search_rounded, size: 22),
              label: Text(_analyzing ? (_status.isNotEmpty ? _status : 'Analyzing…') : L.t('analyze_btn'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 56),
                  backgroundColor: Colors.blue, foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.blue.withOpacity(0.45),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          )),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// HISTORY SCREEN
// ══════════════════════════════════════════════════════════════

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ScanResult> _history = [];
  bool _loading = true;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final h = await HistoryService.load();
    if (mounted) setState(() { _history = h; _loading = false; });
  }

  Future<void> _clear() async {
    await HistoryService.clear();
    if (mounted) setState(() => _history = []);
  }

  @override
  Widget build(BuildContext context) {
    final highCount = _history.where((r) => r.riskLevel == RiskLevel.highRisk).length;
    final suspCount = _history.where((r) => r.riskLevel == RiskLevel.suspicious).length;
    final safeCount = _history.where((r) => r.riskLevel == RiskLevel.safe).length;

    return Scaffold(
      appBar: AppBar(
        title: Text('Scan History (${_history.length})', style: const TextStyle(fontWeight: FontWeight.bold)), centerTitle: true,
        actions: [
          if (_history.isNotEmpty)
            IconButton(icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Clear All',
                onPressed: () async {
                  final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
                    title: const Text('History Delete చేయాలా?'),
                    content: const Text('అన్ని scan records permanently delete అవుతాయి.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(context, true),  child: const Text('Delete All', style: TextStyle(color: Colors.red))),
                    ],
                  ));
                  if (ok == true) _clear();
                }),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
          ? Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.history_rounded, size: 64, color: Colors.grey), const SizedBox(height: 16),
        Text(L.t('history_empty'), style: const TextStyle(color: Colors.grey, fontSize: 16)),
        const SizedBox(height: 6),
        Text(L.t('history_hint'), style: const TextStyle(color: Colors.grey, fontSize: 13)),
      ]))
          : Column(children: [
        if (highCount > 0)
          Container(margin: const EdgeInsets.fromLTRB(12, 12, 12, 4), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.withOpacity(0.35))),
              child: Row(children: [const Icon(Icons.warning_rounded, color: Colors.red, size: 18), const SizedBox(width: 8),
                Text('$highCount అధిక ప్రమాదం / high-risk message${highCount > 1 ? "s" : ""}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13))])),
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              _SC(label: 'Total',           value: _history.length.toString(), color: Colors.white70),
              _SC(label: '🚨 High Risk',    value: highCount.toString(),       color: _C.highRisk),
              _SC(label: '⚠️ Suspicious',  value: suspCount.toString(),       color: _C.suspicious),
              _SC(label: '✅ Safe',         value: safeCount.toString(),       color: _C.safe),
            ])),
        Expanded(child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          itemCount: _history.length,
          itemBuilder: (_, i) => _HistoryCard(result: _history[i]),
        )),
      ]),
    );
  }
}

class _SC extends StatelessWidget {
  final String label; final String value; final Color color;
  const _SC({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(0.3))),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(value, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16)),
      Text(label,  style: const TextStyle(color: Colors.grey, fontSize: 10)),
    ]),
  );
}

class _HistoryCard extends StatelessWidget {
  final ScanResult result;
  const _HistoryCard({required this.result});
  String _fmt(DateTime dt) => '${dt.day}/${dt.month}/${dt.year} ${dt.hour}:${dt.minute.toString().padLeft(2, "0")}';
  @override
  Widget build(BuildContext context) {
    final color = result.riskLevel.color;
    final title = result.riskLevel == RiskLevel.highRisk ? '🚨 Scam!' : result.riskLevel == RiskLevel.suspicious ? '⚠️ అనుమానాస్పద' : '✅ Safe';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: color.withOpacity(0.35))),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(backgroundColor: color.withOpacity(0.15), child: Icon(result.riskLevel.icon, color: color, size: 22)),
        title: Row(children: [
          Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(width: 8),
          Text(result.fraudType.emoji, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 4),
          Flexible(child: Text(result.fraudType.label, overflow: TextOverflow.ellipsis, style: TextStyle(color: result.fraudType.color, fontSize: 11, fontWeight: FontWeight.w500))),
        ]),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 3),
          Text(result.originalText.length > 70 ? '${result.originalText.substring(0, 70)}…' : result.originalText,
              style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text(_fmt(result.timestamp), style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ]),
        trailing: Text('${result.scamProbability.toInt()}%', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
        onTap: () => showDialog(context: context, builder: (_) => ScamAlertDialog(result: result)),
      ),
    );
  }
}