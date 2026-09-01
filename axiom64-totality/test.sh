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
if [[ ! -s "$QEMU_DATA/bios-256k.bin" ]]; then
  QEMU_DATA=/usr/share/qemu
fi
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
  local log="$1"
  local marker="$2"
  if ! grep -Fq "$marker" "$log"; then
    echo "Missing marker: $marker" >&2
    tail -n 250 "$log" >&2 || true
    exit 1
  fi
}

run_core() {
  local cpus="$1"
  local log="$LOGS/core-smp${cpus}.log"
  timeout 300 "$QEMU_BIN" \
    -L "$QEMU_DATA" -machine q35,accel=tcg -cpu max -smp "$cpus" -m 1536 \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "console=ttyS0,115200n8 rdinit=/sbin/axiom-init axiom.test=core axiom.expected_cpus=$cpus panic=-1 pti=on vsyscall=none randomize_kstack_offset=on slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1" \
    -display none -monitor none -serial "file:$log" -no-reboot || true
  require_marker "$log" "AXIOM-CORE-QUALIFIED: PASS"
  require_marker "$log" "CPU-COUNT: $cpus"
  record_pass "SMP $cpus core boot"
}

for n in 1 2 4 8; do run_core "$n"; done

make_disk() {
  local file="$1"
  local label="$2"
  local size="${3:-128M}"
  truncate -s "$size" "$file"
  mkfs.ext4 -q -F -L "$label" "$file"
}
make_disk "$WORK/virtio.raw" AXIOM_VIRTIO 128M
make_disk "$WORK/nvme.raw" AXIOM_NVME 128M
make_disk "$WORK/sata.raw" AXIOM_AHCI 128M

TPMDIR="$WORK/tpm-state"
rm -rf "$TPMDIR"; mkdir -p "$TPMDIR"
swtpm socket --tpm2 --tpmstate dir="$TPMDIR" \
  --ctrl type=unixio,path="$TPMDIR/swtpm.sock" \
  --flags not-need-init --daemon
for _ in $(seq 1 50); do [[ -S "$TPMDIR/swtpm.sock" ]] && break; sleep 0.1; done

FULL_LOG="$LOGS/full-hardware.log"
timeout 540 "$QEMU_BIN" \
  -L "$QEMU_DATA" -machine q35,accel=tcg -cpu max \
  -smp 8,sockets=2,cores=2,threads=2 -m 3072 \
  -object memory-backend-ram,id=mem0,size=1536M \
  -object memory-backend-ram,id=mem1,size=1536M \
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
  -device ide-hd,drive=sata0,bus=ide.0 \
  -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
  -device virtio-gpu-pci \
  -audiodev none,id=audio0 -device ich9-intel-hda -device hda-duplex,audiodev=audio0 \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -chardev socket,id=chrtpm,path="$TPMDIR/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -display none -monitor none -serial "file:$FULL_LOG" -no-reboot || true
require_marker "$FULL_LOG" 'AXIOM-FULL-QUALIFIED: PASS'
for marker in 'IOMMU: PASS' 'TPM2: PASS' 'VIRTIO-BLK: PASS' 'NVME: PASS' 'AHCI: PASS' 'XHCI-USB: PASS' 'NETWORK: PASS' 'GPU-DRM: PASS' 'AUDIO: PASS' 'DM-CRYPT: PASS' 'BTRFS: PASS' 'WIREGUARD: PASS'; do
  require_marker "$FULL_LOG" "$marker"
done
record_pass 'full Q35 hardware and security matrix'

BIOS_LOG="$LOGS/iso-bios.log"
timeout 360 "$QEMU_BIN" -L "$QEMU_DATA" -machine q35,accel=tcg -cpu max -smp 2 -m 1536 \
  -cdrom "$WORK/axiom64-totality-ci.iso" -boot d \
  -display none -monitor none -serial "file:$BIOS_LOG" -no-reboot || true
require_marker "$BIOS_LOG" 'AXIOM-ISO-QUALIFIED: PASS'
require_marker "$BIOS_LOG" 'BOOT-FIRMWARE: BIOS'
record_pass 'hybrid ISO legacy BIOS boot'

OVMF_CODE=''
for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do [[ -f "$p" ]] && OVMF_CODE="$p" && break; done
if [[ -z "$OVMF_CODE" ]]; then echo 'OVMF firmware not found' >&2; exit 1; fi
OVMF_VARS_SRC=''
for p in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do [[ -f "$p" ]] && OVMF_VARS_SRC="$p" && break; done
if [[ -z "$OVMF_VARS_SRC" ]]; then echo 'OVMF vars not found' >&2; exit 1; fi
cp "$OVMF_VARS_SRC" "$WORK/OVMF_VARS.fd"
UEFI_LOG="$LOGS/iso-uefi.log"
timeout 360 "$QEMU_BIN" -L "$QEMU_DATA" -machine q35,accel=tcg -cpu max -smp 2 -m 1536 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file="$WORK/OVMF_VARS.fd" \
  -cdrom "$WORK/axiom64-totality-ci.iso" -boot d \
  -display none -monitor none -serial "file:$UEFI_LOG" -no-reboot || true
require_marker "$UEFI_LOG" 'AXIOM-ISO-QUALIFIED: PASS'
require_marker "$UEFI_LOG" 'BOOT-FIRMWARE: UEFI'
record_pass 'hybrid ISO native UEFI boot'

(
  cd "$OUT"
  sha256sum -c SHA256SUMS
)
record_pass 'release SHA-256 manifest'

unzip -t "$OUT/Axiom64-Totality-7.0.0.zip" >/dev/null
record_pass 'release ZIP integrity'

{
  echo 'Axiom64 Totality 7.0.0 Qualification'
  echo 'STATUS: PASS'
  echo "PASS_COUNT: $PASS_COUNT"
  echo "QEMU: $($QEMU_BIN --version | head -n1)"
  echo "QEMU_FIRMWARE: $QEMU_DATA"
  echo 'Profiles: SMP 1/2/4/8, Q35 full hardware, BIOS ISO, UEFI ISO'
} >> "$REPORT"

cat "$REPORT"
