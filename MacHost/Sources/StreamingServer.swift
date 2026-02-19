import Foundation
import Network

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?
    var onTouchEvent: ((Float, Float, Int) -> Void)?
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

    // Frame dropping for latency control
    // 50ms frame age - balanced with client's 60ms tolerance
    // Lower = less latency, but may drop more P-frames during encoding spikes
    private let maxFrameAge: UInt64 = 50_000_000  // 50ms in nanoseconds - drop older frames
    private var canSendNextFrame = true  // Simple backpressure

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
        canSendNextFrame = true
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

        // Touch: 13 bytes (1 type + 4 x + 4 y + 4 action)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 13) { [weak self] data, _, isComplete, error in
            guard let self = self, self.isReceiving, !self.isStopped else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                return
            }

            if let data = data, data.count >= 13, data[0] == 2 {
                let x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: Float.self) }
                let y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: Float.self) }
                let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: Int32.self) }

                // Dispatch to main thread for event handling
                DispatchQueue.main.async {
                    self.onTouchEvent?(x, y, Int(action))
                }
            }

            // Continue loop (non-recursive)
            self.receiveQueue.async {
                self.touchReceiveLoop()
            }
        }
    }

    func sendFrame(_ data: Data, timestamp: UInt64, isKeyframe: Bool = false) {
        guard let connection = connection, !isStopped else { return }

        // GOP-aware frame dropping: NEVER drop keyframes
        if !isKeyframe {
            let now = DispatchTime.now().uptimeNanoseconds
            let frameAge = now - timestamp
            if frameAge > maxFrameAge {
                droppedFrames += 1
                return
            }
        }

        frameQueue.async { [weak self] in
            guard let self = self else { return }

            // Backpressure check inside frameQueue for thread safety
            if !isKeyframe && !self.canSendNextFrame {
                self.droppedFrames += 1
                return
            }

            var packet = Data(capacity: data.count + 5)
            packet.append(0) // Type: Video frame
            var frameSize = Int32(data.count).bigEndian
            withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
            packet.append(data)

            self.canSendNextFrame = false

            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                self?.frameQueue.async {
                    self?.canSendNextFrame = true
                }
                if error != nil {
                    self?.droppedFrames += 1
                }
            })

            self.updateStats(bytes: data.count)
        }
    }

    private func updateStats(bytes: Int) {
        bytesSent += UInt64(bytes)
        frameCount += 1

        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastStatsTime.uptimeNanoseconds) / 1_000_000_000

        if elapsed >= 1.0 {  // Update stats every 1 second for more responsive display
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps)

            if droppedFrames > 0 {
                print("⚠️ Dropped \(droppedFrames) frames in last interval")
            }

            bytesSent = 0
            frameCount = 0
            droppedFrames = 0
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
