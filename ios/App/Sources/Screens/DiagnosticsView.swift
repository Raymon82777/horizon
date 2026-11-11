import Darwin
import SwiftUI

/// Whether the memory entitlements are in effect: what the app's code signature grants, and what
/// iOS actually lets it use right now.
struct DiagnosticsView: View {
    struct Report {
        var signed: [String: Bool] = [:]
        var available: UInt64 = 0
        /// What the app holds now (the footprint iOS counts against the limit).
        var footprint: UInt64 = 0
        var limit: UInt64 { footprint + available }
        var physical: UInt64 = ProcessInfo.processInfo.physicalMemory
        /// The largest address-space reservation that succeeded, in GiB (tried down from 64).
        var reserved: Int = 0
    }

    static let increasedMemory = "com.apple.developer.kernel.increased-memory-limit"
    static let extendedAddressing = "com.apple.developer.kernel.extended-virtual-addressing"
    static let debuggable = "get-task-allow"

    @State private var report = Report()

    var body: some View {
        List {
            Section {
                row("Increased Memory Limit", signed: report.signed[Self.increasedMemory])
                row("Extended Virtual Addressing", signed: report.signed[Self.extendedAddressing])
                row("Development build (debuggable)", signed: report.signed[Self.debuggable])
            } header: {
                Text("Signed into the app")
            } footer: {
                Text("Read from Horizon's own code signature: what iOS was asked to grant.")
            }
            Section {
                LabeledContent("iOS memory limit for Horizon", value: gib(report.limit))
                LabeledContent("Phone's memory", value: gib(report.physical))
                LabeledContent("Limit as a share of memory", value: report.physical > 0
                               ? "\(Int(Double(report.limit) / Double(report.physical) * 100))%" : "?")
                LabeledContent("Used by the launcher now", value: gib(report.footprint))
                LabeledContent("Address space reserved", value: report.reserved > 0 ? "\(report.reserved) GB" : "under 8 GB")
                verdict
            } header: {
                Text("In effect")
            } footer: {
                Text("iOS sets each app's limit; an app can't choose its own. Increased Memory Limit asks for more, and iOS grants what this model and its current memory pressure allow, so the number can change between checks. The game's own use is set per instance: Edit instance → Memory, and render distance in the game's Options.")
            }
            Section {
                Button("Check again", systemImage: "arrow.clockwise", action: measure)
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear(perform: measure)
    }

    private func row(_ title: String, signed: Bool?) -> some View {
        LabeledContent(title) {
            switch signed {
            case true?: Label("Yes", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: Label("No", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            case nil: Text("Couldn't read").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var verdict: some View {
        let memoryOn = report.physical > 0 && Double(report.limit) / Double(report.physical) > 0.55
        let addressingOn = report.reserved >= 16
        Label(memoryOn ? "Increased memory limit is in effect" : "Limit is about the usual share (iOS may not raise it on this model)",
              systemImage: memoryOn ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(memoryOn ? .green : .orange)
        Label(addressingOn ? "Extended virtual addressing is in effect" : "Extended virtual addressing isn't in effect",
              systemImage: addressingOn ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(addressingOn ? .green : .orange)
    }

    private func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    private func measure() {
        var r = Report()
        r.signed = Self.signedEntitlements()
        r.available = UInt64(os_proc_available_memory())
        r.footprint = Self.footprint()
        r.reserved = Self.largestReservation()
        report = r
    }

    /// The entitlements plist in the executable's code signature (stored as plain XML there).
    static func signedEntitlements() -> [String: Bool] {
        guard let url = Bundle.main.executableURL,
              let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return [:] }
        // The signature sits at the end of the file: search the last few MB.
        let tail = data.suffix(min(data.count, 4 << 20))
        let start = Data("<?xml".utf8), end = Data("</plist>".utf8)
        var from = tail.startIndex
        while let open = tail.range(of: start, in: from..<tail.endIndex),
              let close = tail.range(of: end, in: open.upperBound..<tail.endIndex)
        {
            let blob = tail[open.lowerBound..<close.upperBound]
            if let plist = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
               plist["application-identifier"] != nil
            {
                return [increasedMemory, extendedAddressing, debuggable].reduce(into: [:]) { result, key in
                    result[key] = (plist[key] as? Bool) == true
                }
            }
            from = close.upperBound
        }
        return [:]
    }

    /// The memory iOS counts against the app's limit (task_vm_info's phys_footprint).
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Reserves (no memory used: PROT_NONE) 64, 32, 16, then 8 GB of address space and releases it.
    static func largestReservation() -> Int {
        for gigabytes in [64, 32, 16, 8] {
            let size = gigabytes << 30
            let p = mmap(nil, size, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
            if p != MAP_FAILED, let p {
                munmap(p, size)
                return gigabytes
            }
        }
        return 0
    }
}
