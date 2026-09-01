#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/bpf.h>
#include <linux/io_uring.h>
#include <linux/memfd.h>
#include <linux/openat2.h>
#include <linux/sched.h>
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

#ifndef SYS_memfd_create
#define SYS_memfd_create 319
#endif
#ifndef SYS_bpf
#define SYS_bpf 321
#endif
#ifndef SYS_io_uring_setup
#define SYS_io_uring_setup 425
#endif
#ifndef SYS_io_uring_enter
#define SYS_io_uring_enter 426
#endif
#ifndef SYS_pidfd_send_signal
#define SYS_pidfd_send_signal 424
#endif
#ifndef SYS_pidfd_open
#define SYS_pidfd_open 434
#endif
#ifndef SYS_clone3
#define SYS_clone3 435
#endif
#ifndef SYS_openat2
#define SYS_openat2 437
#endif
#ifndef SYS_memfd_secret
#define SYS_memfd_secret 447
#endif
#ifndef SYS_mseal
#define SYS_mseal 462
#endif
#ifndef MFD_ALLOW_SEALING
#define MFD_ALLOW_SEALING 0x0002U
#endif
#ifndef F_ADD_SEALS
#define F_ADD_SEALS 1033
#define F_GET_SEALS 1034
#endif
#ifndef F_SEAL_SEAL
#define F_SEAL_SEAL 0x0001
#define F_SEAL_SHRINK 0x0002
#define F_SEAL_GROW 0x0004
#define F_SEAL_WRITE 0x0008
#endif

static int failures;

static void pass(const char *name) { printf("%s: PASS\n", name); }
static void fail(const char *name, const char *why) {
    printf("%s: FAIL — %s (errno=%d %s)\n", name, why, errno, strerror(errno));
    failures++;
}

static void test_pidfd(void) {
    int fd = (int)syscall(SYS_pidfd_open, getpid(), 0);
    if (fd < 0) { fail("PIDFD", "pidfd_open"); return; }
    if (syscall(SYS_pidfd_send_signal, fd, 0, NULL, 0) != 0) {
        fail("PIDFD", "pidfd_send_signal"); close(fd); return;
    }
    close(fd);
    pass("PIDFD");
}

static void test_openat2(void) {
    const char *base = "/tmp/axiom-openat2";
    (void)mkdir(base, 0700);
    int dir = open(base, O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (dir < 0) { fail("OPENAT2", "open base"); return; }
    int seed = openat(dir, "inside", O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0600);
    if (seed < 0) { fail("OPENAT2", "create seed"); close(dir); return; }
    if (write(seed, "axiom", 5) != 5) { fail("OPENAT2", "write seed"); close(seed); close(dir); return; }
    close(seed);

    struct open_how how = {
        .flags = O_RDONLY | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | RESOLVE_NO_SYMLINKS,
    };
    int ok = (int)syscall(SYS_openat2, dir, "inside", &how, sizeof(how));
    if (ok < 0) { fail("OPENAT2", "safe resolution"); close(dir); return; }
    close(ok);

    errno = 0;
    int bad = (int)syscall(SYS_openat2, dir, "../etc/passwd", &how, sizeof(how));
    if (bad >= 0) {
        close(bad); errno = EACCES; fail("OPENAT2", "RESOLVE_BENEATH escape accepted"); close(dir); return;
    }
    close(dir);
    pass("OPENAT2");
}

static void test_io_uring(void) {
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));
    int fd = (int)syscall(SYS_io_uring_setup, 8, &p);
    if (fd < 0) { fail("IO-URING", "io_uring_setup"); return; }

    size_t sq_size = p.sq_off.array + p.sq_entries * sizeof(uint32_t);
    size_t cq_size = p.cq_off.cqes + p.cq_entries * sizeof(struct io_uring_cqe);
    size_t ring_size = sq_size > cq_size ? sq_size : cq_size;
    void *sq_ring = mmap(NULL, (p.features & IORING_FEAT_SINGLE_MMAP) ? ring_size : sq_size,
                         PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                         fd, IORING_OFF_SQ_RING);
    if (sq_ring == MAP_FAILED) { fail("IO-URING", "map SQ ring"); close(fd); return; }
    void *cq_ring = sq_ring;
    if (!(p.features & IORING_FEAT_SINGLE_MMAP)) {
        cq_ring = mmap(NULL, cq_size, PROT_READ | PROT_WRITE,
                       MAP_SHARED | MAP_POPULATE, fd, IORING_OFF_CQ_RING);
        if (cq_ring == MAP_FAILED) {
            fail("IO-URING", "map CQ ring");
            munmap(sq_ring, sq_size); close(fd); return;
        }
    }
    struct io_uring_sqe *sqes = mmap(NULL, p.sq_entries * sizeof(*sqes),
                                     PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE,
                                     fd, IORING_OFF_SQES);
    if (sqes == MAP_FAILED) {
        fail("IO-URING", "map SQEs");
        if (cq_ring != sq_ring) munmap(cq_ring, cq_size);
        munmap(sq_ring, (p.features & IORING_FEAT_SINGLE_MMAP) ? ring_size : sq_size);
        close(fd); return;
    }

    uint32_t *sq_tail = (uint32_t *)((char *)sq_ring + p.sq_off.tail);
    uint32_t *sq_mask = (uint32_t *)((char *)sq_ring + p.sq_off.ring_mask);
    uint32_t *sq_array = (uint32_t *)((char *)sq_ring + p.sq_off.array);
    uint32_t tail = __atomic_load_n(sq_tail, __ATOMIC_RELAXED);
    uint32_t index = tail & *sq_mask;
    memset(&sqes[index], 0, sizeof(sqes[index]));
    sqes[index].opcode = IORING_OP_NOP;
    sqes[index].user_data = UINT64_C(0x4158494f4d3634);
    sq_array[index] = index;
    __atomic_store_n(sq_tail, tail + 1, __ATOMIC_RELEASE);

    long entered = syscall(SYS_io_uring_enter, fd, 1, 1,
                           IORING_ENTER_GETEVENTS, NULL, 0);
    uint32_t *cq_head = (uint32_t *)((char *)cq_ring + p.cq_off.head);
    uint32_t *cq_tail = (uint32_t *)((char *)cq_ring + p.cq_off.tail);
    uint32_t *cq_mask = (uint32_t *)((char *)cq_ring + p.cq_off.ring_mask);
    struct io_uring_cqe *cqes = (struct io_uring_cqe *)((char *)cq_ring + p.cq_off.cqes);
    uint32_t head = __atomic_load_n(cq_head, __ATOMIC_ACQUIRE);
    uint32_t completed = __atomic_load_n(cq_tail, __ATOMIC_ACQUIRE);
    if (entered < 1 || head == completed) {
        fail("IO-URING", "NOP completion absent");
    } else {
        struct io_uring_cqe cqe = cqes[head & *cq_mask];
        if (cqe.user_data != UINT64_C(0x4158494f4d3634) || cqe.res != 0) {
            errno = EPROTO; fail("IO-URING", "invalid completion");
        } else {
            __atomic_store_n(cq_head, head + 1, __ATOMIC_RELEASE);
            pass("IO-URING");
        }
    }

    munmap(sqes, p.sq_entries * sizeof(*sqes));
    if (cq_ring != sq_ring) munmap(cq_ring, cq_size);
    munmap(sq_ring, (p.features & IORING_FEAT_SINGLE_MMAP) ? ring_size : sq_size);
    close(fd);
}

static void test_clone3(void) {
    struct clone_args args;
    memset(&args, 0, sizeof(args));
    int pidfd = -1;
    args.flags = CLONE_PIDFD;
    args.pidfd = (uintptr_t)&pidfd;
    args.exit_signal = SIGCHLD;
    pid_t pid = (pid_t)syscall(SYS_clone3, &args, sizeof(args));
    if (pid < 0) { fail("CLONE3", "clone3"); return; }
    if (pid == 0) _exit(37);
    int status = 0;
    if (waitpid(pid, &status, 0) != pid || !WIFEXITED(status) ||
        WEXITSTATUS(status) != 37 || pidfd < 0) {
        errno = ECHILD; fail("CLONE3", "child lifecycle");
        if (pidfd >= 0) close(pidfd);
        return;
    }
    close(pidfd);
    pass("CLONE3");
}

static void test_memfd_secret(void) {
    int fd = (int)syscall(SYS_memfd_secret, 0);
    if (fd < 0) { fail("MEMFD-SECRET", "memfd_secret"); return; }
    if (ftruncate(fd, 4096) != 0) { fail("MEMFD-SECRET", "ftruncate"); close(fd); return; }
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) { fail("MEMFD-SECRET", "mmap"); close(fd); return; }
    memcpy(p, "axiom-secret", 13);
    if (memcmp(p, "axiom-secret", 13) != 0) {
        errno = EIO; fail("MEMFD-SECRET", "readback");
    } else {
        pass("MEMFD-SECRET");
    }
    munmap(p, 4096);
    close(fd);
}

static void test_memfd_seals(void) {
    int fd = (int)syscall(SYS_memfd_create, "axiom-sealed", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) { fail("MEMFD-SEALS", "memfd_create"); return; }
    if (write(fd, "immutable", 9) != 9) { fail("MEMFD-SEALS", "initial write"); close(fd); return; }
    int seals = F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
    if (fcntl(fd, F_ADD_SEALS, seals) != 0) { fail("MEMFD-SEALS", "F_ADD_SEALS"); close(fd); return; }
    errno = 0;
    if (pwrite(fd, "X", 1, 0) >= 0 || errno != EPERM) {
        errno = EPERM; fail("MEMFD-SEALS", "write after seal accepted"); close(fd); return;
    }
    if ((fcntl(fd, F_GET_SEALS) & seals) != seals) {
        errno = EPROTO; fail("MEMFD-SEALS", "seal set mismatch"); close(fd); return;
    }
    close(fd);
    pass("MEMFD-SEALS");
}

static void test_mseal(void) {
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) { fail("MSEAL", "mmap"); return; }
    if (syscall(SYS_mseal, p, 4096, 0) != 0) {
        fail("MSEAL", "mseal"); munmap(p, 4096); return;
    }
    errno = 0;
    if (mprotect(p, 4096, PROT_READ) == 0 || errno != EPERM) {
        errno = EPERM; fail("MSEAL", "mprotect after seal accepted"); return;
    }
    errno = 0;
    if (munmap(p, 4096) == 0 || errno != EPERM) {
        errno = EPERM; fail("MSEAL", "munmap after seal accepted"); return;
    }
    pass("MSEAL");
}

static int bpf_sys(enum bpf_cmd cmd, union bpf_attr *attr) {
    return (int)syscall(SYS_bpf, cmd, attr, sizeof(*attr));
}

static void test_ebpf(void) {
    struct rlimit rl = { RLIM_INFINITY, RLIM_INFINITY };
    (void)setrlimit(RLIMIT_MEMLOCK, &rl);
    union bpf_attr a;
    memset(&a, 0, sizeof(a));
    a.map_type = BPF_MAP_TYPE_ARRAY;
    a.key_size = sizeof(uint32_t);
    a.value_size = sizeof(uint64_t);
    a.max_entries = 4;
    int map = bpf_sys(BPF_MAP_CREATE, &a);
    if (map < 0) { fail("EBPF-MAP", "BPF_MAP_CREATE"); return; }

    uint32_t key = 2;
    uint64_t value = UINT64_C(0x004158494f4d3634), out = 0;
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map;
    a.key = (uintptr_t)&key;
    a.value = (uintptr_t)&value;
    a.flags = BPF_ANY;
    if (bpf_sys(BPF_MAP_UPDATE_ELEM, &a) != 0) {
        fail("EBPF-MAP", "update"); close(map); return;
    }
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map;
    a.key = (uintptr_t)&key;
    a.value = (uintptr_t)&out;
    if (bpf_sys(BPF_MAP_LOOKUP_ELEM, &a) != 0 || out != value) {
        errno = EIO; fail("EBPF-MAP", "lookup"); close(map); return;
    }
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map;
    if (bpf_sys(BPF_MAP_FREEZE, &a) != 0) {
        fail("EBPF-MAP", "freeze"); close(map); return;
    }
    value++;
    memset(&a, 0, sizeof(a));
    a.map_fd = (uint32_t)map;
    a.key = (uintptr_t)&key;
    a.value = (uintptr_t)&value;
    a.flags = BPF_ANY;
    errno = 0;
    if (bpf_sys(BPF_MAP_UPDATE_ELEM, &a) == 0 || errno != EPERM) {
        errno = EPERM; fail("EBPF-MAP", "frozen map accepted update"); close(map); return;
    }
    close(map);
    pass("EBPF-MAP");
}

int main(void) {
    test_pidfd();
    test_openat2();
    test_io_uring();
    test_clone3();
    test_memfd_secret();
    test_memfd_seals();
    test_mseal();
    test_ebpf();
    if (failures) {
        printf("AXIOM-ADVANCED-ABI: FAIL failures=%d\n", failures);
        return 1;
    }
    puts("AXIOM-ADVANCED-ABI: PASS");
    return 0;
}
