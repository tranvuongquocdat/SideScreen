#ifdef HAS_PIPEWIRE

#include "capture/PipeWireCapture.h"
#include "Config.h"

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <spa/debug/types.h>
#include <spa/param/video/type-info.h>

#include <iostream>
#include <cstring>
#include <chrono>
#include <thread>
#include <sched.h>
#include <sys/resource.h>
#include <unistd.h>

// D-Bus interaction via QDBus (Qt already required by the project)
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusReply>
#include <QDBusUnixFileDescriptor>
#include <QVariantMap>

// =====================================================================
//  PipeWire stream event table
// =====================================================================
static const struct pw_stream_events kStreamEvents = {
    .version       = PW_VERSION_STREAM_EVENTS,
    .state_changed = PipeWireCapture::onStreamStateChanged,
    .param_changed = PipeWireCapture::onStreamParamChanged,
    .process       = PipeWireCapture::onStreamProcess,
};

// =====================================================================
//  Construction / Destruction
// =====================================================================

PipeWireCapture::PipeWireCapture() {
    pw_init(nullptr, nullptr);
}

PipeWireCapture::~PipeWireCapture() {
    stop();
    pw_deinit();
}

// =====================================================================
//  initialize()
// =====================================================================

bool PipeWireCapture::initialize(int displayIndex) {
    // Step 1 — Ask the portal for a ScreenCast session
    if (!requestScreenCastSession(displayIndex)) {
        std::cerr << "[PipeWireCapture] Failed to create ScreenCast session\n";
        return false;
    }

    // Step 2 — Obtain PipeWire remote fd from the portal
    if (!openPipeWireRemote()) {
        std::cerr << "[PipeWireCapture] Failed to open PipeWire remote\n";
        return false;
    }

    // Step 3 — Create PipeWire thread loop + context + core
    m_loop = pw_thread_loop_new("sidescreen-capture", nullptr);
    if (!m_loop) {
        std::cerr << "[PipeWireCapture] Failed to create PipeWire thread loop\n";
        return false;
    }

    m_context = pw_context_new(pw_thread_loop_get_loop(m_loop), nullptr, 0);
    if (!m_context) {
        std::cerr << "[PipeWireCapture] Failed to create PipeWire context\n";
        return false;
    }

    m_core = pw_context_connect_fd(m_context, m_pipewireFd, nullptr, 0);
    if (!m_core) {
        std::cerr << "[PipeWireCapture] Failed to connect to PipeWire core (fd="
                  << m_pipewireFd << ")\n";
        return false;
    }

    // Step 4 — Create the stream (format negotiation happens on start)
    auto props = pw_properties_new(
        PW_KEY_MEDIA_TYPE,    "Video",
        PW_KEY_MEDIA_CATEGORY,"Capture",
        PW_KEY_MEDIA_ROLE,    "Screen",
        nullptr
    );

    m_stream = pw_stream_new(m_core, "sidescreen-screen-capture", props);
    if (!m_stream) {
        std::cerr << "[PipeWireCapture] Failed to create PipeWire stream\n";
        return false;
    }

    // Allocate the listener hook
    m_streamListener = static_cast<spa_hook*>(calloc(1, sizeof(spa_hook)));
    pw_stream_add_listener(m_stream, m_streamListener, &kStreamEvents, this);

    std::cout << "[PipeWireCapture] Initialized (node=" << m_nodeId << ")\n";
    return true;
}

// =====================================================================
//  startCapture()
// =====================================================================

void PipeWireCapture::startCapture(int targetFps) {
    if (m_running.exchange(true))
        return; // already running

    m_targetFps = targetFps;

    // Build format parameters: prefer BGRx, accept RGBx / NV12
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    const enum spa_video_format formats[] = {
        SPA_VIDEO_FORMAT_BGRx,
        SPA_VIDEO_FORMAT_BGRA,
        SPA_VIDEO_FORMAT_RGBx,
        SPA_VIDEO_FORMAT_RGBA,
        SPA_VIDEO_FORMAT_NV12,
    };

    const struct spa_pod* params[1];
    params[0] = static_cast<const struct spa_pod*>(
        spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
            SPA_FORMAT_mediaType,    SPA_POD_Id(SPA_MEDIA_TYPE_video),
            SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
            SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(
                5,
                formats[0], formats[0], formats[1], formats[2], formats[3]),
            SPA_FORMAT_VIDEO_size,   SPA_POD_CHOICE_RANGE_Rectangle(
                &SPA_RECTANGLE(1920, 1080),
                &SPA_RECTANGLE(1, 1),
                &SPA_RECTANGLE(7680, 4320)),
            SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
                &SPA_FRACTION(targetFps, 1),
                &SPA_FRACTION(1, 1),
                &SPA_FRACTION(240, 1))
        ));

    // Connect the stream to the ScreenCast node
    pw_thread_loop_lock(m_loop);

    if (pw_thread_loop_start(m_loop) < 0) {
        std::cerr << "[PipeWireCapture] Failed to start PipeWire loop\n";
        pw_thread_loop_unlock(m_loop);
        m_running = false;
        return;
    }

    pw_stream_connect(m_stream,
        PW_DIRECTION_INPUT,
        m_nodeId,
        static_cast<pw_stream_flags>(
            PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS),
        params, 1);

    pw_thread_loop_unlock(m_loop);

    // Start idle-resend thread
    m_idleThread = std::thread(&PipeWireCapture::idleResendLoop, this);

    // Try to set high scheduling priority
    setpriority(PRIO_PROCESS, 0, -10);

    std::cout << "[PipeWireCapture] Capture started at " << targetFps << " fps\n";
}

// =====================================================================
//  stop()
// =====================================================================

void PipeWireCapture::stop() {
    if (!m_running.exchange(false))
        return;

    // Join idle thread
    if (m_idleThread.joinable())
        m_idleThread.join();

    // Tear down PipeWire
    if (m_loop) {
        pw_thread_loop_lock(m_loop);
        if (m_stream) {
            pw_stream_disconnect(m_stream);
            pw_stream_destroy(m_stream);
            m_stream = nullptr;
        }
        pw_thread_loop_unlock(m_loop);
        pw_thread_loop_stop(m_loop);
    }

    if (m_core) {
        pw_core_disconnect(m_core);
        m_core = nullptr;
    }
    if (m_context) {
        pw_context_destroy(m_context);
        m_context = nullptr;
    }
    if (m_loop) {
        pw_thread_loop_destroy(m_loop);
        m_loop = nullptr;
    }
    if (m_streamListener) {
        free(m_streamListener);
        m_streamListener = nullptr;
    }

    std::cout << "[PipeWireCapture] Stopped\n";
}

// =====================================================================
//  setFrameCallback()
// =====================================================================

void PipeWireCapture::setFrameCallback(FrameCallback cb) {
    std::lock_guard<std::mutex> lock(m_callbackMutex);
    m_callback = std::move(cb);
}

// =====================================================================
//  PipeWire stream callbacks
// =====================================================================

void PipeWireCapture::onStreamStateChanged(void* data,
        enum pw_stream_state old, enum pw_stream_state state,
        const char* error) {
    (void)old;
    auto* self = static_cast<PipeWireCapture*>(data);
    std::cout << "[PipeWireCapture] Stream state: "
              << pw_stream_state_as_string(state);
    if (error)
        std::cout << " (error: " << error << ")";
    std::cout << "\n";

    if (state == PW_STREAM_STATE_ERROR) {
        self->m_running = false;
    }
}

void PipeWireCapture::onStreamParamChanged(void* data, uint32_t id,
        const struct spa_pod* param) {
    auto* self = static_cast<PipeWireCapture*>(data);
    self->handleParamChanged(id, param);
}

void PipeWireCapture::onStreamProcess(void* data) {
    auto* self = static_cast<PipeWireCapture*>(data);
    self->handleProcess();
}

// =====================================================================
//  handleParamChanged — negotiated format
// =====================================================================

void PipeWireCapture::handleParamChanged(uint32_t id,
        const struct spa_pod* param) {
    if (!param || id != SPA_PARAM_Format)
        return;

    struct spa_video_info_raw info;
    if (spa_format_video_raw_parse(param, &info) < 0) {
        std::cerr << "[PipeWireCapture] Failed to parse video format\n";
        return;
    }

    m_width.store(info.size.width, std::memory_order_relaxed);
    m_height.store(info.size.height, std::memory_order_relaxed);

    // Stride depends on format; BGRA = 4 bytes/pixel
    int bpp = 4; // default for BGRx/BGRA/RGBx/RGBA
    if (info.format == SPA_VIDEO_FORMAT_NV12) {
        bpp = 1; // Y plane stride = width
    }
    m_stride = static_cast<int>(info.size.width) * bpp;

    std::cout << "[PipeWireCapture] Format negotiated: "
              << info.size.width << "x" << info.size.height
              << " stride=" << m_stride
              << " format=" << spa_debug_type_find_name(
                     spa_type_video_format, info.format)
              << "\n";

    // Tell PipeWire what buffers we want
    uint8_t bufferParams[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(bufferParams, sizeof(bufferParams));

    const struct spa_pod* bufParam = static_cast<const struct spa_pod*>(
        spa_pod_builder_add_object(&b,
            SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
            SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(
                Config::CAPTURE_QUEUE_DEPTH, 2, Config::CAPTURE_QUEUE_DEPTH),
            SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(
                (1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd) | (1 << SPA_DATA_DmaBuf))
        ));

    pw_stream_update_params(m_stream, &bufParam, 1);
}

// =====================================================================
//  handleProcess — a new frame arrived from PipeWire
// =====================================================================

void PipeWireCapture::handleProcess() {
    struct pw_buffer* pwBuf = pw_stream_dequeue_buffer(m_stream);
    if (!pwBuf)
        return;

    struct spa_buffer* buf = pwBuf->buffer;
    if (!buf->datas[0].data) {
        pw_stream_queue_buffer(m_stream, pwBuf);
        return;
    }

    // Back-pressure check
    if (isBackpressured()) {
        pw_stream_queue_buffer(m_stream, pwBuf);
        return;
    }

    const uint8_t* data = static_cast<const uint8_t*>(buf->datas[0].data);
    int w = m_width.load(std::memory_order_relaxed);
    int h = m_height.load(std::memory_order_relaxed);
    int stride = m_stride;

    // Timestamp: monotonic clock
    auto now = std::chrono::steady_clock::now();
    uint64_t tsNs = static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            now.time_since_epoch()).count());

    // Deliver to callback directly from PipeWire buffer (zero-copy hot path).
    // The PipeWire buffer is valid until we call pw_stream_queue_buffer().
    {
        std::lock_guard<std::mutex> lock(m_callbackMutex);
        if (m_callback) {
            m_callback(data, w, h, stride, tsNs);
        }
    }

    // Save last frame for idle re-send (only copy needed for resend path)
    {
        std::lock_guard<std::mutex> lock(m_lastFrameMutex);
        size_t frameSize = static_cast<size_t>(stride * h);
        m_lastFrame.resize(frameSize);
        std::memcpy(m_lastFrame.data(), data, frameSize);
        m_lastFrameTs.store(tsNs, std::memory_order_release);
    }

    pw_stream_queue_buffer(m_stream, pwBuf);
}

// =====================================================================
//  Idle re-send loop
// =====================================================================

void PipeWireCapture::idleResendLoop() {
    // Re-deliver the last frame if no new frame arrives within 2x the
    // frame interval, so that the encoder always has something to send.
    while (m_running.load(std::memory_order_relaxed)) {
        int fps = m_targetFps > 0 ? m_targetFps : 30;
        auto interval = std::chrono::milliseconds(1000 / fps);
        std::this_thread::sleep_for(interval * 2);

        if (!m_running.load(std::memory_order_relaxed))
            break;

        if (isBackpressured())
            continue;

        uint64_t lastTs = m_lastFrameTs.load(std::memory_order_acquire);
        if (lastTs == 0)
            continue;

        auto now = std::chrono::steady_clock::now();
        uint64_t nowNs = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                now.time_since_epoch()).count());

        // If no new frame for > 2 frame intervals, re-send
        uint64_t thresholdNs = static_cast<uint64_t>(2'000'000'000ULL / fps);
        if ((nowNs - lastTs) > thresholdNs) {
            std::lock_guard<std::mutex> frameLock(m_lastFrameMutex);
            if (m_lastFrame.empty())
                continue;

            int w = m_width.load(std::memory_order_relaxed);
            int h = m_height.load(std::memory_order_relaxed);
            int stride = m_stride;

            std::lock_guard<std::mutex> cbLock(m_callbackMutex);
            if (m_callback) {
                m_callback(m_lastFrame.data(), w, h, stride, nowNs);
            }
        }
    }
}

// =====================================================================
//  Portal D-Bus: requestScreenCastSession()
// =====================================================================

bool PipeWireCapture::requestScreenCastSession(int displayIndex) {
    (void)displayIndex; // Portal shows its own monitor picker

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        std::cerr << "[PipeWireCapture] Cannot connect to session D-Bus\n";
        return false;
    }

    QDBusInterface portal(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        bus);

    if (!portal.isValid()) {
        std::cerr << "[PipeWireCapture] ScreenCast portal not available\n";
        return false;
    }

    // CreateSession
    QVariantMap sessionOpts;
    sessionOpts["handle_token"] = QString("sidescreen_%1").arg(getpid());
    sessionOpts["session_handle_token"] = QString("sidescreen_session_%1").arg(getpid());

    QDBusReply<QDBusObjectPath> sessionReply = portal.call(
        "CreateSession", sessionOpts);
    if (!sessionReply.isValid()) {
        std::cerr << "[PipeWireCapture] CreateSession failed: "
                  << sessionReply.error().message().toStdString() << "\n";
        return false;
    }
    m_sessionHandle = sessionReply.value().path().toStdString();

    // SelectSources — request monitor capture
    QVariantMap sourceOpts;
    sourceOpts["handle_token"] = QString("sidescreen_src_%1").arg(getpid());
    sourceOpts["types"] = QVariant::fromValue(1u);        // MONITOR = 1
    sourceOpts["multiple"] = QVariant::fromValue(false);
    sourceOpts["cursor_mode"] = QVariant::fromValue(2u);  // EMBEDDED = 2

    QDBusReply<QDBusObjectPath> sourceReply = portal.call(
        "SelectSources",
        QVariant::fromValue(QDBusObjectPath(QString::fromStdString(m_sessionHandle))),
        sourceOpts);
    if (!sourceReply.isValid()) {
        std::cerr << "[PipeWireCapture] SelectSources failed: "
                  << sourceReply.error().message().toStdString() << "\n";
        return false;
    }

    // Start — triggers the user consent dialog.
    // The portal Start method is async: it returns a Request object path,
    // and the real result arrives via a Response D-Bus signal.
    //
    // We use gdbus-based blocking call approach: call Start synchronously
    // with a long timeout. On many portal implementations (xdg-desktop-portal-gnome,
    // xdg-desktop-portal-kde), the D-Bus method blocks until the user accepts
    // the consent dialog, so the synchronous call works. After Start returns,
    // we call OpenPipeWireRemote to get the fd, which implicitly confirms the
    // session is ready.
    //
    // We use PW_ID_ANY for the node — when connected via the portal's fd,
    // PipeWire automatically routes to the portal's offered stream.
    QVariantMap startOpts;
    startOpts["handle_token"] = QString("sidescreen_start_%1").arg(getpid());

    // Use a long timeout (120s) to allow for the consent dialog
    portal.setTimeout(120000);
    QDBusReply<QDBusObjectPath> startReply = portal.call(
        "Start",
        QVariant::fromValue(QDBusObjectPath(QString::fromStdString(m_sessionHandle))),
        QString(""),  // parent_window
        startOpts);

    if (!startReply.isValid()) {
        std::cerr << "[PipeWireCapture] Start failed: "
                  << startReply.error().message().toStdString() << "\n";
        return false;
    }

    // The portal stream is now active. When connecting via the portal's
    // PipeWire fd (from OpenPipeWireRemote), PW_ID_ANY auto-routes to the
    // offered screen capture stream.
    m_nodeId = PW_ID_ANY;

    std::cout << "[PipeWireCapture] ScreenCast session created: "
              << m_sessionHandle << "\n";
    return true;
}

// =====================================================================
//  Portal D-Bus: openPipeWireRemote()
// =====================================================================

bool PipeWireCapture::openPipeWireRemote() {
    QDBusConnection bus = QDBusConnection::sessionBus();
    QDBusInterface portal(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.ScreenCast",
        bus);

    QVariantMap opts;
    QDBusReply<QDBusUnixFileDescriptor> reply = portal.call(
        "OpenPipeWireRemote",
        QVariant::fromValue(QDBusObjectPath(QString::fromStdString(m_sessionHandle))),
        opts);

    if (!reply.isValid()) {
        std::cerr << "[PipeWireCapture] OpenPipeWireRemote failed: "
                  << reply.error().message().toStdString() << "\n";
        return false;
    }

    int rawFd = reply.value().fileDescriptor();
    if (rawFd < 0) {
        std::cerr << "[PipeWireCapture] Invalid PipeWire fd\n";
        return false;
    }
    // dup() because QDBusUnixFileDescriptor closes rawFd when reply goes out
    // of scope, and pw_context_connect_fd() also takes ownership — double-close.
    m_pipewireFd = dup(rawFd);
    if (m_pipewireFd < 0) {
        std::cerr << "[PipeWireCapture] dup() failed for PipeWire fd\n";
        return false;
    }

    std::cout << "[PipeWireCapture] PipeWire remote fd=" << m_pipewireFd << "\n";
    return true;
}

#endif // HAS_PIPEWIRE
