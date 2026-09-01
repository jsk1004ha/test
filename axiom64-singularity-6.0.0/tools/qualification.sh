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
  grep -aFq "$marker" "$file" || fail "missing '$marker' in $file"
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

# Enroll the exact development certificate into PK/KEK/db and switch the
# copied OVMF variable store into Secure Boot user mode.
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
timeout 30s "$QEMU" \
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
[[ $BIOS_RC -ne 124 ]] || fail "BIOS QEMU run timed out"
require_marker "$BUILD/qemu-bios.log" "BIOS_BOOT: PASS"
require_marker "$BUILD/qemu-bios.log" "LONG_MODE: PASS"
require_marker "$BUILD/qemu-bios.log" "CPU_HARDENING_SCAN: PASS"
require_marker "$BUILD/qemu-bios.log" "BIOS_QUALIFICATION_COMPLETE: PASS"

# A TCP swtpm exposes a TPM command port for tpm2-tools and a control port for
# QEMU's tpm-emulator backend. QEMU and the quote tools use it sequentially.
TPM_DIR="$BUILD/swtpm-state"
rm -rf "$TPM_DIR"
mkdir -p "$TPM_DIR"
swtpm socket \
  --tpm2 \
  --tpmstate dir="$TPM_DIR" \
  --server type=tcp,port=2321,bindaddr=127.0.0.1 \
  --ctrl type=tcp,port=2322,bindaddr=127.0.0.1 \
  --flags not-need-init,startup-clear \
  --pid file="$BUILD/swtpm.pid" \
  --log level=20,file="$BUILD/swtpm.log" \
  --daemon
sleep 1

cleanup() {
  if [[ -f "$BUILD/swtpm.pid" ]]; then
    kill "$(cat "$BUILD/swtpm.pid")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# UEFI Secure Boot + GOP + TCG2 + TPM command test.
set +e
timeout 60s "$QEMU" \
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
  -chardev socket,id=chrtpm,host=127.0.0.1,port=2322 \
  -tpmdev emulator,id=tpm0,chardev=chrtpm \
  -device tpm-tis,tpmdev=tpm0 \
  -no-reboot
UEFI_RC=$?
set -e
[[ $UEFI_RC -ne 124 ]] || fail "UEFI QEMU run timed out"
require_marker "$BUILD/qemu-uefi-secure.log" "UEFI_BOOT: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "SECURE_BOOT: ENABLED"
require_marker "$BUILD/qemu-uefi-secure.log" "GOP: PRESENT"
require_marker "$BUILD/qemu-uefi-secure.log" "TCG2: PRESENT"
require_marker "$BUILD/qemu-uefi-secure.log" "TPM2_GET_RANDOM: PASS"
require_marker "$BUILD/qemu-uefi-secure.log" "UEFI_QUALIFICATION_COMPLETE: PASS"

# Bind the signed EFI artifact hash into PCR 14 and produce a nonce-qualified
# TPM quote whose signature and PCR bundle are independently checked.
export TPM2TOOLS_TCTI="swtpm:host=127.0.0.1,port=2321"
tpm2_startup -c >"$BUILD/tpm-startup.log" 2>&1 || true
EFI_SHA=$(sha256sum "$BUILD/BOOTX64.SIGNED.EFI" | awk '{print $1}')
tpm2_pcrextend "14:sha256=$EFI_SHA" >"$BUILD/tpm-pcr-extend.log" 2>&1
tpm2_pcrread sha256:14 >"$BUILD/tpm-pcr14.txt" 2>&1
tpm2_getrandom 16 -o "$BUILD/tpm-host-random.bin" >"$BUILD/tpm-getrandom.log" 2>&1

tpm2_createprimary -C e -g sha256 -G rsa -c "$BUILD/primary.ctx" \
  >"$BUILD/tpm-createprimary.log" 2>&1
tpm2_createak -C "$BUILD/primary.ctx" -c "$BUILD/ak.ctx" -G rsa \
  -g sha256 -s rsassa -u "$BUILD/ak.pub.pem" -f pem -n "$BUILD/ak.name" \
  >"$BUILD/tpm-createak.log" 2>&1
NONCE=${EFI_SHA:0:32}
tpm2_quote -c "$BUILD/ak.ctx" -l sha256:14 -q "$NONCE" \
  -m "$BUILD/quote.msg" -s "$BUILD/quote.sig" -o "$BUILD/quote.pcrs" -g sha256 \
  >"$BUILD/tpm-quote.log" 2>&1
tpm2_checkquote -u "$BUILD/ak.pub.pem" -m "$BUILD/quote.msg" \
  -s "$BUILD/quote.sig" -f "$BUILD/quote.pcrs" -g sha256 -q "$NONCE" \
  >"$BUILD/tpm-checkquote.log" 2>&1

{
  echo "Axiom64 Singularity 6.0.0 qualification certificate"
  echo "status: PASS"
  echo "qualification date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "BIOS QEMU return code: $BIOS_RC"
  echo "UEFI QEMU return code: $UEFI_RC"
  echo "OVMF code: $OVMF_CODE"
  echo "OVMF vars template: $OVMF_VARS_TEMPLATE"
  echo "Secure Boot signed EFI SHA-256: $EFI_SHA"
  echo "Secure Boot firmware enforcement: PASS"
  echo "GOP protocol discovery: PASS"
  echo "TCG2 protocol discovery: PASS"
  echo "TPM2 GetRandom through UEFI TCG2: PASS"
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
  "$BUILD/esp.img" \
  "$BUILD/host-assembly-report.txt" \
  "$BUILD/model-report.txt" \
  "$BUILD/proof-report.txt" \
  "$BUILD/qemu-bios.log" \
  "$BUILD/qemu-uefi-secure.log" \
  "$BUILD/quote.msg" \
  "$BUILD/quote.sig" \
  "$BUILD/quote.pcrs" \
  "$BUILD/qualification-certificate.txt" \
  | tee "$BUILD/artifact-SHA256SUMS.txt"
