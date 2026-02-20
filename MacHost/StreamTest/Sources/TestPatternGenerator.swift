import Foundation
import CoreVideo
import CoreGraphics

/// Generates animated BGRA test patterns for pipeline testing
class TestPatternGenerator {
    let width: Int
    let height: Int
    private var frameNumber: UInt64 = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Generate next frame with animated color bars
    func nextFrame() -> CVPixelBuffer? {
        frameNumber += 1
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        let baseAddr = CVPixelBufferGetBaseAddress(pb)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)

        // Animated vertical color bars that shift over time
        let barCount = 8
        let barWidth = width / barCount
        let shift = Int(frameNumber) % width  // animate by shifting bars

        // Colors: White, Yellow, Cyan, Green, Magenta, Red, Blue, Black
        let colors: [(UInt8, UInt8, UInt8)] = [
            (255, 255, 255), // White
            (0, 255, 255),   // Yellow (BGRA: B=0, G=255, R=255)
            (255, 255, 0),   // Cyan (BGRA: B=255, G=255, R=0)
            (0, 255, 0),     // Green
            (255, 0, 255),   // Magenta
            (0, 0, 255),     // Red (BGRA: B=0, G=0, R=255)
            (255, 0, 0),     // Blue (BGRA: B=255, G=0, R=0)
            (0, 0, 0),       // Black
        ]

        for y in 0..<height {
            let row = baseAddr.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let shiftedX = (x + shift) % width
                let barIndex = (shiftedX / barWidth) % barCount
                let (b, g, r) = colors[barIndex]
                let offset = x * 4
                row[offset + 0] = b   // B
                row[offset + 1] = g   // G
                row[offset + 2] = r   // R
                row[offset + 3] = 255 // A
            }
        }

        // Draw frame counter text area (top-left white box with frame number)
        let boxW = min(200, width)
        let boxH = min(40, height)
        for y in 0..<boxH {
            let row = baseAddr.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<boxW {
                let offset = x * 4
                row[offset + 0] = 255 // B
                row[offset + 1] = 255 // G
                row[offset + 2] = 255 // R
                row[offset + 3] = 255 // A
            }
        }

        // Simple digit rendering for frame counter (big blocky digits)
        renderNumber(Int(frameNumber), at: baseAddr, bytesPerRow: bytesPerRow, x: 10, y: 8)

        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }

    /// Render a number using simple 5x7 block digits
    private func renderNumber(_ number: Int, at baseAddr: UnsafeMutableRawPointer, bytesPerRow: Int, x startX: Int, y startY: Int) {
        let digits = String(number).compactMap { $0.wholeNumberValue }
        let scale = 3  // pixel scale for each "dot"
        var curX = startX

        for digit in digits {
            let pattern = digitPatterns[digit]
            for row in 0..<7 {
                for col in 0..<5 {
                    let on = (pattern[row] >> (4 - col)) & 1 == 1
                    if on {
                        // Draw a scale x scale block
                        for dy in 0..<scale {
                            for dx in 0..<scale {
                                let px = curX + col * scale + dx
                                let py = startY + row * scale + dy
                                guard px < width && py < height else { continue }
                                let rowPtr = baseAddr.advanced(by: py * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                                let offset = px * 4
                                rowPtr[offset + 0] = 0   // B
                                rowPtr[offset + 1] = 0   // G
                                rowPtr[offset + 2] = 0   // R
                                rowPtr[offset + 3] = 255 // A
                            }
                        }
                    }
                }
            }
            curX += 6 * scale  // 5 wide + 1 gap
        }
    }

    // 5x7 digit bitmaps (each row is 5 bits, MSB first)
    private let digitPatterns: [[UInt8]] = [
        [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110], // 0
        [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110], // 1
        [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111], // 2
        [0b01110, 0b10001, 0b00001, 0b00110, 0b00001, 0b10001, 0b01110], // 3
        [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010], // 4
        [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110], // 5
        [0b01110, 0b10000, 0b11110, 0b10001, 0b10001, 0b10001, 0b01110], // 6
        [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000], // 7
        [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110], // 8
        [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110], // 9
    ]
}
