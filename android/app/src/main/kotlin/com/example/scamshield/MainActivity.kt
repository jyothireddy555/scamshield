package com.example.scamshield

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {


    companion object {
        const val OVERLAY_CHANNEL = "overlay"
        const val CAPTURE_CHANNEL = "screen_capture"
        const val CALL_CHANNEL = "call_state"
        const val NOTIF_READER_CHANNEL = "notification_reader"
        const val NOTIF_SETTINGS_CHANNEL = "notification_settings"
        const val SHARE_CHANNEL = "share_intent"
        const val REQUEST_MEDIA_PROJECTION = 1001

        var captureChannel: MethodChannel? = null
        var callChannel: MethodChannel? = null
        var notificationChannel: MethodChannel? = null
        var pendingCallNumber: String = ""
    }

    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private var shareChannel: MethodChannel? = null

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
                        stopService(Intent(this, OverlayService::class.java))
                        result.success(true)
                    }

                    "hasOverlayPermission" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }

                    "requestOverlayPermission" -> {
                        startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                        result.success(true)
                    }

                    "showCallAlert" -> {
                        val number = call.argument<String>("number") ?: ""
                        val level = call.argument<String>("level") ?: "unknown"
                        val message = call.argument<String>("message") ?: ""

                        ensureOverlayServiceRunning()

                        OverlayService.showCallAlert(
                            this,
                            number,
                            level,
                            message
                        )

                        result.success(true)
                    }

                    "showScamAlert" -> {

                        val source = call.argument<String>("source") ?: "Message"
                        val sender = call.argument<String>("sender") ?: "Unknown"
                        val message = call.argument<String>("message") ?: ""

                        val probability = call.argument<Int>("probability") ?: 0
                        val riskLevel = call.argument<String>("riskLevel") ?: "Suspicious"
                        val fraudType = call.argument<String>("fraudType") ?: ""
                        val fraudEmoji = call.argument<String>("fraudEmoji") ?: "⚠️"
                        val explanation = call.argument<String>("explanation") ?: ""
                        val whatToDo = call.argument<String>("whatToDo") ?: ""
                        val keywords = call.argument<String>("keywords") ?: ""
                        val helpline = call.argument<String>("helpline") ?: "1930"
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

        /* ───────── Screen Capture Channel ───────── */

        captureChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAPTURE_CHANNEL)

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

        callChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CALL_CHANNEL)

        callChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        if (pendingCallNumber.isNotEmpty()) {

            handler.postDelayed({

                callChannel?.invokeMethod(
                    "onCallState",
                    mapOf(
                        "state" to "RINGING",
                        "number" to pendingCallNumber
                    )
                )

                pendingCallNumber = ""

            }, 500)
        }

        /* ───────── Notification Channel ───────── */

        notificationChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, NOTIF_READER_CHANNEL)

        notificationChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        /* ───────── Notification Settings ───────── */

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NOTIF_SETTINGS_CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "openNotificationAccess" -> {

                    try {

                        startActivity(
                            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                                .apply {
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

        /* ───────── Share Intent Channel ───────── */

        shareChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)

        shareChannel!!.setMethodCallHandler { _, result ->
            result.notImplemented()
        }

        handleShareIntent(intent)
    }

    /* ───────── Overlay Service Helpers ───────── */

    private fun startOverlayService() {

        val intent = Intent(this, OverlayService::class.java)

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

                    val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return

                    handler.postDelayed({

                        shareChannel?.invokeMethod(
                            "onSharedFile",
                            mapOf(
                                "path" to "",
                                "mimeType" to "text/plain",
                                "fileName" to "",
                                "text" to text
                            )
                        )

                    }, 600)

                    return
                }

                val uri: Uri? =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                        intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    else
                        intent.getParcelableExtra(Intent.EXTRA_STREAM)

                uri?.let { dispatchUri(it, intent.type) }
            }

            Intent.ACTION_SEND_MULTIPLE -> {

                val uris: ArrayList<Uri>? =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    else
                        intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

                uris?.forEach { dispatchUri(it, intent.type) }
            }
        }
    }

    private fun dispatchUri(uri: Uri, declaredMime: String?) {

        try {

            val cr = contentResolver
            val mime = cr.getType(uri) ?: declaredMime ?: "application/octet-stream"

            val ext =
                MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
                    ?: uri.path?.substringAfterLast('.', "") ?: ""

            val fileName = resolveFileName(cr, uri, ext)
            val cached = copyUriToCache(cr, uri, fileName)

            handler.postDelayed({

                shareChannel?.invokeMethod(
                    "onSharedFile",
                    mapOf(
                        "path" to cached,
                        "mimeType" to mime,
                        "fileName" to fileName,
                        "text" to ""
                    )
                )

            }, 600)

        } catch (e: Exception) {

            Log.e("SCAMSHIELD_SHARE", "dispatchUri: ${e.message}")

        }
    }

    private fun copyUriToCache(
        cr: ContentResolver,
        uri: Uri,
        fileName: String
    ): String {

        val dest =
            java.io.File(cacheDir, "share_${System.currentTimeMillis()}_$fileName")

        cr.openInputStream(uri)?.use { input ->
            dest.outputStream().use { output ->
                input.copyTo(output)
            }
        }

        return dest.absolutePath
    }

    private fun resolveFileName(
        cr: ContentResolver,
        uri: Uri,
        fallbackExt: String
    ): String {

        var name: String? = null

        try {

            cr.query(
                uri,
                arrayOf(android.provider.OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { c ->

                if (c.moveToFirst())
                    name = c.getString(
                        c.getColumnIndexOrThrow(
                            android.provider.OpenableColumns.DISPLAY_NAME
                        )
                    )
            }

        } catch (_: Exception) {}

        return name ?: (
                uri.lastPathSegment?.substringAfterLast('/')
                    ?: "file.${fallbackExt.ifEmpty { "bin" }}"
                )
    }

    /* ───────── Call Intent Handling ───────── */

    private fun handleCallIntent(intent: Intent?) {

        if (intent == null) return

        val capturedPath = intent.getStringExtra("capturedPath")

        if (capturedPath != null) {

            handler.postDelayed({
                captureChannel?.invokeMethod("onScreenCaptured", capturedPath)
            }, 300)

            intent.removeExtra("capturedPath")
        }

        val callState = intent.getStringExtra("call_state") ?: return
        val callNumber = intent.getStringExtra("call_number") ?: ""

        val stateToken = when (callState) {
            TelephonyManager.EXTRA_STATE_RINGING -> "RINGING"
            TelephonyManager.EXTRA_STATE_OFFHOOK -> "OFFHOOK"
            TelephonyManager.EXTRA_STATE_IDLE -> "IDLE"
            else -> return
        }

        handler.postDelayed({

            callChannel?.invokeMethod(
                "onCallState",
                mapOf(
                    "state" to stateToken,
                    "number" to callNumber
                )
            )

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
        handleShareIntent(intent)
    }

    /* ───────── Media Projection ───────── */

    private fun triggerMediaProjection() {

        val pm =
            getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager

        startActivityForResult(
            pm.createScreenCaptureIntent(),
            REQUEST_MEDIA_PROJECTION
        )
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {

        super.onActivityResult(requestCode, resultCode, data)

        if (requestCode == REQUEST_MEDIA_PROJECTION &&
            resultCode == Activity.RESULT_OK &&
            data != null
        ) {

            moveTaskToBack(true)

            handler.postDelayed({

                val svc =
                    Intent(this, ScreenCaptureService::class.java).apply {

                        putExtra("resultCode", resultCode)
                        putExtra("data", data)

                    }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    startForegroundService(svc)
                else
                    startService(svc)

            }, 1000)
        }
    }


}
