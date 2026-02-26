package com.sidescreen.app

import android.content.Context
import android.util.Log
import java.io.File

/**
 * Shared diagnostic file logger for debugging on devices that suppress logcat.
 * Writes to app-private files directory. Log file is capped at 1MB to prevent unbounded growth.
 */
object DiagLog {
    private const val TAG = "DiagLog"
    private const val LOG_FILE = "diag.log"
    private const val MAX_LOG_SIZE = 1_048_576L // 1MB

    @Volatile
    private var logFile: File? = null

    /** Initialize with app context. Call once from Application.onCreate() or MainActivity. */
    fun init(context: Context) {
        logFile = File(context.filesDir, LOG_FILE)
    }

    fun log(
        tag: String,
        msg: String,
    ) {
        Log.d(tag, msg)
        val f = logFile ?: return
        try {
            // Rotate if too large
            if (f.exists() && f.length() > MAX_LOG_SIZE) {
                val backup = File(f.parent, "diag.log.old")
                backup.delete()
                f.renameTo(backup)
            }
            f.appendText("[${System.currentTimeMillis()}] $tag: $msg\n")
        } catch (_: Exception) {
        }
    }
}
