package com.example.scamshield

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Listens for android.intent.action.PHONE_STATE broadcasts.
 *
 * RINGING  → notify Flutter that an unknown call is incoming
 * OFFHOOK  → call was answered; tell Flutter to start STT + enable speakerphone
 * IDLE     → call ended; tell Flutter to stop STT
 *
 * We do NOT enable speakerphone here directly because:
 *  1. BroadcastReceivers have a very short execution window
 *  2. Speakerphone should only activate once the call is answered (OFFHOOK),
 *     not while the phone is still ringing
 *  3. The Flutter side does the contact check first — if the number is saved,
 *     we never enable speakerphone at all
 */
class CallReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "SCAMSHIELD_CALL"
    }

    override fun onReceive(context: Context, intent: Intent) {

        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) return

        val state  = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        val number = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER) ?: ""

        Log.d(TAG, "Phone state: $state  number: $number")

        // Build an intent for MainActivity and pass the call state + number.
        // FLAG_ACTIVITY_NEW_TASK is required because we're outside an Activity.
        // FLAG_ACTIVITY_SINGLE_TOP ensures we reuse the existing Activity if it
        // is already running (pairs with launchMode="singleTop" in manifest).
        val activityIntent = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra("call_state", state)
            putExtra("call_number", number)
        }

        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                // Phone is ringing — pass the number to Flutter for contact check.
                // Do NOT enable speakerphone yet — call not answered.
                Log.d(TAG, "RINGING from $number")
                context.startActivity(activityIntent)
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                // Call answered — Flutter will start STT and enable speakerphone
                // only if this number is not a saved contact.
                Log.d(TAG, "OFFHOOK (answered)")
                context.startActivity(activityIntent)
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                // Call ended — tell Flutter to stop STT.
                Log.d(TAG, "IDLE (call ended)")
                context.startActivity(activityIntent)
            }
        }
    }
}