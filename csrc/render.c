#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include <poll.h>
#include <cairo.h>
#include <librsvg/rsvg.h>
#include <wayland-client.h>
#include "render.h"
#include "wlr-layer-shell-unstable-v1.h"
#include "xdg-shell.h"

/* ── renderer struct (opaque in header) ─────────────────────── */
struct renderer {
  /* wayland core */
  struct wl_display *display;
  struct wl_registry *registry;
  struct wl_compositor *compositor;
  struct wl_shm *shm;
  struct wl_surface *surface;
  struct zwlr_layer_shell_v1 *layer_shell;
  struct zwlr_layer_surface_v1 *layer_surface;

  /* geometry */
  int width, height;

  /* cairo draw surface (persistent, cleared each frame) */
  cairo_surface_t *draw_surf;
  cairo_t *draw_cr;

  /* font */
  char font_family[256];
  int font_size;
  double font_r, font_g, font_b;

  /* background */
  char bg[16];

  /* shm buffer tracking */
  struct wl_buffer *pending_buffer;
  unsigned char *pending_data;
  size_t pending_size;
};

static void safecpy(char *dst, size_t sz, const char *src) {
  if (sz == 0) return;
  size_t n = strlen(src);
  if (n >= sz) n = sz - 1;
  memcpy(dst, src, n);
  dst[n] = '\0';
}

/* ── SHM helpers ────────────────────────────────────────────── */
static int create_tmpfile_cloexec(void) {
  const char *dir = getenv("XDG_RUNTIME_DIR");
  if (!dir) return -1;
  char template[256];
  snprintf(template, sizeof(template), "%s/ribbon-shm-XXXXXX", dir);
  int fd = mkstemp(template);
  if (fd < 0) return -1;
  unlink(template);
  int flags = fcntl(fd, F_GETFD);
  if (flags >= 0) fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
  return fd;
}

static int allocate_shm_file(int size) {
  int fd = create_tmpfile_cloexec();
  if (fd < 0) return -1;
  if (ftruncate(fd, size) < 0) { close(fd); return -1; }
  return fd;
}

static struct wl_buffer *create_shm_buffer(struct renderer *r, int w, int h,
                                            unsigned char **data_out) {
  int stride = w * 4;
  int size = stride * h;
  int fd = allocate_shm_file(size);
  if (fd < 0) return NULL;
  unsigned char *data = mmap(NULL, size, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0);
  if (data == MAP_FAILED) { close(fd); return NULL; }
  struct wl_shm_pool *pool = wl_shm_create_pool(r->shm, fd, size);
  struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
      WL_SHM_FORMAT_ARGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  *data_out = data;
  return buf;
}

/* ── Wayland listeners ──────────────────────────────────────── */
static void layer_surface_configure(void *data,
    struct zwlr_layer_surface_v1 *surface, uint32_t serial,
    uint32_t w, uint32_t h) {
  struct renderer *r = data;
  r->width = w;
  r->height = h;
  if (!r->draw_surf) {
    r->draw_surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    r->draw_cr = cairo_create(r->draw_surf);
  }
  zwlr_layer_surface_v1_ack_configure(surface, serial);
}

static void layer_surface_closed(void *data,
    struct zwlr_layer_surface_v1 *surface) {
  /* compositor wants us to go away; caller should check after dispatch */
  struct renderer *r = data;
  (void)r;
}

static const struct zwlr_layer_surface_v1_listener layer_surface_listener = {
  .configure = layer_surface_configure,
  .closed = layer_surface_closed,
};

static void global_handler(void *data, struct wl_registry *reg,
                            uint32_t name, const char *iface, uint32_t ver) {
  struct renderer *r = data;
  if (!strcmp(iface, "wl_compositor"))
    r->compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
  else if (!strcmp(iface, "zwlr_layer_shell_v1"))
    r->layer_shell = wl_registry_bind(reg, name,
        &zwlr_layer_shell_v1_interface, 1);
  else if (!strcmp(iface, "wl_shm"))
    r->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
}

static void global_remove_handler(void *data, struct wl_registry *reg,
                                   uint32_t name) {}
static const struct wl_registry_listener registry_listener = {
  .global = global_handler,
  .global_remove = global_remove_handler,
};

/* ── API: lifecycle ─────────────────────────────────────────── */
renderer_t *renderer_create(int height, const char *bg_hex) {
  struct renderer *r = calloc(1, sizeof(*r));
  if (!r) return NULL;

  r->height = height;
  r->font_size = 14;
  r->font_r = r->font_g = r->font_b = 1.0;
  safecpy(r->font_family, sizeof(r->font_family), "DejaVu Sans");
  if (bg_hex)
    safecpy(r->bg, sizeof(r->bg), bg_hex);
  else
    safecpy(r->bg, sizeof(r->bg), "222222");

  r->display = wl_display_connect(NULL);
  if (!r->display) { fprintf(stderr, "renderer: cannot connect to wayland\n"); free(r); return NULL; }

  r->registry = wl_display_get_registry(r->display);
  wl_registry_add_listener(r->registry, &registry_listener, r);
  wl_display_roundtrip(r->display);
  wl_display_roundtrip(r->display);

  if (!r->compositor || !r->layer_shell || !r->shm) {
    fprintf(stderr, "renderer: missing compositor/layer_shell/shm\n");
    renderer_destroy(r);
    return NULL;
  }

  r->surface = wl_compositor_create_surface(r->compositor);
  r->layer_surface = zwlr_layer_shell_v1_get_layer_surface(
      r->layer_shell, r->surface, NULL,
      ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM, "ribbon");
  zwlr_layer_surface_v1_set_size(r->layer_surface, 0, r->height);
  zwlr_layer_surface_v1_set_anchor(r->layer_surface,
      ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
      ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT |
      ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP);
  zwlr_layer_surface_v1_set_exclusive_zone(r->layer_surface, r->height);
  zwlr_layer_surface_v1_set_keyboard_interactivity(r->layer_surface, 0);
  zwlr_layer_surface_v1_add_listener(r->layer_surface,
      &layer_surface_listener, r);
  wl_surface_commit(r->surface);
  wl_display_roundtrip(r->display);

  if (!r->draw_surf && r->width > 0 && r->height > 0) {
    r->draw_surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32,
        r->width, r->height);
    r->draw_cr = cairo_create(r->draw_surf);
  }

  return r;
}

void renderer_destroy(renderer_t *rp) {
  struct renderer *r = rp;
  if (!r) return;
  if (r->draw_cr) cairo_destroy(r->draw_cr);
  if (r->draw_surf) cairo_surface_destroy(r->draw_surf);
  if (r->pending_buffer) {
    wl_buffer_destroy(r->pending_buffer);
    munmap(r->pending_data, r->pending_size);
  }
  if (r->layer_surface) zwlr_layer_surface_v1_destroy(r->layer_surface);
  if (r->surface) wl_surface_destroy(r->surface);
  if (r->shm) wl_shm_destroy(r->shm);
  if (r->compositor) wl_compositor_destroy(r->compositor);
  if (r->layer_shell) zwlr_layer_shell_v1_destroy(r->layer_shell);
  if (r->registry) wl_registry_destroy(r->registry);
  if (r->display) wl_display_disconnect(r->display);
  free(r);
}

/* ── API: wayland event integration ─────────────────────────── */
int renderer_get_fd(renderer_t *r) {
  return wl_display_get_fd(r->display);
}

int renderer_get_width(renderer_t *r) { return r->width; }
int renderer_get_height(renderer_t *r) { return r->height; }

void renderer_dispatch(renderer_t *r) {
  wl_display_dispatch_pending(r->display);
  wl_display_flush(r->display);
}

/* ── internal: clear draw surface to background colour ──────── */
static void clear_draw_surf(struct renderer *r) {
  const char *bg = r->bg;
  if (bg[0] == '#') bg++;
  char comp[3] = {0};
  comp[0] = bg[0]; comp[1] = bg[1];
  double cr = strtol(comp, NULL, 16) / 255.0;
  comp[0] = bg[2]; comp[1] = bg[3];
  double cg = strtol(comp, NULL, 16) / 255.0;
  comp[0] = bg[4]; comp[1] = bg[5];
  double cb = strtol(comp, NULL, 16) / 255.0;
  cairo_set_source_rgb(r->draw_cr, cr, cg, cb);
  cairo_paint(r->draw_cr);
}

/* ── API: drawing surface management ────────────────────────── */
void renderer_clear(renderer_t *r) {
  if (!r->draw_surf) return;
  clear_draw_surf(r);
}

/* ── API: font state ────────────────────────────────────────── */
void renderer_set_font(renderer_t *r, const char *family, int size) {
  safecpy(r->font_family, sizeof(r->font_family), family);
  r->font_size = size;
}

void renderer_set_font_color(renderer_t *r, double fr, double fg, double fb) {
  r->font_r = fr; r->font_g = fg; r->font_b = fb;
}

void renderer_get_text_extents(renderer_t *r, const char *text,
                                double *w, double *h) {
  if (!r->draw_surf) return;
  cairo_select_font_face(r->draw_cr, r->font_family,
                          CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size(r->draw_cr, r->font_size);
  cairo_text_extents_t ext;
  cairo_text_extents(r->draw_cr, text, &ext);
  if (w) *w = ext.x_advance;
  if (h) *h = ext.height;
}

void renderer_draw_text(renderer_t *r, double x, double y, const char *text) {
  if (!r->draw_surf) return;
  cairo_select_font_face(r->draw_cr, r->font_family,
                          CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
  cairo_set_font_size(r->draw_cr, r->font_size);
  cairo_set_source_rgb(r->draw_cr, r->font_r, r->font_g, r->font_b);
  cairo_move_to(r->draw_cr, x, y);
  cairo_show_text(r->draw_cr, text);
}

/* ── icon path resolution ───────────────────────────────────── */
static int try_icon_path_png(const char *name, int size,
                              char *out, int outsz) {
  const char *themes[] = {"hicolor","Adwaita","Papirus","breeze","gnome"};
  const char *subdirs[] = {"apps","places","status","devices","actions","categories"};
  char buf[512];
  for (int ti = 0; ti < 5; ti++) {
    for (int si = 0; si < 6; si++) {
      int n = snprintf(buf, sizeof(buf),
          "/usr/share/icons/%s/%dx%d/%s/%s.png",
          themes[ti], size, size, subdirs[si], name);
      if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
        safecpy(out, outsz, buf); return 1;
      }
    }
  }
  const char *home = getenv("HOME");
  if (home) {
    for (int ti = 0; ti < 5; ti++) {
      for (int si = 0; si < 6; si++) {
        int n = snprintf(buf, sizeof(buf),
            "%s/.icons/%s/%dx%d/%s/%s.png",
            home, themes[ti], size, size, subdirs[si], name);
        if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
          safecpy(out, outsz, buf); return 1;
        }
      }
    }
  }
  {
    int n = snprintf(buf, sizeof(buf),
        "/run/current-system/sw/share/icons/hicolor/%dx%d/apps/%s.png",
        size, size, name);
    if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
      safecpy(out, outsz, buf); return 1;
    }
  }
  return 0;
}

static int try_icon_path_svg(const char *name, int size,
                              char *out, int outsz) {
  const char *themes[] = {"hicolor","Adwaita","Papirus","breeze","gnome"};
  const char *subdirs[] = {"apps","places","status","devices","actions","categories"};
  char buf[512];
  for (int ti = 0; ti < 5; ti++) {
    for (int si = 0; si < 6; si++) {
      int n = snprintf(buf, sizeof(buf),
          "/usr/share/icons/%s/scalable/%s/%s.svg",
          themes[ti], subdirs[si], name);
      if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
        safecpy(out, outsz, buf); return 1;
      }
    }
  }
  const char *home = getenv("HOME");
  if (home) {
    for (int ti = 0; ti < 5; ti++) {
      for (int si = 0; si < 6; si++) {
        int n = snprintf(buf, sizeof(buf),
            "%s/.icons/%s/scalable/%s/%s.svg",
            home, themes[ti], subdirs[si], name);
        if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
          safecpy(out, outsz, buf); return 1;
        }
      }
    }
  }
  {
    int n = snprintf(buf, sizeof(buf),
        "/run/current-system/sw/share/icons/hicolor/scalable/apps/%s.svg",
        name);
    if (n > 0 && n < (int)sizeof(buf) && access(buf, F_OK) == 0) {
      safecpy(out, outsz, buf); return 1;
    }
  }
  return 0;
}

static int resolve_icon_path(const char *name, int size, char *out, int outsz) {
  if (try_icon_path_png(name, size, out, outsz)) return 1;
  if (try_icon_path_svg(name, size, out, outsz)) return 2;
  return 0;
}

/* ── cached SVG handle ──────────────────────────────────────── */
static struct svg_cache {
  char path[512]; RsvgHandle *handle; RsvgRectangle vb;
} svg_cache;

static RsvgHandle *get_svg(const char *path, RsvgRectangle *vb) {
  if (svg_cache.handle && !strcmp(svg_cache.path, path)) {
    *vb = svg_cache.vb;
    return svg_cache.handle;
  }
  if (svg_cache.handle) { g_object_unref(svg_cache.handle); svg_cache.handle = NULL; }
  GError *err = NULL;
  RsvgHandle *h = rsvg_handle_new_from_file(path, &err);
  if (!h) return NULL;
  rsvg_handle_get_geometry_for_element(h, NULL, vb, NULL, NULL);
  safecpy(svg_cache.path, sizeof(svg_cache.path), path);
  svg_cache.vb = *vb;
  svg_cache.handle = h;
  return h;
}

/* draw logo — renders SVG directly onto bar surface, no intermediate buffer */
static void draw_logo_at(renderer_t *r, const char *name, int x, int *out_w, int icon_size, int draw) {
  if (icon_size < 8) icon_size = 8;
  char path[512];
  int kind = resolve_icon_path(name, icon_size, path, sizeof(path));
  if (kind == 2) {
    RsvgRectangle vb;
    RsvgHandle *h = get_svg(path, &vb);
    if (h) {
      double scale = icon_size / (vb.width > vb.height ? vb.width : vb.height);
      int iw = (int)(vb.width * scale + 0.5);
      int ih = (int)(vb.height * scale + 0.5);
      if (iw < 1) iw = 1;
      if (ih < 1) ih = 1;
      if (out_w) *out_w = iw;
      if (draw && r->draw_surf) {
        int y_off = (r->height - ih) / 2 + 1;
        cairo_save(r->draw_cr);
        cairo_translate(r->draw_cr, x, y_off);
        RsvgRectangle viewport = {0, 0, (double)iw, (double)ih};
        rsvg_handle_render_document(h, r->draw_cr, &viewport, NULL);
        cairo_restore(r->draw_cr);
      }
      return;
    }
  } else if (kind == 1) {
    cairo_surface_t *s = cairo_image_surface_create_from_png(path);
    if (cairo_surface_status(s) == CAIRO_STATUS_SUCCESS) {
      int iw = cairo_image_surface_get_width(s);
      int ih = cairo_image_surface_get_height(s);
      if (out_w) *out_w = iw;
      if (draw && r->draw_surf) {
        int y_off = (r->height - ih) / 2 + 1;
        cairo_save(r->draw_cr);
        cairo_set_source_surface(r->draw_cr, s, x, y_off);
        cairo_paint(r->draw_cr);
        cairo_restore(r->draw_cr);
      }
      cairo_surface_destroy(s);
      return;
    }
    cairo_surface_destroy(s);
  }
  if (out_w) *out_w = icon_size;
  if (draw && r->draw_surf) {
    cairo_save(r->draw_cr);
    int cx = x + icon_size/2;
  int cy = r->height / 2 + 100;
    cairo_set_source_rgb(r->draw_cr, 0.3, 0.6, 0.9);
    cairo_arc(r->draw_cr, cx, cy, icon_size/2, 0, 6.2832);
    cairo_fill(r->draw_cr);
    cairo_restore(r->draw_cr);
  }
}

void renderer_draw_logo(renderer_t *r, const char *name, int x, int icon_size) {
  draw_logo_at(r, name, x, NULL, icon_size, 1);
}

void renderer_get_logo_width(renderer_t *r, const char *name, int *out_w, int icon_size) {
  if (!r->draw_surf) { *out_w = 0; return; }
  draw_logo_at(r, name, 0, out_w, icon_size, 0);
}

void renderer_draw_logo_w(renderer_t *r, const char *name, int x, int *out_w, int icon_size) {
  if (!r->draw_surf) { *out_w = 0; return; }
  draw_logo_at(r, name, x, out_w, icon_size, 1);
}

/* ── API: wifi drawing ──────────────────────────────────────── */
#define WIFI_RPAD 10

void renderer_draw_wifi(renderer_t *r, int signal, const char *ssid,
                         int *out_width) {
  if (!r->draw_surf) return;
  if (signal < 0) { *out_width = 0; return; }

  double s = (double)(r->height - 8);
  if (s < 8) s = 8;

  int n = (signal >= 75) ? 4 : (signal >= 50) ? 3 : (signal >= 25) ? 2 : (signal >= 8) ? 1 : 0;
  double dot_r   = s * 0.09;
  double thick   = s * 0.10;
  double gap     = s * 0.06;
  double first_r = dot_r * 2.5;
  double tot_r   = n > 0 ? first_r + n * (thick + gap) - gap : dot_r;
  int cx = r->width - WIFI_RPAD - (int)tot_r;
  int cy = r->height / 2 + 3;

  cairo_save(r->draw_cr);
  cairo_set_source_rgb(r->draw_cr, r->font_r, r->font_g, r->font_b);

  for (int i = 0; i < n; i++) {
    double ri = first_r + i * (thick + gap);
    double ro = ri + thick;
    double half = M_PI * 0.45;
    double a0 = -M_PI * 0.5 - half;
    double a1 = -M_PI * 0.5 + half;
    cairo_new_path(r->draw_cr);
    cairo_arc(r->draw_cr, cx, cy, ro, a0, a1);
    cairo_arc_negative(r->draw_cr, cx, cy, ri, a1, a0);
    cairo_close_path(r->draw_cr);
    cairo_fill(r->draw_cr);
  }

  if (n > 0) {
    cairo_new_path(r->draw_cr);
    cairo_arc(r->draw_cr, cx, cy, dot_r, 0, 2 * M_PI);
    cairo_fill(r->draw_cr);
  }

  cairo_restore(r->draw_cr);
  *out_width = (int)(WIFI_RPAD + 2.0 * tot_r);
}

/* ── API: render frame ──────────────────────────────────────── */
void renderer_frame(renderer_t *r) {
  if (!r->draw_surf) return;
  int w = r->width, h = r->height;
  unsigned char *data;
  struct wl_buffer *buffer = create_shm_buffer(r, w, h, &data);
  if (!buffer) return;

  cairo_surface_t *out = cairo_image_surface_create_for_data(data,
      CAIRO_FORMAT_ARGB32, w, h, w * 4);
  cairo_t *cr = cairo_create(out);
  cairo_set_source_surface(cr, r->draw_surf, 0, 0);
  cairo_paint(cr);
  cairo_destroy(cr);
  cairo_surface_destroy(out);

  wl_surface_attach(r->surface, buffer, 0, 0);
  wl_surface_damage_buffer(r->surface, 0, 0, w, h);
  wl_surface_commit(r->surface);
  wl_display_flush(r->display);

  if (r->pending_buffer) {
    wl_buffer_destroy(r->pending_buffer);
    munmap(r->pending_data, r->pending_size);
  }
  r->pending_buffer = buffer;
  r->pending_data = data;
  r->pending_size = w * h * 4;

  /* clear draw surface for next frame (avoids accumulation) */
  clear_draw_surf(r);
}
