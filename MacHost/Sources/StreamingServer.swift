import Foundation
import Network

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    var onClientConnected: (() -> Void)?
    var onTouchEvent: ((Float, Float, Int) -> Void)?
    var onStats: ((Double, Double) -> Void)?

    private let frameQueue = DispatchQueue(label: "frameQueue", qos: .userInteractive)
    private let receiveQueue = DispatchQueue(label: "receiveQueue", qos: .userInteractive)
    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var lastStatsTime = Date()
    private var displayWidth = 1920
    private var displayHeight = 1080
    private var rotation = 0
    private var isReceiving = false

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

            listener?.newConnectionHandler = { [weak self] newConnection in
                self?.handleConnection(newConnection)
            }

            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("✅ TCP Server listening on port \(self.port)")
                    print("💡 Run on tablet: adb reverse tcp:\(self.port) tcp:\(self.port)")
                case .failed(let error):
                    print("❌ Server failed: \(error)")
                default:
                    break
                }
            }

            listener?.start(queue: .main)
        } catch {
            print("❌ Failed to start server: \(error)")
        }
    }

    private func handleConnection(_ newConnection: NWConnection) {
        print("🔌 New connection incoming...")
        connection?.cancel()
        connection = newConnection

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
            case .cancelled:
                print("⚠️  Connection cancelled")
            default:
                break
            }
        }

        connection?.start(queue: .main)
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
        print("👆 Starting touch receive loop on dedicated queue...")
        receiveQueue.async { [weak self] in
            self?.receiveNextTouch()
        }
    }

    private func receiveNextTouch() {
        guard let connection = connection else {
            isReceiving = false
            return
        }

        // Touch: 13 bytes (1 type + 4 x + 4 y + 4 action)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 13) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil || isComplete {
                self.isReceiving = false
                return
            }

            if let data = data, data.count >= 13, data[0] == 2 {
                let x = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 1, as: Float.self) }
                let y = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5, as: Float.self) }
                let action = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 9, as: Int32.self) }

                DispatchQueue.main.async {
                    self.onTouchEvent?(x, y, Int(action))
                }
            }

            self.receiveQueue.async {
                self.receiveNextTouch()
            }
        }
    }

    func sendFrame(_ data: Data) {
        guard let connection = connection else { return }

        frameQueue.async { [weak self] in
            // Pre-allocate packet buffer for better performance
            var packet = Data(capacity: data.count + 5)
            packet.append(0) // Type: Video frame
            var frameSize = Int32(data.count).bigEndian
            packet.append(Data(bytes: &frameSize, count: 4))
            packet.append(data)

            // Use .idempotent for fire-and-forget sending (lowest latency)
            connection.send(content: packet, completion: .idempotent)

            self?.updateStats(bytes: data.count)
        }
    }

    private func updateStats(bytes: Int) {
        bytesSent += UInt64(bytes)
        frameCount += 1

        let now = Date()
        let elapsed = now.timeIntervalSince(lastStatsTime)

        if elapsed >= 2.0 { // Print stats every 2 seconds
            let mbps = Double(bytesSent * 8) / elapsed / 1_000_000
            let fps = Double(frameCount) / elapsed
            onStats?(fps, mbps) // print("📊 Stats: \(String(format: "%.2f", fps)) fps, \(String(format: "%.2f", mbps)) Mbps")

            bytesSent = 0
            frameCount = 0
            lastStatsTime = now
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
    }
}
