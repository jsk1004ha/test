#!/usr/bin/env python3
"""Structural release checker for Axiom64 Singularity 6."""

from __future__ import annotations

import argparse
import hashlib
import struct
import subprocess
from pathlib import Path


class Checks:
    def __init__(self) -> None:
        self.count = 0

    def require(self, condition: bool, message: str) -> None:
        self.count += 1
        if not condition:
            raise SystemExit(f"[FAIL] {message}")
        print(f"[OK] {message}")


def pe_fields(data: bytes) -> tuple[int, int, int, int, int, int]:
    if len(data) < 0x100 or data[:2] != b"MZ":
        raise ValueError("not an MZ image")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 0x100 > len(data) or data[pe : pe + 4] != b"PE\0\0":
        raise ValueError("missing PE signature")
    machine = struct.unpack_from("<H", data, pe + 4)[0]
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    subsystem = struct.unpack_from("<H", data, optional + 68)[0]
    dll_characteristics = struct.unpack_from("<H", data, optional + 70)[0]
    security_offset, security_size = struct.unpack_from("<II", data, optional + 112 + 4 * 8)
    if optional + optional_size > len(data):
        raise ValueError("truncated optional header")
    return machine, magic, subsystem, dll_characteristics, security_offset, security_size


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    args = parser.parse_args()
    build = args.build
    checks = Checks()

    names = {
        "bios": "axiom64-singularity-6-bios.img",
        "uefi": "BOOTX64.EFI",
        "signed": "BOOTX64.SIGNED.EFI",
        "certificate": "db.crt",
        "esp": "esp.img",
        "advanced": "advanced.o",
        "harness": "advanced-harness",
        "host_report": "host-assembly-report.txt",
        "model_report": "model-report.txt",
        "proof_report": "proof-report.txt",
    }
    paths = {key: build / value for key, value in names.items()}
    for key, path in paths.items():
        checks.require(path.is_file(), f"required artifact exists: {key} -> {path.name}")

    bios = paths["bios"].read_bytes()
    checks.require(len(bios) >= 1024, "BIOS image includes a nontrivial stage2")
    checks.require(len(bios) % 512 == 0, "BIOS image is sector aligned")
    checks.require(bios[510:512] == b"\x55\xaa", "BIOS boot signature is 0x55AA")
    checks.require(b"BIOS_BOOT: PASS" in bios, "BIOS image embeds boot qualification marker")
    checks.require(b"LONG_MODE: PASS" in bios, "BIOS image embeds long-mode marker")
    checks.require(b"CPU_HARDENING_SCAN: PASS" in bios, "BIOS image embeds hardening marker")

    uefi = paths["uefi"].read_bytes()
    machine, magic, subsystem, dllchars, sec_off, sec_size = pe_fields(uefi)
    checks.require(machine == 0x8664, "UEFI image targets AMD64")
    checks.require(magic == 0x20B, "UEFI image uses PE32+ optional header")
    checks.require(subsystem == 10, "UEFI image subsystem is EFI application")
    checks.require(bool(dllchars & 0x40), "UEFI image requests dynamic-base relocation")
    checks.require(bool(dllchars & 0x100), "UEFI image requests NX compatibility")
    checks.require(sec_off == 0 and sec_size == 0, "unsigned UEFI image has no certificate table")
    for marker in (
        b"UEFI_BOOT: PASS",
        b"SECURE_BOOT: ENABLED",
        b"GOP: PRESENT",
        b"TCG2: PRESENT",
        b"TPM2_GET_RANDOM: PASS",
        b"UEFI_QUALIFICATION_COMPLETE: PASS",
    ):
        checks.require(marker in uefi, f"UEFI image embeds marker: {marker.decode()}")

    certificate = paths["certificate"].read_bytes()
    checks.require(certificate.startswith(b"-----BEGIN CERTIFICATE-----"),
                   "Secure Boot public certificate is PEM encoded")
    checks.require(b"-----END CERTIFICATE-----" in certificate,
                   "Secure Boot public certificate is complete")

    signed = paths["signed"].read_bytes()
    smachine, smagic, ssubsystem, sdllchars, ssec_off, ssec_size = pe_fields(signed)
    checks.require((smachine, smagic, ssubsystem) == (0x8664, 0x20B, 10),
                   "signed UEFI image preserves AMD64 EFI metadata")
    checks.require(ssec_off > 0 and ssec_size > 0, "signed UEFI image has an Authenticode certificate table")
    checks.require(ssec_off + ssec_size <= len(signed), "UEFI certificate table lies inside signed image")
    checks.require(len(signed) > len(uefi), "Secure Boot signature increases image size")
    checks.require(sdllchars == dllchars, "signing preserves UEFI hardening flags")

    esp = paths["esp"].read_bytes()
    checks.require(len(esp) == 64 * 1024 * 1024, "ESP image is exactly 64 MiB")
    checks.require(esp[510:512] == b"\x55\xaa", "ESP has a valid FAT boot-sector signature")

    verify = subprocess.run(
        ["sbverify", "--cert", str(paths["certificate"]), str(paths["signed"])],
        check=True,
        capture_output=True,
        text=True,
    )
    checks.require(verify.returncode == 0, "signed EFI verifies against the emitted public certificate")

    nm = subprocess.run(
        ["nm", "-g", "--defined-only", str(paths["advanced"])],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    required_symbols = (
        "ax_cap_derive",
        "ax_x2apic_icr",
        "ax_smp_pick_cpu",
        "ax_numa_pick_node",
        "ax_hotplug_transition",
        "ax_vtd_context",
        "ax_dma_window_contains",
        "ax_pcie_ecam_address",
        "ax_nvme_identify",
        "ax_xhci_trb",
        "ax_usb_setup_packet",
        "ax_virtio_desc",
        "ax_elf64_validate",
        "ax_linux_syscall_map",
        "ax_kaslr_choose",
        "ax_kpti_cr3",
        "ax_cet_policy",
        "ax_mpk_mask",
        "ax_page_table_entry",
        "ax_fat32_next",
        "ax_ext2_dirent_valid",
        "ax_ipv4_checksum",
        "ax_iommu_bdf_allowed",
        "ax_framebuffer_offset",
    )
    for symbol in required_symbols:
        checks.require(symbol in nm, f"advanced assembly exports {symbol}")

    for key in ("host_report", "model_report", "proof_report"):
        report = paths[key].read_text(encoding="utf-8")
        checks.require("status: PASS" in report, f"{key} records PASS")

    readelf = subprocess.run(
        ["readelf", "-W", "-S", str(paths["advanced"])],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    checks.require(".note.GNU-stack" in readelf, "assembly object declares a non-executable host stack")

    digest = hashlib.sha256()
    for key in sorted(paths):
        digest.update(paths[key].read_bytes())
    print(f"aggregate checked-artifact SHA-256: {digest.hexdigest()}")
    print(f"checks: {checks.count}")
    print("status: PASS")


if __name__ == "__main__":
    main()
