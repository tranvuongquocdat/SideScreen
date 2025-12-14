package com.virtualdisplay.client

import android.annotation.SuppressLint
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.MotionEvent
import android.view.SurfaceHolder
import android.view.View
import android.view.Window
import android.view.WindowManager
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
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

    // For dragging stats overlay
    private var isDraggingOverlay = false
    private var overlayDx = 0f
    private var overlayDy = 0f

    // For dragging settings button
    private var isDraggingSettings = false
    private var settingsDx = 0f
    private var settingsDy = 0f

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        prefs = PreferencesManager(this)

        // Keep screen on
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // Fullscreen immersive mode
        window.decorView.systemUiVisibility = (
            View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            or View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
        )

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        setupSurface()
        setupUI()
        setupDraggableOverlay()
        setupDraggableSettingsButton()
        restoreOverlayPosition()
        restoreSettingsButtonPosition()
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
            val host = binding.hostInput.text.toString().ifEmpty { "localhost" }
            val port = binding.portInput.text.toString().toIntOrNull() ?: 8888
            connect(host, port)
        }

        binding.disconnectButton.setOnClickListener {
            disconnect()
        }

        // Settings button click is handled in setupDraggableSettingsButton()
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

        // Load current settings
        showStatsSwitch.isChecked = prefs.showStatsOverlay
        opacitySlider.value = prefs.overlayOpacity
        opacityValue.text = "${(prefs.overlayOpacity * 100).toInt()}%"

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

        resetSettingsBtn.setOnClickListener {
            prefs.settingsButtonX = -1f
            prefs.settingsButtonY = -1f
            val rightEdgeX = binding.root.width - binding.settingsButton.width.toFloat() - 24f
            val bottomY = binding.root.height - binding.settingsButton.height.toFloat() - 24f
            binding.settingsButton.animate()
                .x(rightEdgeX)
                .y(bottomY)
                .setDuration(300)
                .start()
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

    @SuppressLint("ClickableViewAccessibility")
    private fun setupDraggableSettingsButton() {
        var startX = 0f
        var startY = 0f
        var hasMoved = false

        binding.settingsButton.setOnTouchListener { view, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    settingsDx = view.x - event.rawX
                    settingsDy = view.y - event.rawY
                    startX = event.rawX
                    startY = event.rawY
                    hasMoved = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = Math.abs(event.rawY - startY)

                    // Only allow vertical dragging (along right edge)
                    if (dy > 10) {
                        hasMoved = true

                        // Calculate new Y position only (keep X fixed at right edge)
                        var newY = event.rawY + settingsDy

                        // Get screen bounds
                        val parent = view.parent as View
                        val maxY = parent.height - view.height.toFloat()

                        // Constrain to screen bounds vertically
                        newY = newY.coerceIn(0f, maxY)

                        // Keep X at right edge
                        val rightEdgeX = parent.width - view.width.toFloat() - 24f

                        view.animate()
                            .x(rightEdgeX)
                            .y(newY)
                            .setDuration(0)
                            .start()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (hasMoved) {
                        // Save position after drag
                        prefs.settingsButtonX = view.x
                        prefs.settingsButtonY = view.y
                    } else {
                        // If not moved, treat as click
                        showSettingsDialog()
                    }
                    true
                }
                else -> false
            }
        }
    }

    private fun restoreSettingsButtonPosition() {
        val y = prefs.settingsButtonY

        binding.settingsButton.post {
            // Always position at right edge
            val rightEdgeX = binding.root.width - binding.settingsButton.width.toFloat() - 24f

            // Use saved Y position if valid, otherwise use default bottom position
            val posY = if (y >= 0) {
                val maxY = binding.root.height - binding.settingsButton.height.toFloat()
                y.coerceIn(0f, maxY)
            } else {
                binding.root.height - binding.settingsButton.height.toFloat() - 24f
            }

            binding.settingsButton.x = rightEdgeX
            binding.settingsButton.y = posY

            log("⚙️ Restored settings button position: x=$rightEdgeX, y=$posY")
            log("⚙️ Screen size: ${binding.root.width}x${binding.root.height}")
        }
    }

    private fun initializeDecoder(holder: SurfaceHolder) {
        try {
            videoDecoder = VideoDecoder(holder.surface)
            log("✅ Decoder initialized")
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
                        binding.statusText.text = if (connected) "Connected" else "Disconnected"
                        binding.connectButton.isEnabled = !connected
                        binding.disconnectButton.isEnabled = connected

                        // Update status indicator color
                        binding.statusIndicator.setBackgroundResource(
                            if (connected) android.R.color.holo_green_light
                            else android.R.color.holo_red_light
                        )

                        if (connected) {
                            binding.settingsPanel.visibility = View.GONE
                            binding.settingsButton.visibility = View.VISIBLE
                            log("⚙️ Settings button set to VISIBLE")
                            log("⚙️ Button position: x=${binding.settingsButton.x}, y=${binding.settingsButton.y}")
                            log("⚙️ Button size: w=${binding.settingsButton.width}, h=${binding.settingsButton.height}")
                            updateOverlayVisibility(prefs.showStatsOverlay)
                        } else {
                            binding.settingsPanel.visibility = View.VISIBLE
                            binding.settingsButton.visibility = View.GONE
                            binding.statusBar.visibility = View.GONE
                        }
                    }
                }

                streamClient?.onDisplaySize = { width, height ->
                    displayWidth = width
                    displayHeight = height
                    runOnUiThread {
                        binding.resolutionText.text = "${width}x${height}"
                    }
                    log("Display: ${width}x${height}")
                }

                streamClient?.onStats = { fps, mbps ->
                    runOnUiThread {
                        binding.fpsText.text = String.format("%.1f", fps)
                        binding.bitrateText.text = String.format("%.1f Mbps", mbps)
                    }
                }

                streamClient?.connect()

            } catch (e: Exception) {
                log("❌ Connection failed: ${e.message}")
                runOnUiThread {
                    binding.statusText.text = "Connection failed"
                }
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
    }

    private fun handleTouch(view: View, event: MotionEvent) {
        val x = event.x / view.width.toFloat()
        val y = event.y / view.height.toFloat()

        val action = when (event.action) {
            MotionEvent.ACTION_DOWN -> 0
            MotionEvent.ACTION_MOVE -> 1
            MotionEvent.ACTION_UP -> 2
            else -> return
        }

        streamClient?.sendTouch(x, y, action)
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
