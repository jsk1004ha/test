.intel_syntax noprefix
.global _start

.section .rodata
banner:
    .ascii "AXIOM-ASSEMBLY-PLANE: PASS\nCPU-VENDOR: "
.set banner_len, . - banner
newline:
    .byte 10

.section .text
_start:
    mov eax, 1
    mov edi, 1
    lea rsi, [rip + banner]
    mov edx, banner_len
    syscall

    sub rsp, 16
    xor eax, eax
    cpuid
    mov dword ptr [rsp + 0], ebx
    mov dword ptr [rsp + 4], edx
    mov dword ptr [rsp + 8], ecx
    mov byte ptr [rsp + 12], 10

    mov eax, 1
    mov edi, 1
    mov rsi, rsp
    mov edx, 13
    syscall
    add rsp, 16

    mov eax, 60
    xor edi, edi
    syscall

.section .note.GNU-stack,"",@progbits
