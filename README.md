# 2018 MacBook Pro home server — Btrfs-over-micro-VM (procedure 2)

A 2018 Intel MacBook Pro (8 GB RAM, macOS Sequoia 15) becomes a home
server on the Tailnet. This part of the project gives it a large,
checksummed, snapshottable data volume: a USB disk that macOS itself
cannot read (Btrfs), owned end-to-end by a tiny Linux guest.

## Architecture

```
macOS (host)                                   Linux guest (256 MiB)
┌────────────────────────────────┐   VZ NAT    ┌─────────────────────┐
│ btrfs-vm launcher              │ 192.168.64  │ /init (busybox)     │
│ (Virtualization.framework)     │◄───────────►│ virtio-blk -> /dev/ │
│                                │   .0/24     │ vda, mounted Btrfs  │
│ diskutil unmountDisk, then     │             │ compress=zstd,noatime│
│ raw device ────────────────────┼── virtio ──►│ on /mnt/usb         │
│ (/dev/rdiskN)                  │             │                     │
│                                │   NFSv4 /   │ exports: nfsd (2049)│
│ mount_nfs / SMB / ssh ─────────┼◄── SMB / ───┤ ksmbd, dropbear     │
└────────────────────────────────┘   SSH       └─────────────────────┘
        USB disk (raw, no filesystem on the host side at all)
```

Why this shape:

- **No APFS nesting** (no disk image on an APFS volume — that doubles
  copy-on-write and write amplification), **no third-party macOS
  filesystem drivers** (kernel-panic / OS-update breakage risk), and
  **no QEMU/UTM/OrbStack** (OrbStack cannot pass raw block devices;
  the others are far heavier than this single-purpose VM needs).
- The guest is stateless: kernel + initramfs are loaded fresh each
  boot. All persistent state lives on the Btrfs disk itself —
  including the dropbear host keys and `authorized_keys`, under
  `/mnt/usb/.btrfs-vm/`.

## Two corrections to the original design note

These were verified against the actual APIs before writing code; see
`notes/2026-11-27-design-review.md`.

1. **Raw devices use a different attachment class.**
   `VZDiskImageStorageDeviceAttachment` only accepts regular files.
   Raw block devices go through
   `VZDiskBlockDeviceStorageDeviceAttachment(fileHandle:readOnly:synchronizationMode:)`
   (throwing, macOS 14+), with `synchronizationMode: .full`. The
   launcher uses it; the DiskImage attachment remains available via
   `--device-image` for safe testing with a plain file.
2. **VirtioFS cannot publish the guest's filesystem back to the host.**
   `VZVirtioFileSystemDeviceConfiguration` only exposes *host*
   directories *to* the guest. The return path is therefore a network
   export over the VM's NAT network: kernel **NFSv4** (primary),
   **ksmbd/SMB**, and **dropbear SSH/SFTP** (admin).

## Components

| Path | What |
|---|---|
| `launcher/` | Swift Package, executable `btrfs-vm` (see below) |
| `guest/` | `build-initramfs.sh`, guest `/init`, outputs `vmlinuz` + `initramfs.cpio.gz` |
| `host/` | launchd plist, automount-suppression notes, `mount-usb.sh`, `INSTALL.md` |
| `notes/` | design review addendum |

## The launcher (`launcher/`)

Build on the MacBook Pro (Xcode / CLT, Swift 5.9+):

```sh
cd launcher && ./build.sh     # swift build -c release + ad-hoc codesign
                              # with the Virtualization entitlement
```

Run:

```sh
# Safe test with an image file:
sudo ./btrfs-vm run --device-image /tmp/test.img \
    --kernel ../guest/vmlinuz --initrd ../guest/initramfs.cpio.gz

# Real USB disk:
sudo ./btrfs-vm run --device /dev/disk4 \
    --i-understand-this-is-the-usb-disk \
    --kernel ../guest/vmlinuz --initrd ../guest/initramfs.cpio.gz \
    [--cpus 1] [--memory-mib 256] [--read-only] \
    [--cmdline "console=ttyS0"] [--log-file /var/log/btrfs-vm.log]
```

Safety behaviour, by design:

- Raw mode requires `--i-understand-this-is-the-usb-disk`.
- Only whole disks (`/dev/diskN`) are accepted; **disk0 and any disk
  `diskutil` reports as internal are refused**.
- The disk is claimed first with `diskutil unmountDisk force`; if
  macOS volumes are still mounted afterwards, the launcher aborts.
- The device is opened as `/dev/rdiskN` (raw character device).
- SIGINT/SIGTERM request a graceful guest stop.

The guest's address comes from VZ NAT DHCP (192.168.64.0/24). There is
no API to query it from the host, so the guest prints it to the serial
console at boot (`btrfs-vm guest up: IP ...`); with `--log-file` (as
in the launchd plist) it lands in `/var/log/btrfs-vm.log`.

## The guest (`guest/`)

Build on any x86_64 Linux (developed/verified on Ubuntu 24.04):

```sh
cd guest && ./build-initramfs.sh
```

The script downloads a stock **Debian bookworm** kernel
(6.1.0-50-amd64, 6.1.176-1) and userland as .debs through a single
sequential apt process (nothing is installed on the build host),
unpacks them, and assembles an initramfs containing:

- busybox (static) as the shell/toolset,
- `btrfs` + `mkfs.btrfs` (btrfs-progs 6.2) with a bookworm-consistent
  library closure (resolved transitively with `readelf`; mixing build-
  host libraries in causes glibc symbol-version failures — this bit
  us, and the script now guards against it),
- kernel modules (dependency closure, 29 modules): `virtio_blk`,
  `virtio_net`, `btrfs`, `nfsd`, `ksmbd`, and their dependencies,
- NFS userland (`rpc.nfsd`, `exportfs`, `rpc.mountd`, `rpcbind`),
  `ksmbd.mountd`, and dropbear (`dropbear`, `dropbearkey`, `dbclient`).

Guest `/init` flow: mount proc/sys/dev → load modules → DHCP on eth0 →
`btrfs device scan` → mount `/dev/vda` with
`compress=zstd,noatime` on `/mnt/usb` → start exports → banner with
the guest IP and mount status → respawning console shell. Init never
exits.

**Formatting:** an unformatted disk is *never* formatted by default.
Only if the kernel cmdline contains `btrfs_format=1` does the guest
run `mkfs.btrfs -f /dev/vda`. Otherwise it prints instructions and
still brings up networking + SSH so the disk can be prepared manually.

**Exports actually started** (all verified in the boot test below):

- **NFSv4** — `rpc.nfsd --no-nfs-version 3`, 2 threads, export
  `/mnt/usb 192.168.64.0/24(rw,sync,no_subtree_check,insecure,no_root_squash)`.
  NFS is v4-only because v3 needs rpcbind, whose daemonized form exits
  silently in this minimal initramfs (its `-d -f` debug form works;
  the binaries remain in the image for manual use). v4 needs no
  portmapper: clients connect to tcp/2049 directly.
- **SMB** — ksmbd with a guest-access share `\\<guest-ip>\usb`
  (disable with `ksmbd=0` on the cmdline).
- **SSH/SFTP** — dropbear on port 22.

Default kernel cmdline: `console=ttyS0`.

## Host side (`host/`)

See `host/INSTALL.md` for the full sequence. In short: identify the
disk with `diskutil list external`, optionally suppress automount via
`/etc/fstab` (`host/fstab-snippet.txt`), smoke-test with
`--device-image`, then install
`host/com.ysk.btrfs-vm.plist` into `/Library/LaunchDaemons`
(LaunchDaemon, not Agent: raw devices need root; `KeepAlive` +
`RunAtLoad`). Mount the export with `host/mount-usb.sh <guest-ip>`
(NFSv4 via `mount_nfs`, or `smb` mode).

## Memory sizing

Default 256 MiB (`--memory-mib`, sensible range 128–512). The guest
runs an initramfs rootfs, the Btrfs mount, nfsd, ksmbd and dropbear;
256 MiB was the size used in the QEMU verification below and is
comfortable. Btrfs page-cache pressure is the only real consumer —
go to 512 MiB if the host side copies very large files over NFS
regularly; stay at 128–256 MiB if the Mac's 8 GB is contested.

## Security notes

- The guest is reachable **only from the host**, over the VZ NAT
  network (192.168.64.0/24 is not routed anywhere else). All export
  policy assumes that boundary: the NFS export is restricted to that
  subnet, but uses `no_root_squash`; SMB is guest-access; dropbear's
  root password defaults to **`btrfsvm`** (build-time overridable via
  `GUEST_ROOT_PASSWORD`). Treat these as lab defaults for a
  host-only network: drop your SSH key into
  `/mnt/usb/.btrfs-vm/ssh/authorized_keys` on the USB disk (the guest
  picks it up at boot, and host keys persist in
  `/mnt/usb/.btrfs-vm/dropbear/`), and change the password if the
  threat model ever grows beyond "only this Mac can reach it".
- The launcher must run as root for raw-device access (hence the
  LaunchDaemon). The image-file mode does not need root for the disk
  itself, only for nothing else — it runs fine unprivileged except
  that Virtualization.framework may still want the entitlement, which
  `build.sh` applies.

## Known limitations

- **Guest IP discovery is via the console log only** (VZ NAT has no
  host-side lease API). The launchd setup logs the console to
  `/var/log/btrfs-vm.log`; grep it for `guest up: IP`.
- **macOS 14+ is required** for the raw-device attachment API; the
  2018 MBP's final OS (Sequoia 15) satisfies this.
- The launcher **cannot be compiled on the build VM** (Linux, no
  Virtualization.framework); it is compile-tested on GitHub Actions
  (`macos-15-intel`, see below) and must be run on the MBP.
- NFS is v4-only (see above); rpcbind/rpc.mountd are shipped but not
  started by `/init`.
- In the guest, dropbear host keys are generated on first boot and
  stored on the USB disk; if the disk is reformatted, SSH host keys
  change (the guest prints no fingerprint warning — check the console
  log if SSH complains).

## Verification status (2026-11-27, Muse VM)

**Boot-tested under QEMU 8.2.2** (TCG emulation, no KVM; QEMU user
networking instead of VZ NAT, so the guest saw 10.0.2.15 — the
192.168.64.x addressing itself is VZ behaviour and is *not* covered
by this test). Logs: `guest/test/boot-format.log`,
`guest/test/boot-mount.log`.

Verified:

- Kernel 6.1.0-50-amd64 + initramfs boot to the guest shell;
  `/init` executable, `/dev/console` + `/dev/null` nodes present
  (packed with the kernel's `gen_init_cpio`, because this sandbox
  denies `mknod` even to root; the script falls back automatically).
- Boot 1 with `btrfs_format=1` on a blank 256 MB image: `mkfs.btrfs`
  ran in the guest, the disk mounted at `/mnt/usb`
  (`df`: 256.0M total), exports started.
- Boot 2 without the format flag: the existing Btrfs mounted as-is;
  wrote `/mnt/usb/HELLO.txt`; `btrfs subvolume snapshot /mnt/usb
  /mnt/usb/snap1` succeeded (`SNAPSHOT_OK` in the log).
- Exports in-guest: NFSv4 up with 2 threads and tcp/2049 listening;
  ksmbd reported its share up; dropbear reported listening on 22.
- Initramfs contents inspected: `btrfs.ko`, `virtio_blk.ko`,
  `virtio_net.ko`, `nfsd.ko`, `ksmbd.ko` (+ closure, 29 modules),
  `modules.dep`, and the `btrfs`/`mkfs.btrfs`/`rpc.nfsd`/`exportfs`/
  `ksmbd.mountd`/`dropbear` binaries are all present.

Bugs found by the boot test and fixed (kept here as a warning to
future editors): a busybox self-symlink that made `/bin/sh`
unexecutable (ELOOP at boot), `/proc/cmdline` read before proc was
mounted (the format flag was ignored), host/glibc-mixed libraries
(guest `mkfs.btrfs` died with `GLIBC_2.38 not found`), a missing
transitive library (`libgmp` for dropbear), and a missing
`/etc/services` (rpc.nfsd could not resolve the `nfs` port).

**Compile-tested on GitHub Actions (Intel Mac)** — workflow
`.github/workflows/launcher-intel-mac.yml` on `macos-15-intel`:
the first run (45935120707) failed with three real compile errors
(the `FileHandle(forUpdatingAtPath:)` Optional/ternary mix, and
`VZVirtioConsoleDeviceSerialPortConfiguration` /
`VZVirtioNetworkDeviceConfiguration` having no attachment-taking
initializer); after fixing them, run 45935251632 passed all steps
(release build, codesign + entitlement verification, `--help`
smoke test, artifact upload) in 1m17s. GitHub runners cannot start
a Virtualization.framework VM, so this covers compilation only.

**Not yet verified** (needs the real MacBook Pro):

- The Swift launcher actually running a VM (Actions covers the
  compile, not VM startup).
- Raw-device passthrough of a physical USB disk, including the
  `diskutil` claim flow and internal-disk refusal paths.
- VZ NAT addressing (192.168.64.0/24) and the guest-IP banner under
  the launcher, and a host-side `mount_nfs` / SMB mount from macOS
  against the guest exports (in-guest listeners are proven; a real
  macOS client mount is not).
- launchd persistence across reboots on the MBP.
