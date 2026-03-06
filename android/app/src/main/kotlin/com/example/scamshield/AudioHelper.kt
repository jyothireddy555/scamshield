package com.example.scamshield

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * AudioHelper — manages audio focus + speakerphone for call monitoring.
 *
 * Flow:
 *   1. Call answered (OFFHOOK) → enableForCallMonitoring()
 *      - Request AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK so STT can use the mic
 *        while the telephony stack holds normal call audio focus.
 *      - Switch to MODE_IN_COMMUNICATION (NOT MODE_IN_CALL — that blocks mic).
 *      - Enable speakerphone so mic picks up both sides of the conversation.
 *
 *   2. Call ended (IDLE) → restoreAudio()
 *      - Abandon audio focus.
 *      - Restore MODE_NORMAL + speakerphone off.
 *
 * Why AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK?
 *   We don't want to steal full audio focus from the telephony stack (that
 *   would mute the call). _MAY_DUCK lets both co-exist: call audio stays
 *   active, our STT engine gets mic access.
 */
object AudioHelper {

    private const val TAG = "SCAMSHIELD_AUDIO"

    private var speakerEnabledByUs = false
    private var focusRequest: AudioFocusRequest? = null  // API 26+
    private var legacyFocusGranted = false               // API < 26

    fun enableForCallMonitoring(context: Context) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // ── Step 1: Request audio focus ─────────────────────────────────────
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(attrs)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()

            focusRequest = req
            am.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } else {
            @Suppress("DEPRECATION")
            val result = am.requestAudioFocus(
                null,
                AudioManager.STREAM_VOICE_CALL,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
            )
            legacyFocusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
            legacyFocusGranted
        }

        Log.d(TAG, "Audio focus request: ${if (granted) "GRANTED" else "DENIED"}")

        // ── Step 2: Set audio mode ───────────────────────────────────────────
        // MODE_IN_COMMUNICATION = designed for VoIP / voice recording apps.
        // Keeps mic accessible to app-level audio APIs (what STT needs).
        // MODE_IN_CALL routes audio through telephony HAL and blocks app mic.
        try {
            am.mode = AudioManager.MODE_IN_COMMUNICATION
        } catch (e: Exception) {
            Log.e(TAG, "setMode failed: ${e.message}")
        }

        // ── Step 3: Enable speakerphone ──────────────────────────────────────
        // This routes the caller's voice through the speaker so the mic
        // can pick up both sides for STT transcription.
        try {
            if (!am.isSpeakerphoneOn) {
                am.isSpeakerphoneOn = true
                speakerEnabledByUs = true
                Log.d(TAG, "Speakerphone ON")
            }
        } catch (e: Exception) {
            Log.e(TAG, "setSpeakerphoneOn failed: ${e.message}")
        }
    }

    fun restoreAudio(context: Context) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager

        // ── Restore speakerphone ─────────────────────────────────────────────
        if (speakerEnabledByUs) {
            try {
                am.isSpeakerphoneOn = false
                speakerEnabledByUs = false
                Log.d(TAG, "Speakerphone OFF")
            } catch (e: Exception) {
                Log.e(TAG, "restoreSpeaker failed: ${e.message}")
            }
        }

        // ── Restore audio mode ───────────────────────────────────────────────
        try {
            am.mode = AudioManager.MODE_NORMAL
        } catch (e: Exception) {
            Log.e(TAG, "restoreMode failed: ${e.message}")
        }

        // ── Abandon audio focus ──────────────────────────────────────────────
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                focusRequest?.let { am.abandonAudioFocusRequest(it) }
                focusRequest = null
            } else {
                if (legacyFocusGranted) {
                    @Suppress("DEPRECATION")
                    am.abandonAudioFocus(null)
                    legacyFocusGranted = false
                }
            }
            Log.d(TAG, "Audio focus released")
        } catch (e: Exception) {
            Log.e(TAG, "abandonFocus failed: ${e.message}")
        }
    }
}