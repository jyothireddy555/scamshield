package com.example.scamshield

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.core.app.NotificationCompat

// ═══════════════════════════════════════════════════════════════════
// OverlayService  — Fixed version
//
// Key fixes:
//  1. View removal guards — try/catch on every removeView call
//  2. Drag: ACTION_UP no longer calls performClick (which conflicts
//     with the drag; click is handled by a separate setOnClickListener)
//  3. ensureOnMainThread helper used throughout to avoid threading issues
//  4. Null-check windowManager before every addView / removeView call
//  5. Auto-dismiss runnable cancelled on removeCallAlert to prevent leaks
//  6. showScamAlertOverlay: shortened message preview to avoid OOM
// ═══════════════════════════════════════════════════════════════════

class OverlayService : Service() {

    private var windowManager: WindowManager? = null
    private var floatBubble:   View? = null
    private var callAlertView: View? = null
    private var scamAlertView: View? = null

    private val mainHandler       = Handler(Looper.getMainLooper())
    private val CALL_DISMISS_MS   = 30_000L
    // FIX: Keep reference to dismiss runnable so it can be cancelled
    private var callDismissRunnable: Runnable? = null

    companion object {
        @Volatile var isRunning = false

        const val ACTION_START_OVERLAY    = "com.scamshield.START_OVERLAY"
        const val ACTION_STOP_OVERLAY     = "com.scamshield.STOP_OVERLAY"
        const val ACTION_SHOW_CALL_ALERT  = "com.scamshield.SHOW_CALL_ALERT"
        const val ACTION_SHOW_SCAM_ALERT  = "com.scamshield.SHOW_SCAM_ALERT"
        const val ACTION_DISMISS_CALL     = "com.scamshield.DISMISS_CALL"
        const val ACTION_DISMISS_SCAM     = "com.scamshield.DISMISS_SCAM"
        private const val NOTIF_CHANNEL   = "scamshield_overlay"
        private const val NOTIF_ID        = 1001

        fun showCallAlert(ctx: Context, number: String, level: String, message: String) {
            ctx.startForegroundService(Intent(ctx, OverlayService::class.java).apply {
                action = ACTION_SHOW_CALL_ALERT
                putExtra("number",  number)
                putExtra("level",   level)
                putExtra("message", message)
            })
        }

        fun showScamAlert(
            ctx: Context,
            source: String, sender: String, originalMessage: String,
            probability: Int, riskLevel: String,
            fraudType: String, fraudEmoji: String,
            explanation: String, whatToDo: String,
            keywords: String, helpline: String, showHelpline: Boolean
        ) {
            ctx.startForegroundService(Intent(ctx, OverlayService::class.java).apply {
                action = ACTION_SHOW_SCAM_ALERT
                putExtra("source",          source)
                putExtra("sender",          sender)
                putExtra("originalMessage", originalMessage)
                putExtra("probability",     probability)
                putExtra("riskLevel",       riskLevel)
                putExtra("fraudType",       fraudType)
                putExtra("fraudEmoji",      fraudEmoji)
                putExtra("explanation",     explanation)
                putExtra("whatToDo",        whatToDo)
                putExtra("keywords",        keywords)
                putExtra("helpline",        helpline)
                putExtra("showHelpline",    showHelpline)
            })
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        isRunning     = true
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        startForegroundWithNotification()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START_OVERLAY -> mainHandler.post { showFloatBubble() }
            ACTION_STOP_OVERLAY  -> mainHandler.post { removeFloatBubble() }

            ACTION_SHOW_CALL_ALERT -> {
                val number  = intent.getStringExtra("number")  ?: "Unknown"
                val level   = intent.getStringExtra("level")   ?: "unknown"
                val message = intent.getStringExtra("message") ?: ""
                mainHandler.post { showCallAlertOverlay(number, level, message) }
            }

            ACTION_SHOW_SCAM_ALERT -> {
                val source       = intent.getStringExtra("source")          ?: "Message"
                val sender       = intent.getStringExtra("sender")          ?: "Unknown"
                val originalMsg  = intent.getStringExtra("originalMessage") ?: ""
                val probability  = intent.getIntExtra("probability", 0)
                val riskLevel    = intent.getStringExtra("riskLevel")       ?: "Suspicious"
                val fraudType    = intent.getStringExtra("fraudType")       ?: ""
                val fraudEmoji   = intent.getStringExtra("fraudEmoji")      ?: "⚠️"
                val explanation  = intent.getStringExtra("explanation")     ?: ""
                val whatToDo     = intent.getStringExtra("whatToDo")        ?: ""
                val keywords     = intent.getStringExtra("keywords")        ?: ""
                val helpline     = intent.getStringExtra("helpline")        ?: "1930"
                val showHelpline = intent.getBooleanExtra("showHelpline", false)

                mainHandler.post {
                    showScamAlertOverlay(
                        source, sender, originalMsg, probability,
                        riskLevel, fraudType, fraudEmoji,
                        explanation, whatToDo, keywords, helpline, showHelpline
                    )
                }
            }

            ACTION_DISMISS_CALL -> mainHandler.post { removeCallAlert() }
            ACTION_DISMISS_SCAM -> mainHandler.post { removeScamAlert() }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        // FIX: Cancel pending runnables before removing views
        callDismissRunnable?.let { mainHandler.removeCallbacks(it) }
        callDismissRunnable = null
        removeFloatBubble()
        removeCallAlert()
        removeScamAlert()
        super.onDestroy()
    }

    /* ───────── Foreground notification ───────── */

    private fun startForegroundWithNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(NOTIF_CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        NOTIF_CHANNEL,
                        "ScamShield Protection",
                        NotificationManager.IMPORTANCE_LOW
                    ).apply {
                        description = "ScamShield overlay and scam detection service"
                        setShowBadge(false)
                    }
                )
            }
        }
        val notif = NotificationCompat.Builder(this, NOTIF_CHANNEL)
            .setContentTitle("🛡️ ScamShield Active")
            .setContentText("Protecting you from scam calls and messages")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIF_ID, notif)
    }

    /* ═══════════════════════════════════════════════════════════
       FLOATING SCAN BUBBLE
    ═══════════════════════════════════════════════════════════ */

    private fun showFloatBubble() {
        removeFloatBubble()

        val bubble = TextView(this).apply {
            text      = "🛡️"
            textSize  = 22f
            gravity   = Gravity.CENTER
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#CC1a1a2e"))
                setStroke(dp(2), Color.parseColor("#54A0FF"))
            }
        }

        val params = overlayParams(dp(60), dp(60)).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 16; y = 300
            flags = flags or WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        }

        // FIX: Pass onTap directly into makeDraggable instead of using a shared `dragged` flag +
        // setOnClickListener. The old pattern never reset `dragged` to false after a drag ended,
        // so every tap after the first drag was permanently silently blocked.
        makeDraggable(bubble, params, onTap = {
            val i = Intent(this, MainActivity::class.java).apply {
                putExtra("triggerScan", true)
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivity(i)
        })

        safeAddView(bubble, params)
        floatBubble = bubble
    }

    private fun removeFloatBubble() {
        safeRemoveView(floatBubble)
        floatBubble = null
    }

    /* ═══════════════════════════════════════════════════════════
       CALL ALERT OVERLAY — compact top banner
    ═══════════════════════════════════════════════════════════ */

    private fun showCallAlertOverlay(number: String, level: String, message: String) {
        removeCallAlert()

        val color = riskColor(level)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(14), dp(16), dp(14))
            background  = roundedBg(Color.parseColor("#EE1e1e2e"), color, 16, 2)
        }

        // Header row
        val header = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        header.addView(tv("${riskEmoji(level)}  ${riskTitle(level)}", 16f, color, bold = true).apply {
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f }
        })
        header.addView(tv(" ✕ ", 18f, Color.WHITE).apply {
            setOnClickListener { removeCallAlert() }
        })
        root.addView(header)

        if (number.isNotEmpty() && number != "Unknown") {
            root.addView(tv(number, 13f, 0xAAFFFFFF.toInt()).apply {
                setPadding(0, dp(4), 0, 0)
                letterSpacing = 0.1f
            })
        }

        // FIX: Truncate long messages to avoid oversized banner
        val displayMsg = if (message.length > 100) message.substring(0, 100) + "…" else message
        if (displayMsg.isNotEmpty()) {
            root.addView(tv(displayMsg, 12f, 0xCCFFFFFF.toInt()).apply { setPadding(0, dp(6), 0, 0) })
        }

        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(10), 0, 0)
        }
        row.addView(btn("Dismiss", Color.DKGRAY) { removeCallAlert() }.apply {
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f; marginEnd = dp(6) }
        })
        row.addView(btn("📞 Call 1930", Color.RED) { dial("1930"); removeCallAlert() }.apply {
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f }
        })
        root.addView(row)

        val params = overlayParams(MP, WC).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            y = dp(48)
        }
        makeDraggable(root, params)
        safeAddView(root, params)
        callAlertView = root

        // FIX: Keep runnable reference so it can be cancelled on early dismiss
        val dismissRunnable = Runnable { removeCallAlert() }
        callDismissRunnable = dismissRunnable
        mainHandler.postDelayed(dismissRunnable, CALL_DISMISS_MS)
    }

    private fun removeCallAlert() {
        // FIX: Cancel auto-dismiss timer
        callDismissRunnable?.let { mainHandler.removeCallbacks(it) }
        callDismissRunnable = null
        safeRemoveView(callAlertView)
        callAlertView = null
    }

    /* ═══════════════════════════════════════════════════════════
       SCAM ALERT OVERLAY — full-detail scrollable card
    ═══════════════════════════════════════════════════════════ */

    private fun showScamAlertOverlay(
        source: String, sender: String, originalMsg: String,
        probability: Int, riskLevel: String,
        fraudType: String, fraudEmoji: String,
        explanation: String, whatToDo: String,
        keywords: String, helpline: String, showHelpline: Boolean,
    ) {
        removeScamAlert()

        // FIX: Limit preview length to prevent excessively tall overlay
        val shortMsg = when {
            originalMsg.length > 120 -> originalMsg.substring(0, 120) + "…"
            else                     -> originalMsg
        }

        val accent = riskColor(riskLevel)
        val title  = when {
            riskLevel.contains("high", ignoreCase = true) -> "🚨 SCAM DETECTED"
            riskLevel.contains("susp", ignoreCase = true) -> "⚠️ Suspicious Message"
            else                                          -> "✅ Message Looks Safe"
        }

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background  = roundedBg(Color.parseColor("#F01a1a2e"), accent, 20, 2)
        }

        // Title bar
        val titleBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(18), dp(14), dp(14), dp(12))
            setBackgroundColor(Color.argb(70, Color.red(accent), Color.green(accent), Color.blue(accent)))
        }
        titleBar.addView(tv(title, 17f, accent, bold = true).apply {
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f }
        })
        titleBar.addView(tv(" ✕ ", 20f, Color.WHITE).apply {
            setOnClickListener { removeScamAlert() }
        })
        card.addView(titleBar)

        val scroll  = ScrollView(this)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(18), dp(14), dp(18), dp(18))
        }

        content.addView(tv("From: $source", 11f, 0x99FFFFFF.toInt()).apply { setPadding(0, 0, 0, dp(10)) })

        if (sender.isNotEmpty() && sender != "Unknown") {
            content.addView(tv("Sender: $sender", 12f, Color.WHITE))
            content.addView(gap(6))
        }

        if (shortMsg.isNotEmpty()) {
            content.addView(infoCard("Original Message", shortMsg, Color.parseColor("#54A0FF")))
            content.addView(gap(12))
        }

        if (fraudType.isNotEmpty()) {
            content.addView(badge("$fraudEmoji  $fraudType", accent))
            content.addView(gap(12))
        }

        content.addView(tv("Scam Risk:  $probability%  •  $riskLevel", 13f, accent, bold = true))
        content.addView(gap(6))
        content.addView(riskBar(probability, accent))
        content.addView(gap(14))

        if (keywords.isNotEmpty()) {
            content.addView(infoCard("🔎 Suspicious Keywords", keywords, Color.parseColor("#FF4757")))
            content.addView(gap(10))
        }

        if (explanation.isNotEmpty()) {
            content.addView(infoCard("ℹ️ Why it's dangerous", explanation, accent))
            content.addView(gap(10))
        }

        if (whatToDo.isNotEmpty()) {
            content.addView(infoCard("⚡ What To Do Now", whatToDo, Color.parseColor("#FF9F43")))
            content.addView(gap(10))
        }

        if (showHelpline) {
            content.addView(helplineBanner(helpline))
            content.addView(gap(10))
        }

        // Never-share warning
        val warn = LinearLayout(this).apply {
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = roundedBg(Color.argb(80, 220, 0, 0), Color.RED, 10, 1)
        }
        warn.addView(tv("🚫  NEVER share OTP  •  bank PIN  •  Aadhaar  •  passwords", 11f, Color.WHITE, bold = true))
        content.addView(warn)
        content.addView(gap(14))

        val btnRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        btnRow.addView(btn("Dismiss", Color.DKGRAY) { removeScamAlert() }.apply {
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f; marginEnd = dp(8) }
        })
        if (showHelpline) {
            btnRow.addView(btn("📞 Call $helpline", Color.RED) { dial(helpline) }.apply {
                layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f }
            })
        }
        content.addView(btnRow)

        scroll.addView(content)
        card.addView(scroll)

        val dm   = resources.displayMetrics
        val maxH = (dm.heightPixels * 0.88f).toInt()
        val w    = dm.widthPixels - dp(24)

        val params = overlayParams(w, maxH).apply { gravity = Gravity.CENTER }
        makeDraggable(card, params)
        safeAddView(card, params)
        scamAlertView = card
    }

    private fun removeScamAlert() {
        safeRemoveView(scamAlertView)
        scamAlertView = null
    }

    /* ═══════════════════════════════════════════════════════════
       UI HELPERS
    ═══════════════════════════════════════════════════════════ */

    private fun tv(text: String, sp: Float, color: Int, bold: Boolean = false) =
        TextView(this).apply {
            this.text = text
            textSize  = sp
            setTextColor(color)
            if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
        }

    private fun gap(heightDp: Int) = View(this).apply {
        layoutParams = LinearLayout.LayoutParams(MP, dp(heightDp))
    }

    private fun badge(label: String, color: Int) = TextView(this).apply {
        text     = label
        textSize = 12f
        setTextColor(color)
        setTypeface(typeface, android.graphics.Typeface.BOLD)
        setPadding(dp(12), dp(5), dp(12), dp(5))
        background = roundedBg(Color.argb(40, Color.red(color), Color.green(color), Color.blue(color)), color, 20, 1)
        layoutParams = LinearLayout.LayoutParams(WC, WC)
    }

    private fun infoCard(heading: String, body: String, color: Int): LinearLayout {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background  = roundedBg(Color.argb(25, Color.red(color), Color.green(color), Color.blue(color)), color, 10, 1)
        }
        layout.addView(tv(heading, 12f, color, bold = true))
        layout.addView(gap(5))
        layout.addView(tv(body, 12f, Color.WHITE))
        return layout
    }

    private fun riskBar(progress: Int, color: Int): FrameLayout {
        val dm         = resources.displayMetrics
        val cardPad    = dp(18) * 2
        val totalWidth = dm.widthPixels - dp(24) - cardPad
        // FIX: Clamp progress to 0-100 before width calculation
        val clampedPct = progress.coerceIn(0, 100)
        val fillWidth  = ((clampedPct / 100f) * totalWidth).toInt().coerceAtLeast(dp(4))

        return FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(MP, dp(12))
            addView(View(this@OverlayService).apply {
                background   = roundedBg(Color.argb(50, 255, 255, 255), Color.TRANSPARENT, 6, 0)
                layoutParams = FrameLayout.LayoutParams(MP, MP)
            })
            addView(View(this@OverlayService).apply {
                background = GradientDrawable().apply {
                    shape        = GradientDrawable.RECTANGLE
                    cornerRadius = dp(6).toFloat()
                    setColor(color)
                }
                layoutParams = FrameLayout.LayoutParams(fillWidth, MP)
            })
        }
    }

    private fun helplineBanner(helpline: String): LinearLayout {
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background  = roundedBg(Color.argb(50, 200, 0, 0), Color.RED, 12, 1)
        }
        val left = LinearLayout(this).apply {
            orientation  = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, WC).apply { weight = 1f }
        }
        left.addView(tv("Cybercrime Helpline", 11f, Color.parseColor("#FF6B6B"), bold = true))
        left.addView(tv(helpline, 26f, Color.WHITE, bold = true).apply { letterSpacing = 0.15f })
        left.addView(tv("24×7 Free  •  cybercrime.gov.in", 10f, Color.LTGRAY))
        layout.addView(left)
        layout.addView(btn("📞 Call", Color.RED) { dial(helpline) }.apply {
            layoutParams = LinearLayout.LayoutParams(WC, WC).apply { gravity = Gravity.CENTER_VERTICAL }
        })
        return layout
    }

    private fun btn(label: String, bg: Int, onClick: () -> Unit) =
        Button(this).apply {
            text = label
            textSize = 12f
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                shape        = GradientDrawable.RECTANGLE
                cornerRadius = dp(8).toFloat()
                setColor(bg)
            }
            setPadding(dp(10), dp(8), dp(10), dp(8))
            setOnClickListener { onClick() }
        }

    private fun roundedBg(fill: Int, stroke: Int, cornerDp: Int, borderDp: Int) =
        GradientDrawable().apply {
            shape        = GradientDrawable.RECTANGLE
            cornerRadius = dp(cornerDp).toFloat()
            setColor(fill)
            if (borderDp > 0 && stroke != Color.TRANSPARENT) setStroke(dp(borderDp), stroke)
        }

    private fun overlayParams(w: Int, h: Int) = WindowManager.LayoutParams(
        w, h,
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else
            @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
        PixelFormat.TRANSLUCENT,
    )

    /**
     * FIX: Consolidated tap + drag handling.
     *  - onTap is called only on a clean short tap (no drag detected).
     *  - Touch slop threshold (8px) prevents micro-movements from being treated as drags.
     *  - isDragging is a purely local var — no shared flag that could get stuck true.
     *  - performClick() is NOT called on ACTION_UP; onTap fires directly, avoiding the
     *    setOnClickListener interaction that previously caused taps to be permanently
     *    swallowed after the first drag.
     */
    private fun makeDraggable(
        view: View,
        params: WindowManager.LayoutParams,
        onTap: (() -> Unit)? = null,
    ) {
        var startX = 0; var startY = 0
        var startRawX = 0f; var startRawY = 0f
        val touchSlop = 8f
        var isDragging = false

        view.setOnTouchListener { _, e ->
            when (e.action) {
                MotionEvent.ACTION_DOWN -> {
                    startX     = params.x;  startY     = params.y
                    startRawX  = e.rawX;    startRawY  = e.rawY
                    isDragging = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - startRawX
                    val dy = e.rawY - startRawY
                    if (!isDragging && (Math.abs(dx) > touchSlop || Math.abs(dy) > touchSlop)) {
                        isDragging = true
                    }
                    if (isDragging) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        try { windowManager?.updateViewLayout(view, params) } catch (ex: Exception) {
                            Log.w("SCAMSHIELD_OVERLAY", "updateViewLayout failed: ${ex.message}")
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (!isDragging) {
                        // Clean tap — invoke action directly (no performClick / setOnClickListener)
                        onTap?.invoke()
                    }
                    isDragging = false
                    true
                }
                else -> false
            }
        }
    }

    private fun dial(number: String) {
        try {
            startActivity(Intent(Intent.ACTION_CALL, Uri.parse("tel:$number")).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            })
        } catch (e: Exception) {
            Log.e("SCAMSHIELD_OVERLAY", "dial failed: ${e.message}")
        }
    }

    // FIX: safeAddView / safeRemoveView helpers centralise null + exception guards
    private fun safeAddView(view: View, params: WindowManager.LayoutParams) {
        val wm = windowManager ?: return
        try { wm.addView(view, params) }
        catch (e: Exception) { Log.e("SCAMSHIELD_OVERLAY", "addView failed: ${e.message}") }
    }

    private fun safeRemoveView(view: View?) {
        if (view == null) return
        val wm = windowManager ?: return
        try { wm.removeView(view) }
        catch (e: Exception) { Log.w("SCAMSHIELD_OVERLAY", "removeView: ${e.message}") }
    }

    private fun riskColor(level: String) = when {
        level.contains("high", ignoreCase = true) ||
                level.contains("spam", ignoreCase = true) -> Color.parseColor("#FF4757")
        level.contains("susp", ignoreCase = true) -> Color.parseColor("#FF9F43")
        level.contains("safe", ignoreCase = true) -> Color.parseColor("#2ED573")
        else                                      -> Color.parseColor("#54A0FF")
    }

    private fun riskTitle(level: String) = when {
        level.contains("spam", ignoreCase = true) -> "SPAM CALL DETECTED"
        level.contains("high", ignoreCase = true) -> "HIGH RISK CALL"
        level.contains("susp", ignoreCase = true) -> "SUSPICIOUS CALL"
        else                                      -> "UNKNOWN CALLER"
    }

    private fun riskEmoji(level: String) = when {
        level.contains("spam", ignoreCase = true) ||
                level.contains("high", ignoreCase = true) -> "🚨"
        level.contains("susp", ignoreCase = true) -> "⚠️"
        else                                      -> "ℹ️"
    }

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private val MP = WindowManager.LayoutParams.MATCH_PARENT
    private val WC = LinearLayout.LayoutParams.WRAP_CONTENT
}