#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <linux/io_uring.h>
#include <linux/openat2.h>
#include <linux/memfd.h>
#include <linux/mman.h>
#include <linux/sched.h>
#include <linux/types.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_clone3
#define SYS_clone3 435
#endif
#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#ifndef SYS_io_uring_setup
#define SYS_io_uring_setup 425
#endif
#ifndef SYS_memfd_secret
#define SYS_memfd_secret 447
#endif
#ifndef SYS_mseal
#define SYS_mseal 462
#endif

static int failures;

static void pass(const char *name) { printf("%s: PASS\n", name); }
static void fail(const char *name, const char *why) {
    printf("%s: FAIL — %s (errno=%d %s)\n", name, why, errno, strerror(errno));
    failures++;
}

static int test_pidfd(void) {
    int fd = (int)syscall(SYS_pidfd_open, getpid(), 0);
    if (fd < 0) { fail("PIDFD", "pidfd_open"); return -1; }
    if (syscall(SYS_pidfd_send_signal, fd, 0, NULL, 0) != 0) {
        fail("PIDFD", "pidfd_send_signal"); close(fd); return -1;
    }
    close(fd); pass("PIDFD"); return 0;
}

static int test_openat2(void) {
    const char *base = "/tmp/axiom-openat2";
    (void)mkdir(base, 0700);
    int dir = open(base, O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) { fail("OPENAT2", "open base"); return -1; }
    int seed = openat(dir, "inside", O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (seed < 0) { fail("OPENAT2", "create seed"); close(dir); return -1; }
    (void)write(seed, "axiom", 5); close(seed);
    struct open_how how = { .flags = O_RDONLY | O_CLOEXEC, .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS };
    int ok = (int)syscall(SYS_openat2, dir, "inside", &how, sizeof(how));
    if (ok < 0) { fail("OPENAT2", "safe resolution"); close(dir); return -1; }
    close(ok);
    errno = 0;
    int bad = (int)syscall(SYS_openat2, dir, "../etc/passwd", &how, sizeof(how));
    if (bad >= 0) { close(bad); errno = EACCES; fail("OPENAT2", "escape accepted"); close(dir); return -1; }
    close(dir); pass("OPENAT2"); return 0;
}

static int test_io_uring(void) {
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    int fd = (int)syscall(SYS_io_uring_setup, 8, &p);
    if (fd < 0) { fail("IO-URING", "io_uring_setup"); return -1; }
    if (p.sq_entries == 0 || p.cq_entries == 0) {
        errno = EPROTO; fail("IO-URING", "invalid rings"); close(fd); return -1;
    }
    close(fd); pass("IO-URING"); return 0;
}

static int test_clone3(void) {
    struct clone_args args;
    memset(&args, 0, sizeof(args));
    args.flags = CLONE_PIDFD;
    args.exit_signal = SIGCHLD;
    int pidfd = -1;
    args.pidfd = (uintptr_t)&pidfd;
    pid_t pid = (pid_t)syscall(SYS_clone3, &args, sizeof(args));
    if (pid < 0) { fail("CLONE3", "clone3"); return -1; }
    if (pid == 0) _exit(37);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 37 || pidfd < 0) {
        errno = ECHILD; fail("CLONE3", "child lifecycle"); if (pidfd >= 0) close(pidfd); return -1;
    }
    close(pidfd); pass("CLONE3"); return 0;
}

static int test_memfd_secret(void) {
    int fd = (int)syscall(SYS_memfd_secret, 0);
    if (fd < 0) { fail("MEMFD-SECRET", "memfd_secret"); return -1; }
    if (ftruncate(fd, 4096) != 0) { fail("MEMFD-SECRET", "ftruncate"); close(fd); return -1; }
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { fail("MEMFD-SECRET", "mmap"); close(fd); return -1; }
    memcpy(p, "axiom-secret", 13);
    if (memcmp(p, "axiom-secret", 13) != 0) { errno = EIO; fail("MEMFD-SECRET", "readback"); }
    else pass("MEMFD-SECRET");
    munmap(p, 4096); close(fd); return 0;
}

static int test_mseal(void) {
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { fail("MSEAL", "mmap"); return -1; }
    if (syscall(SYS_mseal, p, 4096, 0) != 0) { fail("MSEAL", "mseal"); munmap(p, 4096); return -1; }
    errno = 0;
    if (munmap(p, 4096) == 0) { errno = EPERM; fail("MSEAL", "sealed mapping unmapped"); return -1; }
    pass("MSEAL"); return 0;
}

static int bpf_sys(enum bpf_cmd cmd, union bpf_attr *attr) {
    return (int)syscall(SYS_bpf, cmd, attr, sizeof(*attr));
}

static int test_ebpf(void) {
    struct rlimit rl = { RLIM_INFINITY, RLIM_INFINITY };
    (void)setrlimit(RLIMIT_MEMLOCK, &rl);
    union bpf_attr a;
    memset(&a, 0, sizeof(a));
    a.map_type = BPF_MAP_TYPE_ARRAY;
    a.key_size = sizeof(uint32_t);
    a.value_size = sizeof(uint64_t);
    a.max_entries = 4;
    int map = bpf_sys(BPF_MAP_CREATE, &a);
    if (map < 0) { fail("EBPF-MAP", "BPF_MAP_CREATE"); return -1; }
    uint32_t key = 2;
    uint64_t value = 0x4158494f4d3634ULL, out = 0;
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map; a.key = (uintptr_t)&key; a.value = (uintptr_t)&value; a.flags = BPF_ANY;
    if (bpf_sys(BPF_MAP_UPDATE_ELEM, &a) != 0) { fail("EBPF-MAP", "update"); close(map); return -1; }
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map; a.key = (uintptr_t)&key; a.value = (uintptr_t)&out;
    if (bpf_sys(BPF_MAP_LOOKUP_ELEM, &a) != 0 || out != value) {
        errno = EIO; fail("EBPF-MAP", "lookup"); close(map); return -1;
    }
    close(map); pass("EBPF-MAP"); return 0;
}

int main(void) {
    test_pidfd();
    test_openat2();
    test_io_uring();
    test_clone3();
    test_memfd_secret();
    test_mseal();
    test_ebpf();
    if (failures) {
        printf("AXIOM-ADVANCED-ABI: FAIL failures=%d\n", failures);
        return 1;
    }
    puts("AXIOM-ADVANCED-ABI: PASS");
    return 0;
}
