import Foundation
import Network
import XCTest
@testable import SideScreen

final class StreamingServerStartupTests: XCTestCase {
    private enum TestError: Error, Equatable {
        case first
        case second
    }

    func testStartupGateKeepsFirstResultBeforeWaiterArrives() async throws {
        let gate = ListenerStartupGate()

        gate.resolve(.success(()))
        gate.resolve(.failure(TestError.second))

        try await gate.wait()
    }

    func testStartupGateResumesWaiterOnlyOnceWithFirstFailure() async {
        let gate = ListenerStartupGate()
        let waiter = Task {
            try await gate.wait()
        }

        await Task.yield()
        gate.resolve(.failure(TestError.first))
        gate.resolve(.success(()))

        do {
            try await waiter.value
            XCTFail("Expected the first startup result to win")
        } catch {
            XCTAssertEqual(error as? TestError, .first)
        }
    }

    func testStartupGateCancellationResumesWaiter() async {
        let gate = ListenerStartupGate()
        let waiter = Task {
            try await gate.wait()
        }

        await Task.yield()
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("Expected cancellation to end the startup wait")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testStartupGateTimeoutPreservesLastWaitingError() async {
        let gate = ListenerStartupGate()
        gate.noteWaitingError(NWError.posix(.ENETDOWN))
        gate.resolveTimeout(port: 54_321)

        do {
            try await gate.wait()
            XCTFail("Expected startup to time out")
        } catch let error as StreamingServerStartError {
            guard case .startupTimedOut(let port, let lastWaitingError) = error else {
                return XCTFail("Expected startupTimedOut, got \(error)")
            }
            XCTAssertEqual(port, 54_321)
            guard let networkError = lastWaitingError as? NWError,
                  case .posix(.ENETDOWN) = networkError else {
                return XCTFail("Expected the last waiting error to be preserved")
            }
        } catch {
            XCTFail("Expected StreamingServerStartError, got \(error)")
        }
    }

    func testStartReturnsOnlyAfterListenerIsReady() async throws {
        let server = StreamingServer(port: 0)
        defer { server.stop() }

        try await server.start()
        XCTAssertNotNil(server.boundPort)
    }

    func testStartPropagatesPortConflict() async throws {
        let blocker = try NWListener(
            using: .tcp,
            on: NWEndpoint.Port(integerLiteral: 0)
        )
        let blockerGate = ListenerStartupGate()
        blocker.stateUpdateHandler = { state in
            switch state {
            case .ready:
                blockerGate.resolve(.success(()))
            case .failed(let error):
                blockerGate.resolve(.failure(error))
            case .cancelled:
                blockerGate.resolve(.failure(CancellationError()))
            default:
                break
            }
        }
        blocker.newConnectionHandler = { connection in
            connection.cancel()
        }
        blocker.start(queue: DispatchQueue(label: "StreamingServerStartupTests.blocker"))
        defer { blocker.cancel() }
        try await blockerGate.wait()

        guard let occupiedPort = blocker.port?.rawValue else {
            return XCTFail("Ready listener did not expose its assigned port")
        }

        let server = StreamingServer(port: occupiedPort)
        defer { server.stop() }
        let startTime = Date()

        do {
            try await server.start()
            XCTFail("Expected startup to fail while another listener owns the port")
        } catch let error as StreamingServerStartError {
            guard case .listenerFailed(let port, _) = error else {
                return XCTFail("Expected listenerFailed, got \(error)")
            }
            XCTAssertEqual(port, occupiedPort)
            XCTAssertTrue(error.localizedDescription.contains(String(occupiedPort)))
            XCTAssertLessThan(Date().timeIntervalSince(startTime), 2)
        } catch {
            XCTFail("Expected StreamingServerStartError, got \(error)")
        }
    }

    func testStopReleasesPortForFreshServer() async throws {
        let firstServer = StreamingServer(port: 0)
        try await firstServer.start()
        guard let port = firstServer.boundPort else {
            firstServer.stop()
            return XCTFail("Ready listener did not expose its assigned port")
        }
        firstServer.stop()

        let deadline = Date().addingTimeInterval(2)
        var lastError: Error?
        repeat {
            let restartedServer = StreamingServer(port: port)
            do {
                try await restartedServer.start(startupTimeout: 0.5)
                restartedServer.stop()
                return
            } catch {
                restartedServer.stop()
                lastError = error
                guard isAddressInUse(error), Date() < deadline else {
                    return XCTFail("Could not restart on released port \(port): \(error)")
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } while Date() < deadline

        XCTFail("Port \(port) was not released in time: \(String(describing: lastError))")
    }

    private func isAddressInUse(_ error: Error) -> Bool {
        guard let startError = error as? StreamingServerStartError,
              case .listenerFailed(_, let underlying) = startError,
              let networkError = underlying as? NWError,
              case .posix(.EADDRINUSE) = networkError else {
            return false
        }
        return true
    }
}
