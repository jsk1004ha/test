#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/out"
ROOTFS="$WORK/rootfs"
ISO="$WORK/iso"
IMAGE="${ALPINE_IMAGE:-alpine:3.24.1}"
VERSION="8.0.0"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1788220800}"

rm -rf "$WORK" "$OUT"
mkdir -p "$ROOTFS" "$ISO/boot/grub" "$OUT/logs"
exec > >(tee "$OUT/build-trace.log") 2>&1
set -x

docker pull "$IMAGE"
CID="$(docker run -d --privileged "$IMAGE" sleep 7200)"
cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

RUNTIME_PACKAGES='alpine-base linux-firmware-none linux-lts kmod busybox-extras openrc util-linux iproute2 iputils nftables e2fsprogs btrfs-progs xfsprogs dosfstools squashfs-tools pciutils usbutils nvme-cli smartmontools cryptsetup lvm2 mdadm tpm2-tools dropbear openssh-client curl ca-certificates openssl bash jq coreutils findutils grep sed gawk procps strace lsof ethtool tcpdump iperf3 socat bind-tools chrony wireguard-tools libcap musl-utils zstd lz4 xz alsa-utils weston mesa-dri-gallium mesa-egl mesa-gbm libdrm wayland dbus seatd scanelf crun numactl acl attr keyutils fuse3'
BUILD_PACKAGES='build-base linux-headers'

docker exec "$CID" sh -euxc "apk update && apk add --no-cache $RUNTIME_PACKAGES $BUILD_PACKAGES"

docker cp "$ROOT/rootfs-overlay/." "$CID":/
docker cp "$ROOT/security_probe.c" "$CID":/tmp/security_probe.c
docker cp "$ROOT/advanced_probe.c" "$CID":/tmp/advanced_probe.c
docker cp "$ROOT/container_probe.c" "$CID":/tmp/container_probe.c

docker exec "$CID" sh -euxc '
  CFLAGS="-Os -static -fno-pie -no-pie -fstack-protector-strong -D_FORTIFY_SOURCE=2 -Wall -Wextra -Werror"
  cc $CFLAGS /tmp/security_probe.c -o /usr/bin/axiom-security-probe
  cc $CFLAGS /tmp/advanced_probe.c -o /usr/bin/axiom-advanced-probe
  cc $CFLAGS /tmp/container_probe.c -o /usr/bin/axiom-container-probe
  strip /usr/bin/axiom-security-probe /usr/bin/axiom-advanced-probe /usr/bin/axiom-container-probe
  chmod 0755 /sbin/axiom-init /usr/sbin/axiom-selftest \
    /usr/bin/axiom-security-probe /usr/bin/axiom-advanced-probe /usr/bin/axiom-container-probe
  mkdir -p /etc/axiom
  if [ -s /boot/config-lts ]; then cp /boot/config-lts /etc/axiom/kernel.config; fi
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
  "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/sys/fs/cgroup" \
  "$ROOTFS/run/lock/lvm"
chmod 0755 "$ROOTFS/run" "$ROOTFS/mnt" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev"
chmod 1777 "$ROOTFS/tmp"
printf '%s\n' 'Axiom64 Totality 8.0.0' > "$ROOTFS/etc/axiom/release"
BASE_DIGEST="$(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo "$IMAGE")"
KERNEL_VERSION="$(basename "$ROOTFS"/lib/modules/*)"
cat > "$ROOTFS/etc/axiom/build.json" <<EOF
{"name":"Axiom64 Totality","version":"$VERSION","base":"$BASE_DIGEST","kernel":"$KERNEL_VERSION","profile":"secure-hybrid-qualified","rootfs":"immutable-initramfs","architecture":"x86_64"}
EOF

KERNEL_SRC="$ROOTFS/boot/vmlinuz-lts"
test -s "$KERNEL_SRC"
cp "$KERNEL_SRC" "$OUT/vmlinuz-axiom64"
rm -f "$ROOTFS/boot/vmlinuz-lts" "$ROOTFS/boot/initramfs-lts"

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

menuentry 'Axiom64 Totality 8.0.0 — Interactive' {
    linux /boot/vmlinuz-axiom64 console=tty0 console=ttyS0,115200n8 rdinit=/sbin/axiom-init loglevel=4 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 intel_iommu=on iommu.strict=1 lockdown=integrity
    initrd /boot/initramfs-axiom64.zst
}
EOF

grub-mkrescue -o "$OUT/axiom64-totality-8.0.0.iso" "$ISO" >"$OUT/grub-mkrescue.log" 2>&1

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

# Build and sign a Unified Kernel Image.  The private qualification key is
# ephemeral and is never copied into the release directory.
SB="$WORK/secureboot"
mkdir -p "$SB"
openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
  -subj '/CN=Axiom64 Totality 8 Qualification/' \
  -keyout "$SB/db.key" -out "$SB/db.crt"
openssl x509 -in "$SB/db.crt" -outform DER -out "$OUT/Axiom64-Totality-8-SecureBoot.cer"
cp "$SB/db.crt" "$OUT/Axiom64-Totality-8-SecureBoot.pem"
openssl x509 -in "$SB/db.crt" -noout -fingerprint -sha256 > "$OUT/SecureBoot-certificate-fingerprint.txt"
cat > "$SB/os-release" <<'EOF'
NAME="Axiom64 Totality"
ID=axiom64
VERSION="8.0.0"
VERSION_ID=8.0.0
PRETTY_NAME="Axiom64 Totality 8.0.0"
EOF
cat > "$SB/cmdline" <<'EOF'
console=ttyS0,115200n8 rdinit=/sbin/axiom-init axiom.test=secureboot axiom.expected_cpus=4 panic=-1 loglevel=4 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 lockdown=integrity
EOF
UKIFY="$(command -v ukify)"
STUB="$(find /usr/lib/systemd/boot/efi /usr/lib/systemd -type f -name 'linuxx64.efi.stub' -print -quit 2>/dev/null || true)"
test -n "$STUB" && test -s "$STUB"
"$UKIFY" build \
  --stub="$STUB" \
  --linux="$OUT/vmlinuz-axiom64" \
  --initrd="$OUT/initramfs-axiom64.zst" \
  --cmdline="@$SB/cmdline" \
  --os-release="@$SB/os-release" \
  --uname="$KERNEL_VERSION" \
  --secureboot-private-key="$SB/db.key" \
  --secureboot-certificate="$SB/db.crt" \
  --output="$OUT/axiom64-totality-8.0.0-signed.efi"
sbverify --list "$OUT/axiom64-totality-8.0.0-signed.efi" > "$OUT/sbverify-list.txt"
sbverify --cert "$SB/db.crt" "$OUT/axiom64-totality-8.0.0-signed.efi"

python3 - "$OUT/axiom64-totality-8.0.0-signed.efi" "$WORK/axiom64-totality-8.0.0-tampered.efi" <<'PY'
import struct, sys
src, dst = sys.argv[1:]
data = bytearray(open(src, 'rb').read())
pe = struct.unpack_from('<I', data, 0x3c)[0]
if data[pe:pe+4] != b'PE\0\0':
    raise SystemExit('not a PE image')
sections = struct.unpack_from('<H', data, pe + 6)[0]
opt_size = struct.unpack_from('<H', data, pe + 20)[0]
table = pe + 24 + opt_size
chosen = None
for i in range(sections):
    off = table + i * 40
    name = bytes(data[off:off+8]).rstrip(b'\0')
    raw_size = struct.unpack_from('<I', data, off + 16)[0]
    raw_ptr = struct.unpack_from('<I', data, off + 20)[0]
    if name in (b'.cmdline', b'.osrel', b'.linux') and raw_size:
        chosen = (raw_ptr, raw_size, name)
        if name == b'.cmdline':
            break
if not chosen:
    raise SystemExit('no signed payload section found')
raw_ptr, raw_size, name = chosen
pos = raw_ptr + min(16, raw_size - 1)
data[pos] ^= 0x01
open(dst, 'wb').write(data)
print(f'tampered {name.decode()} at file offset {pos}')
PY
if sbverify --cert "$SB/db.crt" "$WORK/axiom64-totality-8.0.0-tampered.efi"; then
  echo 'tampered UKI unexpectedly verified' >&2
  exit 1
fi

make_esp() {
  local uki="$1"
  local image="$2"
  local bytes size_mib
  bytes=$(stat -c %s "$uki")
  size_mib=$(( (bytes + 96*1024*1024 + 1024*1024 - 1) / (1024*1024) ))
  if (( size_mib < 192 )); then size_mib=192; fi
  truncate -s "${size_mib}M" "$image"
  mkfs.vfat -F 32 -n AXIOM_EFI "$image" >/dev/null
  mmd -i "$image" ::/EFI ::/EFI/BOOT
  mcopy -i "$image" "$uki" ::/EFI/BOOT/BOOTX64.EFI
}
make_esp "$OUT/axiom64-totality-8.0.0-signed.efi" "$OUT/axiom64-totality-8.0.0-secureboot-esp.img"
make_esp "$WORK/axiom64-totality-8.0.0-tampered.efi" "$WORK/axiom64-totality-8.0.0-tampered-esp.img"

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
    'SPDXID':'SPDXRef-DOCUMENT', 'name':'Axiom64-Totality-8.0.0',
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
exec qemu-system-x86_64 -machine q35 -cpu max -smp 8 -m 4096 \
  -cdrom "$HERE/axiom64-totality-8.0.0.iso" -serial stdio
EOF
chmod +x "$OUT/run-qemu.sh"

# Ship the complete implementation source used for this image, excluding build
# outputs and downloaded emulator binaries.
tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner \
  --exclude='./work' --exclude='./out' --exclude='./tools' \
  -C "$ROOT" -cf - . | zstd -19 -T0 -q -o "$OUT/Axiom64-Totality-8.0.0-source.tar.zst"

cp "$ROOT/README.md" "$OUT/README.md"
python3 - "$OUT" "$BASE_DIGEST" "$KERNEL_VERSION" <<'PY'
import hashlib, json, pathlib, sys
out = pathlib.Path(sys.argv[1])
def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()
files = {}
for name in [
    'axiom64-totality-8.0.0.iso',
    'axiom64-totality-8.0.0-signed.efi',
    'axiom64-totality-8.0.0-secureboot-esp.img',
    'vmlinuz-axiom64', 'initramfs-axiom64.zst',
    'Axiom64-Totality-8.0.0-source.tar.zst', 'SBOM.spdx.json']:
    p = out / name
    files[name] = {'sha256': sha(p), 'bytes': p.stat().st_size}
obj = {
    'name':'Axiom64 Totality', 'version':'8.0.0',
    'build_base':sys.argv[2], 'kernel':sys.argv[3],
    'architecture':'x86_64', 'boot':['BIOS','UEFI','UEFI Secure Boot UKI'],
    'files':files,
    'qualification':'pending runtime matrix',
}
(out / 'provenance.json').write_text(json.dumps(obj, indent=2, sort_keys=True) + '\n')
PY

(
  cd "$OUT"
  sha256sum \
    axiom64-totality-8.0.0.iso \
    axiom64-totality-8.0.0-signed.efi \
    axiom64-totality-8.0.0-secureboot-esp.img \
    Axiom64-Totality-8-SecureBoot.cer \
    Axiom64-Totality-8-SecureBoot.pem \
    vmlinuz-axiom64 initramfs-axiom64.zst \
    Axiom64-Totality-8.0.0-source.tar.zst \
    SBOM.spdx.json provenance.json README.md > SHA256SUMS
)

mkdir -p "$WORK/release/Axiom64-Totality-8.0.0"
cp "$OUT/README.md" "$OUT/run-qemu.sh" "$OUT/SHA256SUMS" "$OUT/SBOM.spdx.json" \
   "$OUT/provenance.json" "$OUT/Axiom64-Totality-8-SecureBoot.cer" \
   "$OUT/Axiom64-Totality-8-SecureBoot.pem" "$OUT/SecureBoot-certificate-fingerprint.txt" \
   "$OUT/axiom64-totality-8.0.0-signed.efi" "$OUT/Axiom64-Totality-8.0.0-source.tar.zst" \
   "$OUT/axiom64-totality-8.0.0.iso" "$WORK/release/Axiom64-Totality-8.0.0/"
(
  cd "$WORK/release"
  zip -X -6 -r "$OUT/Axiom64-Totality-8.0.0.zip" Axiom64-Totality-8.0.0 >/dev/null
)

echo 'BUILD: PASS' > "$OUT/build-report.txt"
echo "VERSION=$VERSION" >> "$OUT/build-report.txt"
echo "BASE=$BASE_DIGEST" >> "$OUT/build-report.txt"
echo "KERNEL=$KERNEL_VERSION" >> "$OUT/build-report.txt"
echo "ISO_BYTES=$(stat -c %s "$OUT/axiom64-totality-8.0.0.iso")" >> "$OUT/build-report.txt"
echo "UKI_BYTES=$(stat -c %s "$OUT/axiom64-totality-8.0.0-signed.efi")" >> "$OUT/build-report.txt"
echo "INITRAMFS_BYTES=$(stat -c %s "$OUT/initramfs-axiom64.zst")" >> "$OUT/build-report.txt"
echo "SECUREBOOT_CERT=$(cat "$OUT/SecureBoot-certificate-fingerprint.txt")" >> "$OUT/build-report.txt"
cat "$OUT/build-report.txt"
