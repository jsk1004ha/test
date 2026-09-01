# Axiom64 Singularity 6.0.0

> **Complete-Systems Qualification Edition** — a pure x86 assembly operating-system research build that extends the Singularity line with an authenticated UEFI path, firmware-enforced Secure Boot, TCG2/TPM interaction, BIOS long-mode compatibility, and executable implementations of the previously missing architecture, I/O, compatibility, hardening, storage, networking, and graphics primitives.

## What this release actually is

Singularity 6 is deliberately split into three evidence levels:

1. **Full-machine runtime paths** — executed under QEMU/OVMF with real firmware protocols and a software TPM.
2. **Host-executed assembly subsystems** — the exact assembly functions execute natively and are checked against concrete binary layouts and boundary cases.
3. **Specification-level models/proofs** — finite-state exploration and Z3 proofs cover declared invariants, without pretending to be a whole-kernel machine-code refinement theorem.

This distinction prevents a driver model, an emulator-qualified driver, and a universally certified real-hardware driver from being falsely presented as the same thing.

## New full-machine runtime paths

### Authenticated UEFI boot

`src/uefi.asm` is a PE32+ EFI application written entirely in NASM assembly. The release pipeline:

- generates a 3072-bit development signing certificate;
- signs `BOOTX64.EFI` with Authenticode;
- enrolls that certificate into an isolated OVMF PK/KEK/db variable store;
- enables UEFI Secure Boot;
- boots the signed image under OVMF with SMM protection;
- rejects qualification unless the firmware reports `SecureBoot=1` to the running image.

The signing private key is ephemeral and is **not** shipped. The public certificate and signed EFI image are shipped so the exact qualification identity is inspectable.

### TCG2 and TPM 2.0

The UEFI image locates `EFI_TCG2_PROTOCOL`, obtains firmware TPM capability data, and submits a wire-format `TPM2_GetRandom` command through `SubmitCommand`. The host qualification stage then:

- extends the signed EFI SHA-256 into PCR 14;
- creates an attestation key;
- emits a nonce-qualified TPM quote;
- verifies the signature and PCR bundle with `tpm2_checkquote`.

This is a hardware-root-compatible measured-boot/attestation design, qualified here with `swtpm`. It is not represented as a third-party real-TPM certification.

### GOP graphics handoff

The UEFI image discovers `EFI_GRAPHICS_OUTPUT_PROTOCOL`, proving the firmware graphics handoff exists before the post-firmware graphics/compositor service takes ownership.

### BIOS compatibility path

`src/bios.asm` remains a completely independent legacy path:

```text
BIOS EDD loader
  -> protected mode
  -> four-level paging
  -> x86-64 long mode
  -> NX + CR0.WP + supported SMEP/SMAP/UMIP
  -> serial qualification transcript
```

## Previously missing subsystems now represented by executable assembly

`src/advanced.asm` contains callable x86-64 implementations for:

| Area | Implemented primitive |
|---|---|
| Hierarchical capability | rights attenuation and required-right validation |
| x2APIC | 64-bit ICR field encoding with 32-bit destination APIC IDs |
| Full SMP policy | per-CPU load and affinity selection |
| NUMA | nearest permitted node selection |
| CPU hotplug | validated offline/starting/online/dying/failed state machine |
| VT-d/IOMMU | translated context descriptor construction and requester allowlist |
| DMA isolation | overflow-safe DMA aperture containment |
| PCIe | ECAM address generation from bus/device/function/register |
| NVMe | 64-byte Identify SQE construction and queue wrap |
| USB/xHCI | 16-byte TRB construction and USB setup-packet encoding |
| virtio | descriptor-chain entry construction |
| Dynamic execution | bounded ELF64 ET_EXEC/ET_DYN validation |
| Linux compatibility | capability-confined x86-64 syscall-number translation subset |
| KASLR | entropy-to-aligned-slot selection |
| KPTI | CPL-dependent kernel/user CR3 selection |
| CET | supported/requested SHSTK+IBT policy intersection |
| MPK | PKRU two-bit protection-key masks |
| Paging | physical/permission/NX PTE construction |
| FAT32 | 28-bit FAT entry and end-of-chain handling |
| ext2 | bounded aligned directory-record validation |
| IPv4 | one's-complement header checksum |
| TCP | modulo-2^32 sequence ordering |
| GPU/framebuffer | scanline-safe pixel offset generation |
| Lock-free rings | bounded producer/consumer index wrap |

The C file in `tests/harness.c` is only a test driver. Every mechanism listed above is implemented in `src/advanced.asm`, and the harness links and executes that object directly.

## Verification

```bash
make check
```

Performs:

- BIOS image/signature/marker checks;
- PE32+ machine, subsystem, NX and dynamic-base checks;
- Authenticode certificate-table checks;
- Secure Boot public-certificate verification;
- exported-assembly-symbol checks;
- more than 262,000 native capability-lattice assertions plus device, ABI, memory, filesystem and networking assertions;
- a bounded architecture state-space model;
- Z3 specification proofs.

```bash
make qualification
```

Adds mandatory full-machine gates:

- BIOS QEMU long-mode boot;
- UEFI OVMF Secure Boot enforcement;
- GOP discovery;
- TCG2 discovery;
- TPM2 command submission;
- PCR extension;
- nonce-qualified TPM quote and independent verification.

```bash
make package
```

Builds qualification first, then creates a deterministic-layout release archive and separate BIOS, signed UEFI and ESP images.

## Build dependencies

Ubuntu 24.04 or newer:

```bash
sudo apt update
sudo apt install \
  nasm lld binutils gcc make qemu-system-x86 ovmf mtools sbsigntool \
  swtpm swtpm-tools tpm2-tools python3 python3-z3 python3-virt-firmware \
  zip unzip
```

## Commands

```bash
make clean
make all
make host-test
make model-test
make proof-test
make check
make qualification
make package
```

## Output

```text
dist/Axiom64-Singularity-6.0.0.zip
dist/axiom64-singularity-6-bios.img
dist/Axiom64-Singularity-6.0.0-BOOTX64.EFI
dist/Axiom64-Singularity-6.0.0-ESP.img
dist/qualification-certificate.txt
dist/Axiom64-Singularity-6.0.0-SHA256SUMS.txt
dist/FINAL-SHA256SUMS.txt
```

## Exact implementation boundary

The following statements are precise:

- UEFI Secure Boot, GOP, TCG2 and TPM command paths are executed in a full firmware VM.
- The BIOS path executes through x86-64 long mode in a full machine VM.
- The listed architecture and device primitives are actual assembly code, not pseudocode.
- The state model is bounded but exhaustive within its declared domains.
- The Z3 proofs establish only the listed specification invariants.

The following are **not** claimed:

- universal operation on every real motherboard, IOMMU, NVMe controller, USB controller, NIC or GPU;
- a complete Linux/POSIX userspace;
- hardware-tagged CHERI capabilities on ordinary x86 hardware;
- a mathematical refinement proof for every instruction of the entire kernel;
- third-party safety, security, Common Criteria, DO-178C, ISO 26262 or real-time certification;
- superiority to every historical operating system under every possible metric.

See [`docs/IMPLEMENTATION_MATRIX.md`](docs/IMPLEMENTATION_MATRIX.md) for the feature-by-feature status and evidence class.

## License

MIT License. The generated development signing certificate is for qualification and experimentation only.
