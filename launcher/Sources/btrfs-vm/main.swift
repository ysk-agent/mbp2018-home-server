// btrfs-vm — minimal Virtualization.framework launcher for the 2018
// MacBook Pro home-server project.
//
// It boots a tiny Linux kernel + initramfs, passing either:
//   * a raw USB block device (/dev/diskN) via
//     VZDiskBlockDeviceStorageDeviceAttachment (macOS 14+), or
//   * a plain disk-image file via VZDiskImageStorageDeviceAttachment
//     (--device-image, for safe testing before touching real hardware)
// as a Virtio block device. The guest mounts the device as Btrfs and
// exports it back over the VZ NAT network (192.168.64.0/24); see the
// project README. VirtioFS cannot do the guest -> host direction, which
// is why the return path is a network export (NFS/SMB/SSH in the guest).
//
// Safety rules enforced here:
//   * raw-device mode requires --i-understand-this-is-the-usb-disk
//   * the target must be a whole disk (/dev/diskN or /dev/rdiskN)
//   * disk0 and any disk `diskutil` reports as internal are refused
//   * the disk is unmounted (diskutil unmountDisk force) before opening

import Foundation
import Virtualization

// MARK: - CLI

struct Options {
    var device: String? = nil          // /dev/diskN (raw mode)
    var deviceImage: String? = nil     // regular file (image mode)
    var readOnly = false
    var cpus = 1
    var memoryMiB: UInt64 = 256
    var kernel: String? = nil
    var initrd: String? = nil
    var cmdline = "console=ttyS0"
    var logFile: String? = nil
    var acknowledgeRawDevice = false
}

func usage() -> Never {
    let text = """
    Usage:
      btrfs-vm run --device /dev/diskN --i-understand-this-is-the-usb-disk \\
                   --kernel <vmlinuz> --initrd <initramfs.cpio.gz> [options]
      btrfs-vm run --device-image <file> \\
                   --kernel <vmlinuz> --initrd <initramfs.cpio.gz> [options]

    Options:
      --device /dev/diskN     Raw USB disk (whole disk only; disk0 and
                              internal disks are refused). Opens /dev/rdiskN.
      --device-image <file>   Plain disk image file (testing mode).
      --read-only             Attach the disk read-only.
      --cpus N                vCPUs (default 1).
      --memory-mib N          Guest RAM in MiB (default 256).
      --kernel <path>         Linux kernel image (required).
      --initrd <path>         Initramfs, cpio.gz (required).
      --cmdline "..."         Kernel command line
                              (default "console=ttyS0"; the guest honours
                              btrfs_format=1 to format an unformatted disk).
      --log-file <path>       Also write the serial console to this file.
      --i-understand-this-is-the-usb-disk
                              Required acknowledgement for raw-device mode.

    The guest gets its address from VZ NAT DHCP (192.168.64.0/24) and
    prints it to the serial console; watch the console output for
    "btrfs-vm guest up: IP ...".
    """
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("btrfs-vm: error: \(message)\n".utf8))
    exit(1)
}

func parseArgs(_ args: [String]) -> Options {
    guard args.first == "run" else { usage() }
    var o = Options()
    var i = 1
    func value(_ flag: String) -> String {
        i += 1
        guard i < args.count else { fail("\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--device": o.device = value("--device")
        case "--device-image": o.deviceImage = value("--device-image")
        case "--read-only": o.readOnly = true
        case "--cpus":
            guard let n = Int(value("--cpus")), n >= 1 else { fail("--cpus must be >= 1") }
            o.cpus = n
        case "--memory-mib":
            guard let n = UInt64(value("--memory-mib")), n >= 64 else { fail("--memory-mib must be >= 64") }
            o.memoryMiB = n
        case "--kernel": o.kernel = value("--kernel")
        case "--initrd": o.initrd = value("--initrd")
        case "--cmdline": o.cmdline = value("--cmdline")
        case "--log-file": o.logFile = value("--log-file")
        case "--i-understand-this-is-the-usb-disk": o.acknowledgeRawDevice = true
        case "--help", "-h": usage()
        default: fail("unknown argument: \(args[i])")
        }
        i += 1
    }
    return o
}

// MARK: - Raw-device safety checks

/// Runs /usr/sbin/diskutil and returns its stdout, or nil on failure.
func diskutil(_ arguments: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    p.arguments = arguments
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Validates a raw-device path and returns (diskutilName, rawPath):
/// diskutilName is "diskN" (for diskutil), rawPath is "/dev/rdiskN"
/// (character device, used for the actual open — much faster than the
/// buffered /dev/diskN).
func validateRawDevice(_ path: String) -> (String, String) {
    let base = (path as NSString).lastPathComponent
    // Accept diskN and rdiskN, whole disks only (no "s1" slice suffix).
    let name: String
    if base.hasPrefix("rdisk") { name = String(base.dropFirst(1)) } else { name = base }
    guard path.hasPrefix("/dev/"),
          name.hasPrefix("disk"),
          name.dropFirst(4).allSatisfy({ $0.isNumber }),
          !name.dropFirst(4).isEmpty
    else {
        fail("--device must be a whole disk: /dev/diskN (got \(path))")
    }
    if name == "disk0" {
        fail("refusing disk0: that is the host's internal disk")
    }
    let info = diskutil(["info", name])
    guard info.status == 0 else {
        fail("diskutil info \(name) failed: \(info.output)")
    }
    // "Device Location: Internal" marks built-in disks (e.g. a soldered
    // internal SSD appearing as disk2 on some machines). Refuse them all.
    if info.output.contains("Internal") &&
       !info.output.contains("External") {
        fail("refusing \(name): diskutil reports it as an internal disk:\n\(info.output)")
    }
    return (name, "/dev/r\(name)")
}

/// Claims the disk from Disk Arbitration so macOS does not mount it or
/// fight the guest over it.
func claimDisk(_ name: String) {
    let r = diskutil(["unmountDisk", "force", name])
    // unmountDisk exits non-zero when nothing was mounted; only treat a
    // hard failure (device busy / not found) as fatal if the disk still
    // has mounted volumes. Check with `diskutil list` output instead:
    // simplest robust rule — fail if the command failed AND the disk is
    // not a valid external disk per the earlier info call.
    if r.status != 0 && !r.output.lowercased().contains("was already unmounted") {
        FileHandle.standardError.write(
            Data("btrfs-vm: warning: diskutil unmountDisk \(name) said: \(r.output)\n".utf8))
        // A mounted volume we cannot unmount means something is using
        // the disk; proceeding could corrupt a live filesystem.
        let list = diskutil(["list", name])
        if list.output.contains("Apple_APFS") || list.output.contains("Apple_HFS") {
            fail("could not unmount \(name) and it still shows mounted macOS volumes; refusing to continue")
        }
    }
}

// MARK: - Serial console plumbing

/// Fan-out: everything the guest writes to its serial port goes to our
/// stdout and, if requested, to a log file. VZ wants a single writing
/// file handle, so we hand it a Pipe and copy from the other end.
final class ConsoleFanOut {
    let writeHandle: FileHandle
    private let readHandle: FileHandle
    private var logHandle: FileHandle?
    private let queue = DispatchQueue(label: "btrfs-vm.console")

    init(logFilePath: String?) {
        let pipe = Pipe()
        writeHandle = pipe.fileHandleForWriting
        readHandle = pipe.fileHandleForReading
        if let path = logFilePath {
            FileManager.default.createFile(atPath: path, contents: nil)
            logHandle = FileHandle(forWritingAtPath: path)
        }
        readHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardOutput.write(data)
            if let log = self?.logHandle {
                try? log.write(contentsOf: data)
            }
        }
    }
}

// MARK: - VM delegate

final class Delegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("\nbtrfs-vm: guest stopped")
        exit(0)
    }
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(
            Data("btrfs-vm: guest stopped with error: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Main

let options = parseArgs(Array(CommandLine.arguments.dropFirst()))
guard let kernelPath = options.kernel, let initrdPath = options.initrd else {
    fail("--kernel and --initrd are required")
}
guard (options.device == nil) != (options.deviceImage == nil) else {
    fail("specify exactly one of --device or --device-image")
}
for p in [kernelPath, initrdPath] + (options.deviceImage.map { [$0] } ?? []) {
    guard FileManager.default.fileExists(atPath: p) else { fail("no such file: \(p)") }
}

// Build the storage attachment.
let storage: VZStorageDeviceConfiguration
if let imagePath = options.deviceImage {
    // Testing mode: a regular file holding a disk image.
    let attachment: VZDiskImageStorageDeviceAttachment
    do {
        attachment = try VZDiskImageStorageDeviceAttachment(
            url: URL(fileURLWithPath: imagePath),
            readOnly: options.readOnly,
            cachingMode: .automatic,
            synchronizationMode: .full)
    } catch { fail("could not attach image file: \(error)") }
    storage = VZVirtioBlockDeviceConfiguration(attachment: attachment)
} else {
    // Raw-device mode.
    guard options.acknowledgeRawDevice else {
        fail("raw-device mode requires --i-understand-this-is-the-usb-disk")
    }
    let (diskName, rawPath) = validateRawDevice(options.device!)
    claimDisk(diskName)
    let handle: FileHandle
    if options.readOnly {
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: rawPath))
        } catch {
            fail("could not open \(rawPath): \(error)")
        }
    } else {
        // FileHandle(forUpdatingAtPath:) is the non-throwing, Optional-
        // returning Objective-C initializer — unlike forReadingFrom above.
        guard let h = FileHandle(forUpdatingAtPath: rawPath) else {
            fail("could not open \(rawPath) (raw devices need root — run via sudo / the LaunchDaemon)")
        }
        handle = h
    }
    let attachment: VZDiskBlockDeviceStorageDeviceAttachment
    do {
        // The correct API for raw block devices (macOS 14+). The
        // DiskImage attachment only accepts regular files.
        attachment = try VZDiskBlockDeviceStorageDeviceAttachment(
            fileHandle: handle,
            readOnly: options.readOnly,
            synchronizationMode: .full)
    } catch { fail("could not attach raw device: \(error)") }
    storage = VZVirtioBlockDeviceConfiguration(attachment: attachment)
}

// Boot loader: direct Linux kernel boot.
let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
bootLoader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
bootLoader.commandLine = options.cmdline

// Serial console on stdio (stdin -> guest, guest -> stdout [+ log]).
let console = ConsoleFanOut(logFilePath: options.logFile)
let serialAttachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: FileHandle.standardInput,
    fileHandleForWriting: console.writeHandle)
// These two configurations have no attachment-taking initializer:
// create them empty and assign the attachment property.
let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
serialPort.attachment = serialAttachment

// Network: VZ NAT. The guest receives a 192.168.64.0/24 address by DHCP
// and prints it to the serial console.
let network = VZVirtioNetworkDeviceConfiguration()
network.attachment = VZNATNetworkDeviceAttachment()

let config = VZVirtualMachineConfiguration()
config.cpuCount = options.cpus
config.memorySize = options.memoryMiB * 1024 * 1024
config.bootLoader = bootLoader
config.storageDevices = [storage]
config.networkDevices = [network]
config.serialPorts = [serialPort]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

do { try config.validate() } catch { fail("configuration invalid: \(error)") }

let vm = VZVirtualMachine(configuration: config, queue: .main)
let delegate = Delegate()
vm.delegate = delegate

// Graceful shutdown on SIGINT/SIGTERM. The sources must stay alive for
// the process lifetime, hence the global array.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        print("\nbtrfs-vm: signal received, requesting guest stop…")
        if vm.canRequestStop {
            try? vm.requestStop()
        } else {
            exit(0)
        }
        // If the guest ignores the request, exit anyway after a grace period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    }
    source.resume()
    signalSources.append(source)
}

print("btrfs-vm: starting guest (\(options.cpus) CPU, \(options.memoryMiB) MiB, " +
      (options.deviceImage != nil ? "image \(options.deviceImage!)" : "device \(options.device!)") +
      ", \(options.readOnly ? "read-only" : "read-write"))")
print("btrfs-vm: guest IP hint — VZ NAT assigns 192.168.64.x by DHCP; the guest prints its address to this console.")
vm.start { result in
    switch result {
    case .success:
        print("btrfs-vm: guest running")
    case .failure(let error):
        fail("guest failed to start: \(error)")
    }
}

dispatchMain()
