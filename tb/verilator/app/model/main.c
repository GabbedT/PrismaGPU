/* Original procedural low-poly Mario fan model: solid mesh, no sprite impostor.
 * Outward box faces are culled after rotation; GE projects/clips the remainder. */
#include "scene.h"
#include <math.h>
#include <stdio.h>

static scene_t scene;
static void part(float x,float y,float z,float sx,float sy,float sz,unsigned color) {
    scene_box(&scene,x,y,z,sx,sy,sz,0,color,0);
}
int main(void) {
    const app_config_t cfg=app_config();
    gpu_init(cfg.width,1);
    gpu_projection(.4f,30);
    printf("MODEL: rotating low-poly Mario, waving arms; original procedural mesh\n");
    host_phase(10);
    for (unsigned frame=0;!cfg.frames || frame<cfg.frames;frame++) {
        const float angle=frame*.055f, wave=.12f*sinf(frame*.16f);
        scene.count=0;
        part(0,.75f,0,.46f,.4f,.35f,0xfb9);          /* Head */
        part(0,1.14f,.02f,.5f,.16f,.38f,0xe22);      /* Red cap */
        part(0,1.02f,-.36f,.5f,.07f,.22f,0xf22);     /* Visor */
        part(0,1.17f,-.365f,.12f,.12f,.035f,0xfff);  /* Cap badge */
        static const unsigned badge[5]={0x11,0x1b,0x15,0x11,0x11};
        for (unsigned row=0;row<5;row++) for (unsigned col=0;col<5;col++) {
            if (!(badge[row]&(1u<<col))) continue;
            const float x=((int)col-2)*.038f,y=1.17f+(2-(int)row)*.038f;
            scene_quad(&scene,scene_vertex(x-.019f,y-.019f,-.405f,0xe22),
                scene_vertex(x-.019f,y+.019f,-.405f,0xe22),
                scene_vertex(x+.019f,y+.019f,-.405f,0xe22),
                scene_vertex(x+.019f,y-.019f,-.405f,0xe22),0);
        }
        part(0,.58f,-.405f,.35f,.075f,.08f,0x321);   /* Moustache */
        part(0,.74f,-.46f,.14f,.14f,.16f,0xfd9);     /* Nose */
        for (int side=-1;side<=1;side+=2) {
            part(side*.23f,.87f,-.36f,.065f,.10f,.025f,0x124); /* Eyes */
            part(side*.49f,.75f,0,.08f,.13f,.15f,0xfc9);       /* Ears */
            part(side*.34f,.75f,.27f,.14f,.31f,.14f,0x431);   /* Hair */
            part(side*.56f,.18f+side*wave,0,.16f,.28f,.2f,0xe22);
            part(side*.65f,-.14f+side*wave,-.02f,.19f,.18f,.22f,0xfff);
            part(side*.23f,-.61f,0,.20f,.30f,.25f,0x25d);     /* Trouser legs */
            part(side*.23f,-.95f,-.14f,.23f,.13f,.38f,0x642); /* Shoes */
            part(side*.22f,.10f,-.28f,.065f,.065f,.035f,0xfd2);/* Buttons */
            part(side*.29f,.29f,-.24f,.08f,.28f,.055f,0x25d);  /* Straps */
        }
        part(0,.18f,.01f,.4f,.32f,.27f,0xe22);
        part(0,-.20f,0,.43f,.29f,.29f,0x25d);
        scene_transform(&scene,angle,.08f,3.4f);
        scene_cull(&scene);
        gpu_clear(0x123,1);
        scene_submit(&scene,1);
        printf("MODEL frame=%u visible_triangles=%u\n",frame+1,scene.count);
    }
    return 0;
}
