#!/usr/bin/env python3
"""QEMU test orchestrator for the btrfs-vm guest.

Boots guest/vmlinuz + guest/initramfs.cpio.gz under QEMU (TCG, user
networking), drives the guest's serial console shell, and interleaves
host-side client tests (NFS / SMB / SSH via hostfwd). Each scenario
writes one combined log under guest/test/.

Usage: run_tests.py <scenario>   # datapath | mem128 | readonly | unformatted
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GUEST = os.path.dirname(HERE)
KERNEL = os.path.join(GUEST, "vmlinuz")
INITRD = os.path.join(GUEST, "initramfs.cpio.gz")
SRC_IMG = os.path.join(HERE, "test-disk.img")


class Guest:
    def __init__(self, logpath, qemu_args):
        self.log = open(logpath, "wb", buffering=0)
        self.buf = bytearray()
        self.lock = threading.Lock()
        cmd = ["qemu-system-x86_64", "-display", "none", "-serial", "stdio",
               "-monitor", "none", "-machine", "pc", "-smp", "1",
               "-kernel", KERNEL, "-initrd", INITRD] + qemu_args
        self.host_say("QEMU: " + " ".join(cmd))
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        self.t = threading.Thread(target=self._reader, daemon=True)
        self.t.start()

    def _reader(self):
        while True:
            # read1, NOT read: BufferedReader.read(n) waits until n
            # bytes are buffered or EOF, which deadlocks against a
            # guest that has gone idle at its shell prompt with <n
            # bytes outstanding (this bug stalled two test runs with
            # the guest sitting healthy at the prompt).
            chunk = self.proc.stdout.read1(4096)
            if not chunk:
                return
            with self.lock:
                self.buf += chunk
            self.log.write(chunk)

    def host_say(self, msg):
        line = ("\nHOST: " + msg + "\n").encode()
        with self.lock:
            self.buf += line
        self.log.write(line)

    def text(self):
        with self.lock:
            return bytes(self.buf).decode("utf-8", "replace")

    def wait_for(self, pattern, timeout=180):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if re.search(pattern, self.text()):
                return True
            if self.proc.poll() is not None:
                return False
            time.sleep(0.3)
        return False

    def cmd(self, command, timeout=90):
        """Run a shell command in the guest; return output between markers."""
        marker = "MK%d" % int(time.time() * 1000 % 10**8)
        self.proc.stdin.write(
            ("echo %s_S; %s; echo %s_E=$?\n" % (marker, command, marker)).encode())
        self.proc.stdin.flush()
        if not self.wait_for(marker + r"_E=(\d+)", timeout):
            self.host_say("TIMEOUT waiting for: " + command)
            return ""
        m = re.search(marker + r"_S(.*)" + marker + r"_E=(\d+)",
                      self.text(), re.S)
        return m.group(1) if m else ""

    def poweroff(self):
        try:
            self.proc.stdin.write(b"poweroff -f\n")
            self.proc.stdin.flush()
            self.proc.wait(timeout=40)
        except Exception:
            self.proc.kill()


def fresh_img(name, size_mb=None, zeroed=False):
    dst = os.path.join(HERE, name)
    if zeroed:
        with open(dst, "wb") as f:
            f.truncate(size_mb * 1024 * 1024)
    else:
        shutil.copyfile(SRC_IMG, dst)
    return dst


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def scenario_datapath():
    logpath = os.path.join(HERE, "boot-datapath.log")
    img = fresh_img("datapath-disk.img")
    g = Guest(logpath, [
        "-m", "256",
        "-append", "console=ttyS0 nfs_allow=10.0.2.0/24,127.0.0.1",
        "-drive", "file=%s,format=raw,if=virtio" % img,
        "-netdev", "user,id=n0,hostfwd=tcp::12049-:2049,"
                   "hostfwd=tcp::10445-:445,hostfwd=tcp::10022-:22",
        "-device", "virtio-net-pci,netdev=n0",
    ])
    ok = g.wait_for(r"guest up: IP", 180)
    g.host_say("banner seen: %s" % ok)
    g.wait_for(r"/ # ", 60)

    # --- guest-side: compression proof (test 4) ---
    out = g.cmd("dd if=/dev/zero of=/mnt/usb/ZEROS10.bin bs=1M count=10 2>&1; sync; "
                "ls -l /mnt/usb/ZEROS10.bin; df -h /mnt/usb; "
                "btrfs filesystem usage /mnt/usb; "
                "echo GUEST_MARKER_CONTENT > /mnt/usb/GUEST_SIDE.txt; sync")
    g.host_say("compression/guest-write output:\n" + out)

    # --- guest-side: scrub (test 8) ---
    out = g.cmd("btrfs scrub start -B /mnt/usb 2>&1; echo SCRUB_RC=$?")
    g.host_say("scrub output:\n" + out)

    # --- host-side: NFS data path (test 1) ---
    mnt = "/tmp/nfsmnt"
    os.makedirs(mnt, exist_ok=True)
    # No soft/timeo caps: a fresh nfsd holds new mounts in its
    # 90-second grace period and the client must be allowed to retry
    # through it. The subprocess timeout (150s) is the bound instead.
    # Single bounded attempt. Status as of 2026-11-27: the host-side
    # NFS mount is UNVERIFIED in every off-device environment tried —
    # this sandbox (no kernel NFS client at all), and GitHub's ubuntu
    # runners (mount.nfs either errors with "Protocol not supported"
    # when mountport is passed, or hangs in negotiation through QEMU
    # slirp hostfwd without it). The result is reported, not asserted;
    # the authoritative client test is macOS mount_nfs in the
    # real-device session kit. See README.
    nfs_host_ok = False
    try:
        r = subprocess.run(["mount", "-t", "nfs", "-o",
                            "vers=4,port=12049",
                            "127.0.0.1:/mnt/usb", mnt],
                           capture_output=True, text=True, timeout=60)
        nfs_host_ok = (r.returncode == 0)
    except subprocess.TimeoutExpired:
        class R: returncode = -1; stdout = ""; stderr = "mount timed out after 60s"
        r = R()
    g.host_say("mount attempt rc=%d out=%s %s" % (r.returncode, r.stdout, r.stderr))
    g.host_say("host mount.nfs rc=%d out=%s %s" % (r.returncode, r.stdout, r.stderr))
    if r.returncode == 0:
        with open(os.path.join(mnt, "HOST_NFS.txt"), "w") as f:
            f.write("written-via-nfs-from-host\n")
        with open(os.path.join(mnt, "GUEST_SIDE.txt")) as f:
            g.host_say("read back GUEST_SIDE.txt via NFS: " + f.read().strip())
        g.host_say("NFS dir listing: " + " ".join(sorted(os.listdir(mnt))))
        subprocess.run(["umount", mnt], capture_output=True, timeout=30)
    else:
        g.host_say("HOST NFS MOUNT FAILED (host kernel NFS client "
                   "unavailable or export refused)")
    g.host_say("HOST_NFS_MOUNT=%s" % ("PASS" if nfs_host_ok else "FAIL"))

    # --- host-side: SMB data path (test 2) ---
    with open("/tmp/smb-put.txt", "w") as f:
        f.write("written-via-smb-from-host\n")
    r = subprocess.run(["smbclient", "-L", "127.0.0.1", "-p", "10445", "-N"],
                       capture_output=True, text=True, timeout=45)
    g.host_say("smbclient -L rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
    r = subprocess.run(["smbclient", "//127.0.0.1/usb", "-p", "10445", "-N",
                        "-c", "ls; put /tmp/smb-put.txt HOST_SMB.txt; get GUEST_SIDE.txt /tmp/smb-get.txt"],
                       capture_output=True, text=True, timeout=45)
    g.host_say("smbclient rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
    if os.path.exists("/tmp/smb-get.txt"):
        with open("/tmp/smb-get.txt") as f:
            g.host_say("SMB get GUEST_SIDE.txt: " + f.read().strip())

    # --- host-side: dropbear data path (test 3) ---
    ssh_opts = ["-p", "10022", "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=15"]
    r = subprocess.run(["ssh"] + ssh_opts + ["-o", "BatchMode=yes",
                                             "-o", "PreferredAuthentications=none",
                                             "root@127.0.0.1", "true"],
                       capture_output=True, text=True, timeout=40)
    g.host_say("ssh blank/none-auth attempt rc=%d\n%s\n%s" % (r.returncode, r.stdout, r.stderr))
    r = subprocess.run(["sshpass", "-p", "btrfsvm", "ssh"] + ssh_opts +
                       ["root@127.0.0.1", "echo SSH_LOGIN_OK"],
                       capture_output=True, text=True, timeout=40)
    g.host_say("ssh password(btrfsvm) login: %s (rc=%d)\n%s\n%s"
               % ("PASS" if "SSH_LOGIN_OK" in r.stdout else "FAIL",
                  r.returncode, r.stdout, r.stderr))
    with open("/tmp/scp-put.txt", "w") as f:
        f.write("written-via-scp-from-host\n")
    # File transfer over ssh stdin: scp cannot work against this
    # guest (dropbear ships no SFTP subsystem, and there is no
    # server-side `scp` binary for legacy mode — both were tried and
    # failed; see README). `ssh 'cat > file' < file` is the supported
    # transfer path.
    with open("/tmp/scp-put.txt", "rb") as f:
        payload = f.read()
    r = subprocess.run(["sshpass", "-p", "btrfsvm", "ssh"] + ssh_opts +
                       ["root@127.0.0.1", "cat > /mnt/usb/HOST_SCP.txt"],
                       input=payload, capture_output=True, timeout=40)
    g.host_say("ssh-stdin transfer rc=%d\n%s" % (r.returncode, r.stderr.decode("utf-8", "replace")))

    # --- guest-side: verify everything landed ---
    out = g.cmd("ls -l /mnt/usb; cat /mnt/usb/HOST_NFS.txt /mnt/usb/HOST_SMB.txt /mnt/usb/HOST_SCP.txt 2>&1; sync")
    g.host_say("guest verification of host-written files:\n" + out)

    # NOTE: an in-guest loopback NFS mount (client and nfsd in the
    # same kernel) was tried as a fallback and timed out at 100s in
    # every run (MOUNT_RC=143) — that configuration is not a valid
    # test of the export, so it was removed. The host-side mount
    # above is the only authoritative NFS test.
    g.poweroff()
    print("datapath done, log:", logpath)


def scenario_mem128():
    logpath = os.path.join(HERE, "boot-mem128.log")
    img = fresh_img("mem128-disk.img")
    g = Guest(logpath, [
        "-m", "128",
        "-append", "console=ttyS0 nfs_allow=10.0.2.0/24",
        "-drive", "file=%s,format=raw,if=virtio" % img,
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
    ])
    ok = g.wait_for(r"guest up: IP", 180)
    g.host_say("banner seen at 128MiB: %s" % ok)
    if ok:
        g.wait_for(r"/ # ", 60)
        out = g.cmd("free; grep -E 'MemTotal|MemAvailable' /proc/meminfo; "
                    "netstat -ltn 2>/dev/null | grep -E '2049|445|22' ; echo PORTS_ABOVE")
        g.host_say("mem128 guest state:\n" + out)
    g.poweroff()
    print("mem128 done, log:", logpath)


def scenario_readonly():
    logpath = os.path.join(HERE, "boot-readonly.log")
    img = fresh_img("readonly-disk.img")
    g = Guest(logpath, [
        "-m", "256",
        "-append", "console=ttyS0 nfs_allow=10.0.2.0/24",
        "-drive", "file=%s,format=raw,if=virtio,readonly=on" % img,
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
    ])
    ok = g.wait_for(r"guest up: IP", 180)
    g.host_say("banner seen (readonly): %s" % ok)
    if ok:
        g.wait_for(r"/ # ", 60)
        out = g.cmd("grep usb /proc/mounts; touch /mnt/usb/WRITE_TEST 2>&1; echo TOUCH_RC=$?; "
                    "cat /etc/exports; ls /mnt/usb")
        g.host_say("readonly guest state:\n" + out)
    g.poweroff()
    print("readonly done, log:", logpath)


def scenario_unformatted():
    logpath = os.path.join(HERE, "boot-unformatted.log")
    img = fresh_img("unformatted-disk.img", size_mb=64, zeroed=True)
    before = sha256(img)
    g = Guest(logpath, [
        "-m", "256",
        "-append", "console=ttyS0",
        "-drive", "file=%s,format=raw,if=virtio" % img,
        "-netdev", "user,id=n0",
        "-device", "virtio-net-pci,netdev=n0",
    ])
    ok = g.wait_for(r"guest up: IP", 180)
    g.host_say("banner seen (unformatted): %s" % ok)
    g.wait_for(r"/ # ", 60)
    g.poweroff()
    after = sha256(img)
    with open(logpath, "a") as f:
        f.write("\nHOST: sha256 before=%s\nHOST: sha256 after =%s\nHOST: IMAGE_UNCHANGED=%s\n"
                % (before, after, before == after))
    print("unformatted done, unchanged:", before == after)


if __name__ == "__main__":
    {"datapath": scenario_datapath, "mem128": scenario_mem128,
     "readonly": scenario_readonly,
     "unformatted": scenario_unformatted}[sys.argv[1]]()
