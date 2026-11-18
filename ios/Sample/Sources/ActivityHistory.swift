import Foundation
import WalletKit

struct ActivityHistory {
    enum Page: Equatable {
        case first, older(String), end
    }

    static let pageSize: Int64 = 30
    private(set) var next: Page = .first
    private(set) var entries: [Entry] = []
    private(set) var visibleEntries: [Entry] = []
    var isLoading = false
    var failed = false

    private var canonical: [String: Row] = [:]
    private var overlay: Entry?
    private var oldest: Row?

    private struct Row {
        let entry: Entry
        let date: Date

        init(_ entry: Entry) {
            self.entry = entry
            date = WalletFormatting.parsedDate(entry.createdAt) ?? .distantPast
        }

        func precedes(_ other: Self) -> Bool {
            if date != other.date { return date > other.date }
            return entry.id.utf8.lexicographicallyPrecedes(other.entry.id.utf8)
        }
    }

    /// The server token refers to the raw page, including hidden top-ups.
    mutating func append(_ page: ActivityList, requested: Page) throws {
        if page.hasMore == true {
            guard let token = page.nextCursor, !token.isEmpty, requested != .older(token) else {
                throw WalletActionError(message: "Activity returned an invalid continuation")
            }
            next = .older(token)
        } else {
            next = .end
        }
        if requested == .first { replaceOverlay(page.entries) }
        for entry in page.entries where !Self.isBoardingOverlay(entry) {
            let row = Row(entry)
            canonical[entry.id] = row
            if oldest.map({ $0.precedes(row) }) ?? true { oldest = row }
        }
        rebuild()
    }

    /// Rows past the loaded range will be read in order by the next page.
    mutating func mergeChanges(_ updates: [Entry]) {
        var changed = false
        for entry in updates {
            let row = Row(entry)
            if canonical[entry.id] != nil || next == .end ||
                oldest.map({ !($0.precedes(row)) }) == true || overlay?.id == entry.id {
                canonical[entry.id] = row
                if overlay?.id == entry.id { overlay = nil }
                changed = true
            }
        }
        if changed { rebuild() }
    }

    @discardableResult mutating func updateOverlay(_ head: [Entry]) -> Bool {
        let previous = overlay
        replaceOverlay(head)
        guard previous?.id != overlay?.id || previous?.amountSat != overlay?.amountSat else { return false }
        rebuild()
        return true
    }

    private mutating func replaceOverlay(_ head: [Entry]) {
        guard let entry = head.first(where: Self.isBoardingOverlay), canonical[entry.id] == nil else {
            overlay = nil
            return
        }
        // List stamps the overlay with the observation time on every read.
        if overlay?.id != entry.id || overlay?.amountSat != entry.amountSat { overlay = entry }
    }

    private mutating func rebuild() {
        let rows = canonical.values.sorted { $0.precedes($1) }.map(\.entry)
        entries = overlay.flatMap { canonical[$0.id] == nil ? [$0] : nil } ?? []
        entries.append(contentsOf: rows)
        visibleEntries = WalletActivityPresentation.entries(entries)
    }

    // Match the SDK projector's unconfirmed-boarding predicate. A confirmed
    // entry can share the ID, but includes a transaction or height.
    private static func isBoardingOverlay(_ entry: Entry) -> Bool {
        guard let progress = entry.progress else { return false }
        return entry.kind == "deposit" && entry.status == "pending" &&
            progress.phase == "waiting_for_confirmation" &&
            progress.txid.isEmpty && progress.confirmationHeight == 0
    }
}
