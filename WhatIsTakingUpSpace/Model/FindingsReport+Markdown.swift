import Foundation

nonisolated extension FindingsReport {
    /// The report as Markdown, worded so that it can be read without the app at hand: pasted into
    /// a chat or saved to a file.
    ///
    /// Always in English with US number formats, whatever the system language: the reader is as
    /// likely a language model as a person, and the text must come out the same on every Mac.
    /// `system` names the macOS version, which decides what many of the folders mean.
    func markdown(madeAt date: Date, in timeZone: TimeZone = .current, on system: String) -> String {
        let opening = [
            "# Disk usage report for `\(rootPath)`",
            """
            Made by What Is Taking Up Space on \(Wording.moment(date, in: timeZone)), \(system).
            Sizes are space taken on disk, in decimal units (1 GB is 1000 MB). \
            Nothing here was checked for being safe to delete.
            """,
        ]
        return (opening + diskSection + largestSection + unreadableSection).joined(separator: "\n\n") + "\n"
    }

    private var diskSection: [String] {
        var lines = ["- Found in files: \(Wording.size(summary.foundInFiles))"]
        if let unaccounted = summary.unaccounted {
            lines.append(
                "- Not found in files: \(Wording.size(unaccounted)) "
                    + "(local snapshots, purgeable data, folders without access)"
            )
        }
        lines += [
            "- Volume capacity: \(Wording.size(summary.capacity))",
            "- Volume used: \(Wording.size(summary.used))",
            "- Volume free: \(Wording.size(summary.free))",
            "- Purgeable, freed by the system on demand: \(Wording.size(summary.purgeable))",
        ]
        return ["## Disk", lines.joined(separator: "\n")]
    }

    private var largestSection: [String] {
        let limit = Wording.size(threshold)
        let heading = "## Largest items, \(limit) and above"
        guard !entries.isEmpty else { return [heading, "Nothing in the scan reaches \(limit)."] }

        var blocks = [
            heading,
            "The items do not overlap. A folder's own size leaves out anything directly inside it "
                + "that reaches \(limit), because that has an item of its own. "
                + "Under a folder is the largest of what makes up its own size.",
        ]
        for (index, entry) in entries.enumerated() {
            blocks += entry.blocks(numbered: index + 1)
        }
        if otherEntries.count > 0 {
            let together = otherEntries.count == 1 ? "" : " together"
            blocks.append(
                "Not listed: \(Wording.counted(otherEntries.count, "smaller item")), "
                    + "\(Wording.size(otherEntries.bytes)) of own size\(together)."
            )
        }
        return blocks
    }

    private var unreadableSection: [String] {
        guard !unreadable.isEmpty else { return [] }
        var lines = unreadable.map { "- `\($0)`" }
        if otherUnreadable > 0 {
            lines.append("- and \(Wording.count(otherUnreadable)) more")
        }
        return [
            "## Folders without access",
            "What is inside them is not counted in this report.",
            lines.joined(separator: "\n"),
        ]
    }
}

nonisolated private extension FindingsReport.Entry {
    func blocks(numbered number: Int) -> [String] {
        var blocks = ["### \(number). `\(path)`", sizeLine]
        let lines = contentLines
        if !lines.isEmpty {
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks
    }

    /// Two sizes that read the same are told once: the difference is below what the units show.
    var sizeLine: String {
        let own = Wording.size(ownSize)
        let total = Wording.size(totalSize)
        let title = kind.word.capitalized
        return own == total ? "\(title), \(own)." : "\(title), \(own) of its own, \(total) in total."
    }

    var contentLines: [String] {
        var lines = items.map { "- \(Wording.size($0.size)): `\($0.name)` (\($0.kind.word))" }
        if otherItems.count > 0 {
            lines.append("- \(Wording.size(otherItems.bytes)): \(Wording.counted(otherItems.count, "more item"))")
        }
        if looseFiles.count > 0 {
            let each = looseFiles.count == 1 ? "" : " each"
            lines.append(
                "- \(Wording.size(looseFiles.bytes)): \(Wording.counted(looseFiles.count, "file")) "
                    + "under \(Wording.size(LooseFiles.cutoff))\(each)"
            )
        }
        return lines
    }
}

/// Numbers and dates the way the report writes them.
nonisolated private enum Wording {
    private static let locale = Locale(identifier: "en_US")

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
    }

    static func count(_ count: Int) -> String {
        count.formatted(.number.locale(locale))
    }

    /// "1 file", "2 files": the nouns used here all take a plain "s".
    static func counted(_ count: Int, _ noun: String) -> String {
        "\(Self.count(count)) \(noun)\(count == 1 ? "" : "s")"
    }

    static func moment(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let style = Date.VerbatimFormatStyle(
            format: """
            \(year: .padded(4))-\(month: .twoDigits)-\(day: .twoDigits) at \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)
            """,
            locale: locale,
            timeZone: timeZone,
            calendar: calendar
        )
        return date.formatted(style)
    }
}
