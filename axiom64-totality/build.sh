#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/out"
ROOTFS="$WORK/rootfs"
ISO="$WORK/iso"
IMAGE="${ALPINE_IMAGE:-alpine:3.24.1}"
VERSION="7.0.0"

rm -rf "$WORK" "$OUT"
mkdir -p "$ROOTFS" "$ISO/boot/grub" "$OUT/logs"
exec > >(tee "$OUT/build-trace.log") 2>&1
set -x

docker pull "$IMAGE"
CID="$(docker run -d --privileged "$IMAGE" sleep 7200)"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

RUNTIME_PACKAGES='alpine-base linux-firmware-none linux-lts kmod busybox-extras openrc util-linux iproute2 nftables e2fsprogs btrfs-progs xfsprogs dosfstools pciutils usbutils nvme-cli smartmontools cryptsetup lvm2 mdadm tpm2-tools dropbear openssh-client curl ca-certificates openssl bash jq coreutils findutils grep sed gawk procps strace lsof ethtool tcpdump iperf3 socat bind-tools chrony wireguard-tools libcap musl-utils zstd lz4 xz alsa-utils weston mesa-dri-gallium mesa-egl mesa-gbm libdrm wayland dbus seatd scanelf'
BUILD_PACKAGES='build-base linux-headers'

docker exec "$CID" sh -euxc "apk update && apk add --no-cache $RUNTIME_PACKAGES $BUILD_PACKAGES"

docker cp "$ROOT/rootfs-overlay/." "$CID":/
docker cp "$ROOT/security_probe.c" "$CID":/tmp/security_probe.c

docker exec "$CID" sh -euxc '
  cc -Os -static -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wall -Wextra -Werror \
    /tmp/security_probe.c -o /usr/bin/axiom-security-probe
  strip /usr/bin/axiom-security-probe
  chmod 0755 /sbin/axiom-init /usr/sbin/axiom-selftest /usr/bin/axiom-security-probe
  KVER=$(basename /lib/modules/*)
  depmod -a "$KVER"
  apk info -vv | sort > /etc/axiom-packages.txt
  apk del --no-cache build-base linux-headers
  rm -rf /var/cache/apk/* /tmp/* /usr/share/man/* /usr/share/doc/*
'

as --64 -o "$WORK/axiom-asm-probe.o" "$ROOT/axiom_asm_probe.S"
ld -m elf_x86_64 -nostdlib -static -z noexecstack -o "$WORK/axiom-asm-probe" "$WORK/axiom-asm-probe.o"
strip "$WORK/axiom-asm-probe"
docker cp "$WORK/axiom-asm-probe" "$CID":/usr/bin/axiom-asm-probe

# Avoid a streaming tar pipeline: special /dev nodes and a non-zero tar/cpio
# exit otherwise become indistinguishable under pipefail on hosted runners.
docker export -o "$WORK/rootfs.tar" "$CID"
cleanup
trap - EXIT

tar --extract --file="$WORK/rootfs.tar" --directory="$ROOTFS" \
  --no-same-owner --no-same-permissions \
  --exclude='dev/*' --exclude='./dev/*' \
  --exclude='proc/*' --exclude='./proc/*' \
  --exclude='sys/*' --exclude='./sys/*' \
  --exclude='run/*' --exclude='./run/*'
rm -f "$WORK/rootfs.tar"

ln -sfn sbin/axiom-init "$ROOTFS/init"
mkdir -p "$ROOTFS/etc/axiom" "$ROOTFS/run" "$ROOTFS/tmp" "$ROOTFS/mnt" \
  "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/sys/fs/cgroup"
chmod 0755 "$ROOTFS/run" "$ROOTFS/mnt" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev"
chmod 1777 "$ROOTFS/tmp"
printf '%s\n' 'Axiom64 Totality 7.0.0' > "$ROOTFS/etc/axiom/release"
BASE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "$IMAGE")"
KERNEL_VERSION="$(basename "$ROOTFS"/lib/modules/*)"
cat > "$ROOTFS/etc/axiom/build.json" <<EOF
{"name":"Axiom64 Totality","version":"$VERSION","base":"$BASE_DIGEST","kernel":"$KERNEL_VERSION","profile":"hybrid-qualified","rootfs":"immutable-initramfs"}
EOF

KERNEL_SRC="$ROOTFS/boot/vmlinuz-lts"
test -s "$KERNEL_SRC"
cp "$KERNEL_SRC" "$OUT/vmlinuz-axiom64"
# The live root does not need another copy of its kernel or Alpine-generated initramfs.
rm -f "$ROOTFS/boot/vmlinuz-lts" "$ROOTFS/boot/initramfs-lts"

# Build the initramfs in two explicit stages and exclude sockets/pseudo-fs
# contents. Root executes cpio so deliberately unreadable setuid helpers keep
# their restrictive mode rather than being weakened merely for packaging.
if ! (
  cd "$ROOTFS"
  find . -xdev \
    \( -path './proc/*' -o -path './sys/*' -o -path './dev/*' -o -path './run/*' -o -path './tmp/*' \) -prune -o \
    ! -type s -print0 \
    | LC_ALL=C sort -z \
    | sudo cpio --null -o --format=newc --owner=0:0 --quiet > "$WORK/initramfs.cpio" 2> "$OUT/cpio.log"
); then
  cat "$OUT/cpio.log" >&2 || true
  exit 1
fi
sudo chown "$(id -u):$(id -g)" "$WORK/initramfs.cpio"
zstd -15 -T0 -f "$WORK/initramfs.cpio" -o "$OUT/initramfs-axiom64.zst"
rm -f "$WORK/initramfs.cpio"

test -s "$OUT/initramfs-axiom64.zst"
cp "$OUT/vmlinuz-axiom64" "$ISO/boot/vmlinuz-axiom64"
cp "$OUT/initramfs-axiom64.zst" "$ISO/boot/initramfs-axiom64.zst"

cat > "$ISO/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=3
set gfxpayload=keep

menuentry 'Axiom64 Totality 7.0.0 — Interactive' {
    linux /boot/vmlinuz-axiom64 console=tty0 console=ttyS0,115200n8 rdinit=/sbin/axiom-init quiet loglevel=4 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 intel_iommu=on iommu.strict=1
    initrd /boot/initramfs-axiom64.zst
}
EOF

grub-mkrescue -o "$OUT/axiom64-totality-7.0.0.iso" "$ISO" >"$OUT/grub-mkrescue.log" 2>&1

CI_ISO="$WORK/iso-ci"
cp -a "$ISO" "$CI_ISO"
cat > "$CI_ISO/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=0
menuentry 'Axiom64 qualification' {
    linux /boot/vmlinuz-axiom64 console=ttyS0,115200n8 rdinit=/sbin/axiom-init axiom.test=iso axiom.expected_cpus=2 loglevel=4 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 intel_iommu=on iommu.strict=1
    initrd /boot/initramfs-axiom64.zst
}
EOF
grub-mkrescue -o "$WORK/axiom64-totality-ci.iso" "$CI_ISO" >"$OUT/grub-mkrescue-ci.log" 2>&1

python3 - "$ROOTFS/etc/axiom-packages.txt" "$OUT/SBOM.spdx.json" <<'PY'
import hashlib, json, pathlib, sys
src, dst = map(pathlib.Path, sys.argv[1:])
packages = []
for line in src.read_text(errors='replace').splitlines():
    if not line.strip():
        continue
    namever = line.split()[0]
    packages.append({
        'SPDXID': 'SPDXRef-Package-' + hashlib.sha256(namever.encode()).hexdigest()[:16],
        'name': namever,
        'versionInfo': namever,
        'downloadLocation': 'NOASSERTION',
        'filesAnalyzed': False,
        'licenseConcluded': 'NOASSERTION',
        'licenseDeclared': 'NOASSERTION',
    })
doc = {
    'spdxVersion':'SPDX-2.3', 'dataLicense':'CC0-1.0',
    'SPDXID':'SPDXRef-DOCUMENT', 'name':'Axiom64-Totality-7.0.0',
    'documentNamespace':'https://axiom64.invalid/spdx/' + hashlib.sha256(src.read_bytes()).hexdigest(),
    'creationInfo':{'created':'2026-09-01T00:00:00Z','creators':['Tool: Axiom64 build.sh']},
    'packages':packages,
}
dst.write_text(json.dumps(doc, indent=2, sort_keys=True) + '\n')
PY

cat > "$OUT/run-qemu.sh" <<'EOF'
#!/usr/bin/env sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec qemu-system-x86_64 -machine q35 -cpu max -smp 8 -m 3072 \
  -cdrom "$HERE/axiom64-totality-7.0.0.iso" -serial stdio
EOF
chmod +x "$OUT/run-qemu.sh"

cp "$ROOT/README.md" "$OUT/README.md"
(
  cd "$OUT"
  sha256sum axiom64-totality-7.0.0.iso vmlinuz-axiom64 initramfs-axiom64.zst SBOM.spdx.json > SHA256SUMS
)

mkdir -p "$WORK/release/Axiom64-Totality-7.0.0"
cp "$OUT/README.md" "$OUT/run-qemu.sh" "$OUT/SHA256SUMS" "$OUT/SBOM.spdx.json" \
   "$OUT/vmlinuz-axiom64" "$OUT/initramfs-axiom64.zst" "$OUT/axiom64-totality-7.0.0.iso" \
   "$WORK/release/Axiom64-Totality-7.0.0/"
(
  cd "$WORK/release"
  zip -X -6 -r "$OUT/Axiom64-Totality-7.0.0.zip" Axiom64-Totality-7.0.0 >/dev/null
)

echo 'BUILD: PASS' > "$OUT/build-report.txt"
echo "BASE=$BASE_DIGEST" >> "$OUT/build-report.txt"
echo "KERNEL=$KERNEL_VERSION" >> "$OUT/build-report.txt"
echo "ISO_BYTES=$(stat -c %s "$OUT/axiom64-totality-7.0.0.iso")" >> "$OUT/build-report.txt"
echo "INITRAMFS_BYTES=$(stat -c %s "$OUT/initramfs-axiom64.zst")" >> "$OUT/build-report.txt"
cat "$OUT/build-report.txt"
