#!/bin/sh
# mount-usb.sh — mount the guest's Btrfs export on this Mac.
#
# Usage:
#   ./mount-usb.sh <guest-ip> [mountpoint]           # NFSv4 (primary)
#   ./mount-usb.sh <guest-ip> [mountpoint] smb       # SMB via Finder CLI
#   ./mount-usb.sh --unmount [mountpoint]
#
# The guest IP is the 192.168.64.x address the guest prints to the
# serial console at boot ("btrfs-vm guest up: IP 192.168.64.x/24") —
# see /var/log/btrfs-vm.log when running under launchd.
#
# NFS notes: the guest exports /mnt/usb to the VZ NAT subnet only.
# macOS NFSv4 wants a resvport by default for privileged sources; the
# guest export uses `insecure`, so a plain mount works. If your macOS
# version's NFSv4 client misbehaves, fall back to SMB.
set -eu

MOUNTPOINT_DEFAULT="$HOME/USB-Btrfs"

if [ "${1:-}" = "--unmount" ]; then
    mp=${2:-$MOUNTPOINT_DEFAULT}
    umount "$mp" 2>/dev/null || diskutil unmount "$mp" || true
    echo "unmounted $mp"
    exit 0
fi

GUEST_IP=${1:?usage: mount-usb.sh <guest-ip> [mountpoint] [nfs|smb]}
MOUNTPOINT=${2:-$MOUNTPOINT_DEFAULT}
MODE=${3:-nfs}

mkdir -p "$MOUNTPOINT"
case "$MODE" in
nfs)
    echo "Mounting nfs://$GUEST_IP/mnt/usb at $MOUNTPOINT (NFSv4)"
    mount_nfs -o vers=4,rw,soft,intr "$GUEST_IP:/mnt/usb" "$MOUNTPOINT"
    ;;
smb)
    echo "Mounting smb://guest@$GUEST_IP/usb at $MOUNTPOINT"
    mount_smbfs "//guest@$GUEST_IP/usb" "$MOUNTPOINT"
    ;;
*)
    echo "unknown mode: $MODE (expected nfs or smb)" >&2
    exit 2
    ;;
esac
echo "Mounted. Try: ls '$MOUNTPOINT'"
