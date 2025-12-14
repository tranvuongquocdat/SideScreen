package com.virtualdisplay.client

import android.annotation.SuppressLint
import android.app.Dialog
import android.content.Context
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.os.PowerManager
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import com.google.android.material.button.MaterialButton
import com.google.android.material.slider.Slider
import com.google.android.material.switchmaterial.SwitchMaterial
import com.virtualdisplay.client.databinding.ActivityMainBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class MainActivity : AppCompatActivity() {
    private lateinit var binding: ActivityMainBinding
    private lateinit var prefs: PreferencesManager
    private var videoDecoder: VideoDecoder? = null
    private var streamClient: StreamClient? = null
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var displayRotation = 0  // 0, 90, 180, 270 degrees
    private var wakeLock: PowerManager.WakeLock? = null

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // For dragging settings button
    private var isDraggingSettings = false
    private var settingsDx = 0f
    private var settingsDy = 0f

    // Input prediction for low-latency gaming
    private val inputPredictor = InputPredictor()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        prefs = PreferencesManager(this)

        // Allow rotation based on device sensor when not connected
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        // Enable performance mode for gaming (after binding is initialized)
        enablePerformanceMode()

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupSettingsButton()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
    }

    /**
     * Enable sustained performance mode for gaming
     * Maximizes CPU/GPU clocks and prevents thermal throttling
     */
    @SuppressLint("WakelockTimeout")
    private fun enablePerformanceMode() {
        // Request sustained performance mode (Android 7.0+)
        window.setSustainedPerformanceMode(true)

        // Acquire wake lock to prevent CPU slowdown
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
            "VirtualDisplay::PerformanceMode"
        )
        wakeLock?.acquire()

        log("🎮 Performance mode ENABLED - CPU/GPU at max clocks")
    }

    /**
     * Enable fullscreen immersive mode (only when connected)
     */
    @Suppress("DEPRECATION")
    private fun enableFullscreenMode() {
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        )
    }

    /**
     * Disable fullscreen mode (when disconnected)
     */
    @Suppress("DEPRECATION")
    private fun disableFullscreenMode() {
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_VISIBLE
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupSurface() {
        binding.surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                log("Surface created")
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                log("Surface changed: ${width}x${height}")
                initializeDecoder(holder)
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                log("Surface destroyed")
                cleanup()
            }
        })

        binding.surfaceView.setOnTouchListener { view, event ->
            handleTouch(view, event)
            true
        }
    }

    private fun setupUI() {
        binding.connectButton.setOnClickListener {
            var host = binding.hostInput.text.toString().ifEmpty { "127.0.0.1" }
            val port = binding.portInput.text.toString().toIntOrNull() ?: 8888

            // Convert localhost to 127.0.0.1 for better Android compatibility
            if (host.equals("localhost", ignoreCase = true)) {
                host = "127.0.0.1"
            }

            // Validate input
            if (host.isBlank()) {
                showError("Please enter a host address")
                return@setOnClickListener
            }

            updateStatus("Connecting to $host:$port...")
            connect(host, port)
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Initial status
        updateStatus("Ready to connect")
    }

    private fun showError(message: String) {
        runOnUiThread {
            android.app.AlertDialog.Builder(this)
                .setTitle("Connection Error")
                .setMessage(message)
                .setPositiveButton("OK", null)
                .show()
        }
    }

    private fun updateStatus(status: String) {
        runOnUiThread {
            binding.statusText.text = status
        }
    }

    @SuppressLint("ClickableViewAccessibility", "InflateParams")
    private fun setupDraggableOverlay() {
        binding.statusBar.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    isDraggingOverlay = true
                    overlayDx = view.x - event.rawX
                    overlayDy = view.y - event.rawY
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (isDraggingOverlay) {
                        // Calculate new position
                        var newX = event.rawX + overlayDx
                        var newY = event.rawY + overlayDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxX = parent.width - view.width.toFloat()
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds
                        newX = newX.coerceIn(0f, maxX)
                        newY = newY.coerceIn(0f, maxY)

                        view.animate()
                            .x(newX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (isDraggingOverlay) {
                        // Save position
                        prefs.overlayX = view.x
                        prefs.overlayY = view.y
                        isDraggingOverlay = false
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun restoreOverlayPosition() {
        val x = prefs.overlayX
        val y = prefs.overlayY

        if (x >= 0 && y >= 0) {
            binding.statusBar.post {
                binding.statusBar.x = x
                binding.statusBar.y = y
            }
        }

        // Apply opacity to both overlay and settings button
        val opacity = prefs.overlayOpacity
        updateOverlayOpacity(opacity)
        updateSettingsButtonOpacity(opacity)

        // Apply visibility
        updateOverlayVisibility(prefs.showStatsOverlay)
    }

    private fun updateOverlayOpacity(opacity: Float) {
        binding.statusBar.alpha = opacity
    }

    private fun updateOverlayVisibility(show: Boolean) {
        if (streamClient != null && show) {
            binding.statusBar.visibility = View.VISIBLE
            // Restore position when showing
            val x = prefs.overlayX
            val y = prefs.overlayY
            if (x >= 0 && y >= 0) {
                binding.statusBar.post {
                    binding.statusBar.x = x
                    binding.statusBar.y = y
                }
            }
        } else {
            binding.statusBar.visibility = View.GONE
        }
    }

    @SuppressLint("InflateParams", "SetTextI18n")
    private fun showSettingsDialog() {
        val dialog = Dialog(this)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        dialog.setContentView(R.layout.dialog_settings)
        dialog.window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        val view = dialog.findViewById<View>(android.R.id.content)
        val showStatsSwitch = view.findViewById<SwitchMaterial>(R.id.showStatsSwitch)
        val opacitySlider = view.findViewById<Slider>(R.id.opacitySlider)
        val opacityValue = view.findViewById<TextView>(R.id.opacityValue)
        val resetButton = view.findViewById<View>(R.id.resetPositionButton)
        val resetSettingsBtn = view.findViewById<View>(R.id.resetSettingsButton)
        val disconnectButton = view.findViewById<View>(R.id.disconnectSettingsButton)
        val closeButton = view.findViewById<View>(R.id.closeButton)

        // Corner position buttons
        val cornerTopLeft = view.findViewById<MaterialButton>(R.id.cornerTopLeft)
        val cornerTopRight = view.findViewById<MaterialButton>(R.id.cornerTopRight)
        val cornerBottomLeft = view.findViewById<MaterialButton>(R.id.cornerBottomLeft)
        val cornerBottomRight = view.findViewById<MaterialButton>(R.id.cornerBottomRight)

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"

        // Highlight current corner selection
        fun updateCornerSelection(selectedCorner: Int) {
            val buttons = listOf(cornerBottomRight, cornerBottomLeft, cornerTopRight, cornerTopLeft)
            buttons.forEachIndexed { index, button ->
                if (index == selectedCorner) {
                    button.backgroundTintList = android.content.res.ColorStateList.valueOf(0x334CAF50)
                } else {
                    button.backgroundTintList = null
                }
            }
        }
        updateCornerSelection(prefs.settingsButtonCorner)

        // Setup listeners
        showStatsSwitch.setOnCheckedChangeListener { _, isChecked ->
            prefs.showStatsOverlay = isChecked
            updateOverlayVisibility(isChecked)
        }

        opacitySlider.addOnChangeListener { _, value, _ ->
            prefs.overlayOpacity = value
            updateOverlayOpacity(value)
            updateSettingsButtonOpacity(value)
            opacityValue.text = "${(value * 100).toInt()}%"
        }

        resetButton.setOnClickListener {
            prefs.overlayX = -1f
            prefs.overlayY = -1f
            binding.statusBar.animate()
                .x(binding.root.width - binding.statusBar.width - 48f)
                .y(48f)
                .setDuration(300)
                .start()
        }

        // Corner position button listeners
        cornerBottomRight.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updateCornerSelection(0)
            updateSettingsButtonPosition(0)
        }

        cornerBottomLeft.setOnClickListener {
            prefs.settingsButtonCorner = 1
            updateCornerSelection(1)
            updateSettingsButtonPosition(1)
        }

        cornerTopRight.setOnClickListener {
            prefs.settingsButtonCorner = 2
            updateCornerSelection(2)
            updateSettingsButtonPosition(2)
        }

        cornerTopLeft.setOnClickListener {
            prefs.settingsButtonCorner = 3
            updateCornerSelection(3)
            updateSettingsButtonPosition(3)
        }

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonCorner = 0
            updateCornerSelection(0)
            updateSettingsButtonPosition(0)
        }

        disconnectButton.setOnClickListener {
            dialog.dismiss()
            disconnect()
        }

        closeButton.setOnClickListener {
            dialog.dismiss()
        }

        dialog.show()
    }

    private fun updateSettingsButtonOpacity(opacity: Float) {
        binding.settingsButton.alpha = opacity
    }

    private fun setupSettingsButton() {
        binding.settingsButton.setOnClickListener {
            showSettingsDialog()
        }
    }

    private fun restoreSettingsButtonPosition() {
        binding.settingsButton.post {
            updateSettingsButtonPosition(prefs.settingsButtonCorner)
        }
    }

    private fun updateSettingsButtonPosition(corner: Int) {
        val margin = 24f
        val x: Float
        val y: Float

        when (corner) {
            0 -> { // Bottom Right (default)
                x = binding.root.width - binding.settingsButton.width.toFloat() - margin
                y = binding.root.height - binding.settingsButton.height.toFloat() - margin
            }
            1 -> { // Bottom Left
                x = margin
                y = binding.root.height - binding.settingsButton.height.toFloat() - margin
            }
            2 -> { // Top Right
                x = binding.root.width - binding.settingsButton.width.toFloat() - margin
                y = margin
            }
            3 -> { // Top Left
                x = margin
                y = margin
            }
            else -> { // Default to bottom right
                x = binding.root.width - binding.settingsButton.width.toFloat() - margin
                y = binding.root.height - binding.settingsButton.height.toFloat() - margin
            }
        }

        binding.settingsButton.animate()
            .x(x)
            .y(y)
            .setDuration(200)
            .start()

        log("⚙️ Settings button positioned at corner $corner: x=$x, y=$y")
    }

    private fun initializeDecoder(holder: SurfaceHolder) {
        try {
            // Pass display for vsync-aligned frame presentation
            val display = windowManager.defaultDisplay
            videoDecoder = VideoDecoder(holder.surface, display)
            log("✅ Decoder initialized (${display.refreshRate}Hz display)")
        } catch (e: Exception) {
            log("❌ Failed to initialize decoder: ${e.message}")
        }
    }

    private fun connect(host: String, port: Int) {
        lifecycleScope.launch(Dispatchers.IO) {
            try {
                log("Connecting to $host:$port...")

                streamClient = StreamClient(host, port)
                streamClient?.onFrameReceived = { frameData ->
                    videoDecoder?.decode(frameData)
                }

                streamClient?.onConnectionStatus = { connected ->
                    runOnUiThread {
                        if (connected) {
                            updateStatus("Connected - Streaming active")
                        } else {
                            updateStatus("Disconnected")
                        }

                        binding.connectButton.isEnabled = !connected
                        binding.disconnectButton.isEnabled = connected

                        // Update status indicator color
                        binding.statusIndicator.setBackgroundResource(
                            if (connected) android.R.color.holo_green_light
                            else android.R.color.holo_red_light
                        )

                        if (connected) {
                            // Enter fullscreen mode when connected
                            enableFullscreenMode()

                            binding.settingsPanel.visibility = View.GONE
                            binding.settingsButton.visibility = View.VISIBLE
                            restoreSettingsButtonPosition()
                            updateOverlayVisibility(prefs.showStatsOverlay)
                        } else {
                            // Exit fullscreen mode when disconnected
                            disableFullscreenMode()

                            // Reset to follow device sensor when disconnected
                            resetOrientationToSensor()

                            binding.settingsPanel.visibility = View.VISIBLE
                            binding.settingsButton.visibility = View.GONE
                            binding.statusBar.visibility = View.GONE
                        }
                    }
                }

                streamClient?.onDisplaySize = { width, height, rotation ->
                    displayWidth = width
                    displayHeight = height
                    displayRotation = rotation

                    // Update decoder resolution
                    videoDecoder?.updateResolution(width, height)

                    runOnUiThread {
                        binding.resolutionText.text = "${width}x${height}"
                        // Apply rotation to SurfaceView
                        applyRotation(rotation)
                    }
                    log("Display: ${width}x${height} @ ${rotation}°")
                }

                streamClient?.onStats = { fps, mbps ->
                    runOnUiThread {
                        binding.fpsText.text = String.format("%.1f", fps)
                        binding.bitrateText.text = String.format("%.1f Mbps", mbps)
                    }
                }

                streamClient?.connect()

            } catch (e: Exception) {
                val errorMessage = when {
                    e.message?.contains("ECONNREFUSED") == true ->
                        "Mac server is not running.\n\nPlease start VirtualDisplay.app on your Mac first."
                    e.message?.contains("Network is unreachable") == true ->
                        "Cannot reach Mac.\n\nMake sure both devices are connected via USB cable and ADB reverse is configured."
                    e.message?.contains("timeout") == true ->
                        "Connection timeout.\n\nCheck if Mac firewall is blocking port $port."
                    else ->
                        "Connection failed: ${e.message}\n\nTry:\n• Start VirtualDisplay.app on Mac\n• Check USB connection\n• Run: adb reverse tcp:8888 tcp:8888"
                }
                updateStatus("Connection failed")
                showError(errorMessage)
            }
        }
    }

    private fun disconnect() {
        streamClient?.disconnect()
        log("Disconnected")
    }

    private fun cleanup() {
        disconnect()
        videoDecoder?.release()
        videoDecoder = null

        // Release wake lock
        wakeLock?.release()
        wakeLock = null
        log("🎮 Performance mode DISABLED")
    }

    private fun handleTouch(view: View, event: MotionEvent) {
        // Since we use requestedOrientation, touch coordinates are already in the correct space
        // No need to transform - Android handles this automatically
        val x = event.x / view.width.toFloat()
        val y = event.y / view.height.toFloat()

        val action = when (event.action) {
            MotionEvent.ACTION_DOWN -> {
                inputPredictor.reset()
                inputPredictor.addSample(x, y)
                0
            }
            MotionEvent.ACTION_MOVE -> {
                inputPredictor.addSample(x, y)
                1
            }
            MotionEvent.ACTION_UP -> {
                inputPredictor.reset()
                2
            }
            else -> return
        }

        // Use predicted position for faster response (predict 12ms ahead - typical glass-to-glass latency)
        val (predictedX, predictedY) = if (action == 1) {
            inputPredictor.predictPosition(12f)
        } else {
            Pair(x, y)
        }

        // Send predicted position to reduce perceived input latency
        streamClient?.sendTouch(predictedX, predictedY, action)
    }

    /**
     * Apply rotation by changing the Activity's screen orientation
     * This provides proper fullscreen portrait/landscape support
     */
    private fun applyRotation(rotation: Int) {
        requestedOrientation = when (rotation) {
            90 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
            270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE // 0°
        }

        // Reset SurfaceView transform (orientation change handles rotation)
        binding.surfaceView.apply {
            this.rotation = 0f
            scaleX = 1f
            scaleY = 1f
        }

        log("🔄 Orientation: ${when(rotation) {
            90 -> "Portrait"
            180 -> "Landscape (flipped)"
            270 -> "Portrait (flipped)"
            else -> "Landscape"
        }}")
    }

    /**
     * Reset orientation to follow device sensor (when disconnected)
     */
    private fun resetOrientationToSensor() {
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
    }

    private fun log(message: String) {
        runOnUiThread {
            val current = binding.logText.text.toString()
            val lines = current.split("\n").takeLast(5)
            binding.logText.text = (lines + message).joinToString("\n")
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        cleanup()
    }
}
