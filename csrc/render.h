#ifndef RENDER_H
#define RENDER_H

typedef struct renderer renderer_t;

/* lifecycle */
renderer_t *renderer_create(int height, const char *bg_hex);
void renderer_destroy(renderer_t *r);

/* wayland event loop integration */
int renderer_get_fd(renderer_t *r);
int renderer_get_width(renderer_t *r);
int renderer_get_height(renderer_t *r);
void renderer_dispatch(renderer_t *r);

/* drawing surface management */
void renderer_clear(renderer_t *r);

/* font state */
void renderer_set_font(renderer_t *r, const char *family, int size);
void renderer_set_font_color(renderer_t *r, double fr, double fg, double fb);
void renderer_get_text_extents(renderer_t *r, const char *text,
                                double *w, double *h);

/* drawing primitives */
void renderer_draw_text(renderer_t *r, double x, double y, const char *text);
void renderer_draw_logo(renderer_t *r, const char *name, int x, int icon_size);
void renderer_get_logo_width(renderer_t *r, const char *name, int *out_w, int icon_size);
void renderer_draw_logo_w(renderer_t *r, const char *name, int x, int *out_w, int icon_size);
void renderer_draw_wifi(renderer_t *r, int signal, const char *ssid,
                         int *out_width);

/* finish frame and send to compositor (also clears for next frame) */
void renderer_frame(renderer_t *r);

#endif
