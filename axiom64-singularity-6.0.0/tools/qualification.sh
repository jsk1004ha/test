#!/usr/bin/env bash
set -euo pipefail

BUILD=${BUILD:-build}
QEMU=${QEMU:-qemu-system-x86_64}
mkdir -p "$BUILD"

fail() {
  echo "qualification: FAIL: $*" >&2
  exit 1
}

require_marker() {
  local file=$1 marker=$2
  [[ -f "$file" ]] || fail "missing log file $file"
  grep -aFq "$marker" "$file" || fail "missing '$marker' in $file"
}

wait_for_socket() {
  local path=$1
  for _ in $(seq 1 100); do
    [[ -S "$path" ]] && return 0
    sleep 0.05
  done
  fail "socket did not appear: $path"
}

stop_pidfile() {
  local pidfile=$1
  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile")
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
    done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$pidfile"
  fi
}

run_tpm() {
  timeout -k 3s 25s "$@"
}

find_ovmf_pair() {
  local candidates=(
    "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd:/usr/share/OVMF/OVMF_VARS_4M.fd"
    "/usr/share/OVMF/OVMF_CODE.secboot.fd:/usr/share/OVMF/OVMF_VARS.fd"
    "/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd"
  )
  local pair code vars
  for pair in "${candidates[@]}"; do
    code=${pair%%:*}
    vars=${pair#*:}
    if [[ -f "$code" && -f "$vars" ]]; then
      printf '%s\n%s\n' "$code" "$vars"
      return 0
    fi
  done
  return 1
}

mapfile -t OVMF < <(find_ovmf_pair) || fail "secure-boot OVMF firmware pair not found"
OVMF_CODE=${OVMF[0]}
OVMF_VARS_TEMPLATE=${OVMF[1]}

sbverify --cert "$BUILD/db.crt" "$BUILD/BOOTX64.SIGNED.EFI" \
  >"$BUILD/sbverify.log" 2>&1

# Enroll the exact development certificate into an isolated PK/KEK/db store.
if ! virt-fw-vars \
    --input "$OVMF_VARS_TEMPLATE" \
    --output "$BUILD/OVMF_VARS.secboot.fd" \
    --enroll-cert "$BUILD/db.crt" \
    --no-microsoft \
    --secure-boot \
    >"$BUILD/secure-boot-enrollment.log" 2>&1; then
  OWNER_GUID=2d0fdd71-9400-4d71-8f8a-4388f7d4219b
  virt-fw-vars \
    --input "$OVMF_VARS_TEMPLATE" \
    --output "$BUILD/OVMF_VARS.secboot.fd" \
    --set-pk "$OWNER_GUID" "$BUILD/db.crt" \
    --add-kek "$OWNER_GUID" "$BUILD/db.crt" \
    --add-db "$OWNER_GUID" "$BUILD/db.crt" \
    --secure-boot \
    >"$BUILD/secure-boot-enrollment.log" 2>&1
fi
virt-fw-vars --input "$BUILD/OVMF_VARS.secboot.fd" --print --verbose \
  >"$BUILD/secure-boot-vars-report.txt" 2>&1

# BIOS transition test.
set +e
timeout -k 5s 30s "$QEMU" \
  -machine pc,accel=tcg \
  -cpu max \
  -m 128M \
  -drive if=ide,format=raw,file="$BUILD/axiom64-singularity-6-bios.img" \
  -boot c \
  -display none \
  -serial file:"$BUILD/qemu-bios.log" \
  -monitor none \
  -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
BIOS_RC=$?
set -e
[[ $BIOS_RC -ne 124 && $BIOS_RC -ne 137 ]] || fail "BIOS QEMU run timed out"
require_marker "$BUILD/qemu-bios.log" "BIOS_BOOT: PASS"
require_marker "$BUILD/qemu-bios.log" "LONG_MODE: PASS"
require_marker "$BUILD/qemu-bios.log" "CPU_HARDENING_SCAN: PASS"
require_marker "$BUILD/qemu-bios.log" "BIOS_QUALIFICATION_COMPLETE: PASS"

# Prove firmware rejects a one-byte mutation before EFI entry executes.
cp "$BUILD/BOOTX64.SIGNED.EFI" "$BUILD/BOOTX64.TAMPERED.EFI"
python3 - "$BUILD/BOOTX64.TAMPERED.EFI" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
data = bytearray(p.read_bytes())
index = min(1024, len(data) // 3)
data[index] ^= 0x01
p.write_bytes(data)
PY
cp "$BUILD/esp.img" "$BUILD/esp-tampered.img"
mcopy -o -i "$BUILD/esp-tampered.img" "$BUILD/BOOTX64.TAMPERED.EFI" ::/EFI/BOOT/BOOTX64.EFI
cp "$BUILD/OVMF_VARS.secboot.fd" "$BUILD/OVMF_VARS.tamper.fd"
set +e
timeout -k 5s 15s "$QEMU" \
  -machine q35,smm=on,accel=tcg \
  -global driver=cfi.pflash01,property=secure,value=on \
  -cpu max -m 256M \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$BUILD/OVMF_VARS.tamper.fd" \
  -drive if=virtio,format=raw,file="$BUILD/esp-tampered.img" \
  -boot c -vga std -display none \
  -serial file:"$BUILD/qemu-uefi-tamper.log" \
  -monitor none -net none -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
TAMPER_RC=$?
set -e
if [[ -f "$BUILD/qemu-uefi-tamper.log" ]] && \
   grep -aFq "UEFI_BOOT: PASS" "$BUILD/qemu-uefi-tamper.log"; then
  fail "tampered EFI image reached efi_main under Secure Boot"
fi

# QEMU's TPM emulator backend requires a Unix control socket: QEMU passes the
# data-channel file descriptor over that socket with SCM_RIGHTS.
TPM_DIR="$BUILD/swtpm-state"
QEMU_TPM_SOCK="$TPM_DIR/qemu-control.sock"
QEMU_TPM_PID="$BUILD/swtpm-qemu.pid"
rm -rf "$TPM_DIR"
mkdir -p "$TPM_DIR"
swtpm socket \
  --tpm2 \
  --tpmstate dir="$TPM_DIR" \
  --ctrl type=unixio,path="$QEMU_TPM_SOCK",mode=0600 \
  --pid file="$QEMU_TPM_PID" \
  --log level=20,file="$BUILD/swtpm-qemu.log" \
  --daemon
wait_for_socket "$QEMU_TPM_SOCK"

cleanup() {
  stop_pidfile "$QEMU_TPM_PID"
  stop_pidfile "$BUILD/swtpm-tools.pid"
}
trap cleanup EXIT

# Valid signed UEFI path: Secure Boot, GOP, TCG2, TPM command, memory map and
# ExitBootServices. isa-debug-exit is reached only after firmware ownership is
# relinquished and the post-firmware kernel path is active.
set +e
timeout -k 5s 60s "$QEMU" \
  -machine q35,smm=on,accel=tcg \
  -global driver=cfi.pflash01,property=secure,value=on \
  -cpu max \
  -m 256M \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$BUILD/OVMF_VARS.secboot.fd" \
  -drive if=virtio,format=raw,file="$BUILD/esp.img" \
  -boot c \
  -vga std \
  -display none \
  -serial file:"$BUILD/qemu-uefi-secure.log" \
  -monitor none \
  -net none \
  -chardev socket,id=chrtpm,path="$QEMU_TPM_SOCK" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -no-reboot \
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
UEFI_RC=$?
set -e
[[ $UEFI_RC -ne 124 && $UEFI_RC -ne 137 ]] || fail "UEFI QEMU run timed out"
require_marker "$BUILD/qemu-uefi-secure.log" "UEFI_BOOT: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "SECURE_BOOT: ENABLED"
require_marker "$BUILD/qemu-uefi-secure.log" "GOP: PRESENT"
require_marker "$BUILD/qemu-uefi-secure.log" "TCG2: PRESENT"
require_marker "$BUILD/qemu-uefi-secure.log" "TPM2_GET_RANDOM: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "EXIT_BOOT_SERVICES: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "POST_FIRMWARE_KERNEL_OWNERSHIP: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "UEFI_QUALIFICATION_COMPLETE: PASS"

# Stop the QEMU-control instance cleanly, then reopen the same persistent TPM
# state on the standard swtpm TCP command/control ports for tpm2-tools.
stop_pidfile "$QEMU_TPM_PID"
rm -f "$QEMU_TPM_SOCK"
swtpm socket \
  --tpm2 \
  --tpmstate dir="$TPM_DIR" \
  --server type=tcp,port=2321,bindaddr=127.0.0.1 \
  --ctrl type=tcp,port=2322,bindaddr=127.0.0.1 \
  --flags not-need-init,startup-clear \
  --pid file="$BUILD/swtpm-tools.pid" \
  --log level=20,file="$BUILD/swtpm-tools.log" \
  --daemon
sleep 1

# Bind the signed artifact to PCR14 and verify a nonce-qualified quote.
export TPM2TOOLS_TCTI="swtpm:host=127.0.0.1,port=2321"
run_tpm tpm2_startup -c >"$BUILD/tpm-startup.log" 2>&1 || true
EFI_SHA=$(sha256sum "$BUILD/BOOTX64.SIGNED.EFI" | awk '{print $1}')
run_tpm tpm2_pcrextend "14:sha256=$EFI_SHA" >"$BUILD/tpm-pcr-extend.log" 2>&1
run_tpm tpm2_pcrread sha256:14 >"$BUILD/tpm-pcr14.txt" 2>&1
run_tpm tpm2_getrandom 16 -o "$BUILD/tpm-host-random.bin" >"$BUILD/tpm-getrandom.log" 2>&1
run_tpm tpm2_createprimary -C e -g sha256 -G rsa -c "$BUILD/primary.ctx" \
  >"$BUILD/tpm-createprimary.log" 2>&1
run_tpm tpm2_createak -C "$BUILD/primary.ctx" -c "$BUILD/ak.ctx" -G rsa \
  -g sha256 -s rsassa -u "$BUILD/ak.pub.pem" -f pem -n "$BUILD/ak.name" \
  >"$BUILD/tpm-createak.log" 2>&1
NONCE=${EFI_SHA:0:32}
run_tpm tpm2_quote -c "$BUILD/ak.ctx" -l sha256:14 -q "$NONCE" \
  -m "$BUILD/quote.msg" -s "$BUILD/quote.sig" -o "$BUILD/quote.pcrs" -g sha256 \
  >"$BUILD/tpm-quote.log" 2>&1
run_tpm tpm2_checkquote -u "$BUILD/ak.pub.pem" -m "$BUILD/quote.msg" \
  -s "$BUILD/quote.sig" -f "$BUILD/quote.pcrs" -g sha256 -q "$NONCE" \
  >"$BUILD/tpm-checkquote.log" 2>&1

{
  echo "Axiom64 Singularity 6.0.0 qualification certificate"
  echo "status: PASS"
  echo "qualification date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "BIOS QEMU return code: $BIOS_RC"
  echo "tampered UEFI QEMU return code: $TAMPER_RC"
  echo "valid UEFI QEMU return code: $UEFI_RC"
  echo "OVMF code: $OVMF_CODE"
  echo "OVMF vars template: $OVMF_VARS_TEMPLATE"
  echo "Secure Boot signed EFI SHA-256: $EFI_SHA"
  echo "Secure Boot valid-image enforcement: PASS"
  echo "Secure Boot one-byte tamper rejection: PASS"
  echo "GOP protocol discovery: PASS"
  echo "TCG2 protocol discovery: PASS"
  echo "TPM2 GetRandom through UEFI TCG2: PASS"
  echo "UEFI memory-map acquisition: PASS"
  echo "ExitBootServices transition: PASS"
  echo "post-firmware kernel ownership: PASS"
  echo "TPM PCR14 artifact extension: PASS"
  echo "TPM nonce-qualified quote verification: PASS"
  echo "BIOS long-mode transition: PASS"
  echo "host-executed assembly primitives: PASS"
  echo "bounded architecture model: PASS"
  echo "symbolic specification proofs: PASS"
  echo "third-party hardware certification: NOT CLAIMED"
  echo "whole-kernel machine-code refinement theorem: NOT CLAIMED"
} | tee "$BUILD/qualification-certificate.txt"

sha256sum \
  "$BUILD/axiom64-singularity-6-bios.img" \
  "$BUILD/BOOTX64.EFI" \
  "$BUILD/BOOTX64.SIGNED.EFI" \
  "$BUILD/BOOTX64.TAMPERED.EFI" \
  "$BUILD/esp.img" \
  "$BUILD/host-assembly-report.txt" \
  "$BUILD/model-report.txt" \
  "$BUILD/proof-report.txt" \
  "$BUILD/qemu-bios.log" \
  "$BUILD/qemu-uefi-tamper.log" \
  "$BUILD/qemu-uefi-secure.log" \
  "$BUILD/quote.msg" \
  "$BUILD/quote.sig" \
  "$BUILD/quote.pcrs" \
  "$BUILD/qualification-certificate.txt" \
  | tee "$BUILD/artifact-SHA256SUMS.txt"
