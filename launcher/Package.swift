// swift-tools-version: 5.9
import PackageDescription

// btrfs-vm: a minimal Virtualization.framework launcher that passes a raw
// USB block device to a tiny Linux guest, which mounts it as Btrfs and
// exports it back to macOS over the VM's NAT network.
//
// No external dependencies: only Foundation + Virtualization.
let package = Package(
    name: "btrfs-vm",
    platforms: [
        // VZDiskBlockDeviceStorageDeviceAttachment requires macOS 14+.
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(name: "btrfs-vm", path: "Sources/btrfs-vm")
    ]
)
