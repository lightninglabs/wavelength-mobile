import Foundation

/// Files live beyond share-sheet dismissal because a receiving app may still
/// be reading them. Only this private export cache is pruned on the next export.
struct DiagnosticLogFiles: Sendable {
    let text: URL
    let zip: URL
    let textSize: Int64
    let zipSize: Int64

    static func prepare(text: String, network: String, root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiagnosticExports", isDirectory: true), now: Date = Date()) throws -> Self {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            if let created = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate,
               now.timeIntervalSince(created) > 86_400 { try? manager.removeItem(at: entry) }
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        do {
            let input = directory.appendingPathComponent("logs", isDirectory: true)
            try manager.createDirectory(at: input, withIntermediateDirectories: false)
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "yyyy-MM-dd-HHmmss'Z'"
            let name = "wavelength-\(network)-\(date.string(from: now))-logs"
            let file = input.appendingPathComponent(name + ".log")
            let data = Data(text.utf8)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            let zip = directory.appendingPathComponent(name + ".zip")
            var coordinationError: NSError?
            var copyError: Error?
            // Foundation makes a ZIP snapshot of a directory for .forUploading.
            // Copy it while the accessor owns the system's temporary snapshot.
            NSFileCoordinator().coordinate(readingItemAt: input, options: .forUploading,
                                           error: &coordinationError) { snapshot in
                do {
                    try manager.copyItem(at: snapshot, to: zip)
                    try manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: zip.path)
                } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return Self(text: file, zip: zip, textSize: Int64(data.count), zipSize: Int64(size))
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
