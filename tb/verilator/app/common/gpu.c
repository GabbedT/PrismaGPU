#include "gpu.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static unsigned screen_width = 320, screen_height = 240;
static unsigned ge_control = 0x100, re_control = 0x100;

void app_check(int condition, const char* message) {
    if (!condition) { printf("FAIL: %s\n", message); app_exit(1); }
}
app_config_t app_config(void) {
    return (app_config_t){host_read(0),host_read(4),host_read(8),host_read(12),host_read(16)};
}
uint32_t app_random(uint32_t* state) {
    *state = *state*1664525u+1013904223u; return *state;
}
void gpu_matrix(const float matrix[16]) {
    for (unsigned i=0; i<16; i++) reg_write(GE_MATRIX+4*i, (uint32_t)(int32_t)lroundf(matrix[i]*65536.0f));
}
void gpu_identity(void) {
    const float matrix[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    gpu_matrix(matrix);
}
void gpu_projection(float near, float far) {
    const float aspect = (float)screen_width/screen_height;
    const float matrix[16] = {1.6f/aspect,0,0,0, 0,1.6f,0,0, 0,0,far/(far-near),-near*far/(far-near), 0,0,1,0};
    gpu_matrix(matrix);
}
void gpu_init(unsigned width, int depth) {
    screen_width = width; screen_height = width*3/4;
    reg_write(GE_CTRL, ge_control|9);
    reg_write(RE_CTRL, re_control|9);
    while (reg_read(RE_STATUS)&1) {}
    gpu_identity();
    reg_write(GE_WIDTH, screen_width); reg_write(GE_HEIGHT, screen_height);
    reg_write(GE_PRIM_BASE, PRIM_BASE); reg_write(GE_PRIM_END, PRIM_LIMIT);
    reg_write(RE_VIEWPORT, width == 320);
    reg_write(RE_FB_BASE, FB_BASE); reg_write(RE_FB_END, FB_BASE+width*screen_height*3/2);
    reg_write(RE_Z_BASE, Z_BASE); reg_write(RE_Z_END, Z_BASE+width*screen_height*2);
    reg_write(RE_DRAW, depth ? 8 : 0); // Affine depth interpolation, flat color.
    reg_write(RE_Z_CFG, depth ? 7 : 0); // LESS, write, test.
}
void gpu_clear(uint16_t rgb, int depth) {
    /* Host fills are explicit setup work, before the frame performance interval.
     * Each aligned 64-bit store is handled by the simulator's shared RAM device. */
    uint64_t pattern[3]={0};
    for (unsigned nibble=0; nibble<48; nibble++)
        pattern[nibble/16] |= (uint64_t)((rgb>>(4*(nibble%3)))&15) << (4*(nibble%16));
    volatile uint64_t* framebuffer=(volatile uint64_t*)(uintptr_t)(GPU_RAM_BASE+FB_BASE);
    for (unsigned i=0; i<screen_width*screen_height*3/2/8; i+=3) {
        framebuffer[i]=pattern[0]; framebuffer[i+1]=pattern[1]; framebuffer[i+2]=pattern[2];
    }
    if (depth) {
        volatile uint64_t* z=(volatile uint64_t*)(uintptr_t)(GPU_RAM_BASE+Z_BASE);
        for (unsigned i=0; i<screen_width*screen_height/4; i++) z[i]=UINT64_MAX;
    }
}
/* Each field spans at most two words. Packing is O(fields), rather than
 * executing a loop for every bit of every coordinate. Padding remains zero. */
static void put_bits(uint32_t* words, unsigned offset, unsigned width, uint32_t value) {
    const unsigned word=offset/32, shift=offset%32;
    value &= (1u<<width)-1;
    words[word] |= value<<shift;
    if (shift+width>32) words[word+1] |= value>>(32-shift);
}
void gpu_upload(const triangle_t* triangles, unsigned count) {
    app_check(count<=MAX_TRIANGLES, "input capacity");
    for (unsigned t=0; t<count; t++) {
        uint32_t words[16]={0};
        for (unsigned v=0; v<3; v++) {
            const vertex_t* p=&triangles[t].v[v];
            const unsigned base=170*v;
            put_bits(words,base+145,25,(uint32_t)(int32_t)lroundf(p->x*65536));
            put_bits(words,base+120,25,(uint32_t)(int32_t)lroundf(p->y*65536));
            put_bits(words,base+95,25,(uint32_t)(int32_t)lroundf(p->z*65536));
            put_bits(words,base+70,25,(uint32_t)(int32_t)lroundf(p->w*65536));
            if (p->u!=0) put_bits(words,base+43,27,(uint32_t)(int32_t)lroundf(p->u*65536));
            if (p->v!=0) put_bits(words,base+16,27,(uint32_t)(int32_t)lroundf(p->v*65536));
            put_bits(words,base,16,((uint32_t)p->rgb<<4)|15u);
        }
        volatile uint32_t* dst=(volatile uint32_t*)(uintptr_t)(GPU_RAM_BASE+VERTEX_BASE+t*64);
        for (unsigned i=0; i<16; i++) dst[i]=words[i];
    }
}
static void wait_re(void) {
    uint32_t status;
    for (;;) {
        /* Keep the hot polling loop small. Error or completion breaks it
         * immediately; GE failures are still checked every 64 status reads. */
        unsigned remaining=64;
        do {
            status=reg_read(RE_STATUS);
            if (status&34) goto finished;
        } while (--remaining);
        app_check(!(reg_read(GE_IRQ)&24),"geometry error IRQ");
    }
finished:
    app_check(!(status&32),"raster error IRQ");
    app_check((status&3)==2,"invalid raster completion");
}
void gpu_render(unsigned count, int passthrough) {
    /* Reset using the previous persistent source bit, then select the next mode
     * while idle. Geometry counts are per submission, including clip expansion. */
    reg_write(GE_CTRL,ge_control|9);
    reg_write(RE_CTRL,re_control|9);
    while (reg_read(RE_STATUS)&1) {}
    ge_control=passthrough ? 0x300 : 0x100;
    re_control=passthrough ? 0x110 : 0x100;
    reg_write(GE_VTX_BASE,VERTEX_BASE); reg_write(GE_VTX_END,VERTEX_BASE+64*count);
    reg_write(GE_CTRL,ge_control|1); reg_write(RE_CTRL,re_control|1);
    host_write(0x108,1); // Arm completed-frame capture and clear frame counters.
    if (passthrough) reg_write(RE_CTRL,re_control|3);
    reg_write(GE_CTRL,ge_control|3);
    if (passthrough) wait_re();
    else {
        for (unsigned polls=0;!(reg_read(GE_STATUS)&2);polls++)
            if ((polls&63)==0) app_check(!(reg_read(GE_IRQ)&24),"geometry error IRQ");
    }
    app_check(!(reg_read(GE_IRQ)&24),"geometry error IRQ");
    const unsigned generated=reg_read(GE_OUTPUT);
    if (!passthrough) {
        *(volatile uint32_t*)(uintptr_t)(GPU_RAM_BASE+COMMAND_BASE)=0x20000000u|generated;
        reg_write(RE_CMD_BASE,COMMAND_BASE); reg_write(RE_CMD_END,COMMAND_BASE+4);
        reg_write(RE_PRIM_BASE,PRIM_BASE); reg_write(RE_PRIM_END,PRIM_BASE+generated*64);
        reg_write(RE_CTRL,re_control|3);
    }
    if (!passthrough) wait_re();
    app_check(reg_read(RE_INPUT)==generated, "GE/RE transfer count mismatch");
    app_check(reg_read(RE_DONE)==generated, "incomplete triangle retirement");
}
uint16_t gpu_pixel(unsigned x, unsigned y) {
    unsigned bit=(y*screen_width+x)*12;
    volatile uint8_t* bytes=(volatile uint8_t*)(uintptr_t)(GPU_RAM_BASE+FB_BASE+bit/8);
    return (uint16_t)((bytes[0]|((uint32_t)bytes[1]<<8))>>(bit%8))&0xfff;
}

void gpu_style(int depth, int texture, int gouraud, unsigned alpha) {
    app_check(alpha<=15,"alpha range");
    reg_write(RE_DRAW,(depth?8u:0u)|(texture?6u:0u)|(gouraud?1u:0u));
    reg_write(RE_Z_CFG,depth?7u:0u);
    reg_write(RE_BLEND_CFG,alpha<15 ? 16u|alpha : 0u);
}
uint64_t host_millis(void) {
    return *(volatile uint64_t*)(uintptr_t)(HOST_BASE+0x128);
}
void host_wait_until(uint64_t milliseconds) {
    *(volatile uint64_t*)(uintptr_t)(HOST_BASE+0x128)=milliseconds;
}
void host_phase(unsigned phase) { host_write(0x130,phase); }
unsigned demo_scene(void) { return host_read(0x18); }
unsigned demo_duration(void) { return host_read(0x1c); }
void gpu_texture(const uint16_t* texels, unsigned size) {
    app_check(size==8 || size==16 || size==32 || size==64,"texture size");
    volatile uint32_t* dst=(volatile uint32_t*)(uintptr_t)(GPU_RAM_BASE+TEXTURE_BASE);
    for (unsigned i=0;i<size*size;i+=2) dst[i/2]=texels[i]|((uint32_t)texels[i+1]<<16);
    reg_write(RE_CTRL,re_control|9);
    while (reg_read(RE_STATUS)&1) {}
    re_control=0x100;
    reg_write(RE_CTRL,re_control|1);
    reg_write(RE_TEX_CFG,size==8?0:size==16?1:size==32?2:3);
    *(volatile uint32_t*)(uintptr_t)(GPU_RAM_BASE+COMMAND_BASE)=0x10000000u|(TEXTURE_BASE>>4);
    reg_write(RE_CMD_BASE,COMMAND_BASE);
    reg_write(RE_CMD_END,COMMAND_BASE+4);
    reg_write(RE_CTRL,re_control|3);
    wait_re();
}
