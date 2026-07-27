import AppKit
import SwiftUI

/// Offscreen renderer for documentation images and for eyeballing the rings
/// without launching the full app.
///
///     ClaudeUsageWidget --render-preview docs/rings.png
///
/// Uses fixed, representative values, so the README image is stable and
/// contains nobody's real numbers.
@MainActor
enum PreviewRenderer {

  static func handleCommandLineIfNeeded() -> Bool {
    let args = CommandLine.arguments
    guard let flagIndex = args.firstIndex(of: "--render-preview") else { return false }
    let outPath = args.indices.contains(flagIndex + 1) ? args[flagIndex + 1] : "preview.png"
    render(rings: demoRings(), to: URL(fileURLWithPath: outPath))
    return true
  }

  /// Fixed values chosen to exercise every visual state at once: a normal
  /// ring, a nearly-full one, and an over-limit one drawing a second lap.
  static func demoRings() -> [RingDatum] {
    let now = Date()
    return [
      RingDatum(
        metric: .fiveHour, progress: 0.62,
        resetsAt: now.addingTimeInterval(3600), isAvailable: true),
      RingDatum(
        metric: .weekly, progress: 0.94,
        resetsAt: now.addingTimeInterval(3 * 86_400), isAvailable: true),
      RingDatum(
        metric: .fable, progress: 1.18,
        resetsAt: now.addingTimeInterval(3600), isAvailable: true),
    ]
  }

  // MARK: - Rendering

  static func render(rings: [RingDatum], to url: URL, size: CGFloat = 260) {
    // `.ultraThinMaterial` has nothing to sample offscreen, so the preview
    // substitutes an opaque panel that approximates how it looks in place.
    let content =
      ZStack {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(Color(hex: 0x1C1C1E))
          .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
              .strokeBorder(.white.opacity(0.10), lineWidth: 1))

        VStack(spacing: 12) {
          ZStack {
            ActivityRingsView(
              rings: rings, thickness: 17, spacing: 6, animated: false
            )
            .frame(width: size * 0.72, height: size * 0.72)

            if let urgent = rings.max(by: { $0.progress < $1.progress }) {
              VStack(spacing: 1) {
                Text(urgent.percentText)
                  .font(.system(size: 32, weight: .semibold, design: .rounded))
                  .foregroundStyle(urgent.metric.color)
                Text(urgent.metric.title.uppercased())
                  .font(.system(size: 10, weight: .bold, design: .rounded))
                  .tracking(0.8)
                  .foregroundStyle(.white.opacity(0.55))
              }
              .lineLimit(1)
              .minimumScaleFactor(0.4)
              // Same 0.82 of the hole the widget itself allows, so this image
              // does not flatter the real layout.
              .frame(maxWidth: size * 0.72 * ActivityRingsView.minimumHoleFraction * 0.82)
            }
          }

          VStack(alignment: .leading, spacing: 5) {
            ForEach(rings) { ring in
              HStack(spacing: 7) {
                Circle().fill(ring.metric.color).frame(width: 8, height: 8)
                Text(ring.metric.title)
                  .font(.system(size: 11, weight: .medium, design: .rounded))
                  .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 12)
                Text(ring.percentText)
                  .font(.system(size: 11, weight: .semibold, design: .rounded))
                  .monospacedDigit()
                  .foregroundStyle(.white)
              }
            }
          }
          .frame(width: size * 0.68)
        }
        .padding(22)
      }
      .frame(width: size, height: size * 1.34)
      .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2.0
    renderer.isOpaque = true

    guard let image = renderer.nsImage,
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else {
      FileHandle.standardError.write(Data("error: failed to render preview\n".utf8))
      exit(1)
    }

    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try png.write(to: url)
      print("wrote \(url.path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    } catch {
      FileHandle.standardError.write(Data("error: \(error)\n".utf8))
      exit(1)
    }
  }
}
