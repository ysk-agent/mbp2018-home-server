# Real-device session checklist (2018 MacBook Pro)

Real-device verification time comes **once every two weeks**. Everything
that can be checked off-device (QEMU guest tests, Intel Mac CI) is
already automated; this checklist is only what genuinely needs the
MBP, ordered to fit one sitting. Run `run-session.sh` first — it
covers the automated sections and leaves a log directory
(`~/btrfs-vm-session-YYYYMMDD-HHMMSS/`) to attach notes to.

## 0. Before you start

- [ ] MBP on AC power, lid state as it will run day-to-day.
- [ ] A **disposable** USB device for the raw test (everything on it
      may be formatted as Btrfs). Identify it:
      `diskutil list external` → note its `diskN`. Cross-check with
      `diskutil info /dev/diskN` (must say `Device Location: External`).

## 1. Automated session script

- [ ] `cd host/session-kit && ./run-session.sh --usb-device /dev/diskN`
- [ ] Expected: sections 0–4 all PASS in the summary (raw section may
      be SKIP only if you deliberately withhold the device), and the
      guest IP in the log is a `192.168.64.x` address (VZ NAT — this
      confirms the addressing QEMU could not cover).

## 2. launchd persistence (script cannot do this for you)

- [ ] Install the daemon:
      `sudo cp host/com.ysk.btrfs-vm.plist /Library/LaunchDaemons/`
      (edit the plist's device path + log path first, per
      `host/INSTALL.md`)
- [ ] `sudo launchctl load -w /Library/LaunchDaemons/com.ysk.btrfs-vm.plist`
- [ ] Expected: `tail -f /var/log/btrfs-vm.log` shows the guest banner
      with its IP; `host/mount-usb.sh <guest-ip>` mounts the export.
- [ ] **Reboot the MBP** (`sudo reboot`), log back in, and confirm
      without touching anything else:
      `grep "guest up: IP" /var/log/btrfs-vm.log` shows a fresh banner
      from after the reboot, and the export mounts again.

## 3. Power / thermal settings

- [ ] Sleep disabled as designed:
      `pmset -g | grep -E "sleep|disksleep"` → expect `sleep 0`,
      `disksleep 0` (see the design note's pmset line).
- [ ] AlDente (or equivalent) charge limit set to **80%**:
      open AlDente → confirm the limit slider is at 80 and the current
      charge is holding at/below it.

## 4. Tailscale

- [ ] `tailscale ip -4` → record the MBP's 100.x address in the
      session log directory.
- [ ] `tailscale status` → the MBP shows as connected, and this
      session's other nodes (mio VM, moto g05) are visible.
- [ ] From the MBP, confirm the residential egress:
      `curl -s https://ifconfig.me` → expect the home fixed-line IP
      (not a datacenter address).

## 5. Soak note (the only item that outlives the sitting)

- [ ] Leave the VM running under launchd when you finish. Next day
      (from anywhere on the Tailnet), check:
      `grep -c "guest up" /var/log/btrfs-vm.log` (should still be the
      count from this session — no crash-restart loop), mount the
      export once more, and confirm the `SESSION_TEST.txt` written
      during the session is still there and intact.
- [ ] Jot the result (uptime, any restarts, any thermal/fan notes)
      into the session log directory as `soak-note.txt`.
