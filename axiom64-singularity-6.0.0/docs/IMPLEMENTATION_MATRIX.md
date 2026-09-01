# Implementation and Evidence Matrix

This matrix separates **implemented code**, **full-machine execution**, and **universal hardware/certification claims**. “Core implemented” means the relevant state transition, descriptor, parser, validation or policy is executable assembly and covered by tests. It does not automatically mean every vendor device has been driven on physical hardware.

| Previously missing area | Singularity 6 implementation | Evidence class | Remaining boundary |
|---|---|---|---|
| UEFI boot | Native AMD64 PE32+ EFI image in pure assembly | Full OVMF machine boot | Physical firmware diversity not certified |
| Secure Boot | RSA-3072 signed EFI; isolated PK/KEK/db enrollment; firmware `SecureBoot=1` gate | Firmware-enforced QEMU/OVMF | Shipped key is development-only; no Microsoft/third-party CA |
| TPM/TCG2 | UEFI TCG2 capability query and TPM2_GetRandom command | Full OVMF+swtpm machine boot | Physical TPM vendor matrix not certified |
| PCR attestation | Signed-EFI SHA-256 extended into PCR14; nonce quote; checkquote | Executed TPM workflow | No remote verifier service included |
| GOP graphics | GOP protocol discovery and framebuffer offset primitive | Firmware runtime + assembly test | No accelerated vendor GPU command processor |
| AP run-queue policy | Load/affinity CPU selector and bounded ring arithmetic | Native assembly + model | v5 kernel integration is a separate merge task |
| x2APIC | 64-bit ICR construction with 32-bit destination IDs | Native assembly + symbolic proof | No physical >255-ID platform qualification |
| NUMA | Allowed-node nearest-distance selector | Native assembly + model | ACPI SRAT/SLIT ingestion not in this standalone edition |
| CPU hotplug | Five-state validated transition machine | Native assembly + exhaustive model | Real ACPI eject/insert events not certified |
| IOMMU / VT-d | Context-entry construction, DMA windows, BDF allowlist | Native assembly + model/proof | No vendor MMIO fault/event queue integration |
| PCIe | ECAM address generation | Native assembly | Full enumeration/BAR allocator not hardware-qualified |
| NVMe | Identify command SQE and queue-wrap logic | Native assembly binary-layout test | No physical controller reset/admin queue/IRQ path |
| USB/xHCI | Transfer Request Block and setup packet construction | Native assembly binary-layout test | No physical port state machine or device-class stack |
| virtio | Descriptor construction | Native assembly binary-layout test | Full virtqueue notification/interrupt service not integrated |
| Network | IPv4 checksum and TCP sequence arithmetic | Native assembly vectors/model | No complete ARP/DHCP/IPv6/TCP socket service |
| Filesystem | FAT32 chain handling and ext2 dirent validator | Native assembly vectors | No journal, crash recovery, or mounted VFS namespace |
| Dynamic ELF | Bounded ELF64 ET_EXEC/ET_DYN header/program-table validator | Native assembly adversarial tests | Relocation interpreter and process spawn service are partial |
| POSIX/Linux ABI | Explicit x86-64 syscall translation subset with ENOSYS fallback | Native assembly test | Not a complete Linux ABI or glibc environment |
| KASLR | Entropy-to-aligned-slot selection | Native assembly + bounded model + proof | UEFI image relocation is firmware-controlled; full v5 kernel relocation not merged |
| KPTI | CPL-sensitive kernel/user CR3 selection | Native assembly + proof | Full per-process v5 page-table split not merged here |
| CET SHSTK/IBT | Requested∩supported policy primitive | Native assembly + proof | Enabling CET requires compatible full call graph/toolchain |
| MPK | PKRU two-bit key mask construction | Native assembly + test | Process allocator and fault policy not integrated |
| Hardware-tagged capabilities | Rights/generation software capability lattice remains implemented | Native assembly + exhaustive lattice | CHERI-style tags cannot be manufactured by software on ordinary x86 |
| Full refinement theorem | Z3 proofs for isolated bit-vector/integer invariants | Symbolic proof report | Whole-kernel machine-code refinement is not claimed |
| Real-PC certification | QEMU machine qualification and reproducible reports | Automated CI evidence | Third-party hardware/safety/security certification absent |

## Why some rows cannot honestly be labelled “universally complete”

A controller driver is a combination of specification logic, actual MMIO/interrupt/DMA integration, device-specific quirks and validation across hardware revisions. Singularity 6 implements and executes the specification-critical primitives for all listed families, but does not fabricate evidence for physical devices that were never attached.

Similarly, hardware-tagged capabilities require ISA support that an x86 program cannot create, while third-party certification and a whole-kernel refinement proof are independent assurance projects rather than ordinary code features.

## Qualification rule

A release is marked PASS only when all of the following succeed:

1. native assembly harness;
2. bounded state-space model;
3. Z3 specification proofs;
4. structural PE/BIOS/signature checks;
5. BIOS long-mode QEMU boot;
6. OVMF Secure Boot boot of the signed EFI image;
7. GOP and TCG2 discovery;
8. TPM2 command execution;
9. PCR extension, quote creation and independent quote verification.
