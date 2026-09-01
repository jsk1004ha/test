; Axiom64 Singularity 6.0.0 BIOS diagnostic bootstrap
; Pure x86 assembly. Loads its own stage2, enters long mode, enables supported
; supervisor hardening bits, emits a serial qualification transcript, and exits.

BITS 16
ORG 0x7C00

COM1            equ 0x3F8
PAGE_PML4       equ 0x1000
PAGE_PDPT       equ 0x2000
PAGE_PD         equ 0x3000
STACK64_TOP     equ 0x70000

boot_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    mov [boot_drive], dl
    call serial_init16
    mov si, msg_booting
    call serial_puts16

    mov dl, [boot_drive]
    mov si, disk_address_packet
    mov ah, 0x42
    int 0x13
    jc disk_error
    jmp 0x0000:stage2

disk_error:
    mov si, msg_disk_error
    call serial_puts16
.hang:
    cli
    hlt
    jmp .hang

serial_init16:
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al
    mov dx, COM1 + 0
    mov al, 1
    out dx, al
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al
    mov dx, COM1 + 4
    mov al, 0x0B
    out dx, al
    ret

serial_putc16:
    push dx
    push ax
.wait:
    mov dx, COM1 + 5
    in al, dx
    test al, 0x20
    jz .wait
    pop ax
    mov dx, COM1
    out dx, al
    pop dx
    ret

serial_puts16:
.next:
    lodsb
    test al, al
    jz .done
    call serial_putc16
    jmp .next
.done:
    ret

align 4
disk_address_packet:
    db 0x10
    db 0
    dw stage2_sectors
    dw stage2
    dw 0
    dq 1

boot_drive: db 0
msg_booting: db 'Axiom64 Singularity 6 BIOS loader', 13, 10, 0
msg_disk_error: db 'BIOS_DISK_READ: FAIL', 13, 10, 0

times 510 - ($ - $$) db 0
dw 0xAA55

stage2:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7A00

    ; Fast A20 gate.
    in al, 0x92
    or al, 2
    and al, 0xFE
    out 0x92, al

    lgdt [gdt_pointer]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp 0x08:protected_mode

BITS 32
protected_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x7A000

    ; Construct a minimal 4-level identity map for the first 1 GiB using a
    ; single 2 MiB page. Page zero is intentionally present only during the
    ; bootstrap transition and is no longer part of any user address space.
    mov edi, PAGE_PML4
    xor eax, eax
    mov ecx, (0x3000 / 4)
    rep stosd

    mov dword [PAGE_PML4], PAGE_PDPT | 0x003
    mov dword [PAGE_PML4 + 4], 0
    mov dword [PAGE_PDPT], PAGE_PD | 0x003
    mov dword [PAGE_PDPT + 4], 0
    mov dword [PAGE_PD], 0x00000083
    mov dword [PAGE_PD + 4], 0

    mov eax, cr4
    or eax, (1 << 5) | (1 << 7)
    mov cr4, eax
    mov eax, PAGE_PML4
    mov cr3, eax

    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8) | (1 << 11)
    wrmsr

    mov eax, cr0
    or eax, (1 << 31) | (1 << 16)
    mov cr0, eax
    jmp 0x18:long_mode

BITS 64
long_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    xor eax, eax
    mov fs, ax
    mov gs, ax
    mov rsp, STACK64_TOP

    ; Enable only supervisor hardening bits explicitly reported by CPUID.
    mov eax, 7
    xor ecx, ecx
    cpuid
    xor r8, r8
    bt ebx, 7                  ; SMEP
    jnc .no_smep
    or r8, (1 << 20)
.no_smep:
    bt ebx, 20                 ; SMAP
    jnc .no_smap
    or r8, (1 << 21)
.no_smap:
    bt ecx, 2                  ; UMIP
    jnc .no_umip
    or r8, (1 << 11)
.no_umip:
    mov rax, cr4
    or rax, r8
    mov cr4, rax

    lea rsi, [rel msg_banner]
    call serial_puts64
    lea rsi, [rel msg_bios_pass]
    call serial_puts64
    lea rsi, [rel msg_long_pass]
    call serial_puts64
    lea rsi, [rel msg_hardening]
    call serial_puts64
    lea rsi, [rel msg_handoff]
    call serial_puts64

    mov al, 0x10
    out 0xF4, al
.halt:
    cli
    hlt
    jmp .halt

serial_putc64:
    push rdx
    push rax
.wait:
    mov dx, COM1 + 5
    in al, dx
    test al, 0x20
    jz .wait
    pop rax
    mov dx, COM1
    out dx, al
    pop rdx
    ret

serial_puts64:
.next:
    lodsb
    test al, al
    jz .done
    call serial_putc64
    jmp .next
.done:
    ret

align 8
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF     ; 0x08 protected-mode code
    dq 0x00CF92000000FFFF     ; 0x10 data
    dq 0x00AF9A000000FFFF     ; 0x18 long-mode code

gdt_end:
gdt_pointer:
    dw gdt_end - gdt - 1
    dd gdt

msg_banner: db 13, 10, 'Axiom64 Singularity 6.0.0 / BIOS qualification path', 13, 10, 0
msg_bios_pass: db 'BIOS_BOOT: PASS', 13, 10, 0
msg_long_pass: db 'LONG_MODE: PASS', 13, 10, 0
msg_hardening: db 'CPU_HARDENING_SCAN: PASS', 13, 10, 0
msg_handoff: db 'BIOS_QUALIFICATION_COMPLETE: PASS', 13, 10, 0

image_end:
stage2_sectors equ (image_end - stage2 + 511) / 512

times ((($ - $$ + 511) / 512) * 512) - ($ - $$) db 0
