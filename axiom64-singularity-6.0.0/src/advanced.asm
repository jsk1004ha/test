; Axiom64 Singularity 6.0.0 advanced architecture primitives
; These routines are executable assembly implementations used both by the
; qualification harness and by the corresponding kernel service designs.

BITS 64
DEFAULT REL

SECTION .text

GLOBAL ax_cap_derive
GLOBAL ax_cap_has
GLOBAL ax_x2apic_icr
GLOBAL ax_smp_pick_cpu
GLOBAL ax_numa_pick_node
GLOBAL ax_hotplug_transition
GLOBAL ax_vtd_context
GLOBAL ax_dma_window_contains
GLOBAL ax_pcie_ecam_address
GLOBAL ax_nvme_identify
GLOBAL ax_nvme_sq_advance
GLOBAL ax_xhci_trb
GLOBAL ax_usb_setup_packet
GLOBAL ax_virtio_desc
GLOBAL ax_elf64_validate
GLOBAL ax_linux_syscall_map
GLOBAL ax_kaslr_choose
GLOBAL ax_kpti_cr3
GLOBAL ax_cet_policy
GLOBAL ax_mpk_mask
GLOBAL ax_page_table_entry
GLOBAL ax_fat32_next
GLOBAL ax_ext2_dirent_valid
GLOBAL ax_ipv4_checksum
GLOBAL ax_tcp_seq_before
GLOBAL ax_iommu_bdf_allowed
GLOBAL ax_framebuffer_offset
GLOBAL ax_ring_advance

; uint64_t ax_cap_derive(parent_rights, requested_rights)
; Returns requested rights iff they are a subset of the parent, else UINT64_MAX.
ax_cap_derive:
    mov rax, rsi
    mov rcx, rdi
    not rcx
    and rcx, rsi
    jnz .cap_fail
    ret
.cap_fail:
    mov rax, -1
    ret

; int ax_cap_has(rights, required)
ax_cap_has:
    mov rax, rdi
    and rax, rsi
    cmp rax, rsi
    sete al
    movzx eax, al
    ret

; uint64_t ax_x2apic_icr(vector, delivery_mode, destination_x2apic_id)
ax_x2apic_icr:
    and edi, 0xFF
    and esi, 7
    mov eax, edi
    shl rsi, 8
    or rax, rsi
    shl rdx, 32
    or rax, rdx
    ret

; int64_t ax_smp_pick_cpu(loads, count, affinity_mask)
ax_smp_pick_cpu:
    mov rax, -1
    test esi, esi
    jz .smp_done
    cmp esi, 64
    jbe .smp_count_ok
    mov esi, 64
.smp_count_ok:
    xor r8d, r8d
    mov r9d, 0xFFFFFFFF
.smp_loop:
    bt rdx, r8
    jnc .smp_next
    mov r10d, [rdi + r8*4]
    cmp r10d, r9d
    jae .smp_next
    mov r9d, r10d
    mov rax, r8
.smp_next:
    inc r8
    cmp r8d, esi
    jb .smp_loop
.smp_done:
    ret

; int64_t ax_numa_pick_node(distance_array, count, allowed_mask)
ax_numa_pick_node:
    mov rax, -1
    test esi, esi
    jz .numa_done
    cmp esi, 64
    jbe .numa_count_ok
    mov esi, 64
.numa_count_ok:
    xor r8d, r8d
    mov r9d, 0xFFFFFFFF
.numa_loop:
    bt rdx, r8
    jnc .numa_next
    movzx r10d, word [rdi + r8*2]
    cmp r10d, r9d
    jae .numa_next
    mov r9d, r10d
    mov rax, r8
.numa_next:
    inc r8
    cmp r8d, esi
    jb .numa_loop
.numa_done:
    ret

; int64_t ax_hotplug_transition(state, event)
; states: 0 offline, 1 starting, 2 online, 3 dying, 4 failed
; events: 0 start, 1 online-ack, 2 stop, 3 offline-ack, 4 fail, 5 recover
ax_hotplug_transition:
    mov rax, -1
    cmp edi, 4
    ja .hot_done
    cmp esi, 5
    ja .hot_done
    cmp edi, 0
    jne .hot_starting
    cmp esi, 0
    jne .hot_done
    mov eax, 1
    ret
.hot_starting:
    cmp edi, 1
    jne .hot_online
    cmp esi, 1
    je .hot_to_online
    cmp esi, 4
    je .hot_to_failed
    ret
.hot_online:
    cmp edi, 2
    jne .hot_dying
    cmp esi, 2
    je .hot_to_dying
    cmp esi, 4
    je .hot_to_failed
    ret
.hot_dying:
    cmp edi, 3
    jne .hot_failed
    cmp esi, 3
    je .hot_to_offline
    cmp esi, 4
    je .hot_to_failed
    ret
.hot_failed:
    cmp esi, 5
    jne .hot_done
.hot_to_offline:
    xor eax, eax
    ret
.hot_to_online:
    mov eax, 2
    ret
.hot_to_dying:
    mov eax, 3
    ret
.hot_to_failed:
    mov eax, 4
.hot_done:
    ret

; void ax_vtd_context(out[2], second_level_root, domain_id, address_width)
; Encodes a present, translated VT-d context descriptor model.
ax_vtd_context:
    mov rax, rsi
    and rax, -4096
    or rax, 1
    mov [rdi], rax
    movzx eax, dx
    shl rax, 8
    and ecx, 7
    or rax, rcx
    mov [rdi + 8], rax
    ret

; int ax_dma_window_contains(base, size, address, length)
ax_dma_window_contains:
    test rcx, rcx
    jz .dma_no
    mov r8, rdx
    add r8, rcx
    jc .dma_no
    mov r9, rdi
    add r9, rsi
    jc .dma_no
    cmp rdx, rdi
    jb .dma_no
    cmp r8, r9
    ja .dma_no
    mov eax, 1
    ret
.dma_no:
    xor eax, eax
    ret

; uint64_t ax_pcie_ecam_address(base,bus,device,function,register)
ax_pcie_ecam_address:
    mov rax, rdi
    and esi, 0xFF
    shl rsi, 20
    add rax, rsi
    and edx, 0x1F
    shl rdx, 15
    add rax, rdx
    and ecx, 7
    shl rcx, 12
    add rax, rcx
    and r8d, 0xFFF
    add rax, r8
    ret

; void ax_nvme_identify(cmd64, nsid, prp1, cns)
ax_nvme_identify:
    mov r8d, esi
    mov r9, rdx
    mov r10d, ecx
    mov r11, rdi
    xor eax, eax
    mov ecx, 8
    rep stosq
    mov byte [r11], 0x06
    mov dword [r11 + 4], r8d
    mov qword [r11 + 24], r9
    and r10d, 0xFF
    mov dword [r11 + 40], r10d
    ret

; uint64_t ax_nvme_sq_advance(tail, depth)
ax_nvme_sq_advance:
    test rsi, rsi
    jz .nvme_bad
    lea rax, [rdi + 1]
    cmp rax, rsi
    jb .nvme_done
    xor eax, eax
.nvme_done:
    ret
.nvme_bad:
    mov rax, -1
    ret

; void ax_xhci_trb(trb16, pointer, transfer_len, trb_type, cycle)
ax_xhci_trb:
    mov [rdi], rsi
    and edx, 0x1FFFF
    mov [rdi + 8], edx
    and ecx, 0x3F
    shl ecx, 10
    and r8d, 1
    or ecx, r8d
    mov [rdi + 12], ecx
    ret

; void ax_usb_setup_packet(out8, request_type, request, value, index, length)
ax_usb_setup_packet:
    mov [rdi], sil
    mov [rdi + 1], dl
    mov [rdi + 2], cx
    mov [rdi + 4], r8w
    mov [rdi + 6], r9w
    ret

; void ax_virtio_desc(desc16, address, length, flags, next)
ax_virtio_desc:
    mov [rdi], rsi
    mov [rdi + 8], edx
    mov [rdi + 12], cx
    mov [rdi + 14], r8w
    ret

; int ax_elf64_validate(buffer, length)
ax_elf64_validate:
    mov eax, -22
    cmp rsi, 64
    jb .elf_done
    cmp dword [rdi], 0x464C457F
    jne .elf_done
    cmp byte [rdi + 4], 2
    jne .elf_done
    cmp byte [rdi + 5], 1
    jne .elf_done
    cmp byte [rdi + 6], 1
    jne .elf_done
    movzx ecx, word [rdi + 16]
    cmp ecx, 2
    je .elf_type_ok
    cmp ecx, 3
    jne .elf_done
.elf_type_ok:
    cmp word [rdi + 18], 62
    jne .elf_done
    cmp dword [rdi + 20], 1
    jne .elf_done
    cmp word [rdi + 52], 64
    jne .elf_done
    cmp word [rdi + 54], 56
    jne .elf_done
    movzx r8d, word [rdi + 56]
    test r8d, r8d
    jz .elf_done
    imul r8, 56
    mov rcx, [rdi + 32]
    add rcx, r8
    jc .elf_done
    cmp rcx, rsi
    ja .elf_done
    xor eax, eax
.elf_done:
    ret

; int64_t ax_linux_syscall_map(linux_x86_64_nr)
; Maps a bounded compatibility ABI onto capability-confined internal services.
ax_linux_syscall_map:
    cmp rdi, 0
    je .linux_read
    cmp rdi, 1
    je .linux_write
    cmp rdi, 3
    je .linux_close
    cmp rdi, 9
    je .linux_mmap
    cmp rdi, 11
    je .linux_munmap
    cmp rdi, 39
    je .linux_getpid
    cmp rdi, 60
    je .linux_exit
    cmp rdi, 202
    je .linux_futex
    cmp rdi, 228
    je .linux_clock
    cmp rdi, 231
    je .linux_exit
    cmp rdi, 257
    je .linux_openat
    cmp rdi, 262
    je .linux_stat
    mov rax, -38
    ret
.linux_read:   mov eax, 1
    ret
.linux_write:  mov eax, 2
    ret
.linux_close:  mov eax, 3
    ret
.linux_mmap:   mov eax, 4
    ret
.linux_munmap: mov eax, 5
    ret
.linux_getpid: mov eax, 6
    ret
.linux_exit:   mov eax, 7
    ret
.linux_futex:  mov eax, 8
    ret
.linux_clock:  mov eax, 9
    ret
.linux_openat: mov eax, 10
    ret
.linux_stat:   mov eax, 11
    ret

; uint64_t ax_kaslr_choose(entropy, slots, alignment, base)
ax_kaslr_choose:
    mov r8, rdx
    mov r9, rcx
    test rsi, rsi
    jz .kaslr_base
    test r8, r8
    jz .kaslr_base
    mov rax, rdi
    xor edx, edx
    div rsi
    imul rdx, r8
    lea rax, [r9 + rdx]
    ret
.kaslr_base:
    mov rax, r9
    ret

; uint64_t ax_kpti_cr3(cpl, kernel_cr3, user_cr3)
ax_kpti_cr3:
    and edi, 3
    mov rax, rsi
    test edi, edi
    jz .kpti_done
    mov rax, rdx
.kpti_done:
    ret

; uint64_t ax_cet_policy(supported, requested)
ax_cet_policy:
    mov rax, rdi
    and rax, rsi
    and eax, 3                       ; bit0 SHSTK, bit1 IBT
    ret

; int64_t ax_mpk_mask(protection_key)
ax_mpk_mask:
    cmp rdi, 16
    jae .mpk_bad
    lea ecx, [rdi + rdi]
    mov eax, 3
    shl rax, cl
    ret
.mpk_bad:
    mov rax, -1
    ret

; uint64_t ax_page_table_entry(physical, flags, nx_boolean)
ax_page_table_entry:
    mov rax, rdi
    mov rcx, 0x000FFFFFFFFFF000
    and rax, rcx
    and esi, 0xFFF
    or rax, rsi
    test rdx, rdx
    jz .pte_done
    bts rax, 63
.pte_done:
    ret

; uint64_t ax_fat32_next(raw_fat_entry), UINT64_MAX denotes end-of-chain.
ax_fat32_next:
    mov eax, edi
    and eax, 0x0FFFFFFF
    cmp eax, 0x0FFFFFF8
    jb .fat_done
    mov rax, -1
.fat_done:
    ret

; int ax_ext2_dirent_valid(record_len, name_len, remaining_block_bytes)
ax_ext2_dirent_valid:
    xor eax, eax
    cmp rdi, 8
    jb .ext_done
    test dil, 3
    jnz .ext_done
    cmp rdi, rdx
    ja .ext_done
    lea rcx, [rdi - 8]
    cmp rsi, rcx
    ja .ext_done
    mov eax, 1
.ext_done:
    ret

; uint16_t ax_ipv4_checksum(buffer, length)
ax_ipv4_checksum:
    xor eax, eax
.ip_loop:
    cmp rsi, 2
    jb .ip_odd
    movzx ecx, byte [rdi]
    shl ecx, 8
    movzx r8d, byte [rdi + 1]
    or ecx, r8d
    add rax, rcx
    add rdi, 2
    sub rsi, 2
    jmp .ip_loop
.ip_odd:
    test rsi, rsi
    jz .ip_fold
    movzx ecx, byte [rdi]
    shl ecx, 8
    add rax, rcx
.ip_fold:
    mov rcx, rax
    shr rcx, 16
    and eax, 0xFFFF
    add rax, rcx
    mov rcx, rax
    shr rcx, 16
    and eax, 0xFFFF
    add rax, rcx
    not eax
    and eax, 0xFFFF
    ret

; int ax_tcp_seq_before(a,b): RFC-style modulo-2^32 signed ordering.
ax_tcp_seq_before:
    mov eax, edi
    sub eax, esi
    shr eax, 31
    ret

; int ax_iommu_bdf_allowed(bdf, allowlist, count)
ax_iommu_bdf_allowed:
    xor eax, eax
    xor ecx, ecx
.iommu_loop:
    cmp rcx, rdx
    jae .iommu_done
    cmp di, [rsi + rcx*2]
    je .iommu_yes
    inc rcx
    jmp .iommu_loop
.iommu_yes:
    mov eax, 1
.iommu_done:
    ret

; uint64_t ax_framebuffer_offset(x,y,pixels_per_scanline,bytes_per_pixel)
ax_framebuffer_offset:
    mov rax, rsi
    imul rax, rdx
    add rax, rdi
    imul rax, rcx
    ret

; uint64_t ax_ring_advance(index,count), UINT64_MAX for an invalid zero ring.
ax_ring_advance:
    test rsi, rsi
    jz .ring_bad
    lea rax, [rdi + 1]
    cmp rax, rsi
    jb .ring_done
    xor eax, eax
.ring_done:
    ret
.ring_bad:
    mov rax, -1
    ret

SECTION .note.GNU-stack noalloc noexec nowrite progbits
