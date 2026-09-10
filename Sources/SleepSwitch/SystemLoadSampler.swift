import Foundation
import Darwin

/// Read-only host counters; works without a privileged helper or shell tools.
final class SystemLoadSampler {
    private var previousTicks: [UInt32]?
    private var cached: CompanionSystemLoad?

    func sample(at now: Date = Date()) -> CompanionSystemLoad {
        if let cached, (0..<1).contains(now.timeIntervalSince(cached.sampledAt)) { return cached }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        var cpuPercent: Double?
        if cpuResult == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            cpuPercent = previousTicks.flatMap { CompanionSystemLoadMath.cpuPercent(previous: $0, current: ticks) }
            previousTicks = ticks
        } else { previousTicks = nil }

        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        let total = ProcessInfo.processInfo.physicalMemory
        let used = vmResult == KERN_SUCCESS && pageResult == KERN_SUCCESS ? CompanionSystemLoadMath.memoryUsed(
            active: UInt64(vm.active_count), inactive: UInt64(vm.inactive_count), wired: UInt64(vm.wire_count),
            compressed: UInt64(vm.compressor_page_count), purgeable: UInt64(vm.purgeable_count),
            fileBacked: UInt64(vm.external_page_count), pageSize: UInt64(pageSize), total: total) : nil
        let result = CompanionSystemLoad(sampledAt: now, cpuPercent: cpuPercent, memoryUsedBytes: used, memoryTotalBytes: used == nil ? nil : total)
        cached = result
        return result
    }
}
