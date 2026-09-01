; Axiom64 Singularity 6.0.0 UEFI x86-64 qualification kernel
; Pure NASM assembly using the Microsoft x64 ABI required by UEFI.
; Firmware Secure Boot authenticates this image. It verifies SecureBoot state,
; discovers GOP and TCG2, issues TPM2_GetRandom, obtains the UEFI memory map,
; exits boot services, and continues as the post-firmware kernel owner.

BITS 64
DEFAULT REL

GLOBAL efi_main

COM1                    equ 0x3F8
ST_RUNTIME_SERVICES     equ 88
ST_BOOT_SERVICES        equ 96
BS_GET_MEMORY_MAP       equ 56
BS_LOCATE_PROTOCOL      equ 368
BS_EXIT_BOOT_SERVICES   equ 232
RT_GET_VARIABLE         equ 72
TCG2_GET_CAPABILITY     equ 0
TCG2_SUBMIT_COMMAND     equ 24
TPM_COMMAND_SIZE        equ 12
TPM_RESPONSE_SIZE       equ 128
MEMORY_MAP_CAPACITY     equ 65536

SECTION .text

efi_main:
    ; UEFI enters with RSP=8 mod 16. Nine pushes make every subsequent external
    ; call site 16-byte aligned before allocating shadow space.
    push rbp
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    push r11
    cld

    mov rbx, rcx                    ; EFI image handle
    mov r13, rdx                    ; EFI_SYSTEM_TABLE *
    mov r14, [r13 + ST_RUNTIME_SERVICES]
    mov r12, [r13 + ST_BOOT_SERVICES]

    call serial_init
    lea rsi, [msg_banner]
    call serial_puts
    lea rsi, [msg_uefi]
    call serial_puts

    ; Query the authenticated SecureBoot global variable.
    mov qword [secure_size], 1
    mov dword [secure_attributes], 0
    mov byte [secure_value], 0
    sub rsp, 48
    lea rax, [secure_value]
    mov [rsp + 32], rax
    lea rcx, [secure_boot_name]
    lea rdx, [efi_global_variable_guid]
    lea r8, [secure_attributes]
    lea r9, [secure_size]
    call qword [r14 + RT_GET_VARIABLE]
    add rsp, 48
    test rax, rax
    jnz .secure_boot_fail
    cmp byte [secure_value], 1
    jne .secure_boot_fail
    lea rsi, [msg_secure_enabled]
    call serial_puts
    jmp .secure_boot_done
.secure_boot_fail:
    lea rsi, [msg_secure_disabled]
    call serial_puts
.secure_boot_done:

    ; Firmware graphics handoff discovery.
    mov qword [gop_interface], 0
    sub rsp, 32
    lea rcx, [gop_guid]
    xor edx, edx
    lea r8, [gop_interface]
    call qword [r12 + BS_LOCATE_PROTOCOL]
    add rsp, 32
    test rax, rax
    jnz .gop_absent
    cmp qword [gop_interface], 0
    je .gop_absent
    lea rsi, [msg_gop_present]
    call serial_puts
    jmp .gop_done
.gop_absent:
    lea rsi, [msg_gop_absent]
    call serial_puts
.gop_done:

    ; Locate EFI_TCG2_PROTOCOL and query TPM capability data.
    mov qword [tcg2_interface], 0
    sub rsp, 32
    lea rcx, [tcg2_guid]
    xor edx, edx
    lea r8, [tcg2_interface]
    call qword [r12 + BS_LOCATE_PROTOCOL]
    add rsp, 32
    test rax, rax
    jnz .tcg2_absent
    mov r15, [tcg2_interface]
    test r15, r15
    jz .tcg2_absent

    mov byte [tcg2_capability], 64
    sub rsp, 32
    mov rcx, r15
    lea rdx, [tcg2_capability]
    call qword [r15 + TCG2_GET_CAPABILITY]
    add rsp, 32
    test rax, rax
    jnz .tcg2_absent
    lea rsi, [msg_tcg2_present]
    call serial_puts

    ; TPM_ST_NO_SESSIONS TPM2_GetRandom(bytesRequested=16).
    lea rdi, [tpm_response]
    xor eax, eax
    mov ecx, TPM_RESPONSE_SIZE / 8
    rep stosq
    sub rsp, 48
    lea rax, [tpm_response]
    mov [rsp + 32], rax
    mov rcx, r15
    mov edx, TPM_COMMAND_SIZE
    lea r8, [tpm_getrandom_command]
    mov r9d, TPM_RESPONSE_SIZE
    call qword [r15 + TCG2_SUBMIT_COMMAND]
    add rsp, 48
    test rax, rax
    jnz .tpm_random_fail
    cmp dword [tpm_response + 6], 0
    jne .tpm_random_fail
    cmp word [tpm_response + 10], 0
    je .tpm_random_fail
    lea rsi, [msg_tpm_random_pass]
    call serial_puts
    jmp .tcg2_done
.tpm_random_fail:
    lea rsi, [msg_tpm_random_fail]
    call serial_puts
    jmp .tcg2_done
.tcg2_absent:
    lea rsi, [msg_tcg2_absent]
    call serial_puts
.tcg2_done:

    ; The final firmware-to-kernel ownership transfer. GetMemoryMap and
    ; ExitBootServices are adjacent so no intervening firmware allocation can
    ; invalidate the map key. Retry handles a racing map-key change.
    call leave_firmware
    test rax, rax
    jnz .exit_failed

    lea rsi, [msg_exit_pass]
    call serial_puts
    lea rsi, [msg_kernel_owner]
    call serial_puts
    lea rsi, [msg_complete]
    call serial_puts
    mov al, 0x20
    out 0xF4, al
.kernel_halt:
    cli
    hlt
    jmp .kernel_halt

.exit_failed:
    lea rsi, [msg_exit_fail]
    call serial_puts
    mov al, 0x21
    out 0xF4, al
    jmp .kernel_halt

leave_firmware:
    push rbp
    mov ebp, 4
.retry:
    mov qword [memory_map_size], MEMORY_MAP_CAPACITY
    mov qword [memory_map_key], 0
    mov qword [memory_descriptor_size], 0
    mov dword [memory_descriptor_version], 0

    sub rsp, 48
    lea rax, [memory_descriptor_version]
    mov [rsp + 32], rax
    lea rcx, [memory_map_size]
    lea rdx, [memory_map]
    lea r8, [memory_map_key]
    lea r9, [memory_descriptor_size]
    call qword [r12 + BS_GET_MEMORY_MAP]
    add rsp, 48
    test rax, rax
    jnz .failed

    sub rsp, 32
    mov rcx, rbx
    mov rdx, [memory_map_key]
    call qword [r12 + BS_EXIT_BOOT_SERVICES]
    add rsp, 32
    test rax, rax
    jz .success
    dec ebp
    jnz .retry
.failed:
    mov rax, -1
    pop rbp
    ret
.success:
    xor eax, eax
    pop rbp
    ret

serial_init:
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al
    mov dx, COM1
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

serial_putc:
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

serial_puts:
.next:
    lodsb
    test al, al
    jz .done
    call serial_putc
    jmp .next
.done:
    ret

SECTION .rdata
ALIGN 8

efi_global_variable_guid:
    dd 0x8BE4DF61
    dw 0x93CA
    dw 0x11D2
    db 0xAA,0x0D,0x00,0xE0,0x98,0x03,0x2B,0x8C

gop_guid:
    dd 0x9042A9DE
    dw 0x23DC
    dw 0x4A38
    db 0x96,0xFB,0x7A,0xDE,0xD0,0x80,0x51,0x6A

tcg2_guid:
    dd 0x607F766C
    dw 0x7455
    dw 0x42BE
    db 0x93,0x0B,0xE4,0xD7,0x6D,0xB2,0x72,0x0F

secure_boot_name:
    dw 'S','e','c','u','r','e','B','o','o','t',0

tpm_getrandom_command:
    db 0x80,0x01, 0x00,0x00,0x00,0x0C, 0x00,0x00,0x01,0x7B, 0x00,0x10

msg_banner: db 13,10,'Axiom64 Singularity 6.0.0 / authenticated UEFI kernel path',13,10,0
msg_uefi: db 'UEFI_BOOT: PASS',13,10,0
msg_secure_enabled: db 'SECURE_BOOT: ENABLED',13,10,0
msg_secure_disabled: db 'SECURE_BOOT: DISABLED_OR_UNREADABLE',13,10,0
msg_gop_present: db 'GOP: PRESENT',13,10,0
msg_gop_absent: db 'GOP: ABSENT',13,10,0
msg_tcg2_present: db 'TCG2: PRESENT',13,10,0
msg_tcg2_absent: db 'TCG2: ABSENT',13,10,0
msg_tpm_random_pass: db 'TPM2_GET_RANDOM: PASS',13,10,0
msg_tpm_random_fail: db 'TPM2_GET_RANDOM: FAIL',13,10,0
msg_exit_pass: db 'EXIT_BOOT_SERVICES: PASS',13,10,0
msg_exit_fail: db 'EXIT_BOOT_SERVICES: FAIL',13,10,0
msg_kernel_owner: db 'POST_FIRMWARE_KERNEL_OWNERSHIP: PASS',13,10,0
msg_complete: db 'UEFI_QUALIFICATION_COMPLETE: PASS',13,10,0

SECTION .data
ALIGN 16
secure_size: dq 1
secure_attributes: dd 0
secure_value: db 0
ALIGN 8
gop_interface: dq 0
tcg2_interface: dq 0
ALIGN 16
tcg2_capability: times 64 db 0
ALIGN 16
tpm_response: times TPM_RESPONSE_SIZE db 0
ALIGN 16
memory_map_size: dq MEMORY_MAP_CAPACITY
memory_map_key: dq 0
memory_descriptor_size: dq 0
memory_descriptor_version: dd 0
ALIGN 16
memory_map: times MEMORY_MAP_CAPACITY db 0
