package com.example.scamshield

import android.app.Notification
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class NotificationListenerServiceImpl : NotificationListenerService() {

    private val mainHandler = Handler(Looper.getMainLooper())

    // Prevent scanning the same notification multiple times
    private val lastProcessedText = mutableMapOf<Int, String>()

    // Apps whose notifications we want to analyze
    private val TARGET_PACKAGES = setOf(
        "com.whatsapp",
        "com.whatsapp.w4b",
        "com.google.android.apps.messaging",
        "com.samsung.android.messaging",
        "com.android.mms",
        "org.thoughtcrime.securesms",
        "com.microsoft.teams",
        "com.google.android.gm",
        "com.microsoft.office.outlook"
    )

    override fun onNotificationPosted(sbn: StatusBarNotification?) {

        sbn ?: return

        val notification = sbn.notification ?: return
        val pkg = sbn.packageName ?: return

        // Only scan target apps
        if (pkg !in TARGET_PACKAGES) return

        // Skip ongoing notifications (calls, music etc.)
        if (sbn.isOngoing) return

        // Skip group summary notifications
        val isGroupSummary =
            notification.flags.and(Notification.FLAG_GROUP_SUMMARY) != 0
        if (isGroupSummary) return

        val extras = notification.extras ?: return

        // -------------------------------
        // 1. Extract message using MessagingStyle
        // -------------------------------
        val messages = extras.getParcelableArray("android.messages")

        val text = if (messages != null && messages.isNotEmpty()) {

            val lastMessage = messages.last() as Bundle
            lastMessage.getCharSequence("text")?.toString() ?: ""

        } else {

            // -------------------------------
            // 2. Fallback extraction
            // -------------------------------
            val bigText = extras.getCharSequence("android.bigText")
            val textLines = extras.getCharSequenceArray("android.textLines")
            val normalText = extras.getCharSequence("android.text")

            when {
                !bigText.isNullOrEmpty() ->
                    bigText.toString()

                !textLines.isNullOrEmpty() ->
                    textLines.joinToString("\n") { it.toString() }

                !normalText.isNullOrEmpty() ->
                    normalText.toString()

                else -> ""
            }
        }

        if (text.isEmpty()) return

        // -------------------------------
        // 3. Prevent duplicate scans
        // -------------------------------
        if (isDuplicate(sbn.id, text)) return

        val title = extras.getCharSequence("android.title")?.toString() ?: ""
        val appName = friendlyName(pkg)

        Log.d("SCAMSHIELD_NOTIF", "[$appName] $title : $text")

        // -------------------------------
        // 4. Send to Flutter
        // -------------------------------
        mainHandler.post {

            MainActivity.notificationChannel?.invokeMethod(
                "onNotificationMessage",
                mapOf(
                    "app" to appName,
                    "title" to title,
                    "text" to text,
                    "pkg" to pkg
                )
            )

        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        // Not needed
    }

    // -------------------------------
    // Duplicate detection cache
    // -------------------------------
    private fun isDuplicate(id: Int, text: String): Boolean {

        if (lastProcessedText[id] == text) return true

        lastProcessedText[id] = text

        if (lastProcessedText.size > 10) {
            lastProcessedText.remove(lastProcessedText.keys.first())
        }

        return false
    }

    // -------------------------------
    // Convert package name to readable app name
    // -------------------------------
    private fun friendlyName(pkg: String): String {

        return when (pkg) {
            "com.whatsapp" -> "WhatsApp"
            "com.whatsapp.w4b" -> "WhatsApp Business"
            "com.google.android.apps.messaging" -> "Messages"
            "com.samsung.android.messaging" -> "Samsung Messages"
            "com.android.mms" -> "SMS"
            "org.thoughtcrime.securesms" -> "Signal"
            "com.microsoft.teams" -> "Teams"
            "com.google.android.gm" -> "Gmail"
            "com.microsoft.office.outlook" -> "Outlook"
            else -> pkg.substringAfterLast('.')
        }

    }
}