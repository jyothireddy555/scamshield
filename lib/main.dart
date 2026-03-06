import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

// ── Show full scam result as a system overlay (works over ANY app) ──
// Sends all result fields to the native OverlayService which inflates
// a WindowManager view directly on screen — no need to be inside ScamShield.
Future<void> _showScamOverlay(ScanResult result, {String source = 'Message'}) async {
  try {
    if (!(await _hasOverlayPermission())) return;
    final prefs = await SharedPreferences.getInstance();
    final floatingEnabled = prefs.getBool(_kOverlayEnabled) ?? false;

    // Only start overlay service if floating button feature is enabled


    await _overlayChannel.invokeMethod('showScamAlert', {
      'source': source,
      'probability': result.scamProbability.toInt(),
      'riskLevel': result.riskLevel.label,
      'fraudType': result.fraudType.label,
      'fraudEmoji': result.fraudType.emoji,
      'explanation': result.explanation,
      'whatToDo': result.whatToDo,
      'keywords': result.suspiciousKeywords.take(4).join(', '),
      'helpline': result.helpline,
      'showHelpline': result.showFullWarning,
    });

  } catch (e) {
    debugPrint('❌ [OVERLAY] showScamAlert: $e');
  }
}

const _kOverlayEnabled       = 'overlay_enabled';
const _kNotificationEnabled  = 'notification_enabled';   // Issue 2 — persist state

// ── Theme colors ───────────────────────────────────────────────
class _C {
  static const safe       = Color(0xFF2ED573);
  static const suspicious = Color(0xFFFF9F43);
  static const highRisk   = Color(0xFFFF4757);
  static const unknown    = Color(0xFF54A0FF);
  static const cardBg     = Color(0xFF1e1e2e);
}

// ── Constants ──────────────────────────────────────────────────
const double _kScamWarningThreshold = 70.0;
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
    'scam_probability': scamProbability, 'is_scam': isScam,            'risk_level':  riskLevel.label,
    'fraud_type':       fraudType.label, 'keywords': suspiciousKeywords, 'explanation': explanation,
    'prevention_tips':  preventionTips,  'what_to_do': whatToDo,        'helpline':    helpline,
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
    if (!valid)                                                                         return NumberCheckResult(number: number, risk: NumberRisk.suspicious, reason: 'This number appears invalid or not in service.',                                   advice: 'Be very cautious. Do not share any personal details.');
    if (lineType == 'voip' || lineType == 'premium' || lineType == 'toll_free')        return NumberCheckResult(number: number, risk: NumberRisk.suspicious, reason: 'This is a ${lineType.toUpperCase()} number — commonly used by scammers.',         advice: 'Never share OTP, bank details, or Aadhaar with this caller.');
    if (country == 'IN') return _localHeuristics(number);
    return NumberCheckResult(number: number, risk: NumberRisk.unknown,    reason: 'This number could not be verified in our database.',                       advice: 'Be careful. Do not share sensitive information with unknown callers.');
  }

  static NumberCheckResult _localHeuristics(String number) {
    final clean = number.replaceAll(RegExp(r'\D'), '');
    if (clean.startsWith('92') && clean.length >= 11) return NumberCheckResult(number: number, risk: NumberRisk.spam,       reason: 'This number originates from Pakistan (+92) — frequently used in international scam calls targeting Indians.', advice: 'Do NOT answer or call back. Block this number immediately.');
    if (clean.startsWith('1')  && clean.length == 11) return NumberCheckResult(number: number, risk: NumberRisk.suspicious, reason: 'This is a US/Canada number. International callers claiming to be from Indian banks or government are almost always scammers.', advice: 'Never share OTP, bank details, or Aadhaar with this caller.');
    if (clean.startsWith('140') || clean.startsWith('160'))               return NumberCheckResult(number: number, risk: NumberRisk.suspicious, reason: 'This is a registered telemarketing number in India.',                  advice: 'You can ignore this. Do NOT share OTP or bank details.');
    if (_isRepeatingPattern(clean))                                       return NumberCheckResult(number: number, risk: NumberRisk.spam,       reason: 'This number has a suspicious repeating digit pattern — likely a spoofed number.', advice: 'Do NOT share any details. This is almost certainly a scam.');
    if (clean.length < 8)                                                 return NumberCheckResult(number: number, risk: NumberRisk.suspicious, reason: 'This number is unusually short.',                                      advice: "Be cautious. Verify the caller's identity before sharing anything.");
    return NumberCheckResult(number: number, risk: NumberRisk.unknown, reason: 'This number is not saved in your contacts and could not be verified.', advice: 'Do not share OTP, bank PIN, Aadhaar, or personal details with unknown callers.');
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
      reason: 'This number could not be identified.',
      advice: 'Do not share sensitive information with unknown callers.');
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

  // Parallel processing + cap at _kOcrMaxChars
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
    final ts       = '${r.timestamp.day.toString().padLeft(2, '0')}/'
        '${r.timestamp.month.toString().padLeft(2, '0')}/'
        '${r.timestamp.year} '
        '${r.timestamp.hour.toString().padLeft(2, '0')}:'
        '${r.timestamp.minute.toString().padLeft(2, '0')}';
    final keywords = r.suspiciousKeywords.isNotEmpty ? r.suspiciousKeywords.join(', ') : 'None';

    final body = [
      '🚨 *SCAM ALERT*',
      '',
      'Detected by *ScamShield*.',
      '',
      '⚠️ Risk Level: ${r.riskLevel.label}',
      '📊 Scam Probability: ${r.scamProbability.toInt()}%',
      '🏷 Fraud Type: ${r.fraudType.label}',
      '',
      '🔎 Suspicious Keywords:',
      keywords,
      '',
      '📩 Message Content:',
      r.originalText,
      '',
      '🧠 Why it is dangerous:',
      r.explanation,
      '',
      '⚠️ Stay safe. Never share OTP, bank PIN, Aadhaar, or passwords.',
      '',
      '— Shared via ScamShield',
    ].join('\n');

    final uri = Uri.parse('whatsapp://send?text=${Uri.encodeComponent(body)}');
    try {
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) debugPrint('⚠️ [REPORT] WhatsApp not installed');
    } catch (e) {
      debugPrint('⚠️ [REPORT] WhatsApp launch failed: $e');
    }
  }
}

// ══════════════════════════════════════════════════════════════
// LOCAL FALLBACK ENGINE
// ══════════════════════════════════════════════════════════════

class _LocalEngine {
  static const _upi     = ['upi','gpay','phonepe','paytm','vpa','payment link','qr code','scan qr','neft','imps','bank account number'];
  static const _job     = ['work from home','part time job','data entry','typing job','earn daily','guaranteed salary','no experience required','registration fee','training fee','whatsapp job'];
  static const _lottery = ['lottery','lucky draw','prize winner','you have won','congratulations you','claim your reward','lucky winner','processing fee','cash prize'];
  static const _phish   = ['click here to verify','verify your account','account suspended','account has been blocked','update your details','login link','bit.ly','tinyurl','password reset link','confirm your identity'];
  static const _kyc     = ['kyc update','kyc expired','kyc pending','kyc verify','complete your kyc','aadhaar link','pan card update','link your aadhaar'];
  static const _otp     = ['otp','one time password','share otp','send otp','anydesk','teamviewer','remote access','screen share'];
  static const _general = ['urgent action required','immediate action','account will expire','limited time offer','act now or lose','do not ignore this'];

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
      whatToDo: rl == RiskLevel.safe ? 'No immediate action needed. Stay vigilant.' : 'Do NOT share any details. Call 1930 immediately if you already responded.',
      helpline: '1930', originalText: text, timestamp: DateTime.now(),
    );
  }

  static int    _hits(String t, List<String> words) => words.where((w) => t.contains(w.toLowerCase())).length;

  static String _explain(FraudType ft, double score) {
    if (score < 15) return 'No significant scam indicators found. The message appears safe.';
    switch (ft) {
      case FraudType.upi:      return 'UPI/payment fraud detected. Never share your PIN, OTP or click unverified payment links.';
      case FraudType.job:      return 'Job scam detected. Legitimate employers never ask you to pay to get hired.';
      case FraudType.lottery:  return 'Lottery scam detected. You cannot win a contest you never entered.';
      case FraudType.phishing: return 'Phishing detected. Always type official URLs — never click links in messages.';
      case FraudType.kyc:      return 'KYC scam detected. Banks never ask you to complete KYC via an SMS link.';
      default:                 return 'Suspicious patterns detected. Verify through official channels before taking any action.';
    }
  }

  static List<String> _tips(FraudType ft) {
    switch (ft) {
      case FraudType.upi:      return ['Never share UPI PIN or OTP — not even with bank employees.','QR code scanning sends money FROM you, not to you.','Only use payment apps from the official Play Store.','Verify the recipient name before every transfer.'];
      case FraudType.job:      return ['Real employers never charge registration or training fees.','Verify the company on LinkedIn or their official site.','WhatsApp job offers from unknown numbers are almost always scams.','Use Naukri or NCS portal for safe job searches.'];
      case FraudType.lottery:  return ['You cannot win a lottery you never entered.','Never pay any fee to receive prize money.','Do not share Aadhaar or bank details for prize claims.','Report at cybercrime.gov.in or call 1930.'];
      case FraudType.phishing: return ['Never click links in SMS or WhatsApp — type official URLs directly.','Your bank will never ask for your password or OTP via a message.','Check URLs carefully — fraudsters use domains like sbi-secure.xyz.','Enable two-factor authentication on all banking apps.'];
      case FraudType.kyc:      return ['KYC is done only at your bank branch or the official banking app.','Never upload Aadhaar/PAN through a link sent in a message.','Call your bank official helpline to verify any KYC request.','Your account will not be blocked just because of a message.'];
      default:                 return ['Do not click any unknown links.','Never share your OTP or bank PIN with anyone.','Call the National Cybercrime Helpline: 1930.','Report scam messages at cybercrime.gov.in.'];
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
  required List<String> imagePaths,
  required BuildContext context,
  required void Function(String) setStatus,
  bool deleteTempAfter = false,
  bool showOverlay = false,
}) async {
  if (imagePaths.isEmpty) { setStatus('No images to analyze.'); return null; }

  setStatus('Extracting text from image…');
  final text = await OcrService.extractFromPaths(imagePaths);
  debugPrint('\n─────\n📄 OCR (${text.length} chars):\n${text.substring(0, text.length.clamp(0, 300))}…\n─────');

  if (text.trim().isEmpty) { setStatus('No text found. Try cropping more tightly.'); return null; }
  if (text.trim().length < 5) { setStatus('Could not read text. Try a sharper crop.'); return null; }

  setStatus('Analyzing with AI…');
  final result = await ApiService.analyze(text);
  await HistoryService.save(result);

  if (deleteTempAfter) {
    for (final p in imagePaths) {
      if (p.contains('snap_')) {
        try { await File(p).delete(); } catch (_) {}
      }
    }
  }

  if (context.mounted) {
    setStatus('Tap the button to scan any message');
    // Show in-app dialog (user is inside ScamShield) AND send to overlay
    // so the result is visible even if the user navigates away mid-scan.
    if (showOverlay && result.scamProbability >= 50) {
      await _showScamOverlay(result, source: 'Screenshot');
    }
    await showDialog<void>(context: context, builder: (_) => ScamAlertDialog(result: result));
  }
  return result;
}

// ══════════════════════════════════════════════════════════════
// CALL ALERT DIALOG
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
        Text(result.risk.title, textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 6),
        Text(result.number, style: const TextStyle(fontSize: 16, color: Colors.white70, letterSpacing: 2)),
        const SizedBox(height: 18),
        _infoBox(color, Icons.info_outline_rounded, 'Why this alert?', result.reason),
        const SizedBox(height: 14),
        _infoBox(Colors.redAccent, Icons.shield_rounded, 'Stay Safe', result.advice),
        const SizedBox(height: 18),
        Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Colors.red.shade900.withOpacity(0.3), borderRadius: BorderRadius.circular(10)),
            child: const Row(children: [
              Text('🚫', style: TextStyle(fontSize: 18)), SizedBox(width: 10),
              Expanded(child: Text('NEVER share OTP • bank PIN • Aadhaar • passwords', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))),
            ])),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: OutlinedButton(
            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24), padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: () => Navigator.pop(context),
            child: const Text('Dismiss'),
          )),
          const SizedBox(width: 10),
          Expanded(child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 12)),
            onPressed: () async { Navigator.pop(context); try { await launchUrl(Uri.parse('tel:1930')); } catch (e) { debugPrint('❌ tel:1930 $e'); } },
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
      Row(children: [Icon(icon, color: color, size: 16), const SizedBox(width: 8), Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13))]),
      const SizedBox(height: 8),
      Text(body, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════
// WIDGETS
// ══════════════════════════════════════════════════════════════

class ProbabilityMeter extends StatelessWidget {
  final double probability; final RiskLevel riskLevel;
  const ProbabilityMeter({super.key, required this.probability, required this.riskLevel});
  @override
  Widget build(BuildContext context) {
    final color = riskLevel.color;
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Scam Risk:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
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
      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('Safe',       style: TextStyle(fontSize: 10, color: _C.safe)),
        Text('Suspicious', style: TextStyle(fontSize: 10, color: _C.suspicious)),
        Text('High Risk',  style: TextStyle(fontSize: 10, color: _C.highRisk)),
      ]),
    ]);
  }
}

class FraudTypeBadge extends StatelessWidget {
  final FraudType fraudType;
  const FraudTypeBadge({super.key, required this.fraudType});
  @override
  Widget build(BuildContext context) {
    final c = fraudType.color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: c.withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: c.withOpacity(0.45))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(fraudType.emoji, style: const TextStyle(fontSize: 14)), const SizedBox(width: 6),
        Text(fraudType.label, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 13)),
      ]),
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
    final regex  = RegExp('(${escaped.join('|')})', caseSensitive: false);
    final spans  = <TextSpan>[]; int last = 0;
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
      const Text('🛡️ Prevention Tips', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: 10),
      ...tips.asMap().entries.map((e) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 34, height: 34, decoration: BoxDecoration(color: Colors.white.withOpacity(0.07), borderRadius: BorderRadius.circular(8)), alignment: Alignment.center, child: Text(_icons[e.key % _icons.length], style: const TextStyle(fontSize: 16))),
          const SizedBox(width: 12), Expanded(child: Text(e.value, style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.5))),
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
          Text('What To Do Now', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Text(action, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5)),
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
            Text('Available 24 × 7  •  Free call', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
            Text('cybercrime.gov.in', style: TextStyle(fontSize: 11, color: Colors.blue.shade300)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
              onPressed: () async { try { await launchUrl(Uri.parse('tel:${result.helpline}')); } catch (e) { debugPrint('❌ tel $e'); } },
              icon: const Icon(Icons.call_rounded, size: 16),
              label: const Text('Call Now', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.green.shade400), foregroundColor: Colors.green.shade400, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
              onPressed: () => WhatsAppReporter.report(result),
              icon: const Icon(Icons.send_rounded, size: 14),
              label: const Text('Report via WhatsApp', style: TextStyle(fontSize: 12)),
            ),
          ]),
        ]),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// SCAM ALERT DIALOG
// ══════════════════════════════════════════════════════════════

class ScamAlertDialog extends StatelessWidget {
  final ScanResult result;
  const ScamAlertDialog({super.key, required this.result});

  String get _title => switch (result.riskLevel) {
    RiskLevel.highRisk   => '🚨 SCAM DETECTED!',
    RiskLevel.suspicious => '⚠️ Suspicious Message',
    RiskLevel.safe       => '✅ Looks Safe',
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
        Text(_title, textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        const SizedBox(height: 10),
        FraudTypeBadge(fraudType: result.fraudType),
        const SizedBox(height: 20),
        ProbabilityMeter(probability: result.scamProbability, riskLevel: result.riskLevel),
        const SizedBox(height: 20),

        if (result.suspiciousKeywords.isNotEmpty) ...[
          _SL('Suspicious Keywords'), const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: result.suspiciousKeywords.map((kw) =>
              Chip(label: Text(kw, style: const TextStyle(color: Colors.white, fontSize: 12)), backgroundColor: const Color(0xFFB71C1C), side: BorderSide.none, padding: const EdgeInsets.symmetric(horizontal: 4), visualDensity: VisualDensity.compact)
          ).toList()),
          const SizedBox(height: 16),
        ],

        if (result.originalText.isNotEmpty) ...[
          _SL('Scanned Message'), const SizedBox(height: 8),
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
          OutlinedButton.icon(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded), label: const Text('Dismiss')),
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
  Widget build(BuildContext context) => Align(alignment: Alignment.centerLeft, child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)));
}

// ══════════════════════════════════════════════════════════════
// INCOMING CALL BANNER
// ══════════════════════════════════════════════════════════════

class _IncomingCallBanner extends StatelessWidget {
  final String number; final bool checking;
  const _IncomingCallBanner({required this.number, required this.checking});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity, padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.blue.withOpacity(0.10), border: Border.all(color: Colors.blue.withOpacity(0.4)), borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        const Icon(Icons.phone_in_talk_rounded, color: Colors.blue, size: 20), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Incoming call — checking number…', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13)),
          if (number.isNotEmpty) Text(number, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ])),
        if (checking) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue)),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// HOME SCREEN
// ══════════════════════════════════════════════════════════════

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool   _scanning            = false;
  String _status              = 'Tap the button to scan any message';
  bool   _overlayEnabled      = false;
  bool   _notificationEnabled = false;   // Issue 2 — persisted state
  bool   _waitingForPerm      = false;
  Timer? _notifDebounce;
  bool   _incomingCall   = false;
  bool   _checkingNumber = false;
  String _incomingNumber = '';
  String _lastCallState  = '';
  String _lastCallNumber = '';

  bool   _callDialogOpen         = false;
  bool   _notificationDialogOpen = false;   // Improvement 1 — dialog flood guard
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
    _loadNotificationState();   // Issue 2 — load persisted notification state
    _initCallChannel();
    _initNotificationListener();

    _captureChannel.setMethodCallHandler((call) async {
      if (call.method == 'onScreenCaptured' && mounted) {
        final path = call.arguments as String?;
        if (path == null || path.isEmpty) return;

        final now = DateTime.now().millisecondsSinceEpoch;
        if (_lastScreenshot == path) return;                 // duplicate path
        if (now - _lastCaptureTime < 800) {                  // rapid duplicate frames
          debugPrint('⚠️ Duplicate capture ignored');
          return;
        }
        _lastScreenshot  = path;
        _lastCaptureTime = now;

        debugPrint('📸 [NATIVE] Screenshot: $path');
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) _appendAndOpenCrop(path);
      }
    });
  }

  // ── Notification listener ────────────────────────────────────

  void _initNotificationListener() {
    _notificationChannel.setMethodCallHandler((call) async {
      if (!_notificationEnabled) return;
      if (call.method != 'onNotificationMessage') return;

      final data = Map<String, dynamic>.from(call.arguments as Map);
      final app  = data['app']  as String? ?? '';
      final text = data['text'] as String? ?? '';

      debugPrint('📩 Notification from $app: $text');

      // Issue 3 — filter noise before calling API
      final lower = text.toLowerCase();

      if (text.length < 10) return;

      if (lower.contains('typing')) return;
      if (lower.contains('delivered')) return;
      if (lower.contains('missed call')) return;
      if (lower.contains('sent a photo')) return;
      if (lower.contains('sent a video')) return;
      if (lower.contains('sent a sticker')) return;
      if (lower.contains('sent a gif')) return;            // shopping updates

      // Improvement 2 — instant suspicious-link detection before AI
      if (_containsSuspiciousLink(text)) {
        // Fire quick overlay immediately — no AI wait needed
        final fakeResult = _LocalEngine.detect(text);
        await _showScamOverlay(fakeResult, source: app);
      }

      _notifDebounce?.cancel();

      _notifDebounce = Timer(const Duration(milliseconds: 500), () async {

        final result = await ApiService.analyze(text);

        if (result.scamProbability >= 60 && !_notificationDialogOpen) {

          _notificationDialogOpen = true;

          await _showScamOverlay(
            result,
            source: app.isNotEmpty ? app : 'Message',
          );

          _notificationDialogOpen = false;
        }

      });
    });
  }

  // Improvement 2 — known phishing patterns, instant detection
  bool _containsSuspiciousLink(String text) {
    final lower = text.toLowerCase();
    return lower.contains('bit.ly')             ||
        lower.contains('tinyurl')            ||
        lower.contains('.xyz')               ||
        lower.contains('.top')               ||
        lower.contains('verify your account')||
        lower.contains('click here')         ||
        lower.contains('login link')         ||
        lower.contains('account suspended');
  }

  // Issue 2 — load notification protection state from SharedPreferences
  Future<void> _loadNotificationState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kNotificationEnabled) ?? false;
    if (mounted) setState(() => _notificationEnabled = enabled);
  }

  // Issue 2 — save notification protection state + open system settings
  Future<void> _enableNotificationProtection() async {
    const platform = MethodChannel('notification_settings');
    try {
      await platform.invokeMethod('openNotificationAccess');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNotificationEnabled, true);
      if (mounted) setState(() => _notificationEnabled = true);
    } catch (e) {
      debugPrint('Error opening notification settings: $e');
      _showSnack('Could not open notification settings. Enable manually in Settings > Apps > ScamShield.');
    }
  }

  @override
  void dispose() {
    _callDebounce?.cancel();
    _notifDebounce?.cancel();
    OcrService.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Call channel ─────────────────────────────────────────────

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

      // ── Always fire native overlay first ──────────────────────
      // This appears OVER the phone dialler / lock screen so the
      // user sees the warning even before accepting the call.
      final level = switch (result.risk) {
        NumberRisk.spam => 'highRisk',
        NumberRisk.suspicious => 'suspicious',
        NumberRisk.unknown => 'unknown',
      };

      await _showCallAlert(number, level, result.reason);

      // ── In-app dialog only when ScamShield is in foreground ───
      _callDialogOpen = true;
      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: result.risk == NumberRisk.unknown,
          builder: (_) => CallAlertDialog(result: result),
        );
      }
      _callDialogOpen = false;
    } catch (e) {
      _callDialogOpen = false;
      debugPrint('❌ [NUMBER CHECK] $e');
      if (mounted) setState(() => _checkingNumber = false);
    }
  }

  // ── Overlay ──────────────────────────────────────────────────

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
        _showSnack('✅ Floating button enabled!');
      } else {
        _showSnack('Permission denied. Open Settings to grant it.');
        if (mounted) {
          final open = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text('Please allow "Display over other apps" for ScamShield in Settings.'),
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
        _showSnack('✅ Floating button enabled!');
      } else {
        _waitingForPerm = true;
        await _requestOverlayPermission();
      }
    }
  }

  // ── Screenshot helpers ───────────────────────────────────────

  Future<void> _scanScreen() async {
    setState(() { _scanning = true; _status = 'Capturing screen…'; });
    try {
      final bytes = await _screenshotCtrl.capture();
      if (bytes == null) { setState(() { _scanning = false; _status = 'Screenshot failed. Try again.'; }); return; }
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/snap_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(bytes);
      setState(() { _scanning = false; _status = 'Tap the button to scan any message'; });
      _pendingScreenshots.clear();
      _cropScreenOpen = false;
      _openCropScreen([path], deleteTempAfter: true);
    } catch (e) {
      debugPrint('❌ [HOME] $e');
      setState(() { _scanning = false; _status = 'Error capturing screen.'; });
    }
  }

  Future<void> _pickFromGallery() async {
    if (_picking) return;
    _picking = true;
    try {
      final picked = await _picker.pickMultiImage() ?? [];
      if (!mounted || picked.isEmpty) return;
      _pendingScreenshots.clear();
      _cropScreenOpen = false;
      _openCropScreen(picked.map((x) => x.path).toList());
    } finally {
      _picking = false;
    }
  }

  void _appendAndOpenCrop(String path) {
    _pendingScreenshots.add(path);
    _pendingScreenshotCount.value = _pendingScreenshots.length;
    debugPrint('📋 Screenshots: ${_pendingScreenshots.length}');
    if (_cropScreenOpen) return;
    _openCropScreen(List.from(_pendingScreenshots), deleteTempAfter: true);
  }

  void _openCropScreen(List<String> paths, {bool deleteTempAfter = false}) {
    if (!mounted || _cropScreenOpen) return;
    _cropScreenOpen = true;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => CropScreen(
        initialPaths: paths,
        deleteTempAfter: deleteTempAfter,
        onDone: () {
          _pendingScreenshots.clear();
          _pendingScreenshotCount.value = 0;
          _cropScreenOpen = false;
        },
      ),
    ));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  Future<void> _toggleNotificationProtection() async {
    final prefs = await SharedPreferences.getInstance();
    final newState = !_notificationEnabled;

    if (newState) {
      const platform = MethodChannel('notification_settings');
      await platform.invokeMethod('openNotificationAccess');
    }

    await prefs.setBool(_kNotificationEnabled, newState);

    setState(() {
      _notificationEnabled = newState;
    });
  }

  // ── Build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Screenshot(
      controller: _screenshotCtrl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('🛡️ ScamShield', style: TextStyle(fontWeight: FontWeight.bold)),
          centerTitle: true,
          actions: [
            IconButton(icon: const Icon(Icons.history_rounded), tooltip: 'Scan History',
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

            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.blue.withOpacity(0.1), border: Border.all(color: Colors.blue.withOpacity(0.4), width: 2)),
              child: const Icon(Icons.security_rounded, size: 80, color: Colors.blue),
            ),
            const SizedBox(height: 18),
            const Text('AI-Powered Scam Detection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(_status, style: const TextStyle(color: Colors.grey, fontSize: 14), textAlign: TextAlign.center),
            const SizedBox(height: 32),

            if (_scanning)
              const Column(children: [CircularProgressIndicator(), SizedBox(height: 12)])
            else ...[
              ElevatedButton.icon(
                onPressed: _scanScreen,
                icon: const Icon(Icons.document_scanner_rounded, size: 22),
                label: const Text('SCAN NOW', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 56), backgroundColor: Colors.blue, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _picking ? null : _pickFromGallery,
                icon: const Icon(Icons.photo_library_rounded, size: 22),
                label: const Text('Scan from Gallery', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52), backgroundColor: const Color(0xFF1565C0), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
              ),
              const SizedBox(height: 12),
              // Issue 1 — Floating button toggle
              _FloatingButtonToggle(enabled: _overlayEnabled, onToggle: _toggleOverlay),
              const SizedBox(height: 12),
              // Issue 1 — Notification protection toggle (was missing from UI)
              _NotificationToggle(
                enabled: _notificationEnabled,
                onToggle: _toggleNotificationProtection,
              )
            ],

            const SizedBox(height: 28),
            const Align(alignment: Alignment.centerLeft, child: Text('Detects:', style: TextStyle(color: Colors.grey, fontSize: 12))),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [FraudType.upi, FraudType.job, FraudType.lottery, FraudType.phishing, FraudType.kyc].map((ft) => FraudTypeBadge(fraudType: ft)).toList()),
            const SizedBox(height: 28),

            const _HomeHelplineBanner(),

            const SizedBox(height: 24),
            Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.center, children: const [
              _InfoChip(icon: Icons.phone_android_rounded,       label: 'On-device OCR'),
              _InfoChip(icon: Icons.lock_rounded,                label: 'Privacy First'),
              _InfoChip(icon: Icons.bolt_rounded,                label: 'AI Powered'),
              _InfoChip(icon: Icons.offline_bolt_rounded,        label: 'Offline Fallback'),
              _InfoChip(icon: Icons.phone_in_talk_rounded,       label: 'Call Guard'),
              _InfoChip(icon: Icons.notifications_active_rounded, label: 'Message Guard'),
            ]),
          ]),
        ),
      ),
    );
  }
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
      decoration: BoxDecoration(color: Colors.red.shade900.withOpacity(0.22), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.red.shade700.withOpacity(0.5))),
      child: Row(children: [
        const Icon(Icons.emergency_rounded, color: Colors.redAccent, size: 32),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Cybercrime Helpline', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.redAccent)),
          const Text('1930', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 4)),
          Text('24×7 Free  •  cybercrime.gov.in', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
        ])),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
          onPressed: () async { try { await launchUrl(Uri.parse('tel:1930')); } catch (e) { debugPrint('❌ tel:1930 $e'); } },
          child: const Text('Call\nNow', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        ),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// FLOATING BUTTON TOGGLE
// ══════════════════════════════════════════════════════════════

class _FloatingButtonToggle extends StatelessWidget {
  final bool enabled; final VoidCallback onToggle;
  const _FloatingButtonToggle({required this.enabled, required this.onToggle});
  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ElevatedButton.icon(
        onPressed: onToggle,
        icon: const Icon(Icons.bubble_chart_rounded, size: 22),
        label: Text(enabled ? 'Disable Floating Button' : 'Enable Floating Button', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52), backgroundColor: enabled ? const Color(0xFFB71C1C) : Colors.deepPurple, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? _C.safe : Colors.grey)),
        const SizedBox(width: 6),
        Text(enabled ? 'Floating button is active — tap to remove' : 'Tap to enable the floating scan button', style: TextStyle(fontSize: 11, color: enabled ? _C.safe : Colors.grey)),
      ]),
    ]);
  }
}

// ══════════════════════════════════════════════════════════════
// NOTIFICATION TOGGLE  (Issue 1 — fully wired up)
// ══════════════════════════════════════════════════════════════

class _NotificationToggle extends StatelessWidget {
  final bool         enabled;
  final VoidCallback onToggle;
  const _NotificationToggle({required this.enabled, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ElevatedButton.icon(
        icon: Icon(enabled ? Icons.notifications_active_rounded : Icons.notifications_off_rounded, size: 22),
        label: Text(enabled ? 'Message Protection ON' : 'Enable Message Protection', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        onPressed: onToggle,
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 52),
          backgroundColor: enabled ? Colors.teal.shade700 : Colors.indigo,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.teal.shade800,
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? _C.safe : Colors.grey)),
        const SizedBox(width: 6),
        Text(
          enabled ? 'Scanning WhatsApp, SMS & Email automatically' : 'Tap to scan messages automatically',
          style: TextStyle(fontSize: 11, color: enabled ? _C.safe : Colors.grey),
        ),
      ]),
    ]);
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon; final String label;
  const _InfoChip({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white24)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: Colors.blue), const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ]),
    );
  }
}

// ══════════════════════════════════════════════════════════════
// CROP SCREEN
// ══════════════════════════════════════════════════════════════

class CropScreen extends StatefulWidget {
  final List<String> initialPaths;
  final VoidCallback? onDone;
  final bool deleteTempAfter;
  const CropScreen({super.key, required this.initialPaths, this.onDone, this.deleteTempAfter = false});
  @override
  State<CropScreen> createState() => _CropScreenState();
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
    _images = widget.initialPaths;   // direct reference — bubble appends are visible instantly

    // Listen for new screenshots appended while CropScreen is open
    _pendingScreenshotCount.addListener(() {
      if (!mounted) return;
      if (_images.length != _pendingScreenshots.length && _pendingScreenshots.isNotEmpty) {
        setState(() { _images = List.from(_pendingScreenshots); });
      }
    });
  }

  @override
  void dispose() { super.dispose(); }

  void _finish() {
    widget.onDone?.call();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _crop(int i) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: _images[i],
      uiSettings: [AndroidUiSettings(
        toolbarTitle: 'Crop Message Area', toolbarColor: Colors.black,
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('At least one image is required.'), duration: Duration(seconds: 2)));
      return;
    }
    setState(() => _images.removeAt(i));
  }

  Future<void> _addFromGallery() async {
    if (_addingImage) return;
    _addingImage = true;
    try {
      final p = await _picker.pickImage(source: ImageSource.gallery);
      if (p != null && mounted) setState(() => _images.add(p.path));
    } finally {
      _addingImage = false;
    }
  }

  Future<void> _analyze() async {
    if (_images.isEmpty) return;
    setState(() { _analyzing = true; _status = 'Starting…'; });
    try {
      final result = await _runPipeline(
        imagePaths: _images,
        context: context,
        setStatus: (s) { if (mounted) setState(() => _status = s); },
        deleteTempAfter: widget.deleteTempAfter,
        showOverlay: false,
      );
      if (result == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No text found. Try cropping more tightly around the message.')));
      }
      if (mounted) _finish();
    } catch (e) {
      debugPrint('❌ [CROP] $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Analysis failed: $e')));
    } finally {
      if (mounted) setState(() { _analyzing = false; _status = ''; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (_analyzing) return false;
        _finish();
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Review Screenshot${_images.length > 1 ? "s (${_images.length})" : ""}', style: const TextStyle(fontWeight: FontWeight.bold)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _analyzing ? null : _finish),
          actions: [IconButton(icon: const Icon(Icons.add_photo_alternate_rounded), tooltip: 'Add another screenshot', onPressed: (_analyzing || _addingImage) ? null : _addFromGallery)],
        ),
        body: Column(children: [
          Container(
            width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.blue.withOpacity(0.1),
            child: Text(
              _images.length == 1
                  ? '💡 Crop to show only the suspicious message, then tap Analyze.'
                  : '💡 ${_images.length} screenshots loaded. Crop each one, then tap Analyze.',
              style: const TextStyle(fontSize: 12, color: Colors.white70), textAlign: TextAlign.center,
            ),
          ),
          Expanded(child: _images.isEmpty
              ? const Center(child: Text('No images. Go back and try again.', style: TextStyle(color: Colors.grey)))
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
                      const SizedBox(width: 4),
                      if (i == _images.length - 1)
                        TextButton.icon(onPressed: (_analyzing || _addingImage) ? null : _addFromGallery, icon: const Icon(Icons.add_rounded, size: 18, color: Colors.green), label: const Text('Add More', style: TextStyle(color: Colors.green))),
                    ])),
              ]),
            ),
          )),
          if (_status.isNotEmpty)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Text(_status, style: const TextStyle(color: Colors.blue, fontSize: 13), textAlign: TextAlign.center)),
          SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: ElevatedButton.icon(
              onPressed: (_analyzing || _images.isEmpty) ? null : _analyze,
              icon: _analyzing ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.search_rounded, size: 22),
              label: Text(_analyzing ? (_status.isNotEmpty ? _status : 'Analyzing…') : 'Analyze for Scam', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 56), backgroundColor: Colors.blue, foregroundColor: Colors.white, disabledBackgroundColor: Colors.blue.withOpacity(0.45), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
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
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<ScanResult> _history = [];
  bool _loading = true;

  @override
  void initState() { super.initState(); _load(); }

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
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded), tooltip: 'Clear All',
              onPressed: () async {
                final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
                  title: const Text('Clear History?'),
                  content: const Text('All scan records will be permanently deleted.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, true),  child: const Text('Delete All', style: TextStyle(color: Colors.red))),
                  ],
                ));
                if (ok == true) _clear();
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
          ? const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.history_rounded, size: 64, color: Colors.grey), SizedBox(height: 16),
        Text('No scans yet',                    style: TextStyle(color: Colors.grey, fontSize: 16)),
        SizedBox(height: 6),
        Text('Scan a message to see results here.', style: TextStyle(color: Colors.grey, fontSize: 13)),
      ]))
          : Column(children: [
        if (highCount > 0)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.red.withOpacity(0.35))),
            child: Row(children: [
              const Icon(Icons.warning_rounded, color: Colors.red, size: 18), const SizedBox(width: 8),
              Text('$highCount high-risk message${highCount > 1 ? "s" : ""} in history', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13)),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            _SC(label: 'Total',      value: _history.length.toString(), color: Colors.white70),
            _SC(label: 'High Risk',  value: highCount.toString(),       color: _C.highRisk),
            _SC(label: 'Suspicious', value: suspCount.toString(),       color: _C.suspicious),
            _SC(label: 'Safe',       value: safeCount.toString(),       color: _C.safe),
          ]),
        ),
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
      Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
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
    final title = result.riskLevel == RiskLevel.highRisk ? '🚨 Scam' : result.riskLevel == RiskLevel.suspicious ? '⚠️ Suspicious' : '✅ Safe';
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
          Text(result.originalText.length > 70 ? '${result.originalText.substring(0, 70)}…' : result.originalText, style: const TextStyle(fontSize: 12, color: Colors.grey), maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 3),
          Text(_fmt(result.timestamp), style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
        ]),
        trailing: Text('${result.scamProbability.toInt()}%', style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18)),
        onTap: () => showDialog(context: context, builder: (_) => ScamAlertDialog(result: result)),
      ),
    );
  }
}