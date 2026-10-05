import AppKit
import XCTest
@testable import PerpetualRadar

final class FrostedBackgroundTests: XCTestCase {
    @MainActor
    private func withDatabase(_ body: (URL, UserDefaults, String) throws -> Void) throws {
        let suite = "FrostedBackgroundTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("radar.sqlite3"), defaults, suite)
    }

    @MainActor
    func testDefaultsAndSQLiteRestorePreserveOpacityWhileDisabled() async throws {
        try withDatabase { url, defaults, suite in
            var radar: Radar? = try Radar(defaults: defaults, storeURL: url)
            let initial = try XCTUnwrap(radar).snapshot(rocPeriod: 9, marocPeriod: 9)
            XCTAssertEqual(initial["frostedBackgroundEnabled"] as? Bool, true)
            XCTAssertEqual(initial["frostedBackgroundOpacity"] as? Double, 0.3)
            let revision = try XCTUnwrap(initial["revision"] as? Int)
            XCTAssertTrue(try XCTUnwrap(radar).setFrostedBackground(enabled: false, opacity: 0.65))
            let changed = try XCTUnwrap(radar).snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)
            XCTAssertNil(changed["unchanged"])
            XCTAssertEqual(changed["frostedBackgroundEnabled"] as? Bool, false)
            XCTAssertEqual(changed["frostedBackgroundOpacity"] as? Double, 0.65)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(changed))
            radar = nil
            defaults.removePersistentDomain(forName: suite)

            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertFalse(reopened.frostedBackgroundEnabled)
            XCTAssertEqual(reopened.frostedBackgroundOpacity, 0.65)
            XCTAssertTrue(try reopened.setFrostedBackground(enabled: true))
            XCTAssertEqual(reopened.frostedBackgroundOpacity, 0.65)
            let invalidPeriods = reopened.snapshot(rocPeriod: 0, marocPeriod: 9)
            XCTAssertEqual(invalidPeriods["frostedBackgroundEnabled"] as? Bool, true)
            XCTAssertEqual(invalidPeriods["frostedBackgroundOpacity"] as? Double, 0.65)

            for opacity in [0.0, 1.0, 0.3] {
                XCTAssertTrue(try reopened.setFrostedBackground(opacity: opacity))
                XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).frostedBackgroundOpacity, opacity)
            }
            let unchangedRevision = try XCTUnwrap(reopened.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            XCTAssertTrue(try reopened.setFrostedBackground(enabled: true, opacity: 0.3))
            XCTAssertEqual(reopened.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: unchangedRevision)["unchanged"] as? Bool, true)
        }
    }

    @MainActor
    func testInvalidOpacityKeepsTheSavedSettingsAndSnapshot() async throws {
        try withDatabase { url, defaults, _ in
            let radar = try Radar(defaults: defaults, storeURL: url)
            XCTAssertTrue(try radar.setFrostedBackground(opacity: 0.45))
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            for opacity in [-0.01, 1.01, .nan, .infinity, -.infinity] {
                XCTAssertFalse(try radar.setFrostedBackground(enabled: false, opacity: opacity))
                XCTAssertTrue(radar.frostedBackgroundEnabled)
                XCTAssertEqual(radar.frostedBackgroundOpacity, 0.45)
                XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
                let reopened = try Radar(defaults: defaults, storeURL: url)
                XCTAssertTrue(reopened.frostedBackgroundEnabled)
                XCTAssertEqual(reopened.frostedBackgroundOpacity, 0.45)
            }
        }
    }

    @MainActor
    func testMalformedStoredPreferencesFallBackToTheDefaults() async throws {
        try withDatabase { url, defaults, _ in
            let store = try Store(url: url)
            try store.setPreference("invalid", forKey: "frostedBackgroundEnabled")
            for opacity in ["invalid", "nan", "inf", "-0.1", "1.1"] {
                try store.setPreference(opacity, forKey: "frostedBackgroundOpacity")
                let radar = try Radar(defaults: defaults, storeURL: url)
                XCTAssertTrue(radar.frostedBackgroundEnabled)
                XCTAssertEqual(radar.frostedBackgroundOpacity, 0.3)
            }
        }
    }

    @MainActor
    func testFailedWriteRollsBackBothPreferencesUntilRetrySucceeds() async throws {
        try withDatabase { url, defaults, _ in
            let radar = try Radar(defaults: defaults, storeURL: url)
            XCTAssertTrue(try radar.setFrostedBackground(opacity: 0.4))
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            let store = try Store(url: url)
            try store.execute("CREATE TRIGGER reject_background_opacity BEFORE UPDATE ON preferences WHEN NEW.key='frostedBackgroundOpacity' BEGIN SELECT RAISE(ABORT,'Cannot save opacity'); END")

            XCTAssertThrowsError(try radar.setFrostedBackground(enabled: false, opacity: 0.8))
            XCTAssertTrue(radar.frostedBackgroundEnabled)
            XCTAssertEqual(radar.frostedBackgroundOpacity, 0.4)
            XCTAssertEqual(try store.preference(forKey: "frostedBackgroundEnabled"), "true")
            XCTAssertEqual(try store.preference(forKey: "frostedBackgroundOpacity"), "0.4")
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)

            try store.execute("DROP TRIGGER reject_background_opacity")
            XCTAssertTrue(try radar.setFrostedBackground(enabled: false, opacity: 0.8))
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertFalse(reopened.frostedBackgroundEnabled)
            XCTAssertEqual(reopened.frostedBackgroundOpacity, 0.8)
        }
    }

    @MainActor
    func testCopiedChartPreservesPixelResolutionAndHasAnOpaqueThemeBackground() async throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        let source = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: NSSize(width: 4, height: 4))
        let image = try XCTUnwrap(opaqueChartSnapshot(source, backgroundRGB: [0.2, 0.4, 0.6]))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertEqual(image.size, source.size)
        XCTAssertEqual(bitmap.pixelsWide, 8)
        XCTAssertEqual(bitmap.pixelsHigh, 8)
        XCTAssertEqual(bitmap.colorSpace, NSColorSpace.sRGB)
        let foreground = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1))
        XCTAssertEqual(foreground.redComponent, 1, accuracy: 1 / 255)
        XCTAssertEqual(foreground.greenComponent, 0, accuracy: 1 / 255)
        XCTAssertEqual(foreground.alphaComponent, 1)
        let background = try XCTUnwrap(bitmap.colorAt(x: 6, y: 1))
        XCTAssertEqual(background.redComponent, 0.2, accuracy: 1 / 255)
        XCTAssertEqual(background.greenComponent, 0.4, accuracy: 1 / 255)
        XCTAssertEqual(background.blueComponent, 0.6, accuracy: 1 / 255)
        XCTAssertEqual(background.alphaComponent, 1)
    }

    @MainActor
    func testNativeBackgroundTogglesWithoutFadingOrResizingContent() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView()
        let background = WindowBackgroundView(contentView: content)
        window.contentView = background
        let effect = try XCTUnwrap(background.subviews.first as? NSVisualEffectView)
        XCTAssertEqual(effect.blendingMode, .behindWindow)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for enabled in [true, false, true] {
                background.apply(enabled: enabled, to: window)
                window.setContentSize(NSSize(width: 900, height: 600))
                background.layoutSubtreeIfNeeded()
                XCTAssertEqual(window.isOpaque, !enabled)
                XCTAssertEqual(window.backgroundColor?.alphaComponent, enabled ? 0 : 1)
                XCTAssertEqual(effect.isHidden, !enabled)
                XCTAssertEqual(effect.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), appearance)
                XCTAssertEqual(content.frame, background.bounds)
                XCTAssertFalse(content.isHidden)
                XCTAssertEqual(content.alphaValue, 1)
            }
        }
    }
}
