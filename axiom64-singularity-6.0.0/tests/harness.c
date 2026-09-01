#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

uint64_t ax_cap_derive(uint64_t parent, uint64_t requested);
int ax_cap_has(uint64_t rights, uint64_t required);
uint64_t ax_x2apic_icr(uint32_t vector, uint32_t delivery, uint32_t destination);
int64_t ax_smp_pick_cpu(const uint32_t *loads, uint32_t count, uint64_t affinity);
int64_t ax_numa_pick_node(const uint16_t *distances, uint32_t count, uint64_t allowed);
int64_t ax_hotplug_transition(uint32_t state, uint32_t event);
void ax_vtd_context(uint64_t out[2], uint64_t slptptr, uint16_t domain, uint8_t aw);
int ax_dma_window_contains(uint64_t base, uint64_t size, uint64_t address, uint64_t length);
uint64_t ax_pcie_ecam_address(uint64_t base, uint32_t bus, uint32_t device,
                              uint32_t function, uint32_t reg);
void ax_nvme_identify(void *command, uint32_t nsid, uint64_t prp1, uint32_t cns);
uint64_t ax_nvme_sq_advance(uint64_t tail, uint64_t depth);
void ax_xhci_trb(void *trb, uint64_t pointer, uint32_t length, uint32_t type,
                 uint32_t cycle);
void ax_usb_setup_packet(void *packet, uint32_t request_type, uint32_t request,
                         uint32_t value, uint32_t index, uint32_t length);
void ax_virtio_desc(void *desc, uint64_t address, uint32_t length, uint32_t flags,
                    uint32_t next);
int ax_elf64_validate(const void *buffer, uint64_t length);
int64_t ax_linux_syscall_map(uint64_t nr);
uint64_t ax_kaslr_choose(uint64_t entropy, uint64_t slots, uint64_t alignment,
                         uint64_t base);
uint64_t ax_kpti_cr3(uint64_t cpl, uint64_t kernel_cr3, uint64_t user_cr3);
uint64_t ax_cet_policy(uint64_t supported, uint64_t requested);
int64_t ax_mpk_mask(uint64_t key);
uint64_t ax_page_table_entry(uint64_t physical, uint64_t flags, uint64_t nx);
uint64_t ax_fat32_next(uint64_t entry);
int ax_ext2_dirent_valid(uint64_t rec_len, uint64_t name_len, uint64_t remaining);
uint16_t ax_ipv4_checksum(const uint8_t *buffer, uint64_t length);
int ax_tcp_seq_before(uint32_t a, uint32_t b);
int ax_iommu_bdf_allowed(uint16_t bdf, const uint16_t *allowlist, uint64_t count);
uint64_t ax_framebuffer_offset(uint64_t x, uint64_t y, uint64_t stride,
                               uint64_t bytes_per_pixel);
uint64_t ax_ring_advance(uint64_t index, uint64_t count);

static unsigned checks;

#define CHECK(expr, label)                                                       \
    do {                                                                         \
        ++checks;                                                                \
        if (!(expr)) {                                                           \
            fprintf(stderr, "FAIL[%u]: %s (%s:%d)\n", checks, label, __FILE__, \
                    __LINE__);                                                   \
            return EXIT_FAILURE;                                                 \
        }                                                                        \
    } while (0)

static uint16_t read16(const uint8_t *p) {
    uint16_t value;
    memcpy(&value, p, sizeof value);
    return value;
}

static uint32_t read32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, sizeof value);
    return value;
}

static uint64_t read64(const uint8_t *p) {
    uint64_t value;
    memcpy(&value, p, sizeof value);
    return value;
}

static void write16(uint8_t *p, uint16_t value) { memcpy(p, &value, sizeof value); }
static void write32(uint8_t *p, uint32_t value) { memcpy(p, &value, sizeof value); }
static void write64(uint8_t *p, uint64_t value) { memcpy(p, &value, sizeof value); }

int main(void) {
    CHECK(ax_cap_derive(0x1ffu, 0x83u) == 0x83u, "capability attenuation accepts subset");
    CHECK(ax_cap_derive(0x1u, 0x3u) == UINT64_MAX, "capability amplification rejected");
    CHECK(ax_cap_has(0x2du, 0x0cu) == 1, "capability rights conjunction");
    CHECK(ax_cap_has(0x05u, 0x0cu) == 0, "missing capability right rejected");
    for (uint64_t parent = 0; parent < 512; ++parent) {
        for (uint64_t requested = 0; requested < 512; ++requested) {
            const uint64_t result = ax_cap_derive(parent, requested);
            const int subset = ((requested & ~parent) == 0);
            CHECK((subset && result == requested) || (!subset && result == UINT64_MAX),
                  "exhaustive nine-bit capability lattice");
        }
    }

    CHECK(ax_x2apic_icr(0x45, 5, 0x12345678u) == UINT64_C(0x1234567800000545),
          "x2APIC ICR field encoding");

    const uint32_t loads[] = {8, 2, 2, 9};
    CHECK(ax_smp_pick_cpu(loads, 4, 0x0du) == 2, "per-CPU load/affinity selection");
    CHECK(ax_smp_pick_cpu(loads, 4, 0) == -1, "empty CPU affinity rejected");

    const uint16_t distances[] = {30, 10, 20, 40};
    CHECK(ax_numa_pick_node(distances, 4, 0x0fu) == 1, "nearest NUMA node selection");
    CHECK(ax_numa_pick_node(distances, 4, 0x0du) == 2, "NUMA allowed-mask isolation");

    CHECK(ax_hotplug_transition(0, 0) == 1, "CPU offline to starting");
    CHECK(ax_hotplug_transition(1, 1) == 2, "CPU starting to online");
    CHECK(ax_hotplug_transition(2, 2) == 3, "CPU online to dying");
    CHECK(ax_hotplug_transition(3, 3) == 0, "CPU dying to offline");
    CHECK(ax_hotplug_transition(2, 4) == 4, "CPU failure containment");
    CHECK(ax_hotplug_transition(4, 5) == 0, "CPU failed recovery");
    CHECK(ax_hotplug_transition(0, 3) == -1, "invalid hotplug transition rejected");

    uint64_t context[2] = {0, 0};
    ax_vtd_context(context, UINT64_C(0x12345abc), 0x1234, 3);
    CHECK(context[0] == UINT64_C(0x12345001), "VT-d translated-root encoding");
    CHECK(context[1] == UINT64_C(0x123403), "VT-d domain/address-width encoding");
    CHECK(ax_dma_window_contains(0x1000, 0x1000, 0x1800, 0x100) == 1,
          "DMA request contained in assigned window");
    CHECK(ax_dma_window_contains(0x1000, 0x1000, 0x1f80, 0x100) == 0,
          "DMA request crossing assignment rejected");
    CHECK(ax_dma_window_contains(UINT64_MAX - 8, 32, UINT64_MAX - 4, 4) == 0,
          "DMA arithmetic overflow rejected");

    CHECK(ax_pcie_ecam_address(UINT64_C(0xe0000000), 2, 3, 1, 0x44) ==
              UINT64_C(0xe0219044),
          "PCIe ECAM BDF/register address");

    uint8_t nvme[64];
    memset(nvme, 0xa5, sizeof nvme);
    ax_nvme_identify(nvme, 7, UINT64_C(0x12345000), 1);
    CHECK(nvme[0] == 0x06, "NVMe Identify opcode");
    CHECK(read32(nvme + 4) == 7, "NVMe namespace field");
    CHECK(read64(nvme + 24) == UINT64_C(0x12345000), "NVMe PRP1 field");
    CHECK(read32(nvme + 40) == 1, "NVMe CNS field");
    CHECK(ax_nvme_sq_advance(7, 8) == 0, "NVMe submission-ring wrap");
    CHECK(ax_nvme_sq_advance(2, 8) == 3, "NVMe submission-ring advance");
    CHECK(ax_nvme_sq_advance(0, 0) == UINT64_MAX, "zero-depth NVMe ring rejected");

    uint8_t trb[16] = {0};
    ax_xhci_trb(trb, UINT64_C(0x123456789abc), 0x12345, 6, 1);
    CHECK(read64(trb) == UINT64_C(0x123456789abc), "xHCI TRB pointer");
    CHECK(read32(trb + 8) == 0x12345, "xHCI TRB transfer length");
    CHECK(read32(trb + 12) == ((6u << 10) | 1u), "xHCI TRB type/cycle");

    uint8_t setup[8] = {0};
    ax_usb_setup_packet(setup, 0x80, 6, 0x0100, 0x0200, 64);
    CHECK(setup[0] == 0x80 && setup[1] == 6, "USB setup request header");
    CHECK(read16(setup + 2) == 0x0100, "USB setup value");
    CHECK(read16(setup + 4) == 0x0200, "USB setup index");
    CHECK(read16(setup + 6) == 64, "USB setup length");

    uint8_t descriptor[16] = {0};
    ax_virtio_desc(descriptor, UINT64_C(0xabcde000), 4096, 3, 17);
    CHECK(read64(descriptor) == UINT64_C(0xabcde000), "virtio descriptor address");
    CHECK(read32(descriptor + 8) == 4096, "virtio descriptor length");
    CHECK(read16(descriptor + 12) == 3 && read16(descriptor + 14) == 17,
          "virtio descriptor chain fields");

    uint8_t elf[128];
    memset(elf, 0, sizeof elf);
    elf[0] = 0x7f;
    elf[1] = 'E';
    elf[2] = 'L';
    elf[3] = 'F';
    elf[4] = 2;
    elf[5] = 1;
    elf[6] = 1;
    write16(elf + 16, 3);
    write16(elf + 18, 62);
    write32(elf + 20, 1);
    write64(elf + 32, 64);
    write16(elf + 52, 64);
    write16(elf + 54, 56);
    write16(elf + 56, 1);
    CHECK(ax_elf64_validate(elf, sizeof elf) == 0, "bounded ELF64 PIE accepted");
    elf[4] = 1;
    CHECK(ax_elf64_validate(elf, sizeof elf) == -22, "ELF32 rejected by ELF64 loader");
    elf[4] = 2;
    CHECK(ax_elf64_validate(elf, 100) == -22, "truncated program table rejected");

    CHECK(ax_linux_syscall_map(0) == 1, "Linux read ABI mapping");
    CHECK(ax_linux_syscall_map(1) == 2, "Linux write ABI mapping");
    CHECK(ax_linux_syscall_map(9) == 4, "Linux mmap ABI mapping");
    CHECK(ax_linux_syscall_map(202) == 8, "Linux futex ABI mapping");
    CHECK(ax_linux_syscall_map(257) == 10, "Linux openat ABI mapping");
    CHECK(ax_linux_syscall_map(9999) == -38, "unsupported Linux syscall is ENOSYS");

    CHECK(ax_kaslr_choose(11, 8, 0x200000, 0xffffffff80000000ULL) ==
              UINT64_C(0xffffffff80600000),
          "KASLR slot selection");
    CHECK(ax_kaslr_choose(11, 0, 0x200000, 0x100000) == 0x100000,
          "KASLR zero-slot fallback");
    CHECK(ax_kpti_cr3(0, 0x1001, 0x2002) == 0x1001, "KPTI kernel CR3 selection");
    CHECK(ax_kpti_cr3(3, 0x1001, 0x2002) == 0x2002, "KPTI user CR3 selection");
    CHECK(ax_cet_policy(3, 1) == 1, "CET requested/supported intersection");
    CHECK(ax_cet_policy(1, 2) == 0, "unsupported CET mode remains disabled");
    CHECK(ax_mpk_mask(3) == (INT64_C(3) << 6), "MPK PKRU mask");
    CHECK(ax_mpk_mask(16) == -1, "out-of-range MPK key rejected");
    CHECK(ax_page_table_entry(0x12345abc, 3, 1) == UINT64_C(0x8000000012345003),
          "page-table W^X/NX encoding");

    CHECK(ax_fat32_next(0xf1234567) == 0x01234567, "FAT32 high nibble masked");
    CHECK(ax_fat32_next(0x0ffffff8) == UINT64_MAX, "FAT32 end-of-chain recognized");
    CHECK(ax_ext2_dirent_valid(12, 3, 1024) == 1, "ext2 directory record accepted");
    CHECK(ax_ext2_dirent_valid(10, 2, 1024) == 0, "unaligned ext2 record rejected");
    CHECK(ax_ext2_dirent_valid(12, 5, 12) == 0, "oversized ext2 name rejected");

    const uint8_t checksum_vector[] = {0x00, 0x01, 0xf2, 0x03};
    CHECK(ax_ipv4_checksum(checksum_vector, sizeof checksum_vector) == 0x0dfb,
          "IPv4 one's-complement checksum");
    CHECK(ax_tcp_seq_before(0xfffffffeu, 2u) == 1, "TCP wrapped sequence ordering");
    CHECK(ax_tcp_seq_before(2u, 0xfffffffeu) == 0, "TCP inverse sequence ordering");

    const uint16_t allowlist[] = {0x0008, 0x0110, 0x02f8};
    CHECK(ax_iommu_bdf_allowed(0x0110, allowlist, 3) == 1,
          "IOMMU requester allowlist hit");
    CHECK(ax_iommu_bdf_allowed(0x0118, allowlist, 3) == 0,
          "IOMMU requester allowlist miss");

    CHECK(ax_framebuffer_offset(3, 2, 100, 4) == 812,
          "GPU/framebuffer scanline offset");
    CHECK(ax_ring_advance(7, 8) == 0, "generic lock-free ring wrap primitive");
    CHECK(ax_ring_advance(4, 8) == 5, "generic lock-free ring advance primitive");
    CHECK(ax_ring_advance(0, 0) == UINT64_MAX, "zero-sized ring rejected");

    printf("Axiom64 Singularity 6 host-executed assembly qualification\n");
    printf("checks: %u\n", checks);
    printf("status: PASS\n");
    return EXIT_SUCCESS;
}
