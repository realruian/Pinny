//
//  GIFConverter.swift
//  Snapzy
//
//  Converts video files to animated GIF using AVFoundation + ImageIO
//  Optimizes for visual quality while keeping file size reasonable
//  No FFmpeg dependency — pure Apple frameworks
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a video file to an animated GIF
@MainActor
final class GIFConverter {

  /// GIF generation parameters
  nonisolated struct Options {
    /// Frame rate for the GIF (higher = smoother but larger)
    var fps: Int = 15

    /// Max output width in pixels (source width used if smaller)
    var maxWidth: CGFloat = 960

    /// Infinite loop by default
    var loopCount: Int = 0

    /// Balanced defaults: 15fps @ up to 960px wide
    nonisolated static let `default` = Options()
  }

  /// Convert a video file to animated GIF
  /// - Parameters:
  ///   - videoURL: URL of the source video
  ///   - options: GIF generation options
  ///   - onProgress: Progress callback (0.0 - 1.0), called on MainActor
  /// - Returns: URL of the generated GIF file
  static func convert(
    videoURL: URL,
    options: Options = .default,
    onProgress: @escaping (Double) -> Void
  ) async throws -> URL {
    let sourceAccess = SandboxFileAccessManager.shared.beginAccessingURL(videoURL)
    let outputDirectoryAccess = SandboxFileAccessManager.shared.beginAccessingURL(
      videoURL.deletingLastPathComponent())
    defer {
      sourceAccess.stop()
      outputDirectoryAccess.stop()
    }
    DiagnosticLogger.shared.log(.info, .recording, "GIF conversion pipeline started", context: [
      "file": videoURL.lastPathComponent,
      "fps": "\(options.fps)",
      "maxWidth": "\(Int(options.maxWidth))",
    ])

    let asset = AVURLAsset(url: videoURL)

    // Get video duration through AVFoundation's async loading API.
    let duration = try await asset.load(.duration)
    let durationSeconds = CMTimeGetSeconds(duration)

    guard durationSeconds > 0, durationSeconds.isFinite else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion invalid video duration", context: [
        "file": videoURL.lastPathComponent,
        "durationSeconds": "\(durationSeconds)",
      ])
      throw GIFConversionError.invalidVideo
    }

    // Get video dimensions for scaling
    let videoTrack = try? await asset.loadTracks(withMediaType: .video).first

    let naturalSize: CGSize
    if let track = videoTrack {
      naturalSize = (try? await track.load(.naturalSize)) ?? CGSize(width: 640, height: 480)
    } else {
      DiagnosticLogger.shared.log(.warning, .recording, "GIF conversion found no video track; using fallback size", context: [
        "file": videoURL.lastPathComponent
      ])
      naturalSize = CGSize(width: 640, height: 480)
    }

    // Scale only if source exceeds maxWidth — never upscale
    let scale = min(1.0, options.maxWidth / naturalSize.width)
    let outputWidth = Int(naturalSize.width * scale)
    let outputHeight = Int(naturalSize.height * scale)

    // Calculate frame times
    let totalFrames = Int(ceil(durationSeconds * Double(options.fps)))
    guard totalFrames > 0 else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion has no frame times", context: [
        "durationSeconds": String(format: "%.3f", durationSeconds),
        "fps": "\(options.fps)",
      ])
      throw GIFConversionError.noFrames
    }
    DiagnosticLogger.shared.log(.debug, .recording, "GIF conversion plan", context: [
      "durationSeconds": String(format: "%.3f", durationSeconds),
      "sourceSize": "\(Int(naturalSize.width))x\(Int(naturalSize.height))",
      "outputSize": "\(outputWidth)x\(outputHeight)",
      "expectedFrames": "\(totalFrames)",
    ])

    let frameTimes = (0..<totalFrames).map { i in
      CMTime(
        seconds: Double(i) / Double(options.fps),
        preferredTimescale: 9600  // High timescale for sub-frame precision
      )
    }

    // Setup image generator with quality-focused settings
    let generator = AVAssetImageGenerator(asset: asset)
    generator.maximumSize = CGSize(width: outputWidth, height: outputHeight)
    generator.appliesPreferredTrackTransform = true

    // Tight tolerance for accurate frame extraction (reduces ghosting)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 9600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 9600)

    // Generate output URL (same directory, .gif extension)
    let gifURL = videoURL.deletingPathExtension().appendingPathExtension("gif")

    // Remove existing GIF if any
    try? FileManager.default.removeItem(at: gifURL)

    // Create GIF destination
    guard let destination = CGImageDestinationCreateWithURL(
      gifURL as CFURL,
      UTType.gif.identifier as CFString,
      totalFrames,
      nil
    ) else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion destination creation failed", context: [
        "file": gifURL.lastPathComponent,
        "expectedFrames": "\(totalFrames)",
      ])
      throw GIFConversionError.destinationCreationFailed
    }

    // Set GIF-level properties (loop count + color model)
    let gifProperties: [String: Any] = [
      kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFLoopCount as String: options.loopCount,
        kCGImagePropertyGIFHasGlobalColorMap as String: true,
      ]
    ]
    CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

    // Frame delay for each frame
    let frameDelay = 1.0 / Double(options.fps)
    let frameProperties: [String: Any] = [
      kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFDelayTime as String: frameDelay,
        kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay,
      ]
    ]

    // Stream frames into the destination in temporal order as they are generated, so a long
    // recording is never held in memory as decoded frames. Only frames that arrive ahead of
    // a slower one wait in `pending`; a failed frame is recorded as nil and skipped.
    var pending: [Int: CGImage?] = [:]
    var nextIndex = 0
    var addedFrames = 0
    var completedCount = 0
    func addReadyFrames() {
      while let frame = pending.removeValue(forKey: nextIndex) {
        if let frame {
          CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
          addedFrames += 1
        }
        nextIndex += 1
      }
    }
    for await result in generator.images(for: frameTimes) {
      completedCount += 1
      let frameIndex = Int((CMTimeGetSeconds(result.requestedTime) * Double(options.fps)).rounded())
      pending.updateValue(try? result.image, forKey: frameIndex)
      addReadyFrames()
      onProgress(Double(completedCount) / Double(totalFrames) * 0.95)
    }
    for index in pending.keys.sorted() {
      if let frame = pending[index] ?? nil {
        CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        addedFrames += 1
      }
    }

    guard addedFrames > 0 else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion generated no frames", context: [
        "file": videoURL.lastPathComponent,
        "expectedFrames": "\(totalFrames)",
      ])
      try? FileManager.default.removeItem(at: gifURL)
      throw GIFConversionError.noFrames
    }
    if addedFrames < totalFrames {
      DiagnosticLogger.shared.log(.warning, .recording, "GIF conversion generated fewer frames than expected", context: [
        "expectedFrames": "\(totalFrames)",
        "generatedFrames": "\(addedFrames)",
      ])
    }

    // Finalize GIF
    guard CGImageDestinationFinalize(destination) else {
      DiagnosticLogger.shared.log(.error, .recording, "GIF conversion finalization failed", context: [
        "file": gifURL.lastPathComponent,
        "frames": "\(addedFrames)",
      ])
      throw GIFConversionError.finalizationFailed
    }

    onProgress(1.0)

    let fileSize = (try? FileManager.default.attributesOfItem(atPath: gifURL.path)[.size] as? Int) ?? 0
    let fileSizeMB = String(format: "%.1f", Double(fileSize) / 1_048_576.0)
    DiagnosticLogger.shared.log(.info, .recording, "GIF conversion completed", context: [
      "file": gifURL.lastPathComponent,
      "frames": "\(addedFrames)",
      "fileSizeMB": fileSizeMB,
    ])

    return gifURL
  }
}

// MARK: - Errors

enum GIFConversionError: Error, LocalizedError {
  case invalidVideo
  case noFrames
  case destinationCreationFailed
  case finalizationFailed

  var errorDescription: String? {
    switch self {
    case .invalidVideo: return L10n.GIF.invalidVideo
    case .noFrames: return L10n.GIF.noFramesFromVideo
    case .destinationCreationFailed: return L10n.GIF.cannotCreateOutputFile
    case .finalizationFailed: return L10n.GIF.finalizeFailed
    }
  }
}
