#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_landlock_create_ruleset
#define SYS_landlock_create_ruleset 444
#define SYS_landlock_add_rule 445
#define SYS_landlock_restrict_self 446
#endif

static int install_seccomp(void) {
    struct sock_filter code[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, SYS_getppid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (EPERM & SECCOMP_RET_DATA)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {.len = (unsigned short)(sizeof(code) / sizeof(code[0])), .filter = code};
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
    if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0) return -1;
    errno = 0;
    long value = syscall(SYS_getppid);
    return value == -1 && errno == EPERM ? 0 : -1;
}

static int install_landlock(void) {
    int abi = (int)syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 1) return -1;

    struct landlock_ruleset_attr attr = {
        .handled_access_fs = LANDLOCK_ACCESS_FS_WRITE_FILE |
                             LANDLOCK_ACCESS_FS_REMOVE_FILE |
                             LANDLOCK_ACCESS_FS_MAKE_REG,
    };
    int fd = (int)syscall(SYS_landlock_create_ruleset, &attr, sizeof(attr), 0);
    if (fd < 0) return -1;
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) { close(fd); return -1; }
    if (syscall(SYS_landlock_restrict_self, fd, 0) != 0) { close(fd); return -1; }
    close(fd);

    errno = 0;
    int blocked = open("/tmp/axiom-landlock-blocked", O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (blocked >= 0) { close(blocked); unlink("/tmp/axiom-landlock-blocked"); return -1; }
    return errno == EACCES || errno == EPERM ? 0 : -1;
}

int main(void) {
    if (install_seccomp() != 0) {
        puts("SECCOMP-BPF: FAIL");
        return 1;
    }
    puts("SECCOMP-BPF: PASS");
    if (install_landlock() != 0) {
        puts("LANDLOCK: FAIL");
        return 1;
    }
    puts("LANDLOCK: PASS");
    puts("AXIOM-SECURITY-PROBE: PASS");
    return 0;
}
