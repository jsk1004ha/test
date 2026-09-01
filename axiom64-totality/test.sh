#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$ROOT/out"
WORK="$ROOT/work"
LOGS="$OUT/logs"
mkdir -p "$LOGS"

QEMU_BIN="${QEMU_BIN:-}"
if [[ -z "$QEMU_BIN" ]]; then
  QEMU_BIN="$(find "$ROOT/tools/qemu" -type f -name qemu-system-x86_64 -print -quit 2>/dev/null || true)"
fi
if [[ -z "$QEMU_BIN" ]]; then QEMU_BIN="$(command -v qemu-system-x86_64)"; fi
chmod +x "$QEMU_BIN"

QEMU_DATA="${QEMU_DATA:-$ROOT/tools/qemu-data}"
if [[ ! -s "$QEMU_DATA/bios-256k.bin" ]]; then QEMU_DATA=/usr/share/qemu; fi
if [[ ! -s "$QEMU_DATA/bios-256k.bin" ]]; then
  echo "QEMU firmware directory is incomplete: $QEMU_DATA" >&2
  exit 1
fi

KERNEL="$OUT/vmlinuz-axiom64"
INITRD="$OUT/initramfs-axiom64.zst"
test -s "$KERNEL" && test -s "$INITRD"

REPORT="$OUT/qualification-report.txt"
: > "$REPORT"
PASS_COUNT=0
record_pass() { echo "PASS: $*" | tee -a "$REPORT"; PASS_COUNT=$((PASS_COUNT+1)); }
require_marker() {
  local log="$1" marker="$2"
  if ! grep -Fq "$marker" "$log"; then
    echo "Missing marker: $marker" >&2
    tail -n 350 "$log" >&2 || true
    exit 1
  fi
}
forbid_marker() {
  local log="$1" marker="$2"
  if grep -Fq "$marker" "$log"; then
    echo "Forbidden marker present: $marker" >&2
    tail -n 200 "$log" >&2 || true
    exit 1
  fi
}

start_tpm() {
  local dir="$1"
  rm -rf "$dir"; mkdir -p "$dir"
  swtpm socket --tpm2 --tpmstate dir="$dir" \
    --ctrl type=unixio,path="$dir/swtpm.sock" \
    --pid file="$dir/swtpm.pid" --flags not-need-init --daemon
  for _ in $(seq 1 100); do [[ -S "$dir/swtpm.sock" ]] && return 0; sleep 0.1; done
  echo "swtpm socket did not appear" >&2
  return 1
}
stop_tpm() {
  local dir="$1"
  if [[ -s "$dir/swtpm.pid" ]]; then kill "$(cat "$dir/swtpm.pid")" 2>/dev/null || true; fi
}

run_core() {
  local cpus="$1" log="$LOGS/core-smp${1}.log"
  timeout 420 "$QEMU_BIN" \
    -L "$QEMU_DATA" -no-user-config -nodefaults \
    -machine q35,accel=tcg -cpu max -smp "$cpus" -m 1792 \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0,115200n8 rdinit=/sbin/axiom-init axiom.test=core axiom.expected_cpus=$cpus panic=-1 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1" \
    -chardev file,id=serial0,path="$log" -device isa-serial,chardev=serial0 \
    -display none -monitor none -no-reboot || true
  require_marker "$log" "AXIOM-CORE-QUALIFIED: PASS"
  require_marker "$log" "CPU-COUNT: $cpus"
  require_marker "$log" "AXIOM-ADVANCED-ABI: PASS"
  record_pass "SMP $cpus core boot and modern ABI"
}
for n in 1 2 4 8; do run_core "$n"; done

make_disk() {
  local file="$1" label="$2" size="${3:-192M}"
  truncate -s "$size" "$file"
  mkfs.ext4 -q -F -L "$label" "$file"
}
make_disk "$WORK/virtio.raw" AXIOM_VIRTIO
make_disk "$WORK/nvme.raw" AXIOM_NVME
make_disk "$WORK/sata.raw" AXIOM_AHCI
make_disk "$WORK/usb.raw" AXIOM_USB

TPMDIR="$WORK/tpm-full"
start_tpm "$TPMDIR"
FULL_LOG="$LOGS/full-hardware.log"
timeout 1500 "$QEMU_BIN" \
  -L "$QEMU_DATA" -no-user-config -nodefaults \
  -machine q35,accel=tcg -cpu max \
  -smp 8,sockets=2,cores=4,threads=1 -m 4096 \
  -object memory-backend-ram,id=mem0,size=2048M \
  -object memory-backend-ram,id=mem1,size=2048M \
  -numa node,nodeid=0,cpus=0-3,memdev=mem0 \
  -numa node,nodeid=1,cpus=4-7,memdev=mem1 \
  -device intel-iommu,caching-mode=on \
  -kernel "$KERNEL" -initrd "$INITRD" \
  -append 'console=ttyS0,115200n8 rdinit=/sbin/axiom-init axiom.test=full axiom.expected_cpus=8 panic=-1 intel_iommu=on iommu.strict=1 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1' \
  -drive file="$WORK/virtio.raw",if=none,id=vblk,format=raw,cache=unsafe \
  -device virtio-blk-pci,drive=vblk \
  -drive file="$WORK/nvme.raw",if=none,id=nvme0,format=raw,cache=unsafe \
  -device nvme,drive=nvme0,serial=AXIOMNVME \
  -drive file="$WORK/sata.raw",if=none,id=sata0,format=raw,cache=unsafe \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=sata0,bus=ahci.0 \
  -device qemu-xhci,id=xhci \
  -drive file="$WORK/usb.raw",if=none,id=usbdisk,format=raw,cache=unsafe \
  -device usb-storage,drive=usbdisk,bus=xhci.0 \
  -device usb-kbd,bus=xhci.0 \
  -device usb-tablet,bus=xhci.0 \
  -device virtio-gpu-pci \
  -audiodev none,id=audio0 \
  -device ich9-intel-hda \
  -device hda-duplex,audiodev=audio0 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0,romfile= \
  -chardev socket,id=chrtpm,path="$TPMDIR/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-crb,tpmdev=tpm0 \
  -chardev file,id=serial0,path="$FULL_LOG" \
  -device isa-serial,chardev=serial0 \
  -display none -monitor none -no-reboot || true
stop_tpm "$TPMDIR"

require_marker "$FULL_LOG" 'AXIOM-FULL-QUALIFIED: PASS'
FULL_MARKERS=(
  'AXIOM-ADVANCED-ABI: PASS'
  'NUMA: PASS' 'NUMA-AFFINITY: PASS' 'IOMMU: PASS' 'TPM2: PASS'
  'VIRTIO-BLK: PASS' 'NVME: PASS' 'AHCI: PASS' 'USB-MASS-STORAGE: PASS' 'XHCI-USB: PASS'
  'NETWORK: PASS' 'GPU-DRM: PASS' 'AUDIO: PASS' 'NFTABLES: PASS' 'WIREGUARD-TUNNEL: PASS'
  'BTRFS-SNAPSHOT: PASS' 'XFS: PASS' 'SQUASHFS-IMMUTABLE: PASS'
  'MD-RAID1: PASS' 'LVM-SNAPSHOT: PASS' 'LUKS2-DM-CRYPT: PASS'
  'DM-VERITY: PASS' 'DM-VERITY-TAMPER-REJECT: PASS'
  'OCI-CONTAINER: PASS' 'CGROUP-V2-CONTROL: PASS' 'ACL-XATTR: PASS' 'KERNEL-KEYRING: PASS'
  'TLS-HANDSHAKE: PASS' 'HTTP-STACK: PASS' 'WAYLAND-COMPOSITOR: PASS'
  'SSH-SERVER: PASS' 'PACKAGE-MANAGER: PASS' 'DYNAMIC-ELF: PASS'
)
for marker in "${FULL_MARKERS[@]}"; do require_marker "$FULL_LOG" "$marker"; done
record_pass 'full Q35 hardware, storage, security, container and service matrix'

verify_persistence() {
  local image="$1" token="$2" name="$3" output
  output=$(debugfs -R 'cat qualification.txt' "$image" 2>/dev/null || true)
  if grep -Fqx "$token" <<<"$output"; then record_pass "$name host-side power-boundary persistence"; else
    echo "Persistence token missing for $name: $output" >&2
    exit 1
  fi
}
verify_persistence "$WORK/virtio.raw" 'Axiom64-PERSIST-AXIOM_VIRTIO' VIRTIO-BLK
verify_persistence "$WORK/nvme.raw" 'Axiom64-PERSIST-AXIOM_NVME' NVMe
verify_persistence "$WORK/sata.raw" 'Axiom64-PERSIST-AXIOM_AHCI' AHCI
verify_persistence "$WORK/usb.raw" 'Axiom64-PERSIST-AXIOM_USB' USB-MASS-STORAGE

BIOS_LOG="$LOGS/iso-bios.log"
timeout 480 "$QEMU_BIN" \
  -L "$QEMU_DATA" -no-user-config -nodefaults \
  -machine q35,accel=tcg -cpu max -smp 2 -m 1792 \
  -drive file="$WORK/axiom64-totality-ci.iso",media=cdrom,if=none,id=cd0,format=raw,readonly=on \
  -device ich9-ahci,id=ahci -device ide-cd,drive=cd0,bus=ahci.0,bootindex=1 \
  -chardev file,id=serial0,path="$BIOS_LOG" -device isa-serial,chardev=serial0 \
  -display none -monitor none -no-reboot || true
require_marker "$BIOS_LOG" 'AXIOM-ISO-QUALIFIED: PASS'
require_marker "$BIOS_LOG" 'BOOT-FIRMWARE: BIOS'
record_pass 'hybrid ISO legacy BIOS boot'

OVMF_CODE=''
for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$p" ]] && OVMF_CODE="$p" && break; done
OVMF_VARS_SRC=''
for p in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f "$p" ]] && OVMF_VARS_SRC="$p" && break; done
[[ -n "$OVMF_CODE" && -n "$OVMF_VARS_SRC" ]] || { echo 'OVMF firmware not found' >&2; exit 1; }
cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
UEFI_LOG="$LOGS/iso-uefi.log"
timeout 480 "$QEMU_BIN" \
  -L "$QEMU_DATA" -no-user-config -nodefaults \
  -machine q35,accel=tcg -cpu max -smp 2 -m 1792 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
  -drive file="$WORK/axiom64-totality-ci.iso",media=cdrom,if=none,id=cd0,format=raw,readonly=on \
  -device ich9-ahci,id=ahci -device ide-cd,drive=cd0,bus=ahci.0,bootindex=1 \
  -chardev file,id=serial0,path="$UEFI_LOG" -device isa-serial,chardev=serial0 \
  -display none -monitor none -no-reboot || true
require_marker "$UEFI_LOG" 'AXIOM-ISO-QUALIFIED: PASS'
require_marker "$UEFI_LOG" 'BOOT-FIRMWARE: UEFI'
record_pass 'hybrid ISO native UEFI boot'

OVMF_SB_CODE=''
for p in /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd; do [[ -f "$p" ]] && OVMF_SB_CODE="$p" && break; done
[[ -n "$OVMF_SB_CODE" ]] || { echo 'Secure Boot OVMF code not found' >&2; exit 1; }
CERT="$OUT/Axiom64-Totality-8-SecureBoot.pem"
GUID=$(uuidgen)
make_sb_vars() {
  local output="$1"
  rm -f "$output"
  if ! virt-fw-vars --input "$OVMF_VARS_SRC" --output "$output" \
       --set-pk "$GUID" "$CERT" --add-kek "$GUID" "$CERT" --add-db "$GUID" "$CERT" \
       --no-microsoft --secure-boot >"$output.log" 2>&1; then
    cat "$output.log" >&2
    virt-fw-vars --help >&2 || true
    exit 1
  fi
}

make_sb_vars "$WORK/OVMF_VARS_SB.fd"
TPMSB="$WORK/tpm-secureboot"
start_tpm "$TPMSB"
SB_LOG="$LOGS/secureboot-positive.log"
timeout 600 "$QEMU_BIN" \
  -L "$QEMU_DATA" -no-user-config -nodefaults \
  -machine q35,accel=tcg,smm=on -global driver=cfi.pflash01,property=secure,value=on \
  -cpu max -smp 4 -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_SB_CODE" \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS_SB.fd" \
  -drive file="$OUT/axiom64-totality-8.0.0-secureboot-esp.img",if=none,id=esp,format=raw,readonly=on \
  -device virtio-blk-pci,drive=esp,bootindex=1 \
  -chardev socket,id=chrtpm,path="$TPMSB/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
  -chardev file,id=serial0,path="$SB_LOG" -device isa-serial,chardev=serial0 \
  -display none -monitor none -no-reboot || true
stop_tpm "$TPMSB"
require_marker "$SB_LOG" 'AXIOM-SECUREBOOT-QUALIFIED: PASS'
require_marker "$SB_LOG" 'UEFI-SECURE-BOOT: PASS'
require_marker "$SB_LOG" 'KERNEL-LOCKDOWN: PASS'
require_marker "$SB_LOG" 'TPM2-MEASURED-BOOT: PASS'
record_pass 'custom-key UEFI Secure Boot signed UKI with TPM2 measured boot'

make_sb_vars "$WORK/OVMF_VARS_SB_TAMPER.fd"
TPMBAD="$WORK/tpm-secureboot-tamper"
start_tpm "$TPMBAD"
BAD_LOG="$LOGS/secureboot-tamper.log"
timeout 90 "$QEMU_BIN" \
  -L "$QEMU_DATA" -no-user-config -nodefaults \
  -machine q35,accel=tcg,smm=on -global driver=cfi.pflash01,property=secure,value=on \
  -cpu max -smp 2 -m 1792 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_SB_CODE" \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS_SB_TAMPER.fd" \
  -drive file="$WORK/axiom64-totality-8.0.0-tampered-esp.img",if=none,id=esp,format=raw,readonly=on \
  -device virtio-blk-pci,drive=esp,bootindex=1 \
  -chardev socket,id=chrtpm,path="$TPMBAD/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
  -chardev file,id=serial0,path="$BAD_LOG" -device isa-serial,chardev=serial0 \
  -display none -monitor none -no-reboot || true
stop_tpm "$TPMBAD"
forbid_marker "$BAD_LOG" 'AXIOM-SECUREBOOT-QUALIFIED: PASS'
forbid_marker "$BAD_LOG" 'Linux version '
record_pass 'one-byte signed-UKI tamper rejected before kernel execution'

(
  cd "$OUT"
  sha256sum -c SHA256SUMS
)
record_pass 'release SHA-256 manifest'

unzip -t "$OUT/Axiom64-Totality-8.0.0.zip" >/dev/null
record_pass 'release ZIP integrity'

cat >> "$REPORT" <<EOF
Axiom64 Totality 8.0.0 Qualification
STATUS: PASS
PASS_COUNT: $PASS_COUNT
QEMU: $($QEMU_BIN --version | head -n1)
QEMU_FIRMWARE: $QEMU_DATA
Profiles: SMP 1/2/4/8, Q35 full hardware, host persistence, BIOS ISO, UEFI ISO, Secure Boot UKI, tamper rejection
EOF

cat > "$OUT/qualification-certificate.txt" <<EOF
Axiom64 Totality 8.0.0
QUALIFICATION_STATUS=PASS
PASS_COUNT=$PASS_COUNT
WORKFLOW_COMMIT=${GITHUB_SHA:-unknown}
QEMU=$($QEMU_BIN --version | head -n1)
KERNEL=x86_64 Linux LTS guest image
SECURE_BOOT=custom-key signed UKI verified and booted
NEGATIVE_TEST=one-byte UKI tamper rejected before Linux entry
EOF

python3 - "$OUT/provenance.json" "$OUT/qualification-report.txt" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1]); report = pathlib.Path(sys.argv[2])
obj = json.loads(p.read_text())
obj['qualification'] = 'PASS'
obj['qualification_report_sha256'] = hashlib.sha256(report.read_bytes()).hexdigest()
obj['runtime_profiles'] = ['SMP1','SMP2','SMP4','SMP8','Q35-full','BIOS-ISO','UEFI-ISO','UEFI-SecureBoot','tamper-negative']
p.write_text(json.dumps(obj, indent=2, sort_keys=True) + '\n')
PY

(
  cd "$OUT"
  sha256sum \
    axiom64-totality-8.0.0.iso axiom64-totality-8.0.0-signed.efi \
    axiom64-totality-8.0.0-secureboot-esp.img \
    Axiom64-Totality-8-SecureBoot.cer Axiom64-Totality-8-SecureBoot.pem \
    vmlinuz-axiom64 initramfs-axiom64.zst Axiom64-Totality-8.0.0-source.tar.zst \
    SBOM.spdx.json provenance.json README.md qualification-report.txt \
    qualification-certificate.txt > SHA256SUMS
)

RELEASE_DIR="$WORK/release/Axiom64-Totality-8.0.0"
cp "$OUT/provenance.json" "$OUT/SHA256SUMS" "$OUT/qualification-report.txt" \
   "$OUT/qualification-certificate.txt" "$RELEASE_DIR/"
rm -f "$OUT/Axiom64-Totality-8.0.0.zip"
(
  cd "$WORK/release"
  zip -X -1 -r "$OUT/Axiom64-Totality-8.0.0.zip" Axiom64-Totality-8.0.0 >/dev/null
)
unzip -t "$OUT/Axiom64-Totality-8.0.0.zip" >/dev/null
(
  cd "$OUT"
  sha256sum Axiom64-Totality-8.0.0.zip axiom64-totality-8.0.0.iso \
    axiom64-totality-8.0.0-secureboot-esp.img axiom64-totality-8.0.0-signed.efi \
    vmlinuz-axiom64 initramfs-axiom64.zst > FINAL-SHA256SUMS
)

cat "$REPORT"
