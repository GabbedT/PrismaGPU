OUTPUT_ARCH(riscv)
ENTRY(_start)

/* Keep RV64 newlib's medlow addresses below 2 GiB. */
MEMORY {
    RAM (rwx) : ORIGIN = 0x10000000, LENGTH = 16M
}

SECTIONS {
    .text : {
        KEEP(*(.text.init))
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.*)
    } > RAM

    .data : {
        *(.data .data.*)
    } > RAM

    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(8);
        _bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(8);
        _bss_end = .;
    } > RAM

    _end = .;
    _heap_limit = ORIGIN(RAM) + LENGTH(RAM) - 65536;
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
