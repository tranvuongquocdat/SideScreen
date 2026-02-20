import AppKit
import CoreGraphics
import CGVirtualDisplayBridge

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let processInfo = ProcessInfo.processInfo
print("========================================")
print("  SideScreen Capture API Test")
print("========================================")
print("macOS version: \(processInfo.operatingSystemVersionString)")
print("")

// MARK: - Create Virtual Display

print("--- Creating CGVirtualDisplay (1920x1200 @ 60Hz) ---")

let width: UInt32 = 1920
let height: UInt32 = 1200
let refreshRate: Double = 60.0

let descriptor = CGVirtualDisplayDescriptor()
descriptor.name = "CaptureTest Virtual Display"
descriptor.maxPixelsWide = width
descriptor.maxPixelsHigh = height

let ratio: Double = 25.4 / 110.0
descriptor.sizeInMillimeters = CGSize(
    width: Double(width) * ratio,
    height: Double(height) * ratio
)
descriptor.vendorID = 0xEEEE
descriptor.productID = UInt32(0xEEEE + Int(width) + Int(height))
descriptor.serialNum = 0x0001

guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
    print("[FAIL] Failed to create CGVirtualDisplay")
    exit(1)
}

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
let mode = CGVirtualDisplayMode(width: width, height: height, refreshRate: refreshRate)
settings.modes = [mode]

guard virtualDisplay.apply(settings) else {
    print("[FAIL] Failed to apply display settings")
    exit(1)
}

let displayID = virtualDisplay.displayID
print("[OK] Virtual display created: \(width)x\(height) @ \(Int(refreshRate))Hz (ID: \(displayID))")

// Wait for display to register with the system
print("Waiting 2s for display to register...")
Thread.sleep(forTimeInterval: 2.0)

// Verify the display is visible
let onlineDisplays = UnsafeMutablePointer<CGDirectDisplayID>.allocate(capacity: 16)
var displayCount: UInt32 = 0
CGGetOnlineDisplayList(16, onlineDisplays, &displayCount)

var found = false
for i in 0..<Int(displayCount) {
    if onlineDisplays[i] == displayID {
        found = true
        break
    }
}
onlineDisplays.deallocate()

if found {
    print("[OK] Display ID \(displayID) confirmed in online display list (\(displayCount) displays total)")
} else {
    print("[WARN] Display ID \(displayID) not found in online display list (\(displayCount) displays total)")
    print("       Tests may fail. Continuing anyway...")
}
print("")

// MARK: - Run Tests

struct TestResult {
    let name: String
    let success: Bool
    let frameCount: Int
    let elapsed: TimeInterval
    let error: String?
}

var results: [TestResult] = []

// Test 1: CGDisplayStream
print("========================================")
print("  Test 1: CGDisplayStream")
print("========================================")
let cgResult = testCGDisplayStream(displayID: displayID, timeout: 10.0)
results.append(TestResult(
    name: "CGDisplayStream",
    success: cgResult.success,
    frameCount: cgResult.frameCount,
    elapsed: cgResult.elapsed,
    error: cgResult.success ? nil : "No frames received"
))
print("")

// Test 2: AVCaptureScreenInput
print("========================================")
print("  Test 2: AVCaptureScreenInput")
print("========================================")
let avResult = testAVCaptureScreenInput(displayID: displayID, timeout: 10.0)
results.append(TestResult(
    name: "AVCaptureScreenInput",
    success: avResult.success,
    frameCount: avResult.frameCount,
    elapsed: avResult.elapsed,
    error: avResult.success ? nil : "No frames received"
))
print("")

// Test 3: SCStream
print("========================================")
print("  Test 3: SCStream (ScreenCaptureKit)")
print("========================================")
let scResult = testSCStream(displayID: displayID, timeout: 10.0)
results.append(TestResult(
    name: "SCStream",
    success: scResult.success,
    frameCount: scResult.frameCount,
    elapsed: scResult.elapsed,
    error: scResult.success ? nil : "Timeout/hang (CoreAudio deadlock?)"
))
print("")

// MARK: - Summary

print("========================================")
print("  Results Summary")
print("========================================")
print("API                      Status     Frames   Time")
print(String(repeating: "-", count: 56))

for r in results {
    let status = r.success ? "[PASS]" : "[FAIL]"
    let time = String(format: "%.2fs", r.elapsed)
    let name = r.name.padding(toLength: 24, withPad: " ", startingAt: 0)
    let st = status.padding(toLength: 10, withPad: " ", startingAt: 0)
    let fc = "\(r.frameCount)".padding(toLength: 8, withPad: " ", startingAt: 0)
    print("\(name) \(st) \(fc) \(time)")
}

print("")
print("========================================")

// Clean up
_ = virtualDisplay  // prevent early deallocation
print("Done. Exiting.")
exit(0)
