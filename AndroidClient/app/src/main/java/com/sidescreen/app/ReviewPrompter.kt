package com.sidescreen.app

import android.content.Context
import android.os.SystemClock
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.Lifecycle
import com.google.android.play.core.review.ReviewManager
import com.google.android.play.core.review.ReviewManagerFactory

private fun revDiag(msg: String) = DiagLog.log("RV", msg)

/**
 * Google Play in-app review. Asks only once the app has proven itself: after a few real
 * sessions of 10+ minutes, right when a stream ends and the idle screen is back — never
 * over a stream, the demo or a failed connection. Play decides whether its sheet actually
 * shows (it keeps its own quota), so there is no "Rate us" button wired to it, and no
 * "do you like the app?" question first: Play policy forbids filtering who gets asked.
 * Sideloaded and .debug builds just log the failure.
 */
class ReviewPrompter(
    private val activity: AppCompatActivity,
    private val isIdle: () -> Boolean,
) {
    private val manager: ReviewManager = ReviewManagerFactory.create(activity)
    private val store = activity.getSharedPreferences("review_prompt", Context.MODE_PRIVATE)
    private var sessionStart = 0L

    /** Call from every onConnectionStatus callback (USB and wireless). */
    fun onConnectionChanged(connected: Boolean) {
        val now = SystemClock.elapsedRealtime()
        if (connected) {
            sessionStart = now
            return
        }
        if (sessionStart == 0L) return
        val minutes = (now - sessionStart) / 60_000
        sessionStart = 0L
        if (minutes < MIN_SESSION_MINUTES) return

        val sessions = store.getInt(KEY_SESSIONS, 0) + 1
        store.edit().putInt(KEY_SESSIONS, sessions).apply()
        val sinceAsked = System.currentTimeMillis() - store.getLong(KEY_LAST_ASKED, 0)
        revDiag("Good session #$sessions (${minutes}m)")
        if (sessions < SESSIONS_BEFORE_ASK || sinceAsked < COOLDOWN_MS) return

        // Let the idle screen settle first; skip if a stream came back in the meantime.
        activity.window.decorView.postDelayed({ ask() }, 1500)
    }

    private fun ask() {
        if (!isIdle() || !activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        manager
            .requestReviewFlow()
            .addOnSuccessListener { info ->
                store
                    .edit()
                    .putLong(KEY_LAST_ASKED, System.currentTimeMillis())
                    .putInt(KEY_SESSIONS, 0)
                    .apply()
                revDiag("Launching review flow")
                manager.launchReviewFlow(activity, info)
            }.addOnFailureListener { e ->
                // Expected for non-Play installs (APK from GitHub, .debug build).
                revDiag("Review flow unavailable: ${e.message}")
            }
    }

    private companion object {
        const val MIN_SESSION_MINUTES = 10
        const val SESSIONS_BEFORE_ASK = 3
        const val COOLDOWN_MS = 30L * 24 * 60 * 60 * 1000
        const val KEY_SESSIONS = "good_sessions"
        const val KEY_LAST_ASKED = "last_asked_ms"
    }
}
