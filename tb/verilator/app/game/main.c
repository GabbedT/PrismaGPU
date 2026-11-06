/* Prism Run: steer a ship through a 3D obstacle course. All visible geometry
 * goes through GE projection/clipping and RE depth/rasterization. */
#include "gpu.h"
#include <math.h>
#include <stdio.h>

static triangle_t scene[512];
static unsigned count;
static vertex_t v(float x,float y,float z,unsigned rgb) {
    return (vertex_t){x,y,z,1,(uint16_t)rgb,0,0};
}
static void tri(vertex_t a,vertex_t b,vertex_t c) {
    app_check(count<512,"scene overflow");
    scene[count++]=(triangle_t){{a,b,c}};
}
static void quad(vertex_t a,vertex_t b,vertex_t c,vertex_t d) {
    tri(a,b,c);tri(a,c,d);
}
static void box(float x,float y,float z,float size,float angle,unsigned color) {
    const unsigned faces[6][4]={{0,2,3,1},{4,5,7,6},{0,1,5,4},{2,6,7,3},{0,4,6,2},{1,3,7,5}};
    vertex_t p[8];
    const float cs=cosf(angle),sn=sinf(angle);
    for (unsigned i=0;i<8;i++) {
        const float dx=(i&1?1:-1)*size,dy=(i&2?1:-1)*size,dz=(i&4?1:-1)*size;
        p[i]=v(x+dx*cs+dz*sn,y+dy,z-dx*sn+dz*cs,color);
    }
    for (unsigned f=0;f<6;f++) {
        const vertex_t a=p[faces[f][0]],b=p[faces[f][1]],c=p[faces[f][2]];
        const float ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z;
        const float vx=c.x-a.x,vy=c.y-a.y,vz=c.z-a.z;
        if ((uy*vz-uz*vy)*a.x+(uz*vx-ux*vz)*a.y+(ux*vy-uy*vx)*a.z>=0) continue;
        // Flat colors distinguish the cube faces without a software rasterizer.
        unsigned shade=f%3==0?color:f%3==1?(color&0xccc):(color&0xaaa);
        for (unsigned i=0;i<4;i++) p[faces[f][i]].rgb=(uint16_t)shade;
        quad(p[faces[f][0]],p[faces[f][1]],p[faces[f][2]],p[faces[f][3]]);
    }
}
int main(void) {
    const app_config_t cfg=app_config();
    uint32_t random=cfg.seed;
    float player=0;
    float obstacle_z[4]={10,18,27,36};
    int lanes[4]={-1,1,0,-1};
    unsigned score=0,lives=3,game_over_frames=0;
    gpu_init(cfg.width,1);
    gpu_projection(.4f,60);
    host_phase(20);
    printf("PRISM RUN: arrows/A,D steer; Space restarts; Q/Escape closes. Autopilot=%u\n",cfg.autopilot);
    for (unsigned frame=0;cfg.frames==0 || frame<cfg.frames;frame++) {
        unsigned keys=host_read(0x110);
        if (lives==0) {
            if ((keys&KEY_SPACE) || (cfg.autopilot && ++game_over_frames>30)) {
                lives=3;score=0;game_over_frames=0;
                for (int i=0;i<4;i++) obstacle_z[i]=10+i*9;
            }
        } else {
            if (cfg.autopilot) player=1.8f*sinf(frame*.11f);
            else {
                player += (keys&KEY_RIGHT ? .16f:0)-(keys&KEY_LEFT ? .16f:0);
                player=fmaxf(-2.2f,fminf(2.2f,player));
            }
            for (int i=0;i<4;i++) {
                obstacle_z[i]-=.45f;
                if (obstacle_z[i]<2.8f) {
                    if (fabsf(player-lanes[i]*1.6f)<.7f) { if(lives) lives--; }
                    else score++;
                    obstacle_z[i]=36+(app_random(&random)%7);
                    lanes[i]=(int)(app_random(&random)%3)-1;
                }
            }
        }
        host_write(0x120,score);host_write(0x124,lives);
        gpu_clear(lives?0x012:0x200,1);
        count=0;
        const unsigned ship_color=lives?0x2ef:0xf22;
        vertex_t nose=v(player,-.65f,3.8f,ship_color);
        vertex_t left=v(player-.45f,-1.1f,2.6f,ship_color);
        vertex_t right=v(player+.45f,-1.1f,2.6f,ship_color);
        vertex_t top=v(player,-.6f,2.8f,0xfff);
        tri(nose,left,top);tri(nose,top,right);tri(left,right,top);tri(nose,right,left);
        // Three floating markers show remaining lives directly in the 3D scene.
        for (unsigned i=0;i<3;i++) box(-.8f+i*.8f,1.1f,4,.13f,frame*.05f,i<lives?0x4f6:0x411);
        /* Submit nearby opaque geometry first. Rejected hidden fragments avoid
         * framebuffer writes, and CPU box culling removes invisible setup work. */
        unsigned order[4]={0,1,2,3};
        for (unsigned i=1;i<4;i++) for (unsigned j=i;j>0 && obstacle_z[order[j]]<obstacle_z[order[j-1]];j--) {
            const unsigned swap=order[j]; order[j]=order[j-1]; order[j-1]=swap;
        }
        for (unsigned j=0;j<4;j++) {
            const unsigned i=order[j];
            box(lanes[i]*1.6f,-.8f,obstacle_z[i],.55f,frame*.04f+i,0xf82);
        }
        for (int row=0;row<10;row++) {
            float z=3+row*5-fmodf(frame*.45f,5);
            if (z<1) z=1;
            for (int lane=0;lane<3;lane++) {
                float x=-2.5f+lane*1.67f;
                unsigned color=(row+lane)%2?0x123:0x234;
                quad(v(x,-1.5f,z,color),v(x+1.67f,-1.5f,z,color),
                     v(x+1.67f,-1.5f,z+5,color),v(x,-1.5f,z+5,color));
            }
            for (int side=-1;side<=1;side+=2) {
                const float x=side*2.6f;
                quad(v(x,-1.5f,z,0x08c),v(x,-1.4f,z,0x08c),
                     v(x,-1.4f,z+3,0x08c),v(x,-1.5f,z+3,0x08c));
            }
        }
        gpu_upload(scene,count);
        gpu_render(count,1);
        printf("GAME frame=%u score=%u lives=%u triangles=%u%s\n",frame+1,score,lives,count,lives?"":" GAME OVER - Space to restart");
    }
    return 0;
}
