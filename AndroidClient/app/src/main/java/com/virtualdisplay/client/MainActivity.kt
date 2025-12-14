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
        setupSettingsButton()
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
                            restoreSettingsButtonPosition()
                            log("⚙️ Settings button set to VISIBLE")
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
