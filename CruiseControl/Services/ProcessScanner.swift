import Foundation
import Darwin

final class ProcessScanner {
    private var previousCPUTimeNanos: [Int32: UInt64] = [:]
    private var previousSampleTime: Date?

    func sampleProcesses() -> [ProcessSample] {
        let pids = listPIDs()
        let now = Date()
        let elapsedSeconds = max(now.timeIntervalSince(previousSampleTime ?? now), 0.001)

        var currentCPU: [Int32: UInt64] = [:]
        var samples: [ProcessSample] = []

        for pid in pids where pid > 0 {
            guard let info = processInfo(pid: pid) else { continue }
            currentCPU[pid] = info.totalCPUTimeNanos

            let previousCPU = previousCPUTimeNanos[pid] ?? info.totalCPUTimeNanos
            let deltaNanos = info.totalCPUTimeNanos >= previousCPU ? info.totalCPUTimeNanos - previousCPU : 0
            let cpuPercent = (Double(deltaNanos) / 1_000_000_000.0) / elapsedSeconds * 100.0

            samples.append(ProcessSample(
                pid: pid,
                name: info.name,
                bundleIdentifier: nil,
                cpuPercent: max(cpuPercent, 0),
                memoryBytes: info.residentBytes,
                sampledAt: now
            ))
        }

        previousCPUTimeNanos = currentCPU
        previousSampleTime = now

        return samples
    }

    private func listPIDs() -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }

        var pids = Array(repeating: Int32(0), count: Int(estimated))
        let bytes = pids.count * MemoryLayout<Int32>.stride

        let filledCount: Int32 = pids.withUnsafeMutableBytes { rawBuffer in
            let ptr = rawBuffer.baseAddress
            return proc_listallpids(ptr, Int32(bytes))
        }

        guard filledCount > 0 else { return [] }
        return Array(pids.prefix(Int(filledCount)))
    }

    private func processInfo(pid: Int32) -> (name: String, totalCPUTimeNanos: UInt64, residentBytes: UInt64)? {
        var taskInfo = proc_taskinfo()
        let expectedSize = MemoryLayout<proc_taskinfo>.stride

        let filled = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, Int32(expectedSize))
        }

        guard filled == expectedSize else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))

        let processName: String
        if nameLength > 0 {
            processName = String(cString: nameBuffer)
        } else {
            processName = "pid-\(pid)"
        }

        let totalCPU = UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
        let resident = UInt64(taskInfo.pti_resident_size)

        return (processName, totalCPU, resident)
    }
}
