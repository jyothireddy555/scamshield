// ════════════════════════════════════════════════════════════════
// lib/localization.dart
// ScamShield — Simple, clean localization
//
// Usage:
//   Text(L.t("scan_now"))
//   L.t("tip_otp")
//
// Change language:
//   L.current = "te";
//   setState(() {});          // rebuilds the widget
//
// Save / load:
//   prefs.setString("lang", L.current);
//   L.current = prefs.getString("lang") ?? "te";
// ════════════════════════════════════════════════════════════════

class L {
  // Currently active language code: "te" | "hi" | "en"
  static String current = 'te';

  /// Look up a translation key. Falls back to English if missing.
  static String t(String key) =>
      data[current]?[key] ?? data['en']![key] ?? key;

  // ──────────────────────────────────────────────────────────────
  // Translation data
  // ──────────────────────────────────────────────────────────────
  static const Map<String, Map<String, String>> data = {

    // ── Telugu ──────────────────────────────────────────────────
    'te': {
      // Home screen
      'app_title':       '🛡️ స్కామ్‌షీల్డ్',
      'app_tagline':     'AI స్కామ్ డిటెక్షన్',
      'scan_now':        '📷 ఇప్పుడే స్కాన్ చేయండి',
      'scan_gallery':    '🖼️ గ్యాలరీ నుండి స్కాన్',
      'status_idle':     'Scan button నొక్కండి',
      'status_ocr':      'Text extract అవుతోంది…',
      'status_ai':       'AI analyze అవుతోంది…',
      'detects':         'ఇవి గుర్తిస్తుంది:',

      // Toggles
      'float_on':        '🔵 Floating Button Enable చేయండి',
      'float_off':       'Floating Button Disable చేయండి',
      'float_on_hint':   'Floating scan bubble active',
      'float_off_hint':  'Tap చేసి floating button enable చేయండి',
      'notif_on':        '✅ Message Protection ON',
      'notif_off':       '🔔 Message Protection Enable చేయండి',
      'notif_on_hint':   'WhatsApp, SMS auto-scan జరుగుతోంది',
      'notif_off_hint':  'Tap చేసి messages auto-scan enable చేయండి',

      // Language selector
      'lang_btn':        '🌐 భాష మార్చండి',
      'lang_current':    'ప్రస్తుత భాష: తెలుగు',

      // Scan result labels
      'scam_found':      '🚨 SCAM!\nమోసం గుర్తించబడింది!',
      'susp_found':      '⚠️ అనుమానాస్పద సందేశం',
      'safe_found':      '✅ సురక్షితం',
      'risk_label':      'Scam Risk / మోసం అవకాశం:',
      'safe_label':      'సురక్షితం',
      'high_risk_label': 'High Risk 🚨',
      'keywords_title':  '🔎 అనుమానాస్పద పదాలు',
      'scanned_msg':     '📩 చదివిన సందేశం',
      'prevention':      '🛡️ జాగ్రత్తలు',
      'what_now':        'ఇప్పుడు ఏం చేయాలి? / Abhi Kya Karein?',
      'dismiss':         'సరే',
      'call_1930':       '📞 1930 కి Call చేయండి',
      'block_num':       '🚫 Number Block చేయండి',
      'report_wa':       '📲 WhatsApp లో Report చేయండి',

      // Fraud type labels
      'fraud_upi':       '💸 UPI మోసం',
      'fraud_job':       '💼 Job మోసం',
      'fraud_lottery':   '🎰 Lottery మోసం',
      'fraud_phishing':  '🎣 Link మోసం',
      'fraud_kyc':       '🆔 KYC మోసం',
      'fraud_other':     '⚠️ మోసం',
      'fraud_safe':      '✅ సురక్షితం',

      // Prevention tips
      'tip_otp':         '🔒 OTP ఎవరికీ చెప్పకండి — Bank కూడా అడగదు!',
      'tip_qr':          '📷 QR Scan చేస్తే మీ account నుండి పోతుంది!',
      'tip_job':         '💼 Job కోసం పైసలు అడిగితే స్కామ్!',
      'tip_lottery':     '🎰 Enter చేయని Lottery Win అంటే స్కామ్!',
      'tip_kyc':         '🆔 KYC link SMS లో వస్తే నమ్మకండి!',
      'tip_link':        '🔗 Unknown links click చేయకండి!',

      // What to do
      'wtd_high':        '1️⃣ Phone కట్ చేయండి!\n2️⃣ Number block చేయండి!\n3️⃣ 1930 కి call చేయండి!',
      'wtd_susp':        '1️⃣ Personal details చెప్పకండి\n2️⃣ OTP, PIN, Aadhaar చెప్పకండి\n3️⃣ Official number కి call చేయండి',
      'wtd_safe':        'సురక్షితంగా కనిపిస్తోంది.\nఐనా జాగ్రత్తగా ఉండండి.',

      // Call warning screen
      'spam_call':       '🚨 SPAM CALL!\nస్పామ్ కాల్!',
      'susp_call':       '⚠️ అనుమానాస్పద కాల్',
      'why_alert':       'ఎందుకు Warning?',
      'stay_safe':       'Safe రహండి',
      'dont_otp':        'OTP చెప్పకండి!',
      'dont_otp_hint':   'Bank కూడా అడగదు!',
      'dont_pin':        'Bank PIN చెప్పకండి!',
      'dont_pin_hint':   'ఎవరికీ చెప్పకండి!',
      'dont_aadhar':     'Aadhaar చెప్పకండి!',
      'dont_aadhar_hint':'Number, DOB చెప్పకండి!',
      'dont_link':       'Links Click చేయకండి!',
      'dont_link_hint':  'Unknown links తెరవకండి!',
      'dont_app':        'App Install చేయకండి!',
      'dont_app_hint':   'AnyDesk, TeamViewer వద్దు!',

      // Quick rules card
      'rules_title':     'గుర్తుంచుకో!',
      'rule_1':          'OTP ఎవరికీ చెప్పకండి!',
      'rule_1_sub':      'Bank Employee కూడా అడగదు!',
      'rule_2':          'Bank PIN share చేయకండి!',
      'rule_2_sub':      'Phone లో చెప్పకండే!',
      'rule_3':          'Unknown links click చేయకండి!',
      'rule_3_sub':      'Message లో వచ్చిన links వద్దు!',
      'rule_4':          'Lottery/Job కోసం పైసలు వద్దు!',
      'rule_4_sub':      'అలాంటివి అన్నీ మోసం!',
      'rule_5':          'Helpline: 1930 (ఉచితం)',
      'rule_5_sub':      '24x7 Cybercrime Helpline',

      // History screen
      'history_title':   'Scan History',
      'history_empty':   'ఇంకా scan లేదు',
      'history_hint':    'Message scan చేస్తే ఇక్కడ కనిపిస్తుంది.',
      'clear_history':   'History Delete చేయాలా?',

      // Crop / analyze screen
      'crop_hint_1':     '💡 Suspicious message area crop చేయండి, తర్వాత Analyze నొక్కండి.',
      'crop_hint_n':     '💡 Screenshots లోడ్ అయ్యాయి. Crop చేసి Analyze నొక్కండి.',
      'analyze_btn':     '🔍 Scam Check చేయండి',
      'no_text':         'Text కనపడలేదు. దగ్గరగా crop చేయండి.',

      // Helpline banner
      'helpline_tag':    '24×7 ఉచితం • cybercrime.gov.in',
      'helpline_call':   'Call / కాల్',

      // Misc
      'notif_settings':  'Settings లో Notification Access enable చేయండి.',
    },

    // ── Hindi ────────────────────────────────────────────────────
    'hi': {
      'app_title':       '🛡️ ScamShield',
      'app_tagline':     'AI स्कैम डिटेक्शन',
      'scan_now':        '📷 अभी स्कैन करें',
      'scan_gallery':    '🖼️ गैलरी से स्कैन करें',
      'status_idle':     'Scan button दबाइए',
      'status_ocr':      'Text निकाला जा रहा है…',
      'status_ai':       'AI analyze कर रहा है…',
      'detects':         'ये पहचानता है:',

      'float_on':        '🔵 Floating Button चालू करें',
      'float_off':       'Floating Button बंद करें',
      'float_on_hint':   'Floating scan bubble active है',
      'float_off_hint':  'Tap करके floating button चालू करें',
      'notif_on':        '✅ Message सुरक्षा चालू है',
      'notif_off':       '🔔 Message सुरक्षा चालू करें',
      'notif_on_hint':   'WhatsApp, SMS auto-scan हो रहा है',
      'notif_off_hint':  'Tap करके messages auto-scan चालू करें',

      'lang_btn':        '🌐 भाषा बदलें',
      'lang_current':    'वर्तमान भाषा: हिंदी',

      'scam_found':      '🚨 SCAM!\nठगी पकड़ी गई!',
      'susp_found':      '⚠️ संदिग्ध संदेश',
      'safe_found':      '✅ सुरक्षित है',
      'risk_label':      'Scam Risk / खतरा:',
      'safe_label':      'सुरक्षित',
      'high_risk_label': 'High Risk 🚨',
      'keywords_title':  '🔎 संदिग्ध शब्द',
      'scanned_msg':     '📩 स्कैन किया संदेश',
      'prevention':      '🛡️ सावधानियां',
      'what_now':        'अभी क्या करें?',
      'dismiss':         'ठीक है',
      'call_1930':       '📞 1930 पे Call करें',
      'block_num':       '🚫 Number Block करें',
      'report_wa':       '📲 WhatsApp पर Report करें',

      'fraud_upi':       '💸 UPI धोखा',
      'fraud_job':       '💼 Job धोखा',
      'fraud_lottery':   '🎰 Lottery धोखा',
      'fraud_phishing':  '🎣 Link धोखा',
      'fraud_kyc':       '🆔 KYC धोखा',
      'fraud_other':     '⚠️ धोखा',
      'fraud_safe':      '✅ सुरक्षित',

      'tip_otp':         '🔒 OTP किसी को मत बताओ — Bank भी नहीं मांगता!',
      'tip_qr':          '📷 QR scan करने से आपका पैसा चला जाता है!',
      'tip_job':         '💼 Job के लिए पैसे मांगना SCAM है!',
      'tip_lottery':     '🎰 बिना खेले lottery जीतना SCAM है!',
      'tip_kyc':         '🆔 SMS में KYC link आए तो मत खोलो!',
      'tip_link':        '🔗 अनजाने links पर CLICK MAT KARO!',

      'wtd_high':        '1️⃣ फोन काट दो!\n2️⃣ नंबर block करो!\n3️⃣ 1930 पे call करो!',
      'wtd_susp':        '1️⃣ Personal details मत बताओ\n2️⃣ OTP, PIN, Aadhaar मत बताओ\n3️⃣ Official number पे call करो',
      'wtd_safe':        'Safe लग रहा है।\nफिर भी सावधान रहें।',

      'spam_call':       '🚨 SPAM CALL!\nस्पैम कॉल!',
      'susp_call':       '⚠️ संदिग्ध कॉल',
      'why_alert':       'Warning क्यों?',
      'stay_safe':       'सावधान रहें',
      'dont_otp':        'OTP मत बताइए!',
      'dont_otp_hint':   'Bank भी नहीं मांगता!',
      'dont_pin':        'Bank PIN मत बताइए!',
      'dont_pin_hint':   'किसी को भी नहीं!',
      'dont_aadhar':     'Aadhaar मत बताइए!',
      'dont_aadhar_hint':'Number, DOB मत बताओ!',
      'dont_link':       'Links मत खोलिए!',
      'dont_link_hint':  'अनजान links मत दबाओ!',
      'dont_app':        'App Install मत करो!',
      'dont_app_hint':   'AnyDesk, TeamViewer मत दो!',

      'rules_title':     'याद रखो!',
      'rule_1':          'OTP किसी को मत बताओ!',
      'rule_1_sub':      'Bank Employee भी नहीं मांगता!',
      'rule_2':          'Bank PIN share मत करो!',
      'rule_2_sub':      'फोन पर कभी मत बताओ!',
      'rule_3':          'Unknown links मत खोलो!',
      'rule_3_sub':      'Message में आए links से दूर रहो!',
      'rule_4':          'Lottery/Job के लिए पैसे मत दो!',
      'rule_4_sub':      'ऐसे सब SCAM हैं!',
      'rule_5':          'Helpline: 1930 (मुफ्त)',
      'rule_5_sub':      '24x7 Cybercrime Helpline',

      'history_title':   'Scan History',
      'history_empty':   'अभी तक कोई scan नहीं',
      'history_hint':    'Message scan करने पर यहाँ दिखेगा।',
      'clear_history':   'History delete करें?',

      'crop_hint_1':     '💡 संदिग्ध message area crop करें, फिर Analyze दबाएं।',
      'crop_hint_n':     '💡 Screenshots लोड हो गए। Crop करके Analyze दबाएं।',
      'analyze_btn':     '🔍 Scam Check करें',
      'no_text':         'Text नहीं मिला। Message area पास से crop करें।',

      'helpline_tag':    '24×7 मुफ्त • cybercrime.gov.in',
      'helpline_call':   'Call करें',

      'notif_settings':  'Settings में Notification Access enable करें।',
    },

    // ── English ──────────────────────────────────────────────────
    'en': {
      'app_title':       '🛡️ ScamShield',
      'app_tagline':     'AI Scam Detection',
      'scan_now':        '📷 SCAN NOW',
      'scan_gallery':    '🖼️ Scan from Gallery',
      'status_idle':     'Tap the button to scan any message',
      'status_ocr':      'Extracting text…',
      'status_ai':       'Analyzing with AI…',
      'detects':         'Detects:',

      'float_on':        '🔵 Enable Floating Button',
      'float_off':       'Disable Floating Button',
      'float_on_hint':   'Floating scan bubble is active',
      'float_off_hint':  'Tap to enable the floating scan button',
      'notif_on':        '✅ Message Protection ON',
      'notif_off':       '🔔 Enable Message Protection',
      'notif_on_hint':   'Scanning WhatsApp & SMS automatically',
      'notif_off_hint':  'Tap to enable automatic message scanning',

      'lang_btn':        '🌐 Change Language',
      'lang_current':    'Current language: English',

      'scam_found':      '🚨 SCAM DETECTED!',
      'susp_found':      '⚠️ Suspicious Message',
      'safe_found':      '✅ Looks Safe',
      'risk_label':      'Scam Risk:',
      'safe_label':      'Safe',
      'high_risk_label': 'High Risk 🚨',
      'keywords_title':  '🔎 Suspicious Keywords',
      'scanned_msg':     '📩 Scanned Message',
      'prevention':      '🛡️ Prevention Tips',
      'what_now':        'What to do now?',
      'dismiss':         'Dismiss',
      'call_1930':       '📞 Call 1930 Now',
      'block_num':       '🚫 Block This Number',
      'report_wa':       '📲 Report on WhatsApp',

      'fraud_upi':       '💸 UPI Fraud',
      'fraud_job':       '💼 Job Scam',
      'fraud_lottery':   '🎰 Lottery Scam',
      'fraud_phishing':  '🎣 Phishing',
      'fraud_kyc':       '🆔 KYC Scam',
      'fraud_other':     '⚠️ Scam',
      'fraud_safe':      '✅ Safe',

      'tip_otp':         '🔒 Never share OTP — not even with bank employees!',
      'tip_qr':          '📷 QR scanning sends money FROM you, not to you!',
      'tip_job':         '💼 Real employers never charge registration fees!',
      'tip_lottery':     '🎰 You cannot win a lottery you never entered!',
      'tip_kyc':         '🆔 Banks never send KYC links via SMS!',
      'tip_link':        '🔗 Never click unknown links in messages!',

      'wtd_high':        '1️⃣ Hang up immediately!\n2️⃣ Block this number!\n3️⃣ Call 1930 right now!',
      'wtd_susp':        '1️⃣ Never share personal details\n2️⃣ Do NOT share OTP, PIN, Aadhaar\n3️⃣ Call your bank\'s official number',
      'wtd_safe':        'Looks safe. Stay vigilant though.',

      'spam_call':       '🚨 SPAM CALL DETECTED!',
      'susp_call':       '⚠️ SUSPICIOUS CALL',
      'why_alert':       'Why this alert?',
      'stay_safe':       'Stay Safe',
      'dont_otp':        'NEVER share OTP!',
      'dont_otp_hint':   'Not even to bank employees!',
      'dont_pin':        'NEVER share Bank PIN!',
      'dont_pin_hint':   'No one needs your PIN!',
      'dont_aadhar':     'NEVER share Aadhaar!',
      'dont_aadhar_hint':'Do not give number or DOB!',
      'dont_link':       'Do NOT click links!',
      'dont_link_hint':  'Never open unknown links!',
      'dont_app':        'Do NOT install any app!',
      'dont_app_hint':   'No AnyDesk or TeamViewer!',

      'rules_title':     'Remember!',
      'rule_1':          'NEVER share OTP with anyone!',
      'rule_1_sub':      'Bank employees never ask for it!',
      'rule_2':          'NEVER share Bank PIN!',
      'rule_2_sub':      'Never tell anyone over phone!',
      'rule_3':          'Do NOT click unknown links!',
      'rule_3_sub':      'Links in messages are often scams!',
      'rule_4':          'Never pay for Lottery or Jobs!',
      'rule_4_sub':      'These are always SCAMS!',
      'rule_5':          'Helpline: 1930 (Free)',
      'rule_5_sub':      '24x7 Cybercrime Helpline',

      'history_title':   'Scan History',
      'history_empty':   'No scans yet',
      'history_hint':    'Scan a message to see results here.',
      'clear_history':   'Clear History?',

      'crop_hint_1':     '💡 Crop to the suspicious message only, then tap Analyze.',
      'crop_hint_n':     '💡 Screenshots loaded. Crop each one, then tap Analyze.',
      'analyze_btn':     '🔍 Analyze for Scam',
      'no_text':         'No text found. Try cropping more tightly.',

      'helpline_tag':    '24×7 Free • cybercrime.gov.in',
      'helpline_call':   'Call',

      'notif_settings':  'Enable Notification Access in Settings.',
    },
  };
}