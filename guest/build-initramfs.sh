#!/bin/sh
# build-initramfs.sh — build the btrfs-vm guest kernel + initramfs.
#
# Runs on any x86_64 Linux with apt/dpkg-deb/curl (developed and verified
# on the Muse VM, Ubuntu 24.04). All downloads are sequential and go
# through a single apt process: a stock Debian bookworm kernel and
# userland are fetched as .debs and unpacked — nothing is installed on
# the host.
#
# Outputs (in this directory):
#   vmlinuz                 Debian bookworm kernel (6.1.x, amd64)
#   initramfs.cpio.gz       the guest root filesystem
#   build/                  scratch (staging root, apt state, logs)
#
# Guest root password defaults to "btrfsvm" (lab use only — the guest is
# reachable only from the host over the VZ NAT network). Override with
# GUEST_ROOT_PASSWORD=... in the environment.
set -eu
cd "$(dirname "$0")"

GUEST_ROOT_PASSWORD=${GUEST_ROOT_PASSWORD:-btrfsvm}
DEBIAN_SUITE=bookworm
WORK=$PWD/build
STAGING=$WORK/staging
ROOTFS=$WORK/rootfs
APT_LISTS=$WORK/apt/lists
APT_CACHE=$WORK/apt/cache
KEYRING_DIR=$WORK/keyring
KEYRING=$KEYRING_DIR/usr/share/keyrings/debian-archive-keyring.gpg
SOURCES=$WORK/sources.list

PACKAGES="linux-image-amd64 busybox-static btrfs-progs dropbear-bin \
nfs-kernel-server ksmbd-tools"

mkdir -p "$WORK" "$STAGING" "$ROOTFS" "$APT_LISTS/partial" "$APT_CACHE/archives/partial"

# --- 1. Debian archive keyring (single sequential download) ----------
if [ ! -f "$KEYRING" ]; then
    echo "== fetching debian-archive-keyring"
    KEYRING_DEB=$WORK/debian-archive-keyring.deb
    # Resolve the current filename from the pool listing, then fetch it.
    fname=$(curl -fs --max-time 30 https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/ \
        | grep -oE 'debian-archive-keyring_[0-9][^"]*\+deb12[^"]*_all\.deb' | sort -u | tail -1)
    [ -n "$fname" ] || { echo "could not resolve keyring deb name" >&2; exit 1; }
    curl -fs --max-time 60 -o "$KEYRING_DEB" \
        "https://deb.debian.org/debian/pool/main/d/debian-archive-keyring/$fname"
    mkdir -p "$KEYRING_DIR"
    dpkg-deb -x "$KEYRING_DEB" "$KEYRING_DIR"
fi

cat > "$SOURCES" <<EOF
deb [signed-by=$KEYRING] https://deb.debian.org/debian $DEBIAN_SUITE main
EOF

APT="apt-get -o Dir::Etc::sourcelist=$SOURCES -o Dir::Etc::sourceparts=/dev/null \
-o Dir::State::lists=$APT_LISTS -o Dir::Cache=$APT_CACHE \
-o Dir::State::status=$WORK/empty-status -o Acquire::Languages=none \
-o APT::Install-Recommends=false -o APT::Install-Suggests=false"
touch "$WORK/empty-status"

# --- 2. Fetch kernel + userland .debs (one apt process, sequential) --
echo "== apt-get update ($DEBIAN_SUITE)"
$APT update
echo "== apt-get download-only: $PACKAGES"
# --download-only pulls the packages plus their dependencies into the
# local cache; nothing is installed on the host.
$APT -y --download-only install $PACKAGES

# --- 3. Unpack everything into the staging root -----------------------
echo "== unpacking debs"
for deb in "$APT_CACHE"/archives/*.deb; do
    dpkg-deb -x "$deb" "$STAGING"
done

KVER=$(ls "$STAGING/lib/modules" | head -1)
[ -n "$KVER" ] || { echo "no kernel modules found in staging" >&2; exit 1; }
cp "$STAGING/boot/vmlinuz-$KVER" ./vmlinuz
echo "== kernel $KVER"
# Debian generates modules.dep in the package postinst, so the .deb
# does not ship it. Generate it for the staging tree with host depmod.
depmod -b "$STAGING" "$KVER"
[ -f "$STAGING/lib/modules/$KVER/modules.dep" ] || \
    { echo "depmod failed to produce modules.dep" >&2; exit 1; }

# --- 4. Assemble the initramfs rootfs ---------------------------------
rm -rf "$ROOTFS"
for d in bin sbin usr/bin usr/sbin proc sys dev etc/udhcpc etc/dropbear \
         lib root/.ssh var/lib/nfs mnt/usb tmp; do
    mkdir -p "$ROOTFS/$d"
done
chmod 1777 "$ROOTFS/tmp"

# busybox (static) + applet symlinks, all in /bin (PATH covers it).
cp "$STAGING/bin/busybox" "$ROOTFS/bin/busybox"
chmod +x "$ROOTFS/bin/busybox"
for applet in $("$STAGING/bin/busybox" --list); do
    # "busybox" itself is in the list — symlinking it would replace the
    # real binary with a self-referential loop (guest exec fails ELOOP).
    [ "$applet" = busybox ] && continue
    ln -sf busybox "$ROOTFS/bin/$applet"
done
[ -f "$ROOTFS/bin/busybox" ] && [ ! -L "$ROOTFS/bin/busybox" ] || \
    { echo "ERROR: /bin/busybox is not a regular file" >&2; exit 1; }
# A few applets are traditionally in /sbin; init uses PATH, but be safe.
for a in modprobe mdev ip ifconfig route; do
    [ -e "$ROOTFS/bin/$a" ] && ln -sf ../bin/busybox "$ROOTFS/sbin/$a"
done

# /init and the udhcpc script.
cp ./init "$ROOTFS/init"
chmod +x "$ROOTFS/init"
cp ./udhcpc-default.script "$ROOTFS/etc/udhcpc/default.script"
chmod +x "$ROOTFS/etc/udhcpc/default.script"

# Helper: copy a staging binary plus its shared libraries (preferring
# the staging/bookworm copies so the guest is self-consistent).
copy_bin() {
    src=$1 dst=$2
    [ -f "$STAGING/$src" ] || { echo "  (missing, skipped: $src)"; return 0; }
    mkdir -p "$ROOTFS$(dirname "$dst")"
    cp "$STAGING/$src" "$ROOTFS$dst"
    chmod +x "$ROOTFS$dst"
    ldd "$STAGING/$src" 2>/dev/null | while read -r a b c _; do
        libpath=""
        case "$a" in /*) libpath=$a ;; esac   # ELF interpreter line
        case "$b" in "=>") [ "$c" != "not" ] && libpath=$c || libpath="" ;; esac
        soname=$(basename "${libpath:-$a}")
        if [ -z "$libpath" ]; then
            # "not found" on the host: look inside staging.
            found=$(find "$STAGING/lib" "$STAGING/usr/lib" -name "$soname" 2>/dev/null | head -1)
            [ -n "$found" ] && libpath=${found#$STAGING}
        fi
        [ -n "$libpath" ] || continue
        mkdir -p "$ROOTFS$(dirname "$libpath")"
        # Prefer the bookworm (staging) copy — mixing host libs in is a
        # glibc-version trap. Debian is merged-usr: a lib the loader
        # calls /lib/... may only exist as /usr/lib/... in staging.
        if [ -f "$STAGING$libpath" ]; then
            cp -L "$STAGING$libpath" "$ROOTFS$libpath"
        elif [ -f "$STAGING/usr$libpath" ]; then
            cp -L "$STAGING/usr$libpath" "$ROOTFS$libpath"
        elif [ -f "$libpath" ]; then
            cp -L "$libpath" "$ROOTFS$libpath"
        fi
    done
}

echo "== userland binaries"
copy_bin usr/bin/btrfs /usr/bin/btrfs
copy_bin bin/btrfs /usr/bin/btrfs
# mkfs.btrfs is a separate program in btrfs-progs (may live in sbin/).
copy_bin usr/sbin/mkfs.btrfs /usr/bin/mkfs.btrfs
copy_bin sbin/mkfs.btrfs /usr/bin/mkfs.btrfs
copy_bin usr/bin/mkfs.btrfs /usr/bin/mkfs.btrfs
copy_bin usr/sbin/dropbear /usr/sbin/dropbear
copy_bin usr/bin/dropbearkey /usr/bin/dropbearkey
copy_bin usr/bin/dbclient /usr/bin/dbclient
# NFS userland (nfs-kernel-server + nfs-common + rpcbind)
copy_bin usr/sbin/exportfs /usr/sbin/exportfs
copy_bin usr/sbin/rpc.nfsd /usr/sbin/rpc.nfsd
copy_bin usr/sbin/rpc.mountd /usr/sbin/rpc.mountd
copy_bin usr/sbin/rpc.statd /usr/sbin/rpc.statd
copy_bin sbin/rpc.statd /usr/sbin/rpc.statd
copy_bin sbin/rpcbind /sbin/rpcbind
copy_bin usr/sbin/rpcbind /sbin/rpcbind
# SMB userland (ksmbd-tools)
copy_bin usr/sbin/ksmbd.mountd /usr/sbin/ksmbd.mountd
copy_bin usr/sbin/ksmbd.adduser /usr/sbin/ksmbd.adduser
# Transitive library closure, bookworm-consistent: walk every ELF in
# the rootfs, read its DT_NEEDED sonames with readelf, and make sure a
# staging (bookworm) copy of each is present — replacing any host copy
# that slipped in, and adding libraries only needed indirectly
# (e.g. libgmp, needed by libtomcrypt, needed by dropbear).
echo "== resolving library closure"
find_lib() {
    for d in "$STAGING/lib/x86_64-linux-gnu" "$STAGING/usr/lib/x86_64-linux-gnu" \
             "$STAGING/lib" "$STAGING/usr/lib"; do
        [ -e "$d/$1" ] && { echo "$d/$1"; return 0; }
    done
    find "$STAGING/lib" "$STAGING/usr/lib" -name "$1" 2>/dev/null | head -1
}
for _round in 1 2 3 4 5 6 7 8; do
    changed=0
    for elf in $(find "$ROOTFS/bin" "$ROOTFS/sbin" "$ROOTFS/usr" "$ROOTFS/lib" -type f 2>/dev/null); do
        for soname in $(readelf -d "$elf" 2>/dev/null | sed -n 's/.*Shared library: \[\(.*\)\].*/\1/p'); do
            dst=""
            [ -e "$ROOTFS/lib/x86_64-linux-gnu/$soname" ] && dst="$ROOTFS/lib/x86_64-linux-gnu/$soname"
            if [ -z "$dst" ] && [ -e "$ROOTFS/usr/lib/x86_64-linux-gnu/$soname" ]; then
                dst="$ROOTFS/usr/lib/x86_64-linux-gnu/$soname"
            fi
            src=$(find_lib "$soname")
            if [ -z "$dst" ]; then
                if [ -n "$src" ]; then
                    mkdir -p "$ROOTFS/lib/x86_64-linux-gnu"
                    cp -L "$src" "$ROOTFS/lib/x86_64-linux-gnu/$soname"; changed=1
                else
                    echo "  warning: no staging lib for $soname (needed by ${elf#$ROOTFS})"
                fi
            elif [ -n "$src" ] && ! cmp -s "$src" "$dst"; then
                cp -L "$src" "$dst"; changed=1
            fi
        done
    done
    [ $changed -eq 0 ] && break
done
# The ELF interpreter must be bookworm's as well.
LD_SRC=$(find_lib ld-linux-x86-64.so.2)
[ -n "$LD_SRC" ] && { mkdir -p "$ROOTFS/lib64"; cp -L "$LD_SRC" "$ROOTFS/lib64/ld-linux-x86-64.so.2"; }

# libgcc_s.so.1 is not in any DT_NEEDED list: glibc dlopen()s it at
# runtime for pthread_cancel, and btrfs-progs' scrub abort()s without
# it ("libgcc_s.so.1 must be installed for pthread_cancel to work",
# seen in the QEMU datapath test). Force-copy it from staging.
GCC_SRC=$(find_lib libgcc_s.so.1)
[ -n "$GCC_SRC" ] && cp -L "$GCC_SRC" "$ROOTFS/lib/x86_64-linux-gnu/libgcc_s.so.1"

# rpcbind needs its runtime dir + the nfs idmap helper config files.
mkdir -p "$ROOTFS/run/rpcbind" "$ROOTFS/var/lib/nfs/sm" "$ROOTFS/var/lib/nfs/sm.bak"
[ -f "$STAGING/etc/idmapd.conf" ] && cp "$STAGING/etc/idmapd.conf" "$ROOTFS/etc/" || true
# rpcbind reads /etc/netconfig (libtirpc); without it rpcbind exits and
# nfsd cannot register its RPC services (errno 111).
[ -f "$STAGING/etc/netconfig" ] && cp "$STAGING/etc/netconfig" "$ROOTFS/etc/" || true
touch "$ROOTFS/var/lib/nfs/rmtab" "$ROOTFS/var/lib/nfs/etab" "$ROOTFS/var/lib/nfs/xtab" \
      "$ROOTFS/var/lib/nfs/state"

# Accounts. Root password is for the host-only NAT network; change it.
HASH=$(openssl passwd -6 "$GUEST_ROOT_PASSWORD" 2>/dev/null || echo '!')
cat > "$ROOTFS/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/bin/false
rpc:x:100:100:rpc:/run/rpcbind:/bin/false
EOF
cat > "$ROOTFS/etc/group" <<'EOF'
root:x:0:
nogroup:x:65534:
rpc:x:100:
EOF
printf 'root:%s:19000:0:99999:7:::\nnobody:*:19000:0:99999:7:::\nrpc:*:19000:0:99999:7:::\n' "$HASH" > "$ROOTFS/etc/shadow"
chmod 600 "$ROOTFS/etc/shadow"
# rpc.nfsd / rpcbind resolve port names ("nfs", "sunrpc") via
# /etc/services; without it nfsd cannot start. Take Debian's file.
if [ -f "$STAGING/etc/services" ]; then
    cp "$STAGING/etc/services" "$ROOTFS/etc/services"
else
    printf 'sunrpc 111/tcp rpcbind\nsunrpc 111/udp rpcbind\nnfs 2049/tcp\nnfs 2049/udp\n' \
        > "$ROOTFS/etc/services"
fi
echo btrfs-vm > "$ROOTFS/etc/hostname"
printf '127.0.0.1 localhost btrfs-vm\n' > "$ROOTFS/etc/hosts"
touch "$ROOTFS/etc/exports"

# --- 5. Kernel modules: dependency closure for the seeds --------------
echo "== kernel modules"
MODSRC=$STAGING/lib/modules/$KVER
MODDST=$ROOTFS/lib/modules/$KVER
mkdir -p "$MODDST"
SEEDS="virtio virtio_ring virtio_pci virtio_blk virtio_net \
libcrc32c crc32c_generic xxhash lzo_compress zlib_deflate zstd_compress \
btrfs nfsd auth_rpcgss rpcsec_gss_krb5 ksmbd \
sunrpc lockd grace nfsv4 dns_resolver"
WANTED=$WORK/wanted.txt; RESOLVED=$WORK/resolved.txt
: > "$WANTED"; : > "$RESOLVED"
for m in $SEEDS; do echo "$m" >> "$WANTED"; done
# Iterate: resolve each wanted module name to a file, then add the names
# of its dependencies (from modules.dep) to the wanted list.
for _round in 1 2 3 4 5 6 7 8 9 10 11 12; do
    progress=0
    while read -r mod; do
        grep -qx "$mod" "$RESOLVED" && continue
        f=$(find "$MODSRC/kernel" -name "$mod.ko" -o -name "$mod.ko.xz" -o -name "$mod.ko.zst" 2>/dev/null | head -1)
        [ -n "$f" ] || continue
        echo "$mod" >> "$RESOLVED"; progress=1
        rel=${f#$MODSRC/}
        mkdir -p "$MODDST/$(dirname "$rel")"
        cp "$f" "$MODDST/$rel"
        deps=$(grep "^$rel:" "$MODSRC/modules.dep" | sed 's/^[^:]*://')
        for d in $deps; do
            n=$(basename "$d" | sed 's/\.ko\(\.xz\|\.zst\)\?$//; s/-/_/g')
            grep -qx "$n" "$WANTED" || echo "$n" >> "$WANTED"
        done
    done < "$WANTED"
    [ $progress -eq 0 ] && break
done
echo "  modules included: $(find "$MODDST" -name '*.ko*' | wc -l)"
for must in virtio_blk btrfs; do
    find "$MODDST" -name "$must.ko*" | grep -q . \
        || { echo "ERROR: required module $must not included" >&2; exit 1; }
done
for opt in nfsd ksmbd virtio_net; do
    if find "$MODDST" -name "$opt.ko*" | grep -q .; then echo "  optional module present: $opt"
    else echo "  optional module ABSENT in this kernel: $opt"; fi
done
# Regenerate modules.dep & friends for the subset (host depmod).
depmod -b "$ROOTFS" "$KVER" 2>/dev/null || \
    echo "  warning: depmod failed; busybox modprobe needs modules.dep — check manually"

# --- 6. Device nodes + pack -------------------------------------------
# The kernel opens /dev/console from the initramfs before devtmpfs is
# mounted, so static nodes for console/null matter.
USE_GEN_INIT_CPIO=0
if mknod -m 600 "$ROOTFS/dev/console" c 5 1 2>/dev/null; then
    mknod -m 666 "$ROOTFS/dev/null" c 1 3 2>/dev/null || true
else
    # Sandboxed builders may lack CAP_MKNOD even as root. Fall back to
    # the kernel's own gen_init_cpio, which writes device-node entries
    # into the archive without creating real nodes on the host.
    echo "  mknod not permitted here; using gen_init_cpio fallback"
    USE_GEN_INIT_CPIO=1
    rm -f "$ROOTFS/dev/console" "$ROOTFS/dev/null"
    GIC=$WORK/gen_init_cpio
    if [ ! -x "$GIC" ]; then
        curl -fs --max-time 30 -o "$WORK/gen_init_cpio.c" \
            https://raw.githubusercontent.com/torvalds/linux/v6.1/usr/gen_init_cpio.c
        cc -O2 -o "$GIC" "$WORK/gen_init_cpio.c"
    fi
fi

echo "== packing initramfs.cpio.gz"
if [ $USE_GEN_INIT_CPIO -eq 0 ]; then
    ( cd "$ROOTFS" && find . | "$STAGING/bin/busybox" cpio -o -H newc 2>/dev/null | gzip -9 ) > ./initramfs.cpio.gz
else
    SPEC=$WORK/initramfs.list
    : > "$SPEC"
    echo "nod /dev/console 600 0 0 c 5 1" >> "$SPEC"
    echo "nod /dev/null 666 0 0 c 1 3" >> "$SPEC"
    ( cd "$ROOTFS" && find . -mindepth 1 | while read -r p; do
        rel=/${p#./}
        mode=$(stat -c %a "$p")
        if [ -L "$p" ]; then
            echo "slink $rel $(readlink "$p") $mode 0 0"
        elif [ -d "$p" ]; then
            echo "dir $rel $mode 0 0"
        elif [ -f "$p" ]; then
            echo "file $rel $PWD/${p#./} $mode 0 0"
        fi
      done ) >> "$SPEC"
    "$GIC" "$SPEC" | gzip -9 > ./initramfs.cpio.gz
fi

ls -lh ./vmlinuz ./initramfs.cpio.gz
echo "== done. Kernel $KVER, modules: $(find "$MODDST" -name '*.ko*' | wc -l)"
