import Foundation
import Network

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    // Touch callback: (x1, y1, action, pointerCount, x2, y2)
    var onTouchEvent: ((Float, Float, Int, Int, Float, Float) -> Void)?
    var onStats: ((Double, Double) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private let networkQueue = DispatchQueue(label: "networkQueue", qos: .userInteractive)
    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var droppedFrames: UInt64 = 0
    private var lastStatsTime = DispatchTime.now()
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var isReceiving = false
    private var isStopped = false

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        isStopped = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            // Optimize TCP for low-latency streaming
            if let tcpOptions = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcpOptions.noDelay = true  // Disable Nagle's algorithm
                tcpOptions.enableFastOpen = true
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("✅ TCP Server listening on port \(self.port)")
                case .failed(let error):
                    print("❌ Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.start(queue: networkQueue)
        } catch {
            print("❌ Failed to start server: \(error)")
        }
    }

    private func handleConnection(_ newConnection: NWConnection) {
        print("🔌 New connection incoming...")

        // Clean up old connection properly
        if let oldConnection = connection {
            isReceiving = false
            oldConnection.cancel()
        }

        connection = newConnection
        droppedFrames = 0

        connection?.stateUpdateHandler = { [weak self] state in
            print("🔌 Connection state: \(state)")
            switch state {
            case .ready:
                print("✅ Client connected - starting touch receive")
                self?.sendDisplaySize()
                self?.onClientConnected?()
                self?.startReceivingTouch()
            case .failed(let error):
                print("❌ Connection failed: \(error)")
                self?.onClientDisconnected?()
            case .cancelled:
                print("⚠️  Connection cancelled")
                self?.onClientDisconnected?()
            default:
                break
            }
        }

        connection?.start(queue: networkQueue)
    }

    func setDisplaySize(width: Int, height: Int, rotation: Int = 0) {
        displayWidth = width
        displayHeight = height
        self.rotation = rotation
    }

    /// Update rotation and send to connected client
    func updateRotation(_ rotation: Int) {
        self.rotation = rotation
        sendDisplaySize() // Re-send display config with new rotation
    }

    func sendDisplaySize() {
        guard let connection = connection else { return }

        var data = Data()
        data.append(1) // Type: Display size + rotation
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(rotation).bigEndian) { Data($0) })

        connection.send(content: data, completion: .contentProcessed { _ in })
        print("📐 Sent display config: \(displayWidth)x\(displayHeight) @ \(rotation)°")
    }

    private func startReceivingTouch() {
        guard !isReceiving else {
            print("⚠️ Already receiving touch events")
            return
        }
        isReceiving = true
        print("👆 Starting touch receive loop...")

        // Use loop-based pattern instead of recursion to prevent stack overflow
        receiveQueue.async { [weak self] in
            self?.touchReceiveLoop()
        }
    }

    private func touchReceiveLoop() {
        guard let connection = connection, isReceiving, !isStopped else {
            isReceiving = false
            return
        }

        // New format: 1 type + 1 pointerCount + N*(4x+4y) + 4 action
        // 1 finger: 14 bytes, 2 fingers: 22 bytes
        connection.receive(minimumIncompleteLength: 2, maximumLength: 22) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isReceiving, !self.isStopped else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                return
            }

            if let data = data, data.count >= 1 {
                let msgType = data[0]

                if msgType == 2 && data.count >= 2 {
                    // Touch event
                    let pointerCount = Int(data[1])
                    let expectedSize = 2 + pointerCount * 8 + 4

                    if data.count >= expectedSize {
                        let x1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: Float.self) }
                        let y1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 6, as: Float.self) }

                        var x2: Float = 0
                        var y2: Float = 0
                        if pointerCount >= 2 {
                            x2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 10, as: Float.self) }
                            y2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: Float.self) }
                        }

                        let actionOffset = 2 + pointerCount * 8
                        let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: actionOffset, as: Int32.self) }

                        DispatchQueue.main.async {
                            self.onTouchEvent?(x1, y1, Int(action), pointerCount, x2, y2)
                        }
                    }
                } else if msgType == 4 && data.count >= 9 {
                    // Ping from client — echo back as pong (type=5) with client's timestamp
                    let clientTimestamp = data.subdata(in: 1..<9)
                    var pong = Data(capacity: 9)
                    pong.append(5) // Type: Pong
                    pong.append(clientTimestamp)
                    connection.send(content: pong, completion: .contentProcessed { _ in })
                }
            }

            self.receiveQueue.async {
                self.touchReceiveLoop()
            }
        }
    }

    func sendFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool = false) {
        guard let connection = connection, !isStopped else { return }

        // With all-intra encoding, every frame is independently decodable.
        // No frame-age dropping or backpressure — send everything immediately.
        // The encode queue depth limit (2 pending) in ScreenCapture handles flow control.
        frameQueue.async { [weak self] in
            guard let self = self else { return }

            var packet = Data(capacity: data.count + 5)
            packet.append(0) // Type: Video frame
            var frameSize = Int32(data.count).bigEndian
            withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
            packet.append(data)

            connection.send(content: packet, completion: .contentProcessed { error in
                if error != nil {
                    self.droppedFrames += 1
                }
            })

            // Track frame age at send time for pipeline profiling
            let sendAge = DispatchTime.now().uptimeNanoseconds - timestamp
            self.updateStats(bytes: data.count, frameAgeNs: sendAge)
        }
    }

    // Pipeline profiling: track frame age at send time
    private var totalFrameAgeNs: UInt64 = 0
    private var profiledFrameCount: UInt64 = 0

    private func updateStats(bytes: Int, frameAgeNs: UInt64 = 0) {
        bytesSent += UInt64(bytes)
        frameCount += 1
        if frameAgeNs > 0 {
            totalFrameAgeNs += frameAgeNs
            profiledFrameCount += 1
        }

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed >= 1.0 {
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps)

            // Log pipeline latency profile
            if profiledFrameCount > 0 {
                let avgAgeMs = Double(totalFrameAgeNs) / Double(profiledFrameCount) / 1_000_000.0
                print("📊 Pipeline: \(String(format: "%.1f", fps))fps, \(String(format: "%.1f", mbps))Mbps, avg frame age: \(String(format: "%.1f", avgAgeMs))ms, dropped: \(droppedFrames)")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
            totalFrameAgeNs = 0
            profiledFrameCount = 0
            lastStatsTime = now
        }
    }

    func stop() {
        isStopped = true
        isReceiving = false

        // Wait for pending operations before cancelling
        frameQueue.sync {}
        receiveQueue.sync {}

        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }
}
