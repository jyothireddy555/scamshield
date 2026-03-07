package com.example.scamshield

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.media.MediaRecorder
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.telephony.TelephonyManager
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {

    companion object {
        const val OVERLAY_CHANNEL         = "overlay"
        const val CAPTURE_CHANNEL         = "screen_capture"
        const val CALL_CHANNEL            = "call_state"
        const val NOTIF_READER_CHANNEL    = "notification_reader"
        const val NOTIF_SETTINGS_CHANNEL  = "notification_settings"
        const val SHARE_CHANNEL           = "share_intent"
        const val VOICE_ADVISOR_CHANNEL   = "voice_advisor_record"
        const val REQUEST_MEDIA_PROJECTION = 1001

        // FIX: Volatile for thread-safe cross-component access
        @Volatile var captureChannel: MethodChannel?      = null
        @Volatile var callChannel: MethodChannel?         = null
        @Volatile var notificationChannel: MethodChannel? = null

        // FIX: Store pending number safely; cleared after use
        @Volatile var pendingCallNumber: String = ""
    }

    private val handler = Handler(Looper.getMainLooper())
    private var shareChannel: MethodChannel? = null

    // ── Voice Advisor: MediaRecorder + TTS ──
    private var mediaRecorder: MediaRecorder? = null
    private var recordingFile: File? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    // FIX: Track if we've already handled the launch intent to avoid re-processing on resume
    private var launchIntentHandled = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        /* ───────── Overlay Channel ───────── */
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startOverlay" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.error("PERMISSION", "Overlay permission not granted", null)
                            return@setMethodCallHandler
                        }
                        startOverlayService()
                        result.success(true)
                    }
                    "stopOverlay" -> {
                        Intent(this, OverlayService::class.java).apply {
                            action = OverlayService.ACTION_STOP_OVERLAY
                        }.also { startService(it) }
                        result.success(true)
                    }
                    "hasOverlayPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestOverlayPermission" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                        result.success(true)
                    }
                    "showCallAlert" -> {
                        val number  = call.argument<String>("number")  ?: ""
                        val level   = call.argument<String>("level")   ?: "unknown"
                        val message = call.argument<String>("message") ?: ""
                        ensureOverlayServiceRunning()
                        OverlayService.showCallAlert(this, number, level, message)
                        result.success(true)
                    }
                    "showScamAlert" -> {
                        val source       = call.argument<String>("source")      ?: "Message"
                        val sender       = call.argument<String>("sender")      ?: "Unknown"
                        val message      = call.argument<String>("message")     ?: ""
                        val probability  = call.argument<Int>("probability")    ?: 0
                        val riskLevel    = call.argument<String>("riskLevel")   ?: "Suspicious"
                        val fraudType    = call.argument<String>("fraudType")   ?: ""
                        val fraudEmoji   = call.argument<String>("fraudEmoji")  ?: "⚠️"
                        val explanation  = call.argument<String>("explanation") ?: ""
                        val whatToDo     = call.argument<String>("whatToDo")    ?: ""
                        val keywords     = call.argument<String>("keywords")    ?: ""
                        val helpline     = call.argument<String>("helpline")    ?: "1930"
                        val showHelpline = call.argument<Boolean>("showHelpline") ?: false

                        ensureOverlayServiceRunning()
                        OverlayService.showScamAlert(
                            this, source, sender, message,
                            probability, riskLevel, fraudType, fraudEmoji,
                            explanation, whatToDo, keywords, helpline, showHelpline
                        )
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        /* ───────── Screen Capture Channel ───────── */
        captureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAPTURE_CHANNEL)
        captureChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCapture" -> {
                    triggerMediaProjection()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        /* ───────── Call State Channel ───────── */
        callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL)
        callChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        // FIX: Use local snapshot to avoid TOCTOU race on pendingCallNumber
        val pendingNumber = pendingCallNumber
        if (pendingNumber.isNotEmpty()) {
            pendingCallNumber = ""
            handler.postDelayed({
                callChannel?.invokeMethod(
                    "onCallState",
                    mapOf("state" to "RINGING", "number" to pendingNumber)
                )
            }, 500)
        }

        /* ───────── Notification Channel ───────── */
        notificationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_READER_CHANNEL)
        notificationChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        /* ───────── Notification Settings ───────── */
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openNotificationAccess" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            })
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        /* ───────── Voice Advisor Channel (recording + TTS) ───────── */
        initTts()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VOICE_ADVISOR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startRecording" -> {
                        try {
                            startVoiceRecording()
                            result.success(true)
                        } catch (e: Exception) {
                            Log.e("SCAMSHIELD_VOICE", "startRecording failed: ${e.message}")
                            result.error("RECORD_ERROR", e.message, null)
                        }
                    }
                    "stopRecording" -> {
                        try {
                            val path = stopVoiceRecording()
                            result.success(path)
                        } catch (e: Exception) {
                            Log.e("SCAMSHIELD_VOICE", "stopRecording failed: ${e.message}")
                            result.error("STOP_ERROR", e.message, null)
                        }
                    }
                    "speak" -> {
                        val text = call.argument<String>("text") ?: ""
                        val lang = call.argument<String>("language") ?: "te-IN"
                        speakText(text, lang, result)
                    }
                    "stopSpeaking" -> {
                        tts?.stop()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }

        /* ───────── Share Intent Channel ───────── */
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        // FIX: Only handle launch intent once — prevents double-dispatch on engine reuse
        if (!launchIntentHandled) {
            launchIntentHandled = true
            // Delay so Flutter's Dart isolate is ready to receive method calls
            handler.postDelayed({ handleShareIntent(intent) }, 800)
        }
    }

    /* ───────── Overlay Service Helpers ───────── */

    private fun startOverlayService() {
        val intent = Intent(this, OverlayService::class.java).apply {
            action = OverlayService.ACTION_START_OVERLAY
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun ensureOverlayServiceRunning() {
        if (!OverlayService.isRunning) {
            startOverlayService()
        }
    }

    /* ───────── Share Intent Handling ───────── */

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return

        when (intent.action) {
            Intent.ACTION_SEND -> {
                if (intent.type == "text/plain") {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (text.isNullOrEmpty()) return
                    handler.postDelayed({
                        shareChannel?.invokeMethod(
                            "onSharedFile",
                            mapOf("path" to "", "mimeType" to "text/plain", "fileName" to "", "text" to text)
                        )
                    }, 600)
                    return
                }

                val uri: Uri? = getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                uri?.let { dispatchUri(it, intent.type) }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: ArrayList<Uri>? =
                    getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java)
                uris?.forEach { dispatchUri(it, intent.type) }
            }
        }
    }

    // FIX: Generic helper to avoid duplicating the version-check for getParcelableExtra
    @Suppress("DEPRECATION")
    private fun <T : android.os.Parcelable> getParcelableExtra(
        intent: Intent, key: String, clazz: Class<T>
    ): T? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(key, clazz)
        } else {
            intent.getParcelableExtra(key)
        }
    }

    // FIX: Generic helper for getParcelableArrayListExtra
    @Suppress("DEPRECATION")
    private fun <T : android.os.Parcelable> getParcelableArrayListExtra(
        intent: Intent, key: String, clazz: Class<T>
    ): ArrayList<T>? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(key, clazz)
        } else {
            intent.getParcelableArrayListExtra(key)
        }
    }

    private fun dispatchUri(uri: Uri, declaredMime: String?) {
        try {
            val cr   = contentResolver
            val mime = cr.getType(uri) ?: declaredMime ?: "application/octet-stream"
            val ext  = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                ?: uri.path?.substringAfterLast('.', "") ?: ""
            val fileName = resolveFileName(cr, uri, ext)
            val cached   = copyUriToCache(cr, uri, fileName)

            handler.postDelayed({
                shareChannel?.invokeMethod(
                    "onSharedFile",
                    mapOf("path" to cached, "mimeType" to mime, "fileName" to fileName, "text" to "")
                )
            }, 600)
        } catch (e: Exception) {
            Log.e("SCAMSHIELD_SHARE", "dispatchUri error: ${e.message}")
        }
    }

    private fun copyUriToCache(cr: ContentResolver, uri: Uri, fileName: String): String {
        val dest = java.io.File(cacheDir, "share_${System.currentTimeMillis()}_$fileName")
        cr.openInputStream(uri)?.use { input ->
            dest.outputStream().use { output ->
                input.copyTo(output)
            }
        }
        return dest.absolutePath
    }

    private fun resolveFileName(cr: ContentResolver, uri: Uri, fallbackExt: String): String {
        var name: String? = null
        try {
            cr.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(c.getColumnIndexOrThrow(android.provider.OpenableColumns.DISPLAY_NAME))
                    }
                }
        } catch (_: Exception) {}
        return name
            ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "file.${fallbackExt.ifEmpty { "bin" }}"
    }

    /* ───────── Call Intent Handling ───────── */

    private fun handleCallIntent(intent: Intent?) {
        if (intent == null) return

        // FIX: Handle captured screenshot path from ScreenCaptureService
        val capturedPath = intent.getStringExtra("capturedPath")
        if (!capturedPath.isNullOrEmpty()) {
            handler.postDelayed({
                captureChannel?.invokeMethod("onScreenCaptured", capturedPath)
            }, 300)
            intent.removeExtra("capturedPath")
        }

        val callState  = intent.getStringExtra("call_state")  ?: return
        val callNumber = intent.getStringExtra("call_number") ?: ""

        val stateToken = when (callState) {
            TelephonyManager.EXTRA_STATE_RINGING  -> "RINGING"
            TelephonyManager.EXTRA_STATE_OFFHOOK  -> "OFFHOOK"
            TelephonyManager.EXTRA_STATE_IDLE     -> "IDLE"
            else -> return
        }

        handler.postDelayed({
            callChannel?.invokeMethod(
                "onCallState",
                mapOf("state" to stateToken, "number" to callNumber)
            )
        }, 300)

        intent.removeExtra("call_state")
        intent.removeExtra("call_number")
    }

    // FIX: Trigger overlay scan — call triggerMediaProjection() directly.
    // The old code incorrectly called captureChannel?.invokeMethod("startCapture")
    // which invokes the Dart side — but Dart has no handler for that method name.
    // The correct flow is: overlay tap → triggerScan intent → triggerMediaProjection()
    // → onActivityResult → ScreenCaptureService → captureChannel.invokeMethod("onScreenCaptured") → Dart.
    private fun checkOverlayScanIntent(intent: Intent?) {
        if (intent?.getBooleanExtra("triggerScan", false) == true) {
            intent.removeExtra("triggerScan")
            handler.postDelayed({
                triggerMediaProjection()
            }, 200)
        }
    }

    override fun onResume() {
        super.onResume()
        handleCallIntent(intent)
        checkOverlayScanIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallIntent(intent)
        handleShareIntent(intent)
        checkOverlayScanIntent(intent)
    }

    /* ───────── Media Projection ───────── */

    private fun triggerMediaProjection() {
        val pm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(pm.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_MEDIA_PROJECTION
            && resultCode == Activity.RESULT_OK
            && data != null
        ) {
            // FIX: Move task to back first so screenshot doesn't capture the permission dialog
            moveTaskToBack(true)

            handler.postDelayed({
                val svc = Intent(this, ScreenCaptureService::class.java).apply {
                    putExtra("resultCode", resultCode)
                    putExtra("data", data)
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(svc)
                } else {
                    startService(svc)
                }
            }, 1000)
        }
    }

    /* ═══════════════════════════════════════════════════════════
       VOICE ADVISOR — Recording + TTS helpers
    ═══════════════════════════════════════════════════════════ */

    private fun initTts() {
        tts = TextToSpeech(this) { status ->
            ttsReady = (status == TextToSpeech.SUCCESS)
            if (ttsReady) {
                // Set default pitch/rate for a calm, clear voice
                tts?.setPitch(0.95f)
                tts?.setSpeechRate(0.88f)
            }
            Log.d("SCAMSHIELD_VOICE", "TTS init: status=$status ready=$ttsReady")
        }
    }

    @Suppress("DEPRECATION")
    private fun startVoiceRecording() {
        stopVoiceRecording() // stop any in-progress recording
        val file = File(cacheDir, "scamshield_voice_${System.currentTimeMillis()}.m4a")
        recordingFile = file

        mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(this)
        } else {
            MediaRecorder()
        }

        mediaRecorder!!.apply {
            setAudioSource(MediaRecorder.AudioSource.MIC)
            setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            setAudioSamplingRate(16000)   // 16 kHz — optimal for Whisper
            setAudioEncodingBitRate(64000)
            setOutputFile(file.absolutePath)
            prepare()
            start()
        }
        Log.d("SCAMSHIELD_VOICE", "Recording started: ${file.absolutePath}")
    }

    private fun stopVoiceRecording(): String {
        return try {
            mediaRecorder?.stop()
            mediaRecorder?.release()
            mediaRecorder = null
            val path = recordingFile?.absolutePath ?: ""
            Log.d("SCAMSHIELD_VOICE", "Recording stopped: $path")
            path
        } catch (e: Exception) {
            Log.e("SCAMSHIELD_VOICE", "stopRecording error: ${e.message}")
            mediaRecorder?.release()
            mediaRecorder = null
            ""
        }
    }

    private fun speakText(text: String, langTag: String, result: MethodChannel.Result) {
        if (!ttsReady || tts == null) {
            // TTS not ready — still return success so app doesn't break; text shown on screen
            Log.w("SCAMSHIELD_VOICE", "TTS not ready yet")
            result.success(false)
            return
        }

        val locale = when {
            langTag.startsWith("te") -> Locale("te", "IN")
            langTag.startsWith("hi") -> Locale("hi", "IN")
            else                     -> Locale("en", "IN")
        }

        // Check if language is supported; fall back to English if not
        val available = tts!!.isLanguageAvailable(locale)
        val usedLocale = if (available >= TextToSpeech.LANG_AVAILABLE) locale else Locale.ENGLISH
        tts!!.language = usedLocale

        tts!!.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) {
                handler.post { result.success(true) }
            }
            override fun onError(utteranceId: String?) {
                handler.post { result.success(false) }
            }
        })

        tts!!.speak(text, TextToSpeech.QUEUE_FLUSH, null, "scamshield_advice")
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        mediaRecorder?.release()
        super.onDestroy()
    }
}