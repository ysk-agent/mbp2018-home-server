# Host install notes (macOS side, 2018 MacBook Pro)

Order matters: identify the disk first, test with an image file,
then go raw.

## 1. Install the pieces

```sh
sudo mkdir -p /usr/local/btrfs-vm
# Built on this Mac (see ../launcher/build.sh):
sudo cp ../launcher/btrfs-vm /usr/local/btrfs-vm/
# Built on the Muse VM / any Linux x86_64 (see ../guest/build-initramfs.sh):
sudo cp ../guest/vmlinuz ../guest/initramfs.cpio.gz /usr/local/btrfs-vm/
```

## 2. Identify the USB disk — carefully

```sh
diskutil list external physical
diskutil info /dev/diskN
```

Confirm: external, the expected size, and NOT the internal SSD.
The launcher refuses disk0 and anything `diskutil` calls internal,
and raw mode needs the `--i-understand-this-is-the-usb-disk` flag —
but those are guardrails, not a substitute for reading the output.

## 3. Smoke-test with an image file first (no hardware risk)

```sh
# A 512 MB scratch image, formatted by the guest itself on first boot:
dd if=/dev/zero of=/tmp/test.img bs=1m count=512
sudo /usr/local/btrfs-vm/btrfs-vm run --device-image /tmp/test.img \
  --kernel /usr/local/btrfs-vm/vmlinuz \
  --initrd /usr/local/btrfs-vm/initramfs.cpio.gz \
  --cmdline "console=ttyS0 btrfs_format=1"
# Second run: drop btrfs_format=1; the guest should mount the image.
```

Watch the console for `btrfs-vm guest up: IP 192.168.64.x` and the
mount banner, then from another terminal:

```sh
./mount-usb.sh 192.168.64.x
```

## 4. Go raw, manually first

Optionally suppress automount (see `fstab-snippet.txt`), then:

```sh
sudo /usr/local/btrfs-vm/btrfs-vm run --device /dev/diskN \
  --i-understand-this-is-the-usb-disk \
  --kernel /usr/local/btrfs-vm/vmlinuz \
  --initrd /usr/local/btrfs-vm/initramfs.cpio.gz
```

Add `btrfs_format=1` to a `--cmdline "console=ttyS0 btrfs_format=1"`
**only** for the first run against a disk you intend to wipe.

## 5. Make it permanent (launchd)

Edit the paths/device in `com.ysk.btrfs-vm.plist`, then:

```sh
sudo cp com.ysk.btrfs-vm.plist /Library/LaunchDaemons/
sudo chown root:wheel /Library/LaunchDaemons/com.ysk.btrfs-vm.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.ysk.btrfs-vm.plist
tail -f /var/log/btrfs-vm.log     # serial console incl. the guest IP
```

To stop: `sudo launchctl bootout system/com.ysk.btrfs-vm`.

## 6. Day-to-day

- Mount from macOS: `./mount-usb.sh <guest-ip>` (NFSv4) — the IP is in
  the boot banner in `/var/log/btrfs-vm.log`; VZ NAT DHCP usually
  reassigns the same address, but do not hard-code it blindly.
- SSH into the guest: `ssh root@<guest-ip>` (see the README's
  "Security notes" for credentials and how to install your key).
- Snapshots etc. run inside the guest: `btrfs subvolume snapshot …`
  over SSH.
