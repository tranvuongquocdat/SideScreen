import Foundation
import Network

class StreamingServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    var onClientConnected: (() -> Void)?
    var onTouchEvent: ((Float, Float, Int) -> Void)?

    var onStats: ((Double, Double) -> Void)?
    private var frameQueue = DispatchQueue(label: "com.virtualDisplay.frameQueue", qos: .userInteractive)
    private var bytesSent: UInt64 = 0
    private var frameCount: UInt64 = 0
    private var lastStatsTime = Date()
    private var displayWidth: Int = 1920
    private var displayHeight: Int = 1080

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
        connection?.cancel()
        connection = newConnection

        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("✅ Client connected")
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

    func setDisplaySize(width: Int, height: Int) {
        displayWidth = width
        displayHeight = height
    }

    private func sendDisplaySize() {
        guard let connection = connection else { return }

        var data = Data()
        data.append(1) // Type: Display size
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayWidth).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(displayHeight).bigEndian) { Data($0) })

        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func startReceivingTouch() {
        receiveNextTouch()
    }

    private func receiveNextTouch() {
        guard let connection = connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, isComplete, error in
            guard let self = self, let data = data, !isComplete, error == nil else { return }

            if data[0] == 2 { // Touch event
                connection.receive(minimumIncompleteLength: 12, maximumLength: 12) { touchData, _, _, _ in
                    guard let touchData = touchData, touchData.count == 12 else {
                        self.receiveNextTouch()
                        return
                    }

                    let x = touchData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float32.self) }
                    let y = touchData.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Float32.self) }
                    let action = touchData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }

                    self.onTouchEvent?(x, y, Int(action))
                    self.receiveNextTouch()
                }
            } else {
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
