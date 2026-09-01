PROJECT := Axiom64-Singularity-6.0.0
BUILD := build
DIST := dist
CC := gcc
NASM := nasm
QEMU := qemu-system-x86_64
.RECIPEPREFIX := >

.PHONY: all clean bios uefi host-test model-test proof-test check qualification package

all: bios uefi $(BUILD)/advanced-harness

$(BUILD) $(DIST):
>mkdir -p $@

bios: $(BUILD)/axiom64-singularity-6-bios.img

$(BUILD)/axiom64-singularity-6-bios.img: src/bios.asm | $(BUILD)
>$(NASM) -f bin -Wall -Werror -o $@ $<

$(BUILD)/uefi.obj: src/uefi.asm | $(BUILD)
>$(NASM) -f win64 -Wall -Werror -o $@ $<

$(BUILD)/BOOTX64.EFI: $(BUILD)/uefi.obj
>lld-link /subsystem:efi_application /entry:efi_main /nodefaultlib /machine:x64 /dynamicbase /nxcompat /out:$@ $<

$(BUILD)/db.key $(BUILD)/db.crt &: | $(BUILD)
>openssl req -new -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 -subj '/CN=Axiom64 Singularity Development Secure Boot/' -keyout $(BUILD)/db.key -out $(BUILD)/db.crt

$(BUILD)/BOOTX64.SIGNED.EFI: $(BUILD)/BOOTX64.EFI $(BUILD)/db.key $(BUILD)/db.crt
>sbsign --key $(BUILD)/db.key --cert $(BUILD)/db.crt --output $@ $(BUILD)/BOOTX64.EFI
>sbverify --cert $(BUILD)/db.crt $@

$(BUILD)/esp.img: $(BUILD)/BOOTX64.SIGNED.EFI README.md | $(BUILD)
>rm -f $@
>truncate -s 64M $@
>mformat -i $@ -F ::
>mmd -i $@ ::/EFI
>mmd -i $@ ::/EFI/BOOT
>mmd -i $@ ::/AXIOM64
>mcopy -i $@ $(BUILD)/BOOTX64.SIGNED.EFI ::/EFI/BOOT/BOOTX64.EFI
>mcopy -i $@ README.md ::/AXIOM64/README.TXT

uefi: $(BUILD)/esp.img

$(BUILD)/advanced.o: src/advanced.asm | $(BUILD)
>$(NASM) -f elf64 -Wall -Werror -o $@ $<

$(BUILD)/advanced-harness: tests/harness.c $(BUILD)/advanced.o | $(BUILD)
>$(CC) -std=c17 -O2 -Wall -Wextra -Werror -fno-pie -no-pie -o $@ tests/harness.c $(BUILD)/advanced.o

host-test: $(BUILD)/advanced-harness
>$(BUILD)/advanced-harness | tee $(BUILD)/host-assembly-report.txt
>grep -q 'status: PASS' $(BUILD)/host-assembly-report.txt

model-test: | $(BUILD)
>python3 tests/model.py | tee $(BUILD)/model-report.txt
>grep -q 'status: PASS' $(BUILD)/model-report.txt

proof-test: | $(BUILD)
>python3 tests/prove.py | tee $(BUILD)/proof-report.txt
>grep -q 'status: PASS' $(BUILD)/proof-report.txt

check: all host-test model-test proof-test
>python3 tools/check.py --build $(BUILD) | tee $(BUILD)/structural-report.txt
>grep -q 'status: PASS' $(BUILD)/structural-report.txt

qualification: check
>bash tools/qualification.sh

package: qualification | $(DIST)
>rm -rf $(BUILD)/package-root
>mkdir -p $(BUILD)/package-root/$(PROJECT)/artifacts
>cp -a Makefile README.md LICENSE src tests tools docs proofs $(BUILD)/package-root/$(PROJECT)/
>cp $(BUILD)/axiom64-singularity-6-bios.img $(BUILD)/BOOTX64.EFI $(BUILD)/BOOTX64.SIGNED.EFI $(BUILD)/esp.img $(BUILD)/db.crt $(BUILD)/package-root/$(PROJECT)/artifacts/
>cp $(BUILD)/*-report.txt $(BUILD)/*.log $(BUILD)/qualification-certificate.txt $(BUILD)/artifact-SHA256SUMS.txt $(BUILD)/package-root/$(PROJECT)/artifacts/ 2>/dev/null || true
>cd $(BUILD)/package-root && TZ=UTC find $(PROJECT) -exec touch -h -d '@0' {} + && zip -X -q -r ../../$(DIST)/$(PROJECT).zip $(PROJECT)
>cp $(BUILD)/axiom64-singularity-6-bios.img $(DIST)/
>cp $(BUILD)/BOOTX64.SIGNED.EFI $(DIST)/Axiom64-Singularity-6.0.0-BOOTX64.EFI
>cp $(BUILD)/esp.img $(DIST)/Axiom64-Singularity-6.0.0-ESP.img
>cp $(BUILD)/qualification-certificate.txt $(DIST)/
>cp $(BUILD)/artifact-SHA256SUMS.txt $(DIST)/Axiom64-Singularity-6.0.0-SHA256SUMS.txt
>sha256sum $(DIST)/* | tee $(DIST)/FINAL-SHA256SUMS.txt

clean:
>rm -rf $(BUILD) $(DIST)
