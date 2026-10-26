package com.sidescreen.app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * Five-state UI machine for the Wireless tab on Android.
 *
 *   ① first-time → ② scanning (QRScannerActivity) → ③ connected
 *                                         ↘ ④ token mismatch / re-pair
 *   ⓹ permission denied permanently
 */
class WirelessTabController(
    private val activity: Activity,
    private val views: Views,
    private val storage: PairedHostStorage,
    private val cameraPerm: CameraPermissionManager,
    private val onConnectRequested: (
        host: String,
        port: Int,
        token: ByteArray,
        deviceName: String,
        macName: String,
    ) -> Unit,
    /** Code pairing (issue #35): open the "enter code" dialog. */
    private val onCodePairRequested: () -> Unit,
) {
    data class Views(
        val connecting: View,
        val firstTime: View,
        val connected: View,
        val pairedIdle: View,
        val repair: View,
        val permDenied: View,
        val scanButton: Button,
        val rescanButton: Button,
        val enterCodeButton: Button,
        val repairEnterCodeButton: Button,
        val permDeniedEnterCodeButton: Button,
        val disconnectButton: Button,
        val forgetButton: Button,
        val reconnectButton: Button,
        val idleForgetButton: Button,
        val openSettingsButton: Button,
        val connectedMacName: TextView,
        val connectedMacIp: TextView,
        val connectingLabel: TextView,
        val connectingSubtitle: TextView,
        val idleMacName: TextView,
        val idleMacIp: TextView,
        val repairTitle: TextView,
        val repairMessage: TextView,
    )

    enum class State { FIRST_TIME, CONNECTING, CONNECTED, PAIRED_IDLE, REPAIR_NEEDED, PERM_DENIED }

    private var state: State = State.FIRST_TIME

    fun bind() {
        views.scanButton.setOnClickListener { triggerScan() }
        views.rescanButton.setOnClickListener { triggerScan() }
        views.enterCodeButton.setOnClickListener { onCodePairRequested() }
        views.repairEnterCodeButton.setOnClickListener { onCodePairRequested() }
        views.permDeniedEnterCodeButton.setOnClickListener { onCodePairRequested() }
        views.openSettingsButton.setOnClickListener { cameraPerm.openAppSettings() }
        views.forgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.idleForgetButton.setOnClickListener {
            storage.clear()
            transition(State.FIRST_TIME)
        }
        views.reconnectButton.setOnClickListener {
            val entry =
                storage.load() ?: run {
                    transition(State.FIRST_TIME)
                    return@setOnClickListener
                }
            showConnecting("Reconnecting to ${entry.macName}", "${entry.host}:${entry.port}")
            attemptAutoConnect(entry)
        }
    }

    /**
     * Called when the TCP stream goes down (user tapped Disconnect, network drop, etc).
     * Move the UI to a clean "paired but idle" state showing the Mac info + Reconnect button.
     */
    fun onStreamDisconnected() {
        android.util.Log.i(
            "WirelessTabController",
            "onStreamDisconnected called, current state=$state, storage entry exists=${storage.load() != null}",
        )
        val entry =
            storage.load() ?: run {
                transition(State.FIRST_TIME)
                return
            }
        views.idleMacName.text = entry.macName
        views.idleMacIp.text = "${entry.host}:${entry.port}"
        transition(State.PAIRED_IDLE)
    }

    private fun transition(next: State) {
        android.util.Log.i("WirelessTabController", "transition $state → $next")
        state = next
        views.connecting.visibility = if (next == State.CONNECTING) View.VISIBLE else View.GONE
        views.firstTime.visibility = if (next == State.FIRST_TIME) View.VISIBLE else View.GONE
        views.connected.visibility = if (next == State.CONNECTED) View.VISIBLE else View.GONE
        views.pairedIdle.visibility = if (next == State.PAIRED_IDLE) View.VISIBLE else View.GONE
        views.repair.visibility = if (next == State.REPAIR_NEEDED) View.VISIBLE else View.GONE
        views.permDenied.visibility = if (next == State.PERM_DENIED) View.VISIBLE else View.GONE
    }

    /**
     * Called when the Wireless tab becomes visible. Decides initial state based on
     * cached host + camera permission state.
     *
     * No auto-connect: even when a cached pairing exists, the user must press
     * the Reconnect button to actually start a connection. Auto-connect was
     * confusing because it could run silently while the user toggled tabs.
     */
    fun show() {
        when {
            cameraPerm.isPermanentlyDenied() -> transition(State.PERM_DENIED)
            storage.load() == null -> transition(State.FIRST_TIME)
            else -> {
                val entry = storage.load()!!
                views.idleMacName.text = entry.macName
                views.idleMacIp.text = "${entry.host}:${entry.port}"
                transition(State.PAIRED_IDLE)
            }
        }
    }

    fun onScanResult(url: String) {
        val parsed = PairingURL.parse(url) ?: return
        val deviceName = defaultDeviceName(activity)
        storage.save(PairedHostStorage.Entry(parsed.host, parsed.port, parsed.token, parsed.macName))
        showConnecting("Connecting to ${parsed.macName}", "${parsed.host}:${parsed.port}")
        onConnectRequested(parsed.host, parsed.port, parsed.token, deviceName, parsed.macName)
    }

    /**
     * Code pairing succeeded (issue #35): the Mac issued the real token. Save it
     * exactly like a QR scan and connect through the normal wireless handshake.
     */
    fun onCodePairComplete(
        host: String,
        port: Int,
        token: ByteArray,
        macName: String,
    ) {
        val deviceName = defaultDeviceName(activity)
        storage.save(PairedHostStorage.Entry(host, port, token, macName))
        showConnecting("Connecting to $macName", "$host:$port")
        onConnectRequested(host, port, token, deviceName, macName)
    }

    fun onConnectError(error: StreamClient.WirelessConnectError) {
        val cached = storage.load()
        when (error) {
            is StreamClient.WirelessConnectError.NetworkUnreachable -> {
                views.repairTitle.text = "⚠ Couldn't reach Mac"
                views.repairMessage.text =
                    if (cached != null) {
                        "No response from ${cached.macName} at ${cached.host}:${cached.port}.\n\n" +
                            "The Mac may have switched WiFi networks, changed its port, or is not " +
                            "running. Open SideScreen on the Mac and scan the new QR to re-pair."
                    } else {
                        "No response from your Mac. Make sure both devices are on the same WiFi " +
                            "and the Mac app is running, then scan the QR again."
                    }
                transition(State.REPAIR_NEEDED)
            }
            is StreamClient.WirelessConnectError.TokenRejected -> {
                views.repairTitle.text = "⚠ Re-pair required"
                views.repairMessage.text =
                    if (cached != null) {
                        "${cached.macName} reset its pairing token (e.g. Reset Token clicked, or " +
                            "reinstalled). Scan the new QR to pair again."
                    } else {
                        "The Mac reset its pairing token. Scan the new QR to pair again."
                    }
                transition(State.REPAIR_NEEDED)
            }
            is StreamClient.WirelessConnectError.ProtocolError -> {
                views.repairTitle.text = "⚠ Connection error"
                views.repairMessage.text = "Couldn't complete the secure handshake with the Mac. Scan the QR again."
                transition(State.REPAIR_NEEDED)
            }
        }
    }

    private fun showConnecting(
        title: String,
        subtitle: String,
    ) {
        views.connectingLabel.text = title
        views.connectingSubtitle.text = subtitle
        transition(State.CONNECTING)
    }

    fun onConnectSuccess(
        macName: String,
        ip: String,
    ) {
        views.connectedMacName.text = macName
        views.connectedMacIp.text = ip
        transition(State.CONNECTED)
    }

    fun onCameraPermissionResult(granted: Boolean) {
        if (granted) {
            // Re-evaluate; user just granted, jump straight into scanner.
            launchScanner()
        } else if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
        }
        // else: stay in current state; user can tap Scan again to re-prompt.
    }

    private fun triggerScan() {
        if (cameraPerm.isPermanentlyDenied()) {
            transition(State.PERM_DENIED)
            return
        }
        if (!cameraPerm.isGranted()) {
            cameraPerm.request(REQ_CAMERA)
            return
        }
        launchScanner()
    }

    private fun launchScanner() {
        val intent = Intent(activity, QRScannerActivity::class.java)
        activity.startActivityForResult(intent, REQ_SCAN)
    }

    private fun attemptAutoConnect(entry: PairedHostStorage.Entry) {
        val deviceName = defaultDeviceName(activity)
        onConnectRequested(entry.host, entry.port, entry.token, deviceName, entry.macName)
    }

    companion object {
        const val REQ_SCAN = 1001
        const val REQ_CAMERA = 1002

        /**
         * The device name sent in handshakes and in the identity message: the
         * name the user sees for their own device (Settings → About, Bluetooth —
         * "V50S ThinQ", "Galaxy Tab S9", or whatever they renamed it to), falling
         * back to the model code. The wire format caps the name at 64 UTF-8 BYTES
         * (not chars — a char-truncated non-ASCII name can still overflow and
         * fail the codec's require), and every source can legally be blank.
         */
        fun defaultDeviceName(context: Context): String {
            val resolver = context.contentResolver
            val candidates =
                sequence {
                    yield(runCatching { Settings.Global.getString(resolver, Settings.Global.DEVICE_NAME) }.getOrNull())
                    yield(runCatching { Settings.Secure.getString(resolver, "bluetooth_name") }.getOrNull())
                    yield(android.os.Build.MODEL)
                }
            var name = candidates.firstOrNull { !it.isNullOrBlank() }?.trim() ?: "Android"
            while (name.toByteArray(Charsets.UTF_8).size > 64) {
                name = name.dropLast(1)
            }
            return name
        }
    }
}
