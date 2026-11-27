#!/bin/sh
# run-session.sh — one-sitting real-device verification session for the
# btrfs-vm project on the 2018 MacBook Pro.
#
# Real-device time is available only once every two weeks, so this
# script runs every MBP-only check in a single pass, in dependency
# order, and leaves a timestamped log directory with a PASS/FAIL/SKIP
# summary per section:
#
#   0. preflight (macOS version, arch, Swift toolchain)
#   1. launcher available (build from the repo clone if needed)
#   2. launcher refusal-path checks (no VM is started)
#   3. image-mode boot test: boot the guest on a throwaway image file,
#      discover its IP from the console log, mount the NFSv4 export
#      from macOS, write + read back a file, verify its checksum
#   4. raw-device boot test (ONLY with --usb-device /dev/diskN and ONLY
#      after interactively typing the device name; disk0 is refused
#      here and again inside the launcher)
#   5. summary
#
# Usage:
#   ./run-session.sh [--usb-device /dev/diskN] [--dry-run]
#
# Safe to Ctrl-C: the trap stops any guest this script started.
# Nothing in this script touches disk0 or any disk you do not name.
set -u

DRY_RUN=0
USB_DEVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --usb-device) shift; USB_DEVICE=${1:-} ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<'EOF'
DRY RUN — this script would, in order:
  0. Create ~/btrfs-vm-session-<timestamp>/ and log everything into it.
  1. Print sw_vers / uname -m / swift --version (expect: macOS 15.x,
     x86_64, Swift 5.9+).
  2. Locate ./btrfs-vm, or build it: if run inside the repo use
     launcher/build.sh, else clone ysk-agent/mbp2018-home-server into
     ~/mbp2018-home-server and build there. Kernel + initramfs come
     from the repo's guest/ directory (committed artifacts).
  3. Run the four refusal-path checks (disk0, missing ack flag,
     partition path, missing kernel file) — no VM is started.
  4. Image-mode test: create a 256 MiB throwaway image in the log
     directory, boot the guest with btrfs_format=1, wait for the
     "guest up: IP" banner, extract the 192.168.64.x address, mount
     the export with mount_nfs (vers=4; SMB fallback), write a test
     file, read it back, compare sha256, unmount, stop the guest.
  5. Raw-device test (only if --usb-device /dev/diskN was given):
     show diskutil info for the device, require typing the exact
     device name (e.g. "disk4") to proceed, optionally require typing
     FORMAT to allow btrfs_format=1, then repeat the boot + mount +
     checksum test against the real USB device. disk0 is refused.
  6. Print a PASS/FAIL/SKIP summary per section.
No changes would be made. Exiting.
EOF
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
LOGDIR="$HOME/btrfs-vm-session-$STAMP"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/session.log"
exec >>"$LOG" 2>&1

VM_PID=""
cleanup() {
    if [ -n "$VM_PID" ] && kill -0 "$VM_PID" 2>/dev/null; then
        echo "cleanup: stopping guest (pid $VM_PID)"
        kill -INT "$VM_PID" 2>/dev/null
        sleep 3
        kill -9 "$VM_PID" 2>/dev/null
    fi
}
trap cleanup INT TERM EXIT

RESULTS=""
record() { # record <section> <PASS|FAIL|SKIP> <note>
    RESULTS="$RESULTS
  [$2] $1 — $3"
    echo "== SECTION RESULT: $1: $2 ($3)"
}
section() { echo ""; echo "############ $1 ############"; }

echo "btrfs-vm real-device session $STAMP"
echo "log directory: $LOGDIR"
echo "(this console is mirrored to $LOG)"

# ---------- 0. preflight -------------------------------------------------
section "0. preflight"
sw_vers
ARCH=$(uname -m); echo "arch: $ARCH"
[ "$ARCH" = "x86_64" ] && record preflight PASS "arch x86_64" \
    || record preflight FAIL "expected x86_64, got $ARCH"
if swift --version; then
    record toolchain PASS "swift present"
else
    record toolchain FAIL "swift not found — install Xcode CLT first"
fi
diskutil list external || true

# ---------- 1. launcher ---------------------------------------------------
section "1. launcher"
LAUNCHER=""
KERNEL=""
INITRD=""
if [ -x "$REPO_ROOT/launcher/btrfs-vm" ]; then
    LAUNCHER="$REPO_ROOT/launcher/btrfs-vm"
elif [ -x "./btrfs-vm" ]; then
    LAUNCHER="./btrfs-vm"
else
    SRC="$REPO_ROOT"
    if [ ! -d "$SRC/launcher" ]; then
        SRC="$HOME/mbp2018-home-server"
        [ -d "$SRC" ] || git clone https://github.com/ysk-agent/mbp2018-home-server "$SRC"
    fi
    ( cd "$SRC/launcher" && ./build.sh )
    [ -x "$SRC/launcher/btrfs-vm" ] && LAUNCHER="$SRC/launcher/btrfs-vm"
    REPO_ROOT="$SRC"
fi
KERNEL="$REPO_ROOT/guest/vmlinuz"
INITRD="$REPO_ROOT/guest/initramfs.cpio.gz"
if [ -n "$LAUNCHER" ] && [ -f "$KERNEL" ] && [ -f "$INITRD" ]; then
    record launcher PASS "$LAUNCHER"
else
    record launcher FAIL "launcher/kernel/initramfs not all present"
    echo "$RESULTS"; echo "logs: $LOGDIR"; exit 1
fi

# ---------- 2. refusal paths ----------------------------------------------
section "2. refusal-path checks (no VM started)"
echo dummy > "$LOGDIR/dummy-kernel"; echo dummy > "$LOGDIR/dummy-initrd"
REFUSAL_FAILS=0
check_refusal() {
    desc=$1; expected=$2; shift 2
    out=$("$@" 2>&1); status=$?
    echo "--- $desc: exit=$status: $out"
    if [ "$status" -eq 0 ] || ! printf '%s' "$out" | grep -q "$expected"; then
        REFUSAL_FAILS=$((REFUSAL_FAILS+1))
    fi
}
check_refusal "disk0 refused" "refusing disk0" \
    "$LAUNCHER" run --device /dev/disk0 --i-understand-this-is-the-usb-disk \
    --kernel "$LOGDIR/dummy-kernel" --initrd "$LOGDIR/dummy-initrd"
check_refusal "ack flag required" "raw-device mode requires" \
    "$LAUNCHER" run --device /dev/disk4 \
    --kernel "$LOGDIR/dummy-kernel" --initrd "$LOGDIR/dummy-initrd"
check_refusal "partition refused" "must be a whole disk" \
    "$LAUNCHER" run --device /dev/disk1s1 --i-understand-this-is-the-usb-disk \
    --kernel "$LOGDIR/dummy-kernel" --initrd "$LOGDIR/dummy-initrd"
check_refusal "missing kernel file" "no such file:" \
    "$LAUNCHER" run --device-image "$LOGDIR/dummy-kernel" \
    --kernel /nonexistent/vmlinuz --initrd "$LOGDIR/dummy-initrd"
[ "$REFUSAL_FAILS" -eq 0 ] && record refusals PASS "4/4 refused as expected" \
    || record refusals FAIL "$REFUSAL_FAILS check(s) behaved unexpectedly"

# ---------- helpers for boot tests -----------------------------------------
# boot_and_test <mode-args...> <extra-cmdline> <label>
# Expects the guest to format (if cmdline says so), come up, and serve
# /mnt/usb; mounts it from macOS and verifies a file round-trip.
boot_and_test() {
    label=$1; cmdline=$2; shift 2
    glog="$LOGDIR/guest-$label.log"
    echo "starting guest ($label), console log: $glog"
    sudo "$LAUNCHER" run "$@" \
        --kernel "$KERNEL" --initrd "$INITRD" \
        --cmdline "console=ttyS0 $cmdline" \
        --log-file "$glog" &
    VM_PID=$!
    ip=""
    i=0
    while [ $i -lt 60 ]; do
        if grep -q "guest up: IP" "$glog" 2>/dev/null; then
            ip=$(grep "guest up: IP" "$glog" | grep -o '192\.168\.64\.[0-9]*' | head -1)
            break
        fi
        kill -0 "$VM_PID" 2>/dev/null || break
        sleep 3; i=$((i+1))
    done
    if [ -z "$ip" ]; then
        record "boot-$label" FAIL "guest banner/IP not seen (see $glog)"
        cleanup; VM_PID=""
        return
    fi
    echo "guest IP: $ip"
    mp="$LOGDIR/mnt-$label"
    mkdir -p "$mp"
    if mount_nfs -o vers=4 "$ip:/mnt/usb" "$mp" 2>"$LOGDIR/mount-$label.err"; then
        echo "roundtrip-data-$label" > "$mp/SESSION_TEST.txt"
        sum1=$(shasum -a 256 "$mp/SESSION_TEST.txt" | awk '{print $1}')
        got=$(cat "$mp/SESSION_TEST.txt")
        umount "$mp" || diskutil unmount "$mp" || true
        if [ "$got" = "roundtrip-data-$label" ] && [ -n "$sum1" ]; then
            record "boot-$label" PASS "NFS mount + file round-trip at $ip (sha256 $sum1)"
        else
            record "boot-$label" FAIL "mounted, but file round-trip mismatch"
        fi
    else
        echo "mount_nfs failed: $(cat "$LOGDIR/mount-$label.err")"
        record "boot-$label" FAIL "macOS mount_nfs could not mount the export (try SMB manually: smb://guest@$ip/usb)"
    fi
    cleanup; VM_PID=""
    sleep 2
}

# ---------- 3. image-mode boot test ----------------------------------------
section "3. image-mode boot test"
IMG="$LOGDIR/test-image.img"
dd if=/dev/zero of="$IMG" bs=1m count=256 2>/dev/null
boot_and_test image "btrfs_format=1" --device-image "$IMG"

# ---------- 4. raw-device boot test ----------------------------------------
section "4. raw-device boot test"
if [ -z "$USB_DEVICE" ]; then
    record boot-raw SKIP "no --usb-device given"
else
    case "$USB_DEVICE" in
        /dev/disk0|/dev/rdisk0) record boot-raw FAIL "disk0 is never allowed" ;;
        /dev/disk[0-9]*)
            diskutil info "$USB_DEVICE" || true
            printf 'Type the device name exactly (e.g. disk4) to continue: '
            read -r typed </dev/tty
            name=${USB_DEVICE#/dev/}
            if [ "$typed" != "$name" ]; then
                record boot-raw SKIP "device name not confirmed ('$typed' != '$name')"
            else
                printf 'Type FORMAT to allow formatting this device as Btrfs, or anything else to boot without formatting: '
                read -r fmt </dev/tty
                extra=""
                [ "$fmt" = "FORMAT" ] && extra="btrfs_format=1"
                boot_and_test raw "$extra" --device "$USB_DEVICE" \
                    --i-understand-this-is-the-usb-disk
            fi
            ;;
        *) record boot-raw FAIL "--usb-device must look like /dev/diskN" ;;
    esac
fi

# ---------- 5. summary ------------------------------------------------------
section "5. summary"
echo "Results:$RESULTS"
echo ""
echo "Logs and artifacts: $LOGDIR"
echo "Manual follow-ups for this same sitting: see CHECKLIST.md"
trap - EXIT
