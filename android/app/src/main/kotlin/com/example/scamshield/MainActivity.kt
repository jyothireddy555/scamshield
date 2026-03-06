package com.example.scamshield

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val OVERLAY_CHANNEL       = "overlay"
        const val CAPTURE_CHANNEL       = "screen_capture"
        const val CALL_CHANNEL          = "call_state"
        const val NOTIF_READER_CHANNEL  = "notification_reader"
        const val NOTIF_SETTINGS_CHANNEL= "notification_settings"
        const val REQUEST_MEDIA_PROJECTION = 1001

        var captureChannel: MethodChannel? = null
        var callChannel:    MethodChannel? = null

        // Exposed so NotificationListenerServiceImpl can push messages to Flutter
        var notificationChannel: MethodChannel? = null

        // Stored by CallScreeningServiceImpl / CallReceiver before Activity resumes
        var pendingCallNumber: String = ""
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // ── Overlay Channel ──────────────────────────────────────────────────
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
                        stopService(Intent(this, OverlayService::class.java))
                        result.success(true)
                    }

                    "hasOverlayPermission" -> result.success(Settings.canDrawOverlays(this))

                    "requestOverlayPermission" -> {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                        result.success(true)
                    }

                    // Compact call-warning banner (existing)
                    "showScamAlert" -> {

                        val source       = call.argument<String>("source") ?: "Message"
                        val sender       = call.argument<String>("sender") ?: "Unknown"
                        val message      = call.argument<String>("message") ?: ""

                        val probability  = call.argument<Int>("probability") ?: 0
                        val riskLevel    = call.argument<String>("riskLevel") ?: "Suspicious"
                        val fraudType    = call.argument<String>("fraudType") ?: ""
                        val fraudEmoji   = call.argument<String>("fraudEmoji") ?: "⚠️"
                        val explanation  = call.argument<String>("explanation") ?: ""
                        val whatToDo     = call.argument<String>("whatToDo") ?: ""
                        val keywords     = call.argument<String>("keywords") ?: ""
                        val helpline     = call.argument<String>("helpline") ?: "1930"
                        val showHelpline = call.argument<Boolean>("showHelpline") ?: false

                        ensureOverlayServiceRunning()

                        OverlayService.showScamAlert(
                            this,
                            source,
                            sender,
                            message,
                            probability,
                            riskLevel,
                            fraudType,
                            fraudEmoji,
                            explanation,
                            whatToDo,
                            keywords,
                            helpline,
                            showHelpline
                        )

                        result.success(true)
                    }

                    else -> result.notImplemented()
                }
            }

        // ── Screen Capture Channel ───────────────────────────────────────────
        captureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAPTURE_CHANNEL)
        captureChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startCapture" -> { triggerMediaProjection(); result.success(true) }
                else           -> result.notImplemented()
            }
        }

        // ── Call State Channel ───────────────────────────────────────────────
        callChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL)
        callChannel!!.setMethodCallHandler { _, result -> result.notImplemented() }

        // If CallReceiver stored a number before we started, send it now
        if (pendingCallNumber.isNotEmpty()) {
            handler.postDelayed({
                callChannel?.invokeMethod("onCallState", mapOf(
                    "state"  to "RINGING",
                    "number" to pendingCallNumber
                ))
                pendingCallNumber = ""
            }, 500)
        }

        // ── Notification Reader Channel ──────────────────────────────────────
        // Flutter listens here for onNotificationMessage events pushed by
        // NotificationListenerServiceImpl whenever WhatsApp / SMS / Email
        // posts a new notification.
        notificationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, NOTIF_READER_CHANNEL
        )
        notificationChannel!!.setMethodCallHandler { _, result -> result.notImplemented() }

        // ── Notification Settings Channel ────────────────────────────────────
        // Flutter calls openNotificationAccess to deep-link the user into
        // Settings › Notification Access so they can grant the permission.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_SETTINGS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openNotificationAccess" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).apply {
                                    flags = Intent.FLAG_ACTIVITY_NEW_TASK
                                }
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Overlay service helpers ──────────────────────────────────────────────

    /** Starts OverlayService as a foreground service if not already running. */
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

    /**
     * showCallAlert / showScamAlert may arrive while OverlayService is not
     * running (e.g. user disabled the floating bubble). We still need the
     * service alive to draw the WindowManager overlay, so start it here.
     * The service won't show the floating bubble unless startOverlay was called.
     */
    private fun ensureOverlayServiceRunning() {
        if (!OverlayService.isRunning) startOverlayService()
    }

    // ── Handle intents from CallReceiver / ScreenCaptureService ─────────────

    private fun handleCallIntent(intent: Intent?) {
        if (intent == null) return

        // Screenshot path forwarded from ScreenCaptureService
        val capturedPath = intent.getStringExtra("capturedPath")
        if (capturedPath != null) {
            handler.postDelayed({
                captureChannel?.invokeMethod("onScreenCaptured", capturedPath)
            }, 300)
            intent.removeExtra("capturedPath")
        }

        // Floating bubble tapped → trigger screen capture
        if (intent.getBooleanExtra("triggerScan", false)) {
            triggerMediaProjection()
            intent.removeExtra("triggerScan")
        }

        // Call state from CallReceiver broadcast
        val callState  = intent.getStringExtra("call_state")  ?: return
        val callNumber = intent.getStringExtra("call_number") ?: ""

        Log.d("SCAMSHIELD", "Call intent: state=$callState  number=$callNumber")

        val stateToken = when (callState) {
            TelephonyManager.EXTRA_STATE_RINGING -> "RINGING"
            TelephonyManager.EXTRA_STATE_OFFHOOK -> "OFFHOOK"
            TelephonyManager.EXTRA_STATE_IDLE    -> "IDLE"
            else -> return
        }

        handler.postDelayed({
            callChannel?.invokeMethod("onCallState", mapOf(
                "state"  to stateToken,
                "number" to callNumber
            ))
        }, 300)

        intent.removeExtra("call_state")
        intent.removeExtra("call_number")
    }

    override fun onResume() {
        super.onResume()
        handleCallIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleCallIntent(intent)
    }

    // ── MediaProjection ──────────────────────────────────────────────────────

    private fun triggerMediaProjection() {
        val pm = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        startActivityForResult(pm.createScreenCaptureIntent(), REQUEST_MEDIA_PROJECTION)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MEDIA_PROJECTION && resultCode == Activity.RESULT_OK && data != null) {
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
}