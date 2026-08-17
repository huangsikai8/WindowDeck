import AppKit
import ScreenCaptureKit

/// Captures images of individual windows: small ones for hover thumbnails and
/// the switcher, full-size ones for the peek.
///
/// This is the only part of WindowDeck needing Screen Recording permission.
/// Window titles are read through the Accessibility API specifically to avoid
/// that grant, so the title chip keeps working when this is refused and the rest
/// of the app is unaffected.
///
/// **Freshness is the caller's decision, not the cache's.** A hover thumbnail
/// must never show badly stale content, while the switcher would rather reuse a
/// minutes-old image than re-screenshot two dozen windows every time it opens.
/// A single shared lifetime cannot satisfy both — so lookups take a `maxAge` and
/// each caller states what it can live with.
@MainActor
final class PreviewService {

    /// Shared so the hover panel and the switcher warm the same cache — cycling
    /// straight after hovering reuses captures already taken.
    static let shared = PreviewService()

    struct Capture {
        let image: NSImage
        /// The window's frame in Cocoa screen coordinates, ready to hand to
        /// NSWindow.setFrame.
        let screenRect: CGRect
    }

    private struct Cached<Value> {
        let value: Value
        let captured: Date
        var lastUsed: Date
    }

    /// What a hover thumbnail accepts. Short on purpose.
    static let hoverMaxAge: TimeInterval = 3
    /// What the switcher accepts. Long on purpose.
    static let switcherMaxAge: TimeInterval = 600

    /// Entry counts, not just ages, bound memory. Full-size peek images are
    /// large, so far fewer are kept.
    private let thumbnailLimit = 60
    private let fullSizeLimit = 8

    private var thumbnails: [CGWindowID: Cached<NSImage>] = [:]
    private var fullSize: [CGWindowID: Cached<Capture>] = [:]

    /// The shareable-content query is comparatively expensive, so the window
    /// list is reused briefly across lookups.
    private var shareable: SCShareableContent?
    private var shareableFetched: Date?
    private let shareableTTL: TimeInterval = 5

    private(set) var isDenied = false

    // MARK: - Thumbnails

    func cachedImage(for id: CGWindowID, maxAge: TimeInterval = hoverMaxAge) -> NSImage? {
        guard let hit = thumbnails[id], Date().timeIntervalSince(hit.captured) < maxAge else { return nil }
        thumbnails[id]?.lastUsed = Date()
        return hit.value
    }

    func image(
        for window: WindowInfo,
        maxSize: CGSize,
        maxAge: TimeInterval = hoverMaxAge
    ) async -> NSImage? {
        if let hit = cachedImage(for: window.id, maxAge: maxAge) { return hit }

        guard let target = await scWindow(for: window.id) else { return nil }
        let frame = target.frame
        guard frame.width > 0, frame.height > 0 else { return nil }

        // Preserve aspect ratio inside the requested bounds.
        let scale = min(maxSize.width / frame.width, maxSize.height / frame.height, 1)
        guard let image = await capture(
            target,
            pixelWidth: max(Int(frame.width * scale), 32),
            pixelHeight: max(Int(frame.height * scale), 32)
        ) else { return nil }

        store(image, for: window.id)
        return image
    }

    /// Snapshots a window without anyone asking to look at it — used when a
    /// window loses focus, which is when its content is final and exactly what a
    /// switcher should later show.
    func warm(_ window: WindowInfo, maxSize: CGSize) async {
        // Deliberately *not* the switcher's tolerance. Accepting a ten-minute-old
        // image here would make this a no-op whenever any capture existed — the
        // window just changed, which is precisely why it is being re-captured.
        // The small tolerance only suppresses redundant back-to-back work.
        _ = await image(for: window, maxSize: maxSize, maxAge: 2)
    }

    // MARK: - Full-size peek

    func cachedCapture(for id: CGWindowID, maxAge: TimeInterval = hoverMaxAge) -> Capture? {
        guard let hit = fullSize[id], Date().timeIntervalSince(hit.captured) < maxAge else { return nil }
        fullSize[id]?.lastUsed = Date()
        return hit.value
    }

    /// One frozen frame at the window's own size, plus where to draw it.
    func fullSizeCapture(for window: WindowInfo) async -> Capture? {
        if let hit = cachedCapture(for: window.id) { return hit }

        guard let target = await scWindow(for: window.id) else { return nil }
        let frame = target.frame
        guard frame.width > 0, frame.height > 0 else { return nil }

        // Capture at backing scale so the image is crisp on Retina.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = await capture(
            target,
            pixelWidth: Int(frame.width * scale),
            pixelHeight: Int(frame.height * scale)
        ) else { return nil }

        let capture = Capture(image: image, screenRect: Self.cocoaRect(fromDisplay: frame))
        let now = Date()
        fullSize[window.id] = Cached(value: capture, captured: now, lastUsed: now)
        trimFullSize()
        return capture
    }

    // MARK: - Storage

    private func store(_ image: NSImage, for id: CGWindowID) {
        let now = Date()
        thumbnails[id] = Cached(value: image, captured: now, lastUsed: now)
        trimThumbnails()
    }

    /// Least-recently-used eviction. Without a count limit a long session
    /// accumulates one image per window ever previewed, which for the full-size
    /// peek images is the expensive kind of growth.
    private func trimThumbnails() {
        guard thumbnails.count > thumbnailLimit else { return }
        let doomed = thumbnails.sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(thumbnails.count - thumbnailLimit)
        for entry in doomed { thumbnails.removeValue(forKey: entry.key) }
    }

    private func trimFullSize() {
        guard fullSize.count > fullSizeLimit else { return }
        let doomed = fullSize.sorted { $0.value.lastUsed < $1.value.lastUsed }
            .prefix(fullSize.count - fullSizeLimit)
        for entry in doomed { fullSize.removeValue(forKey: entry.key) }
    }

    func forget(_ id: CGWindowID) {
        thumbnails.removeValue(forKey: id)
        fullSize.removeValue(forKey: id)
    }

    /// Drops anything past the *longest* tolerance. Using the short one here
    /// would have hover's housekeeping throw away the images the switcher is
    /// relying on.
    func evictExpired() {
        let now = Date()
        thumbnails = thumbnails.filter { now.timeIntervalSince($0.value.captured) < Self.switcherMaxAge }
        fullSize = fullSize.filter { now.timeIntervalSince($0.value.captured) < Self.switcherMaxAge }
    }

    // MARK: - Shared plumbing

    private func capture(_ target: SCWindow, pixelWidth: Int, pixelHeight: Int) async -> NSImage? {
        do {
            let config = SCStreamConfiguration()
            config.width = pixelWidth
            config.height = pixelHeight
            config.showsCursor = false
            config.ignoreGlobalClipDisplay = true
            config.captureResolution = .best

            let filter = SCContentFilter(desktopIndependentWindow: target)
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            isDenied = false
            return NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
        } catch {
            // Permission refused, or the window vanished mid-capture. Either way
            // the caller degrades rather than fails.
            isDenied = true
            return nil
        }
    }

    private func scWindow(for id: CGWindowID) async -> SCWindow? {
        guard let content = try? await shareableContent() else {
            isDenied = true
            return nil
        }
        return content.windows.first { $0.windowID == id }
    }

    private func shareableContent() async throws -> SCShareableContent {
        if let shareable, let fetched = shareableFetched,
           Date().timeIntervalSince(fetched) < shareableTTL {
            return shareable
        }
        // onScreenWindowsOnly: false so windows on other Spaces still preview.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        shareable = content
        shareableFetched = Date()
        return content
    }

    /// `SCWindow.frame` is top-left-origin in global display space; NSWindow
    /// wants bottom-left-origin relative to the primary screen. Getting this
    /// wrong puts the peek image visibly off-position.
    private static func cocoaRect(fromDisplay rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}
