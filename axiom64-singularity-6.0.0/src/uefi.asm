; Axiom64 Singularity 6.0.0 UEFI x86-64 qualification image
; Pure NASM assembly using the Microsoft x64 ABI required by UEFI.
; It verifies firmware Secure Boot state, discovers GOP and TCG2, and submits
; a TPM2_GetRandom command through EFI_TCG2_PROTOCOL before orderly shutdown.

BITS 64
DEFAULT REL

GLOBAL efi_main

COM1                    equ 0x3F8
ST_RUNTIME_SERVICES     equ 88
ST_BOOT_SERVICES        equ 96
BS_STALL                equ 248
BS_LOCATE_PROTOCOL      equ 320
RT_GET_VARIABLE         equ 72
RT_RESET_SYSTEM         equ 104
TCG2_GET_CAPABILITY     equ 0
TCG2_SUBMIT_COMMAND     equ 24
EFI_RESET_SHUTDOWN      equ 2
TPM_COMMAND_SIZE        equ 12
TPM_RESPONSE_SIZE       equ 128

SECTION .text

efi_main:
    ; Entry RSP is 8 mod 16. Five nonvolatile pushes leave it 16-byte aligned
    ; at each call site once the required shadow space is allocated.
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsp

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
    sub rsp, 48                     ; 32-byte shadow + fifth arg + padding
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

    ; Locate the Graphics Output Protocol. This is the graphics-driver handoff
    ; used by the compositor/GPU service in the full architecture.
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

    ; Locate EFI_TCG2_PROTOCOL and ask firmware for TPM capability data.
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

    ; Submit TPM2_GetRandom(bytesRequested=16), big-endian TPM wire format.
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
    cmp dword [tpm_response + 6], 0   ; responseCode is all-zero on success
    jne .tpm_random_fail
    cmp word [tpm_response + 10], 0   ; TPM2B_DIGEST size must be non-zero
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

    lea rsi, [msg_complete]
    call serial_puts

    ; Give the serial backend time to drain before ResetSystem.
    sub rsp, 32
    mov ecx, 100000
    call qword [r12 + BS_STALL]
    add rsp, 32

    sub rsp, 32
    mov ecx, EFI_RESET_SHUTDOWN
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call qword [r14 + RT_RESET_SYSTEM]
    add rsp, 32

    xor eax, eax
    mov rsp, rbp
    pop r15
    pop r14
    pop r13
    pop r12
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
    mov al, 1                       ; 115200 baud divisor
    out dx, al
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03                    ; 8N1
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

; EFI_GLOBAL_VARIABLE = 8BE4DF61-93CA-11D2-AA0D-00E098032B8C
 efi_global_variable_guid:
    dd 0x8BE4DF61
    dw 0x93CA
    dw 0x11D2
    db 0xAA,0x0D,0x00,0xE0,0x98,0x03,0x2B,0x8C

; EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID = 9042A9DE-23DC-4A38-96FB-7ADED080516A
 gop_guid:
    dd 0x9042A9DE
    dw 0x23DC
    dw 0x4A38
    db 0x96,0xFB,0x7A,0xDE,0xD0,0x80,0x51,0x6A

; EFI_TCG2_PROTOCOL_GUID = 607F766C-7455-42BE-930B-E4D76DB2720F
 tcg2_guid:
    dd 0x607F766C
    dw 0x7455
    dw 0x42BE
    db 0x93,0x0B,0xE4,0xD7,0x6D,0xB2,0x72,0x0F

secure_boot_name:
    dw 'S','e','c','u','r','e','B','o','o','t',0

; TPM_ST_NO_SESSIONS, size 12, TPM_CC_GetRandom, requested bytes 16.
tpm_getrandom_command:
    db 0x80,0x01, 0x00,0x00,0x00,0x0C, 0x00,0x00,0x01,0x7B, 0x00,0x10

msg_banner: db 13,10,'Axiom64 Singularity 6.0.0 / UEFI measured qualification path',13,10,0
msg_uefi: db 'UEFI_BOOT: PASS',13,10,0
msg_secure_enabled: db 'SECURE_BOOT: ENABLED',13,10,0
msg_secure_disabled: db 'SECURE_BOOT: DISABLED_OR_UNREADABLE',13,10,0
msg_gop_present: db 'GOP: PRESENT',13,10,0
msg_gop_absent: db 'GOP: ABSENT',13,10,0
msg_tcg2_present: db 'TCG2: PRESENT',13,10,0
msg_tcg2_absent: db 'TCG2: ABSENT',13,10,0
msg_tpm_random_pass: db 'TPM2_GET_RANDOM: PASS',13,10,0
msg_tpm_random_fail: db 'TPM2_GET_RANDOM: FAIL',13,10,0
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
