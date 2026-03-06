package com.example.scamshield

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * SttForegroundService — runs Android SpeechRecognizer in a foreground service.
 *
 * Why a foreground service?
 *   When a phone call is active, our Flutter Activity goes to background and
 *   loses audio focus. The speech_to_text Flutter package can't survive this
 *   because it ties the SpeechRecognizer lifecycle to the Activity.
 *   A foreground service keeps running regardless of Activity state, holds
 *   its own audio focus, and survives screen-off + phone-call-in-progress.
 *
 * Communication back to Flutter:
 *   Results are sent via MainActivity.callChannel (a static MethodChannel ref).
 *   If MainActivity is not running, results are queued and sent on next attach.
 *
 * Continuous loop:
 *   SpeechRecognizer fires onResults / onError → we immediately restart listening.
 *   error_speech_timeout is treated as normal (silence in call) and restarts.
 *   error_recognizer_busy gets a 1-second delay before restart.
 */
class SttForegroundService : Service() {

    companion object {
        private const val TAG          = "SCAMSHIELD_STT"
        private const val NOTIF_ID     = 42
        private const val CHANNEL_ID   = "scamshield_stt"
        const  val ACTION_START        = "START_STT"
        const  val ACTION_STOP         = "STOP_STT"
        const  val EXTRA_NUMBER        = "caller_number"

        // Non-fatal errors — restart after short delay
        private val RESTARTABLE_ERRORS = setOf(
            SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
            SpeechRecognizer.ERROR_NO_MATCH,
            SpeechRecognizer.ERROR_AUDIO,
            SpeechRecognizer.ERROR_NETWORK,        // transient network blip
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY
        )
    }

    private var recognizer: SpeechRecognizer? = null
    private var isListening  = false
    private var callerNumber = ""
    private val transcript   = StringBuilder()
    private val handler      = android.os.Handler(android.os.Looper.getMainLooper())
    private var restartDelay = 400L   // ms

    // ── Service lifecycle ──────────────────────────────────────────────────

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIF_ID, buildNotification())
        Log.d(TAG, "Service created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                callerNumber = intent.getStringExtra(EXTRA_NUMBER) ?: ""
                transcript.clear()
                Log.d(TAG, "Starting STT for $callerNumber")
                initRecognizerAndListen()
            }
            ACTION_STOP -> {
                Log.d(TAG, "Stopping STT")
                stopListening()
                sendFinalTranscript()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopListening()
        super.onDestroy()
        Log.d(TAG, "Service destroyed")
    }

    // ── SpeechRecognizer setup ─────────────────────────────────────────────

    private fun initRecognizerAndListen() {
        handler.post {
            if (recognizer == null) {
                recognizer = SpeechRecognizer.createSpeechRecognizer(this)
                recognizer!!.setRecognitionListener(listener)
            }
            startListening()
        }
    }

    private fun startListening() {
        if (!isListening) {
            isListening = true
            restartDelay = 400L
            Log.d(TAG, "🎤 listen() called")

            val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                // Telugu primary, falls back to en-IN for mixed speech
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "te-IN")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, "te-IN")
                putExtra(RecognizerIntent.EXTRA_ONLY_RETURN_LANGUAGE_PREFERENCE, false)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                // Max silence before the engine auto-stops: 10 seconds
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 10_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 10_000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_MINIMUM_LENGTH_MILLIS, 2_000L)
            }
            recognizer?.startListening(intent)
        }
    }

    private fun stopListening() {
        handler.removeCallbacksAndMessages(null)
        isListening = false
        try {
            recognizer?.stopListening()
            recognizer?.destroy()
        } catch (_: Exception) {}
        recognizer = null
    }

    private fun scheduleRestart(delayMs: Long = restartDelay) {
        isListening = false
        handler.postDelayed({ startListening() }, delayMs)
    }

    // ── RecognitionListener ────────────────────────────────────────────────

    private val listener = object : RecognitionListener {

        override fun onReadyForSpeech(params: Bundle?) {
            Log.d(TAG, "onReadyForSpeech")
        }

        override fun onBeginningOfSpeech() {
            Log.d(TAG, "onBeginningOfSpeech")
        }

        override fun onRmsChanged(rmsdB: Float) { /* volume meter — ignore */ }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onEndOfSpeech() {
            Log.d(TAG, "onEndOfSpeech")
            isListening = false
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val partial = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull() ?: return
            if (partial.isBlank()) return
            Log.d(TAG, "partial: $partial")
            // Send partial to Flutter for live banner update
            sendToFlutter("onPartialResult", partial)
        }

        override fun onResults(results: Bundle?) {
            isListening = false
            val text = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull() ?: ""

            if (text.isNotBlank()) {
                Log.d(TAG, "✅ result: $text")
                transcript.append(" ").append(text)
                sendToFlutter("onSttResult", text)
            }
            // Immediately restart — continuous loop
            scheduleRestart(400)
        }

        override fun onError(error: Int) {
            isListening = false
            val name = errorName(error)
            Log.d(TAG, "onError: $name ($error)")

            if (error in RESTARTABLE_ERRORS) {
                // Silence timeout / no match / transient — normal during pauses
                val delay = if (error == SpeechRecognizer.ERROR_RECOGNIZER_BUSY) 1500L else 600L
                scheduleRestart(delay)
            } else {
                // Fatal: no permission, server error — stop service
                Log.e(TAG, "Fatal STT error: $name — stopping")
                sendToFlutter("onSttError", name)
                stopSelf()
            }
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    // ── Flutter communication ──────────────────────────────────────────────

    private fun sendToFlutter(method: String, payload: String) {
        handler.post {
            MainActivity.callChannel?.invokeMethod(method, mapOf(
                "text"   to payload,
                "number" to callerNumber
            ))
        }
    }

    private fun sendFinalTranscript() {
        val full = transcript.toString().trim()
        if (full.isNotEmpty()) {
            sendToFlutter("onFinalTranscript", full)
        }
    }

    // ── Notification (required for foreground service) ─────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "ScamShield Call Monitor",
                NotificationManager.IMPORTANCE_LOW   // silent — no sound/vibrate
            ).apply {
                description = "Monitoring call for scam detection"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("ScamShield")
            .setContentText("Monitoring call for scam patterns…")
            .setOngoing(true)
            .build()
    }

    private fun errorName(code: Int) = when (code) {
        SpeechRecognizer.ERROR_AUDIO              -> "error_audio"
        SpeechRecognizer.ERROR_CLIENT             -> "error_client"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "error_no_permission"
        SpeechRecognizer.ERROR_NETWORK            -> "error_network"
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT    -> "error_network_timeout"
        SpeechRecognizer.ERROR_NO_MATCH           -> "error_no_match"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY    -> "error_recognizer_busy"
        SpeechRecognizer.ERROR_SERVER             -> "error_server"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT     -> "error_speech_timeout"
        else                                      -> "error_unknown_$code"
    }
}