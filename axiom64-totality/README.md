# Axiom64 Totality 7.0.0

Axiom64 Totality is the practical, hardware-rich companion to the native Axiom64 capability-microkernel research line.

The live system is assembled from Alpine Linux 3.24.1 and its hardened `linux-virt` kernel, then augmented with an assembly-only diagnostic plane, a fail-closed init, hardware qualification, TPM/IOMMU checks, storage persistence tests, namespace/cgroup/seccomp/Landlock tests, an immutable initramfs, and a hybrid BIOS/UEFI ISO.

It is intentionally described as a **hybrid operating system distribution**, not as a from-scratch pure-assembly kernel. Mature Linux subsystems provide the broad hardware and application compatibility that cannot honestly be reproduced as a complete new kernel in a single release.

## Qualified targets

The CI matrix exercises:

- 1, 2, 4, and 8 virtual CPUs
- two NUMA nodes
- Intel VT-d/IOMMU strict translation
- TPM 2.0 through swtpm
- virtio-blk, NVMe, and AHCI persistence
- virtio-net DHCP and TCP/IP
- xHCI with USB keyboard and tablet
- virtio GPU DRM and Intel HDA audio discovery
- ext4 journaling, Btrfs, OverlayFS, loop and dm-crypt
- cgroup v2, mount namespaces, seccomp-BPF, Landlock, nftables, WireGuard
- BIOS and UEFI boot of the same ISO

## Build

```bash
sudo apt-get install docker.io binutils gcc cpio zstd zip grub-pc-bin grub-efi-amd64-bin xorriso mtools qemu-system-x86 ovmf swtpm
./build.sh
./test.sh
```

## Run

```bash
qemu-system-x86_64 \
  -machine q35 \
  -cpu max \
  -smp 8 \
  -m 2048 \
  -cdrom out/axiom64-totality-7.0.0.iso \
  -serial stdio
```

The interactive live environment starts Dropbear SSH when a network interface is available and opens a root maintenance shell on the console. The root filesystem is an immutable compressed initramfs; runtime state lives in RAM unless an explicitly mounted disk is used.

## Claim boundary

This release does not claim that every physical device ever produced is supported, nor that the Linux kernel was written by this project. It claims a reproducibly specified, independently boot-tested integration with explicit evidence for each qualified subsystem.
