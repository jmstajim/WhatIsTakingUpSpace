import AppKit
import SwiftUI

/// What the app can do with something on disk. None of it changes the disk.
enum FileActions {
    static func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Text for Edit > Copy. Text only: a file reference pasted into Finder would copy the file, and
/// the app leaves the disk as it is.
enum CopiedPath {
    static func providers(for path: String?) -> [NSItemProvider] {
        path.map { [NSItemProvider(object: $0 as NSString)] } ?? []
    }
}

enum Metrics {
    /// Distance of the strips' content from the window's edge: where a table starts its text.
    static let edge: CGFloat = 18
}

/// The icon Finder shows for something on disk, or the icon of its kind once it is gone.
struct FileIconView: View {
    static let side: CGFloat = 18

    let path: String
    let kind: Culprit.Kind

    var body: some View {
        Image(nsImage: FileIcons.icon(forPath: path, isDirectory: kind != .file))
            .resizable()
            .frame(width: Self.side, height: Self.side)
            .accessibilityLabel(kind.word.capitalized)
    }
}

/// Looks icons up once per path: a table asks again every time a row comes into view.
private enum FileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 2000
        return cache
    }()

    static func icon(forPath path: String, isDirectory: Bool) -> NSImage {
        if let known = cache.object(forKey: path as NSString) { return known }
        let icon = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : NSWorkspace.shared.icon(for: ItemType.named(path, isDirectory: isDirectory))
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// Why a folder shows no contents.
struct FlagBadge: View {
    let flags: FileTree.Flags

    var body: some View {
        if let note {
            Label(note.text, systemImage: note.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    private var note: (text: String, systemImage: String)? {
        if flags.contains(.unreadable) { return ("No access", "lock.fill") }
        if flags.contains(.dataless) { return ("In iCloud", "icloud") }
        if flags.contains(.otherVolume) { return ("Other volume", "externaldrive") }
        return nil
    }
}

/// A row's share of the whole: a level, not progress, with the figure beside it.
struct ShareCell: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Gauge(value: min(max(fraction, 0), 1)) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                // The gauge draws a dot even at zero, which would say "a little" about nothing.
                .tint(fraction > 0 ? nil : Color.clear)
            Text(fraction, format: Self.percent)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share")
        .accessibilityValue(Text(fraction, format: Self.percent))
    }

    private static let percent = FloatingPointFormatStyle<Double>.Percent().precision(.fractionLength(0...1))
}

extension FormatStyle where Self == ByteCountFormatStyle {
    /// Sizes as Finder shows them, with zero as a digit.
    static var fileSize: ByteCountFormatStyle { .byteCount(style: .file, spellsOutZero: false) }
}

struct SizeText: View {
    let bytes: Int64

    var body: some View {
        Text(bytes, format: .fileSize)
            .monospacedDigit()
    }
}
