import Foundation

// MARK: - Shell helper

@discardableResult
func shell(_ path: String, _ args: [String]) -> (status: Int32, out: Data, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    do {
        try p.run()
    } catch {
        return (-1, Data(), "launch failed: \(error.localizedDescription)")
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, outData, String(data: errData, encoding: .utf8) ?? "")
}

private func plist(_ data: Data) -> [String: Any]? {
    guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
    return obj as? [String: Any]
}

// MARK: - Model

enum DiskCategory: Int, Comparable, CaseIterable {
    case usb = 0
    case sdCard = 1
    case externalOther = 2
    case internalDisk = 3

    var title: String {
        switch self {
        case .usb: return "USB"
        case .sdCard: return "SD"
        case .externalOther: return "EXT"
        case .internalDisk: return "INT"
        }
    }

    static func < (lhs: DiskCategory, rhs: DiskCategory) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Disk: Identifiable, Hashable {
    let id: String            // "disk4"
    let mediaName: String     // "SanDisk Ultra Media"
    let sizeBytes: Int64
    let busProtocol: String   // "USB", "Secure Digital", "PCI-Express", ...
    let isInternal: Bool
    let isRemovable: Bool
    let isSolidState: Bool
    let isBootDisk: Bool
    let volumeNames: [String]
    let category: DiskCategory

    var devNode: String { "/dev/\(id)" }
    var rawDevNode: String { "/dev/r\(id)" }

    var sizeString: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useTB, .useMB]
        return f.string(fromByteCount: sizeBytes)
    }

    var volumeSummary: String {
        if volumeNames.isEmpty { return "no readable volumes" }
        return volumeNames.joined(separator: ", ")
    }

    var menuLabel: String {
        let flag = isBootDisk ? "  ** SYSTEM DISK **" : ""
        return "\(category.title) · \(id) · \(sizeString) · \(mediaName) [\(volumeSummary)]\(flag)"
    }

    var detailLine: String {
        "\(devNode)  |  \(busProtocol)  |  \(isInternal ? "internal" : "external")"
            + "  |  \(isRemovable ? "removable" : "fixed")"
            + "  |  \(isSolidState ? "solid-state" : "rotational/unknown")"
    }
}

// MARK: - Scanner

enum DiskScanner {

    static func scan() -> [Disk] {
        let bootWholes = bootWholeDisks()
        var volumesByDisk: [String: [String]] = [:]
        var wholeDisks: [String] = []

        let listed = shell("/usr/sbin/diskutil", ["list", "-plist", "physical"])
        if let root = plist(listed.out) {
            wholeDisks = root["WholeDisks"] as? [String] ?? []
            if let all = root["AllDisksAndPartitions"] as? [[String: Any]] {
                for entry in all {
                    guard let ident = entry["DeviceIdentifier"] as? String else { continue }
                    var names: [String] = []
                    if let parts = entry["Partitions"] as? [[String: Any]] {
                        names += parts.compactMap { $0["VolumeName"] as? String }
                    }
                    if let apfs = entry["APFSVolumes"] as? [[String: Any]] {
                        names += apfs.compactMap { $0["VolumeName"] as? String }
                    }
                    volumesByDisk[ident] = names
                }
            }
        }

        var result: [Disk] = []
        for ident in wholeDisks {
            guard let disk = info(for: ident,
                                  volumes: volumesByDisk[ident] ?? [],
                                  bootWholes: bootWholes) else { continue }
            result.append(disk)
        }

        return result.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return numericSuffix($0.id) < numericSuffix($1.id)
        }
    }

    private static func info(for ident: String, volumes: [String], bootWholes: Set<String>) -> Disk? {
        let r = shell("/usr/sbin/diskutil", ["info", "-plist", "/dev/\(ident)"])
        guard r.status == 0, let d = plist(r.out) else { return nil }
        if (d["VirtualOrPhysical"] as? String) == "Virtual" { return nil }

        let size = (d["Size"] as? NSNumber)?.int64Value
            ?? (d["TotalSize"] as? NSNumber)?.int64Value
            ?? 0
        if size <= 0 { return nil }

        let proto = (d["BusProtocol"] as? String) ?? "Unknown"
        let isInternal = (d["Internal"] as? Bool) ?? false
        let removable = (d["RemovableMedia"] as? Bool)
            ?? (d["Removable"] as? Bool)
            ?? (d["RemovableMediaOrExternalDevice"] as? Bool)
            ?? false
        let ssd = (d["SolidState"] as? Bool) ?? false
        let media = (d["MediaName"] as? String)
            ?? (d["IORegistryEntryName"] as? String)
            ?? "Unknown device"

        let category: DiskCategory
        let protoLower = proto.lowercased()
        if protoLower == "usb" && !isInternal {
            category = .usb
        } else if protoLower.contains("secure digital") || media.lowercased().contains("sd card") {
            category = .sdCard
        } else if !isInternal {
            category = .externalOther
        } else {
            category = .internalDisk
        }

        return Disk(id: ident,
                    mediaName: media.trimmingCharacters(in: .whitespaces),
                    sizeBytes: size,
                    busProtocol: proto,
                    isInternal: isInternal,
                    isRemovable: removable,
                    isSolidState: ssd,
                    isBootDisk: bootWholes.contains(ident),
                    volumeNames: volumes,
                    category: category)
    }

    /// Every whole disk that backs "/" — these are hard-blocked in the UI.
    private static func bootWholeDisks() -> Set<String> {
        var out = Set<String>()
        for mount in ["/", "/System/Volumes/Data"] {
            let r = shell("/usr/sbin/diskutil", ["info", "-plist", mount])
            guard r.status == 0, let d = plist(r.out) else { continue }
            if let parent = d["ParentWholeDisk"] as? String { out.insert(whole(parent)) }
            if let ident = d["DeviceIdentifier"] as? String { out.insert(whole(ident)) }
            if let stores = d["APFSPhysicalStores"] as? [[String: Any]] {
                for s in stores {
                    if let dev = (s["APFSPhysicalStore"] as? String) ?? (s["DeviceIdentifier"] as? String) {
                        out.insert(whole(dev))
                    }
                }
            }
        }
        return out
    }

    /// "disk0s2" -> "disk0"
    private static func whole(_ ident: String) -> String {
        var result = ""
        var seenDigit = false
        for ch in ident {
            if ch.isNumber { seenDigit = true; result.append(ch); continue }
            if seenDigit { break }
            result.append(ch)
        }
        return result.isEmpty ? ident : result
    }

    private static func numericSuffix(_ ident: String) -> Int {
        Int(ident.drop(while: { !$0.isNumber })) ?? 0
    }
}
