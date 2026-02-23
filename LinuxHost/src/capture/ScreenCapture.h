#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <atomic>
#include <string>

/**
 * ScreenCapture — abstract interface for screen capture on Linux.
 *
 * The factory method create() auto-detects the best backend:
 *   1. PipeWire (Wayland via ScreenCast portal)  — if HAS_PIPEWIRE
 *   2. X11 (XShm + XComposite fallback)          — if HAS_X11
 *
 * Back-pressure: callers increment/decrement pendingEncodes.
 * The capture loop skips frames when pendingEncodes >= ENCODER_QUEUE_DEPTH.
 */
class ScreenCapture {
public:
    /**
     * Called on every captured frame.
     * @param data      Pointer to pixel data (BGRA or NV12 depending on backend)
     * @param width     Frame width in pixels
     * @param height    Frame height in pixels
     * @param stride    Bytes per row (may include padding)
     * @param timestampNs  Monotonic timestamp in nanoseconds
     */
    using FrameCallback = std::function<void(const uint8_t* data,
                                             int width,
                                             int height,
                                             int stride,
                                             uint64_t timestampNs)>;

    virtual ~ScreenCapture() = default;

    /**
     * Factory: auto-detect the best available capture backend.
     * Returns nullptr if no backend is available.
     */
    static std::unique_ptr<ScreenCapture> create();

    /**
     * Initialize the capture backend for the given display/monitor index.
     * @param displayIndex  0-based monitor index
     * @return true on success
     */
    virtual bool initialize(int displayIndex) = 0;

    /**
     * Start capturing at the requested frame rate.
     * Spawns an internal capture thread.
     * @param targetFps  Desired frames per second (e.g. 30, 60, 120)
     */
    virtual void startCapture(int targetFps) = 0;

    /**
     * Stop capturing and join the capture thread.
     * Safe to call multiple times.
     */
    virtual void stop() = 0;

    /** Register the callback that receives captured frames. */
    virtual void setFrameCallback(FrameCallback cb) = 0;

    /** Current capture width in pixels (valid after initialize). */
    virtual int width() const = 0;

    /** Current capture height in pixels (valid after initialize). */
    virtual int height() const = 0;

    // ------------------------------------------------------------------
    // Back-pressure helpers (shared across all backends)
    // ------------------------------------------------------------------

    /** Atomic counter for frames currently queued for encoding. */
    std::atomic<int> pendingEncodes{0};

    /** Convenience: true when the encoder queue is full. */
    bool isBackpressured() const {
        return pendingEncodes.load(std::memory_order_relaxed) >= 2; // ENCODER_QUEUE_DEPTH
    }

protected:
    ScreenCapture() = default;
};
