#include "gpu.h"
#include <sys/stat.h>
#include <errno.h>

void app_exit(int status) {
    host_write(0x104,(uint32_t)status);
    for (;;) __asm__ volatile("nop");
}
int _write(int fd, const char* p, int n) {
    (void)fd;
    for (int i=0; i<n; i++) *(volatile uint8_t*)(uintptr_t)(HOST_BASE+0x100)=(uint8_t)p[i];
    return n;
}
void* _sbrk(int increment) {
    extern char _end, _heap_limit;
    static char* next;
    if (!next) next=&_end;
    if (increment<0 || increment>&_heap_limit-next) { errno=ENOMEM; return (void*)-1; }
    char* old=next; next+=increment; return old;
}
int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat* s) { (void)fd; s->st_mode=S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd,int offset,int whence) { (void)fd;(void)offset;(void)whence;return 0; }
int _read(int fd,char* p,int n) { (void)fd;(void)p;(void)n;return 0; }
int _getpid(void) { return 1; }
int _kill(int pid,int signal) { (void)pid;(void)signal;return -1; }
void _exit(int status) { app_exit(status); }
