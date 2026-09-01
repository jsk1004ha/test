#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

int main(void) {
    struct utsname u;
    if (uname(&u) != 0) {
        fprintf(stderr, "uname failed: %s\n", strerror(errno));
        return 1;
    }
    printf("OCI-PID: %ld\n", (long)getpid());
    printf("OCI-HOSTNAME: %s\n", u.nodename);
    if (getpid() != 1 || strcmp(u.nodename, "axiom-sandbox") != 0) {
        puts("OCI-CONTAINER: FAIL");
        return 1;
    }
    puts("OCI-CONTAINER: PASS");
    return 0;
}
