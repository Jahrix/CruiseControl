import Foundation
import Darwin
import IOKit
import IOKit.storage

struct MemorySnapshot {
    let freeBytes: UInt64
    let activeBytes: UInt64
    let wiredBytes: UInt64
    let compressedBytes: UInt64
}

struct DiskIOSnapshot {
    let bytesRead: UInt64
    let bytesWritten: UInt64
}

enum SystemMetricsReader {
    static func readHostCPUTicks() -> host_cpu_load_info_data_t? {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return cpuInfo
    }

    static func readMemorySnapshot() -> MemorySnapshot? {
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let pageBytes = UInt64(pageSize)
        return MemorySnapshot(
            freeBytes: (UInt64(vmStats.free_count) + UInt64(vmStats.speculative_count)) * pageBytes,
            activeBytes: UInt64(vmStats.active_count) * pageBytes,
            wiredBytes: UInt64(vmStats.wire_count) * pageBytes,
            compressedBytes: UInt64(vmStats.compressor_page_count) * pageBytes
        )
    }

    static func readSwapUsedBytes() -> UInt64? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size

        let result = sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        guard result == 0 else { return nil }

        return swap.xsu_used
    }

    static func readDiskIOSnapshot() -> DiskIOSnapshot? {
        guard let matching = IOServiceMatching(kIOBlockStorageDriverClass) else { return nil }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totalRead: UInt64 = 0
        var totalWritten: UInt64 = 0

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 {
                break
            }

            defer { IOObjectRelease(entry) }

            guard let properties = readProperties(entry: entry),
                  let statistics = properties[kIOBlockStorageDriverStatisticsKey as String] as? [String: Any] else {
                continue
            }

            totalRead += anyToUInt64(statistics[kIOBlockStorageDriverStatisticsBytesReadKey as String])
            totalWritten += anyToUInt64(statistics[kIOBlockStorageDriverStatisticsBytesWrittenKey as String])
        }

        return DiskIOSnapshot(bytesRead: totalRead, bytesWritten: totalWritten)
    }

    static func readFreeDiskBytes() -> UInt64? {
        do {
            let values = try URL(fileURLWithPath: NSHomeDirectory())
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])

            if let important = values.volumeAvailableCapacityForImportantUsage {
                return UInt64(max(important, 0))
            }
            if let available = values.volumeAvailableCapacity {
                return UInt64(max(available, 0))
            }
            return nil
        } catch {
            return nil
        }
    }

    private static func readProperties(entry: io_registry_entry_t) -> [String: Any]? {
        var unmanagedProperties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(entry, &unmanagedProperties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let retained = unmanagedProperties?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return retained
    }

    private static func anyToUInt64(_ value: Any?) -> UInt64 {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int64 {
            return UInt64(max(value, 0))
        }
        return 0
    }
}
