# Capture API Test Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a standalone .app that tests 3 capture APIs (CGDisplayStream, AVCaptureScreenInput, SCStream) against a CGVirtualDisplay to find which one works on macOS 26.2 with virtual audio drivers.

**Architecture:** Standalone Swift Package at `MacHost/CaptureTest/` that creates a virtual display, tests each capture API with a 10s timeout, reports results. Built as .app bundle for TCC compatibility.

**Tech Stack:** Swift 5.9, CoreGraphics (CGDisplayStream), AVFoundation (AVCaptureScreenInput), ScreenCaptureKit (SCStream), CGVirtualDisplay private API

---

### Task 1: Project scaffold and build script

**Files:**
- Create: `MacHost/CaptureTest/Package.swift`
- Create: `MacHost/CaptureTest/Sources/main.swift` (stub)
- Create: `MacHost/CaptureTest/Sources/CGVirtualDisplayBridge.h` (copy)
- Create: `MacHost/CaptureTest/Sources/module.modulemap` (copy)
- Create: `MacHost/CaptureTest/build.sh`
- Create: `MacHost/CaptureTest/CaptureTest.entitlements`

**Step 1: Create directory structure**

```bash
mkdir -p "/Users/dat_macbook/Documents/2025/ý tưởng mới/Side_Screen/SideScreen/MacHost/CaptureTest/Sources"
```

**Step 2: Create Package.swift**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureTest",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CaptureTest", targets: ["CaptureTest"])
    ],
    targets: [
        .executableTarget(
            name: "CaptureTest",
            dependencies: [],
            path: "Sources",
            cSettings: [
                .unsafeFlags(["-I", "Sources"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/module.modulemap"])
            ])
    ]
)
```

**Step 3: Copy bridge header and module map from MacHost**

Copy `MacHost/Sources/CGVirtualDisplayBridge.h` → `MacHost/CaptureTest/Sources/CGVirtualDisplayBridge.h`
Copy `MacHost/Sources/module.modulemap` → `MacHost/CaptureTest/Sources/module.modulemap`

**Step 4: Create entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
```

**Step 5: Create build.sh**

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building CaptureTest..."
pkill -f CaptureTest 2>/dev/null || true
sleep 0.3

swift build -c release 2>&1

APP_DIR="$SCRIPT_DIR/CaptureTest.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp .build/release/CaptureTest "$APP_DIR/Contents/MacOS/"

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CaptureTest</string>
    <key>CFBundleIdentifier</key>
    <string>com.sidescreen.capturetest</string>
    <key>CFBundleName</key>
    <string>CaptureTest</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>CaptureTest needs screen recording to test capture APIs on virtual display.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - --entitlements "$SCRIPT_DIR/CaptureTest.entitlements" "$APP_DIR"
echo ""
echo "Build OK: $APP_DIR"
echo "Run: open CaptureTest.app"
```

**Step 6: Create stub main.swift**

```swift
import Foundation
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("CaptureTest stub - build OK")
exit(0)
```

**Step 7: Build and verify**

Run: `bash MacHost/CaptureTest/build.sh`
Expected: Build succeeds, CaptureTest.app created

**Step 8: Commit**

```bash
git add MacHost/CaptureTest/
git commit -m "feat: scaffold CaptureTest standalone package"
```

---

### Task 2: Virtual display creation

**Files:**
- Modify: `MacHost/CaptureTest/Sources/main.swift`

**Step 1: Write main.swift with virtual display creation**

```swift
import Foundation
import AppKit
import CoreGraphics
import CGVirtualDisplayBridge

// NSApplication required for CGVirtualDisplay and TCC
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

print("=== CaptureTest: macOS Screen Capture API Comparison ===")
print("macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("")

// Create virtual display
print("[Setup] Creating virtual display 1920x1200 @ 60Hz...")
let descriptor = CGVirtualDisplayDescriptor()
descriptor.name = "CaptureTest Display"
descriptor.maxPixelsWide = 1920
descriptor.maxPixelsHigh = 1200
descriptor.sizeInMillimeters = CGSize(width: 443, height: 277) // ~110 PPI
descriptor.productID = 0xFFFF
descriptor.vendorID = 0xEEEE
descriptor.serialNum = 0x0001

guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
    print("❌ Failed to create virtual display")
    exit(1)
}

let settings = CGVirtualDisplaySettings()
settings.hiDPI = 0
let mode = CGVirtualDisplayMode(width: 1920, height: 1200, refreshRate: 60.0)
settings.modes = [mode]

guard virtualDisplay.apply(settings) else {
    print("❌ Failed to apply display settings")
    exit(1)
}

let displayID = virtualDisplay.displayID
print("✅ Virtual display created: ID=\(displayID), 1920x1200 @ 60Hz")
print("")

// Wait for display to register
print("[Setup] Waiting 2s for display to register...")
Thread.sleep(forTimeInterval: 2.0)

// TODO: Run capture tests here
print("[TODO] Capture tests not yet implemented")

// Cleanup
print("")
print("[Cleanup] Destroying virtual display...")
// virtualDisplay goes out of scope → destroyed
print("Done.")
exit(0)
```

**Step 2: Build and verify**

Run: `bash MacHost/CaptureTest/build.sh && open MacHost/CaptureTest/CaptureTest.app`
Expected: "Virtual display created: ID=XX" printed, app exits cleanly

Note: Run from Terminal to see stdout: `MacHost/CaptureTest/CaptureTest.app/Contents/MacOS/CaptureTest`

**Step 3: Commit**

```bash
git add MacHost/CaptureTest/Sources/main.swift
git commit -m "feat: add virtual display creation to CaptureTest"
```

---

### Task 3: CGDisplayStream test

**Files:**
- Create: `MacHost/CaptureTest/Sources/TestCGDisplayStream.swift`
- Modify: `MacHost/CaptureTest/Sources/main.swift` (call test)

**Step 1: Write TestCGDisplayStream.swift**

```swift
import Foundation
import CoreGraphics

func testCGDisplayStream(displayID: CGDirectDisplayID, timeout: TimeInterval = 10.0) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    print("[Test CGDisplayStream] Starting...")

    let startTime = CFAbsoluteTimeGetCurrent()
    var frameCount = 0
    let targetFrames = 5
    let semaphore = DispatchSemaphore(value: 0)

    let width = Int(CGDisplayPixelsWide(displayID))
    let height = Int(CGDisplayPixelsHigh(displayID))
    print("  Display size: \(width)x\(height)")

    let properties: [CFString: Any] = [
        CGDisplayStream.minimumFrameTime: 1.0 / 60.0,
        CGDisplayStream.queueDepth: 3
    ] as [CFString: Any]

    let streamQueue = DispatchQueue(label: "cgdisplaystream.test")

    guard let stream = CGDisplayStream(
        displayID: displayID,
        outputWidth: width,
        outputHeight: height,
        pixelFormat: Int32(kCVPixelFormatType_32BGRA),
        properties: properties as CFDictionary,
        queue: streamQueue,
        handler: { status, displayTime, frameSurface, updateRef in
            if status == .frameComplete, frameSurface != nil {
                frameCount += 1
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                print("  Frame \(frameCount): \(String(format: "%.1f", elapsed))s")
                if frameCount >= targetFrames {
                    semaphore.signal()
                }
            } else if status == .stopped {
                print("  Stream stopped")
            }
        }
    ) else {
        print("  ❌ Failed to create CGDisplayStream")
        return (false, 0, CFAbsoluteTimeGetCurrent() - startTime)
    }

    let startResult = stream.start()
    if startResult != .success {
        print("  ❌ Failed to start: \(startResult)")
        return (false, 0, CFAbsoluteTimeGetCurrent() - startTime)
    }

    print("  Stream started, waiting for \(targetFrames) frames...")
    let result = semaphore.wait(timeout: .now() + timeout)

    stream.stop()
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    if result == .timedOut {
        print("  ❌ Timed out after \(Int(timeout))s (got \(frameCount) frames)")
        return (false, frameCount, elapsed)
    }

    print("  ✅ Captured \(frameCount) frames in \(String(format: "%.1f", elapsed))s")
    return (true, frameCount, elapsed)
}
```

**Step 2: Add call in main.swift**

Add before `// TODO: Run capture tests here`:

```swift
// Test 1: CGDisplayStream
let cgResult = testCGDisplayStream(displayID: displayID)
print("")
```

**Step 3: Build and run**

Run: `bash MacHost/CaptureTest/build.sh && MacHost/CaptureTest/CaptureTest.app/Contents/MacOS/CaptureTest`
Expected: Either captures 5 frames or times out with clear error message

**Step 4: Commit**

```bash
git add MacHost/CaptureTest/Sources/
git commit -m "feat: add CGDisplayStream capture test"
```

---

### Task 4: AVCaptureScreenInput test

**Files:**
- Create: `MacHost/CaptureTest/Sources/TestAVCapture.swift`
- Modify: `MacHost/CaptureTest/Sources/main.swift` (call test)

**Step 1: Write TestAVCapture.swift**

```swift
import Foundation
import AVFoundation

class AVCaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var frameCount = 0
    var targetFrames = 5
    var semaphore: DispatchSemaphore
    var startTime: CFAbsoluteTime

    init(semaphore: DispatchSemaphore, startTime: CFAbsoluteTime) {
        self.semaphore = semaphore
        self.startTime = startTime
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  Frame \(frameCount): \(String(format: "%.1f", elapsed))s")
        if frameCount >= targetFrames {
            semaphore.signal()
        }
    }
}

func testAVCaptureScreenInput(displayID: CGDirectDisplayID, timeout: TimeInterval = 10.0) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    print("[Test AVCaptureScreenInput] Starting...")

    let startTime = CFAbsoluteTimeGetCurrent()
    let semaphore = DispatchSemaphore(value: 0)
    let delegate = AVCaptureDelegate(semaphore: semaphore, startTime: startTime)

    let session = AVCaptureSession()

    guard let screenInput = AVCaptureScreenInput(displayID: displayID) else {
        print("  ❌ Failed to create AVCaptureScreenInput")
        return (false, 0, CFAbsoluteTimeGetCurrent() - startTime)
    }

    screenInput.minFrameDuration = CMTime(value: 1, timescale: 60)

    guard session.canAddInput(screenInput) else {
        print("  ❌ Cannot add screen input to session")
        return (false, 0, CFAbsoluteTimeGetCurrent() - startTime)
    }
    session.addInput(screenInput)

    let videoOutput = AVCaptureVideoDataOutput()
    let captureQueue = DispatchQueue(label: "avcapture.test")
    videoOutput.setSampleBufferDelegate(delegate, queue: captureQueue)

    guard session.canAddOutput(videoOutput) else {
        print("  ❌ Cannot add video output to session")
        return (false, 0, CFAbsoluteTimeGetCurrent() - startTime)
    }
    session.addOutput(videoOutput)

    print("  Starting capture session...")
    session.startRunning()

    print("  Waiting for 5 frames...")
    let result = semaphore.wait(timeout: .now() + timeout)

    session.stopRunning()
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    if result == .timedOut {
        print("  ❌ Timed out after \(Int(timeout))s (got \(delegate.frameCount) frames)")
        return (false, delegate.frameCount, elapsed)
    }

    print("  ✅ Captured \(delegate.frameCount) frames in \(String(format: "%.1f", elapsed))s")
    return (true, delegate.frameCount, elapsed)
}
```

**Step 2: Add call in main.swift**

After CGDisplayStream test:

```swift
// Test 2: AVCaptureScreenInput
let avResult = testAVCaptureScreenInput(displayID: displayID)
print("")
```

**Step 3: Build and run**

Run: `bash MacHost/CaptureTest/build.sh && MacHost/CaptureTest/CaptureTest.app/Contents/MacOS/CaptureTest`
Expected: Either captures 5 frames or times out

**Step 4: Commit**

```bash
git add MacHost/CaptureTest/Sources/
git commit -m "feat: add AVCaptureScreenInput capture test"
```

---

### Task 5: SCStream test (baseline)

**Files:**
- Create: `MacHost/CaptureTest/Sources/TestSCStream.swift`
- Modify: `MacHost/CaptureTest/Sources/main.swift` (call test + summary)

**Step 1: Write TestSCStream.swift**

```swift
import Foundation
import ScreenCaptureKit
import CoreMedia

class SCStreamTestOutput: NSObject, SCStreamOutput {
    var frameCount = 0
    var targetFrames = 5
    var semaphore: DispatchSemaphore
    var startTime: CFAbsoluteTime

    init(semaphore: DispatchSemaphore, startTime: CFAbsoluteTime) {
        self.semaphore = semaphore
        self.startTime = startTime
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        frameCount += 1
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  Frame \(frameCount): \(String(format: "%.1f", elapsed))s")
        if frameCount >= targetFrames {
            semaphore.signal()
        }
    }
}

func testSCStream(displayID: CGDirectDisplayID, timeout: TimeInterval = 10.0) -> (success: Bool, frameCount: Int, elapsed: TimeInterval) {
    print("[Test SCStream] Starting...")
    print("  (Expected to hang due to CoreAudio HAL deadlock)")

    let startTime = CFAbsoluteTimeGetCurrent()
    let semaphore = DispatchSemaphore(value: 0)
    let output = SCStreamTestOutput(semaphore: semaphore, startTime: startTime)

    // SCStream init must be on background thread (blocks on CoreAudio HAL)
    var initSuccess = false
    let initSemaphore = DispatchSemaphore(value: 0)

    DispatchQueue.global(qos: .userInitiated).async {
        // First find the display in SCShareableContent
        let contentSem = DispatchSemaphore(value: 0)
        var scDisplay: SCDisplay?

        SCShareableContent.getShareableContent(excludingDesktopWindows: false, onScreenWindowsOnly: false) { content, error in
            if let content = content {
                scDisplay = content.displays.first(where: { $0.displayID == displayID })
            }
            contentSem.signal()
        }

        let contentResult = contentSem.wait(timeout: .now() + 5.0)
        if contentResult == .timedOut || scDisplay == nil {
            print("  ❌ Could not find display in SCShareableContent")
            initSemaphore.signal()
            return
        }

        print("  Found display, creating SCStream (may block on CoreAudio)...")

        let filter = SCContentFilter(display: scDisplay!, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = scDisplay!.width
        config.height = scDisplay!.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        config.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        print("  SCStream created!")

        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            print("  Stream output added, starting capture...")

            stream.startCapture { error in
                if let error = error {
                    print("  ❌ startCapture failed: \(error)")
                } else {
                    print("  Capture started!")
                    initSuccess = true
                }
                initSemaphore.signal()
            }
        } catch {
            print("  ❌ addStreamOutput failed: \(error)")
            initSemaphore.signal()
        }
    }

    // Wait for init (may never complete if CoreAudio hangs)
    let initResult = initSemaphore.wait(timeout: .now() + timeout)

    if initResult == .timedOut {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        print("  ❌ SCStream init timed out after \(Int(timeout))s (CoreAudio HAL stuck)")
        return (false, 0, elapsed)
    }

    if !initSuccess {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        return (false, 0, elapsed)
    }

    // Wait for frames
    let frameResult = semaphore.wait(timeout: .now() + timeout)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime

    if frameResult == .timedOut {
        print("  ❌ Frame capture timed out (got \(output.frameCount) frames)")
        return (false, output.frameCount, elapsed)
    }

    print("  ✅ Captured \(output.frameCount) frames in \(String(format: "%.1f", elapsed))s")
    return (true, output.frameCount, elapsed)
}
```

**Step 2: Update main.swift with SCStream test + results summary**

Replace `// TODO: Run capture tests here` and everything after with:

```swift
// === Run Tests ===

// Test 1: CGDisplayStream
let cgResult = testCGDisplayStream(displayID: displayID)
print("")

// Test 2: AVCaptureScreenInput
let avResult = testAVCaptureScreenInput(displayID: displayID)
print("")

// Test 3: SCStream
let scResult = testSCStream(displayID: displayID)
print("")

// === Results Summary ===
print("=" * 50 is not valid Swift, use String(repeating:))
let separator = String(repeating: "=", count: 50)
print(separator)
print("RESULTS SUMMARY")
print(separator)

func statusIcon(_ success: Bool) -> String { success ? "✅" : "❌" }

print("\(statusIcon(cgResult.success)) CGDisplayStream:       \(cgResult.frameCount) frames, \(String(format: "%.1f", cgResult.elapsed))s")
print("\(statusIcon(avResult.success)) AVCaptureScreenInput:  \(avResult.frameCount) frames, \(String(format: "%.1f", avResult.elapsed))s")
print("\(statusIcon(scResult.success)) SCStream:              \(scResult.frameCount) frames, \(String(format: "%.1f", scResult.elapsed))s")

print(separator)

let workingAPIs = [
    cgResult.success ? "CGDisplayStream" : nil,
    avResult.success ? "AVCaptureScreenInput" : nil,
    scResult.success ? "SCStream" : nil
].compactMap { $0 }

if workingAPIs.isEmpty {
    print("No working capture API found!")
    print("Recommendation: Check Screen Recording permission, or try restarting Mac.")
} else {
    print("Working APIs: \(workingAPIs.joined(separator: ", "))")
    print("Recommended for SideScreen: \(workingAPIs[0])")
}

print(separator)

// Cleanup
print("")
print("[Cleanup] Done.")
exit(0)
```

**Step 3: Build and run the full test**

Run: `bash MacHost/CaptureTest/build.sh && MacHost/CaptureTest/CaptureTest.app/Contents/MacOS/CaptureTest`

Expected output (approximate):
```
=== CaptureTest: macOS Screen Capture API Comparison ===
[Setup] Creating virtual display 1920x1200 @ 60Hz...
✅ Virtual display created: ID=XX

[Test CGDisplayStream] Starting...
  ✅ Captured 5 frames in X.Xs

[Test AVCaptureScreenInput] Starting...
  ✅ Captured 5 frames in X.Xs  (or timeout)

[Test SCStream] Starting...
  ❌ SCStream init timed out after 10s

==================================================
RESULTS SUMMARY
==================================================
✅ CGDisplayStream:       5 frames, X.Xs
✅ AVCaptureScreenInput:  5 frames, X.Xs
❌ SCStream:              0 frames, 10.0s
==================================================
Working APIs: CGDisplayStream, AVCaptureScreenInput
Recommended for SideScreen: CGDisplayStream
==================================================
```

**Step 4: Commit**

```bash
git add MacHost/CaptureTest/Sources/
git commit -m "feat: complete CaptureTest with all 3 API tests"
```

---

### Task 6: Grant permission and run final test

**Step 1:** Open System Settings > Privacy & Security > Screen Recording
**Step 2:** Find "CaptureTest" and enable it
**Step 3:** Run test again and collect results
**Step 4:** Based on results, decide which API to integrate into SideScreen

---

## Post-Test: Integration into SideScreen

After identifying the working API, create a new `ScreenCapture.swift` that uses the working API instead of (or as fallback to) SCStream. This is a separate plan to be written after test results are known.
