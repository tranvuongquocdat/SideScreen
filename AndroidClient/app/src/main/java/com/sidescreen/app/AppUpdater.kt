package com.sidescreen.app

import android.view.View
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.IntentSenderRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.snackbar.Snackbar
import com.google.android.play.core.appupdate.AppUpdateManager
import com.google.android.play.core.appupdate.AppUpdateManagerFactory
import com.google.android.play.core.appupdate.AppUpdateOptions
import com.google.android.play.core.install.InstallStateUpdatedListener
import com.google.android.play.core.install.model.AppUpdateType
import com.google.android.play.core.install.model.InstallStatus
import com.google.android.play.core.install.model.UpdateAvailability

private fun updDiag(msg: String) = DiagLog.log("UP", msg)

/**
 * Google Play flexible in-app updates: when Play has a newer build, show its
 * update prompt; the download runs in the background and a snackbar offers the
 * restart once it has landed. Only Play-installed builds get offers — sideloaded
 * APKs and the .debug build just log the failure and carry on.
 */
class AppUpdater(
    private val activity: AppCompatActivity,
    private val anchor: () -> View,
) {
    private val manager: AppUpdateManager = AppUpdateManagerFactory.create(activity)
    private var promptedThisLaunch = false

    private val launcher: ActivityResultLauncher<IntentSenderRequest> =
        activity.registerForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
            updDiag("Update flow result: ${result.resultCode}")
        }

    private val installListener =
        InstallStateUpdatedListener { state ->
            if (state.installStatus() == InstallStatus.DOWNLOADED) {
                offerRestart()
            }
        }

    init {
        manager.registerListener(installListener)
    }

    /** Call when the app is idle (not streaming) — typically from onResume. */
    fun checkForUpdate() {
        manager.appUpdateInfo
            .addOnSuccessListener { info ->
                when {
                    // A download finished while we were away (or in a previous launch).
                    info.installStatus() == InstallStatus.DOWNLOADED -> offerRestart()

                    !promptedThisLaunch &&
                        info.updateAvailability() == UpdateAvailability.UPDATE_AVAILABLE &&
                        info.isUpdateTypeAllowed(AppUpdateType.FLEXIBLE) -> {
                        promptedThisLaunch = true
                        updDiag("Update available: versionCode=${info.availableVersionCode()}")
                        manager.startUpdateFlowForResult(
                            info,
                            launcher,
                            AppUpdateOptions.newBuilder(AppUpdateType.FLEXIBLE).build(),
                        )
                    }
                }
            }.addOnFailureListener { e ->
                // Expected for non-Play installs (APK from GitHub, .debug build).
                updDiag("Update check unavailable: ${e.message}")
            }
    }

    fun release() {
        manager.unregisterListener(installListener)
    }

    private fun offerRestart() {
        Snackbar
            .make(anchor(), "Update downloaded", Snackbar.LENGTH_INDEFINITE)
            .setAction("Restart") { manager.completeUpdate() }
            .show()
    }
}
