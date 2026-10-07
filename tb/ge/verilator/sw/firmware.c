#include "ge_test.h"

#include <sys/stat.h>
#include <errno.h>

void device_reset(unsigned stage) {
    *(volatile uint32_t *)(uintptr_t)(GE_HOST + 0x110) = stage;
}

void device_write(unsigned reg, uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)(GE_MMIO + reg * 4) = value;
}

uint32_t device_read(unsigned reg) {
    return *(volatile uint32_t *)(uintptr_t)(GE_MMIO + reg * 4);
}

void gpu_write(uint32_t address, const uint8_t *bytes, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        *(volatile uint8_t *)(uintptr_t)(GE_GPU + address + i) = bytes[i];
    }
}

void gpu_read(uint32_t address, uint8_t *bytes, size_t size) {
    for (size_t i = 0; i < size; ++i) {
        bytes[i] = *(volatile uint8_t *)(uintptr_t)(GE_GPU + address + i);
    }
}

void test_log(const char *p) {
    while (*p) {
        *(volatile uint8_t *)(uintptr_t)(GE_HOST + 0x100) = *p++;
    }
}

void test_phase(const char *p, unsigned index) {
    *(volatile uint32_t *)(uintptr_t)(GE_HOST + 0x108) = index;
    do {
        *(volatile uint8_t *)(uintptr_t)(GE_HOST + 0x10c) = *p;
    } while (*p++);
}

int main(void) {
    test_config cfg;
    for (size_t i = 0; i < sizeof(cfg); ++i) {
        ((uint8_t *)&cfg)[i] = *(volatile uint8_t *)(uintptr_t)(GE_HOST + i);
    }

    int result = run_test(&cfg);
    *(volatile uint32_t *)(uintptr_t)(GE_HOST + 0x104) = result;
    for (;;) {
        __asm__ volatile("nop");
    }
}

/* Newlib only needs these services for formatting; there is no host filesystem. */
int _write(int fd, const char *p, int n) {
    (void)fd;
    for (int i = 0; i < n; ++i) {
        *(volatile uint8_t *)(uintptr_t)(GE_HOST + 0x100) = p[i];
    }

    return n;
}

void *_sbrk(int increment) {
    extern char _end;
    extern char _heap_limit;
    static char *next;

    if (!next) {
        next = &_end;
    }

    if (increment < 0 || increment > &_heap_limit - next) {
        errno = ENOMEM;
        return (void *)-1;
    }

    char *old = next;
    next += increment;
    return old;
}

int _close(int fd) {
    (void)fd;
    return -1;
}

int _fstat(int fd, struct stat *s) {
    (void)fd;
    s->st_mode = S_IFCHR;
    return 0;
}

int _isatty(int fd) {
    (void)fd;
    return 1;
}

int _lseek(int fd, int offset, int whence) {
    (void)fd;
    (void)offset;
    (void)whence;
    return 0;
}

int _read(int fd, char *p, int n) {
    (void)fd;
    (void)p;
    (void)n;
    return 0;
}

int _getpid(void) {
    return 1;
}

int _kill(int pid, int signal) {
    (void)pid;
    (void)signal;
    return -1;
}

void _exit(int code) {
    *(volatile uint32_t *)(uintptr_t)(GE_HOST + 0x104) = code ? code : 1;
    for (;;) {
        __asm__ volatile("nop");
    }
}
