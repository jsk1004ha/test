# Axiom64 Totality 8.0.0

Axiom64 Totality is a qualified x86-64 operating-system image that combines a
small hand-written assembly diagnostic plane with a Linux LTS hardware and
service plane. The hybrid design is intentional: a modern usable system must
support real firmware interfaces, multiprocessor scheduling, IOMMUs, storage,
filesystems, networking, graphics, audio, USB, cryptography and application
isolation. Reimplementing every mature subsystem in one unreviewed assembly
kernel would reduce, not increase, trustworthiness.

## Architecture

```text
BIOS / UEFI / UEFI Secure Boot
        |
        +-- GRUB hybrid ISO
        +-- signed Unified Kernel Image (UKI)
                    |
              Linux LTS x86-64
                    |
    +---------------+--------------------+
    |                                    |
Assembly diagnostic plane         Alpine/musl service plane
syscall / CPUID / RDTSC            storage, network, TPM, OCI,
serial and protection probes       Wayland, SSH, crypto, tools
```

The base root filesystem is a compressed immutable initramfs. Runtime writes
live in RAM or on explicitly mounted block devices. The release contains a
hybrid BIOS/UEFI ISO, signed UKI, Secure-Boot ESP image, complete source archive,
package SBOM, provenance and qualification evidence.

## Qualified execution profiles

A release is not marked qualified unless all mandatory profiles pass:

- direct-kernel boot with 1, 2, 4 and 8 virtual CPUs;
- Q35 with two NUMA nodes and strict Intel VT-d translation;
- virtio-blk, NVMe, AHCI and USB mass storage with write, sync, readback and
  host-side post-poweroff verification;
- xHCI keyboard/tablet/storage, virtio GPU, HDA audio and virtio networking;
- TPM 2.0 random generation, PCR access and object seal/unseal;
- BIOS and native UEFI boot of the same hybrid ISO;
- custom-key UEFI Secure Boot of the signed UKI;
- one-byte signed-payload tamper rejection before Linux starts.

## Security and isolation tests

The guest executes positive and negative tests for:

- seccomp filtering and Landlock filesystem confinement;
- KASLR, page-table isolation, namespaces, cgroup v2 and kernel hardening;
- PIDFD, `clone3`, `openat2`, an actual `io_uring` NOP completion,
  `memfd_secret`, immutable memory seals and frozen eBPF maps;
- LUKS2/dm-crypt and dm-verity, including deliberate corruption rejection;
- OCI isolation through crun with PID, mount, UTS, IPC and cgroup namespaces,
  no capabilities, `noNewPrivileges` and a read-only root;
- nftables and a real encrypted WireGuard tunnel between network namespaces;
- ACLs, extended attributes, kernel keyrings and TLS handshakes;
- Btrfs read-only snapshots, XFS, SquashFS, md RAID1 and LVM snapshots.

## Runtime services

The live environment contains a package manager, dynamically linked musl
userland, Dropbear SSH, Weston/Wayland, cryptographic and storage utilities,
network diagnostics and an interactive maintenance shell. The default network
and kernel policy is hardened; unprivileged BPF, kexec, kernel pointers and
unrestricted performance events are disabled.

## Building

The reference build runs on Ubuntu 24.04 with Docker and the packages installed
by `.github/workflows/axiom64-totality.yml`.

```bash
cd axiom64-totality
sudo ./build.sh
sudo ./test.sh
```

The test harness uses QEMU 11, OVMF, swtpm and a custom Secure Boot certificate.
The private qualification key is ephemeral and is never included in the
release. The public certificate is included so the UKI can be verified or
enrolled in a separate test firmware variable store.

## Running the hybrid ISO

```bash
qemu-system-x86_64 \
  -machine q35 \
  -cpu max \
  -smp 8 \
  -m 4096 \
  -cdrom axiom64-totality-8.0.0.iso \
  -serial stdio
```

## Scope of the claim

Totality 8.0.0 is designed to be the most capable and most thoroughly tested
Axiom64 release. Its qualification applies to the declared x86-64/Q35 virtual
hardware matrix. It is not a proof that every physical device, CPU erratum or
third-party application in existence is supported, and it is not a formal
machine-code proof comparable to a verified microkernel. Unsupported or
untested behavior is not relabeled as implemented.
