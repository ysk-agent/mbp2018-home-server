# 2018 MacBook Pro home server — design review addendum (2026-11-27)

Source: Yosuke's design note in chat, 2026-11-27. This file records only the
checks and corrections mio added; the note itself remains the authoritative
design.

## Corrections / risks found on review

1. **Raw-device attachment API name is wrong in the note.**
   `VZDiskImageStorageDeviceAttachment` is for regular disk-image files.
   Raw block devices are supported by Virtualization.framework through a
   different attachment: `VZDiskBlockDeviceStorageDeviceAttachment`
   (vfkit's VZ adapter uses exactly this for its block-device backend:
   validates `S_IFBLK`, opens the device, sync mode `Full`).
   So the architecture is feasible, but the launcher must use the
   DiskBlockDevice attachment, run with permission to open `/dev/rdiskX`,
   and first claim/eject the disk from Disk Arbitration so macOS does not
   mount or fight over it. This is the single make-or-break spike for
   roadmap step 2 and should be tested before writing the full launcher:
   attach a throwaway USB stick, boot a stock Linux kernel, confirm the
   guest sees `/dev/vda` with the stick's size and can write/read back.

2. **VirtioFS cannot share guest -> host.**
   `VZVirtioFileSystemDeviceConfiguration` exposes *host* directories *to*
   the guest. It cannot publish the guest's Btrfs mount back to macOS.
   The return path must be network-based over the VM's network device
   (VZ NAT, 192.168.64.0/24, or a socketpair network):
   guest runs NFS / SMB / sshfs server on the Btrfs mount, host mounts it.
   NFS from the guest is the lightest of those. The note listed VirtioFS
   among the return-path candidates; remove it from that list.

3. **Consequences for step ordering.**
   Step 2 has one binary risk (raw attachment) that can be retired in a
   half-day spike with a disposable USB stick and no Btrfs commitment.
   Step 3 (resident programs) does not depend on Btrfs at all — it only
   needs the proxy + launchd base from roadmap step 1 — so it can proceed
   in parallel once a target program is named.

## Recommended sequence

- 1a. Base setup (pmset, Tailscale, tinyproxy/gost bound to the Tailscale IP)
  — unblocks both tracks.
- 2-spike. Raw-attachment feasibility test only (no initramfs polish).
- Then either 2-full (launcher + initramfs + guest NFS export) or 3,
  depending on which resident workload is more urgent.
