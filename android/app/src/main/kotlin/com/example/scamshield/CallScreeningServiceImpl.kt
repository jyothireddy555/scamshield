package com.example.scamshield

import android.telecom.Call
import android.telecom.CallScreeningService
import android.util.Log

/**
 * CallScreeningService fires BEFORE the phone rings when ScamShield
 * is set as the default Phone/Screening app.  We never block or reject
 * calls here — ScamShield's job is to WARN the user, not block calls.
 *
 * The number is forwarded to MainActivity via the call_number channel so
 * Flutter can start monitoring as early as possible.
 *
 * NOTE: This service only activates when the user explicitly sets
 * ScamShield as the default caller-ID app in Android settings.
 * CallReceiver (PHONE_STATE broadcast) is the fallback that always works.
 */
class CallScreeningServiceImpl : CallScreeningService() {

    companion object {
        private const val TAG = "SCAMSHIELD_SCREEN"
    }

    override fun onScreenCall(callDetails: Call.Details) {

        val number = try {
            callDetails.handle?.schemeSpecificPart ?: "unknown"
        } catch (e: Exception) {
            "unknown"
        }

        Log.d(TAG, "Screening call from: $number")

        // Store number in MainActivity companion so Flutter can read it
        // even before onNewIntent fires
        MainActivity.pendingCallNumber = number

        // Always allow the call through — we only warn, never block
        val response = CallResponse.Builder()
            .setDisallowCall(false)
            .setRejectCall(false)
            .setSkipCallLog(false)
            .setSkipNotification(false)
            .build()

        respondToCall(callDetails, response)
    }
}