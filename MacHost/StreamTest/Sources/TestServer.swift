import Foundation
import Network

/// Minimal TCP server that matches SideScreen's protocol exactly
/// Protocol:
///   Display config: [type=1][width:4B BE][height:4B BE][rotation:4B BE]
///   Video metadata: [type=6][size:4B BE][flags:1B][timestamp:8B BE][H.265 data]
class TestServer {
    private let port: UInt16
    private var listener: NWListener?
    private var connection: NWConnection?
    private let networkQueue = DispatchQueue(label: "testserver.network", qos: .userInteractive)
    private let sendQueue = DispatchQueue(label: "testserver.send", qos: .userInteractive)
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    private(set) var isClientConnected = false
    private var framesSent: UInt64 = 0
    private var bytesSent: UInt64 = 0
    private var framesDropped: UInt64 = 0
    private var canSendNext = true

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                tcp.noDelay = true
                tcp.enableFastOpen = true
            }

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }
            listener?.stateUpdateHandler = { state in
                if case .ready = state {
                    print("[OK] TCP server listening on port \(self.port)")
                    print("     Run: adb reverse tcp:\(self.port) tcp:\(self.port)")
                }
            }
            listener?.start(queue: networkQueue)
        } catch {
            print("[FAIL] Server start error: \(error)")
        }
    }

    private func handleConnection(_ newConnection: NWConnection) {
        if let old = connection {
            old.cancel()
        }
        connection = newConnection
        canSendNext = true
        framesSent = 0
        bytesSent = 0
        framesDropped = 0
        isClientConnected = false

        newConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("[OK] Client connected!")
                self?.finishClientStartup(on: newConnection)
            case .failed, .cancelled:
                print("[INFO] Client disconnected")
                self?.isClientConnected = false
                self?.onClientDisconnected?()
            default: break
            }
        }
        newConnection.start(queue: networkQueue)
    }

    private func finishClientStartup(on conn: NWConnection) {
        guard connection === conn, !isClientConnected else { return }
        print("[OK] Frame metadata: enabled")
        onClientConnected?()
        isClientConnected = true
    }

    /// Send display size config (must be sent before frames)
    func sendDisplaySize(width: Int, height: Int, rotation: Int = 0) {
        guard let connection = connection else { return }
        var data = Data()
        data.append(1)  // type = display config
        data.append(contentsOf: withUnsafeBytes(of: Int32(width).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(height).bigEndian) { Data($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(rotation).bigEndian) { Data($0) })
        connection.send(content: data, completion: .contentProcessed { _ in })
        print("[OK] Sent display config: \(width)x\(height) @ \(rotation) deg")
    }

    /// Send a video frame (same protocol as SideScreen)
    func sendFrame(_ data: Data, isKeyframe: Bool) {
        guard let connection = connection, isClientConnected else { return }

        sendQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.isClientConnected else { return }

            // Simple backpressure - but NEVER drop keyframes
            if !isKeyframe && !self.canSendNext {
                self.framesDropped += 1
                return
            }

            let packet = self.makeFramePacket(data, isKeyframe: isKeyframe)

            self.canSendNext = false
            connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                self?.sendQueue.async {
                    self?.canSendNext = true
                }
                if error != nil {
                    self?.framesDropped += 1
                }
            })

            self.framesSent += 1
            self.bytesSent += UInt64(data.count)
        }
    }

    func printStats() {
        print("  Frames sent: \(framesSent), dropped: \(framesDropped), bytes: \(bytesSent / 1024)KB")
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
    }

    private func makeFramePacket(_ data: Data, isKeyframe: Bool) -> Data {
        var packet = Data(capacity: data.count + 14)
        packet.append(6)  // type = video frame with metadata
        appendFrameSize(data.count, to: &packet)
        packet.append(isKeyframe ? 1 : 0)
        var timestamp = DispatchTime.now().uptimeNanoseconds.bigEndian
        withUnsafeBytes(of: &timestamp) { packet.append(contentsOf: $0) }
        packet.append(data)
        return packet
    }

    private func appendFrameSize(_ size: Int, to packet: inout Data) {
        var frameSize = Int32(size).bigEndian
        withUnsafeBytes(of: &frameSize) { packet.append(contentsOf: $0) }
    }
}
