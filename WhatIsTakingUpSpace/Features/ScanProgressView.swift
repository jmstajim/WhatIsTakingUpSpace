import SwiftUI

/// What a first scan shows: how far it has got, how much it has found so far and where it is.
struct ScanProgressView: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // With no fraction to show the bar runs without an end, and gets one as soon as there is.
            ProgressView(value: progress.fraction) {
                Text("Scanning…")
                    .font(.headline)
            } currentValueLabel: {
                ScanCounts(progress: progress)
            }
            ScanPath(path: progress.currentPath)
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: 460)
        .padding(32)
        .accessibilityElement(children: .contain)
    }
}

/// A rescan, shown in the place of the disk summary it is about to replace: the result stays on
/// screen and in use meanwhile.
struct ScanProgressStrip: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .frame(width: 160)
                .accessibilityLabel("Scanning")
            VStack(alignment: .leading, spacing: 2) {
                ScanCounts(progress: progress)
                ScanPath(path: progress.currentPath)
            }
            Spacer(minLength: 12)
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ScanCounts: View {
    let progress: ScanProgress

    var body: some View {
        Text("^[\(progress.filesSeen) file](inflect: true) · \(progress.bytesSeen.formatted(.fileSize))")
            .monospacedDigit()
            .contentTransition(.numericText())
    }
}

private struct ScanPath: View {
    let path: String

    var body: some View {
        Text(verbatim: path)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

#if DEBUG
private extension ScanProgress {
    static func preview(expecting expected: Int64?) -> ScanProgress {
        ScanProgress(
            filesSeen: 1_234_567,
            bytesSeen: 123_456_789_012,
            currentPath: "/Users/ada/Library/Developer/Xcode/DerivedData/App-abcdefgh/Build/Products",
            expectedBytes: expected
        )
    }
}

#Preview("First scan") {
    ScanProgressView(progress: .preview(expecting: 400_000_000_000), onCancel: {})
        .frame(width: 700, height: 400)
}

#Preview("No estimate") {
    ScanProgressView(progress: .preview(expecting: nil), onCancel: {})
        .frame(width: 700, height: 400)
}

#Preview("Rescan") {
    ScanProgressStrip(progress: .preview(expecting: 200_000_000_000), onCancel: {})
        .padding()
        .frame(width: 820)
}
#endif
