import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Writes what the OS reports about every file in the sync folder to
/// `<folder>/Mystnotes/diagnostics/<device>-<time>.txt`, so a two-device
/// experiment can be read back from either side. Built for the M0 task-8
/// spike (`Docs/SPIKE_ICLOUD_CONFLICTS.md`): whether iCloud Drive surfaces
/// concurrent writes to a user-picked folder as `NSFileVersion` conflicts,
/// as renamed siblings, or not at all. Debug builds only.
enum SyncDiagnostics {
    @discardableResult
    static func write() -> Result<URL, Error> {
        do {
            return .success(try SyncFolder.withFolder { folder in
                let workingDir = try SyncFolder.workingDirectory(in: folder)
                let report = try makeReport(workingDir: workingDir)
                let dir = workingDir.appendingPathComponent("diagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let url = dir.appendingPathComponent("\(deviceName)-\(stamp).txt")
                try report.write(to: url, atomically: true, encoding: .utf8)
                return url
            })
        } catch {
            return .failure(error)
        }
    }

    private static func makeReport(workingDir: URL) throws -> String {
        var lines: [String] = []
        lines.append("MystNotes sync diagnostics")
        lines.append("device: \(deviceName)")
        lines.append("time: \(Date())")
        lines.append("folder: \(workingDir.path)")
        lines.append("ubiquityIdentityToken: \(FileManager.default.ubiquityIdentityToken == nil ? "nil" : "present")")
        lines.append("")

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: workingDir, includingPropertiesForKeys: nil) else {
            lines.append("could not enumerate folder")
            return lines.joined(separator: "\n")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if url.path.contains("/diagnostics/") { continue }
            if url.path.contains("/files/") && !name.hasSuffix(".drawing") { continue }
            urls.append(url)
        }
        urls.sort { $0.path < $1.path }

        for url in urls {
            lines.append(describe(url, relativeTo: workingDir))
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ url: URL, relativeTo root: URL) -> String {
        let fm = FileManager.default
        let relative = String(url.path.dropFirst(root.path.count + 1))
        var out = "== \(relative)"

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return out + " (directory)"
        }

        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            out += "\n   size=\(values.fileSize ?? -1) modified=\(values.contentModificationDate.map { "\($0)" } ?? "?")"
            out += "\n   isUbiquitousItem=\(values.isUbiquitousItem.map { "\($0)" } ?? "nil")"
            out += " downloadingStatus=\(values.ubiquitousItemDownloadingStatus?.rawValue ?? "nil")"
            out += " hasUnresolvedConflicts=\(values.ubiquitousItemHasUnresolvedConflicts.map { "\($0)" } ?? "nil")"
            out += "\n   isUploaded=\(values.ubiquitousItemIsUploaded.map { "\($0)" } ?? "nil")"
            out += " isUploading=\(values.ubiquitousItemIsUploading.map { "\($0)" } ?? "nil")"
            out += " isDownloading=\(values.ubiquitousItemIsDownloading.map { "\($0)" } ?? "nil")"
            if let e = values.ubiquitousItemDownloadingError { out += "\n   downloadingError=\(e.localizedDescription)" }
            if let e = values.ubiquitousItemUploadingError { out += "\n   uploadingError=\(e.localizedDescription)" }
        } else {
            out += "\n   (resourceValues failed)"
        }

        if let current = NSFileVersion.currentVersionOfItem(at: url) {
            out += "\n   currentVersion: \(describe(current))"
        } else {
            out += "\n   currentVersion: nil"
        }
        let others = NSFileVersion.otherVersionsOfItem(at: url) ?? []
        out += "\n   otherVersions: \(others.count)"
        for v in others { out += "\n      - \(describe(v))" }
        let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        out += "\n   unresolvedConflictVersions: \(conflicts.count)"
        for v in conflicts { out += "\n      - \(describe(v))" }

        if url.pathExtension == "json", let data = try? Data(contentsOf: url) {
            // The first line of the file body is enough to tell versions apart.
            let head = String(decoding: data.prefix(160), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            out += "\n   head: \(head)"
        }
        return out
    }

    private static func describe(_ version: NSFileVersion) -> String {
        var s = "modified=\(version.modificationDate.map { "\($0)" } ?? "?")"
        s += " by=\(version.localizedNameOfSavingComputer ?? "?")"
        s += " conflict=\(version.isConflict) resolved=\(version.isResolved)"
        s += " url=\(version.url.lastPathComponent)"
        return s
    }

    private static var deviceName: String {
        #if canImport(UIKit)
        let raw = UIDevice.current.name
        #else
        let raw = Host.current().localizedName ?? "Mac"
        #endif
        return String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
    }
}
