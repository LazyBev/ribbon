package main

import "base:runtime"
import "core:os"
import "core:fmt"

@(default_calling_convention="c")
foreign _ {
  renderer_create         :: proc(height: i32, bg_hex: cstring) -> rawptr ---
  renderer_destroy        :: proc(r: rawptr) ---
  renderer_get_fd         :: proc(r: rawptr) -> i32 ---
  renderer_get_width      :: proc(r: rawptr) -> i32 ---
  renderer_get_height     :: proc(r: rawptr) -> i32 ---
  renderer_dispatch       :: proc(r: rawptr) ---
  renderer_clear          :: proc(r: rawptr) ---
  renderer_set_font       :: proc(r: rawptr, family: cstring, sz: i32) ---
  renderer_set_font_color :: proc(r: rawptr, fr, fg, fb: f64) ---
  renderer_get_text_extents :: proc(r: rawptr, text: cstring, w: ^f64, h: ^f64) ---
  renderer_draw_text      :: proc(r: rawptr, x: f64, y: f64, text: cstring) ---
  renderer_draw_logo      :: proc(r: rawptr, name: cstring, x: i32, icon_size: i32) ---
  renderer_get_logo_width :: proc(r: rawptr, name: cstring, out_w: ^i32, icon_size: i32) ---
  renderer_draw_logo_w    :: proc(r: rawptr, name: cstring, x: i32, out_w: ^i32, icon_size: i32) ---
  renderer_draw_wifi      :: proc(r: rawptr, signal: i32, ssid: cstring, out_w: ^i32) ---
  renderer_frame          :: proc(r: rawptr) ---
}

hex_to_floats :: proc(hex: string) -> (f64, f64, f64) {
  h := hex
  if len(h) > 0 && h[0] == '#' { h = h[1:] }
  if len(h) < 6 { return 1, 1, 1 }
  hex_val :: proc(c: u8) -> u8 {
    if c >= '0' && c <= '9' { return c - '0' }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10 }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10 }
    return 0
  }
  r := f64(hex_val(h[0]) * 16 + hex_val(h[1])) / 255.0
  g := f64(hex_val(h[2]) * 16 + hex_val(h[3])) / 255.0
  b := f64(hex_val(h[4]) * 16 + hex_val(h[5])) / 255.0
  return r, g, b
}

cstr_empty :: proc(s: cstring) -> bool {
  return (cast(^u8)s)^ == 0
}

draw_side :: proc(r: rawptr, segs: []Segment, x_pos: f64, y: f64, cfg: ^BarConfig, cc: ^CpuCache, bc: ^BatteryCache, wd: ^WifiData) {
  seg_bufs: [16]Buf512
  x := x_pos
  first_visible := true

  sep_buf: [64]byte
  n := copy(sep_buf[:], cfg.separator_text)
  sep_buf[n] = 0
  has_sep := n > 0

  for i in 0 ..< min(len(segs), 16) {
    val := resolve_source(segs[i].source, &seg_bufs[i], cc, bc, wd, segs[i].fmt)
    is_logo: bool
    logo_name: string
    #partial switch s in segs[i].source {
    case DataDistroLogo:
      is_logo = true
      logo_name = s.name
    }

    if !is_logo && cstr_empty(val) { continue }

    if !first_visible && has_sep {
      if cfg.separator_color != "" {
        sr, sg, sb := hex_to_floats(cfg.separator_color)
        renderer_set_font_color(r, sr, sg, sb)
      }
      sw: f64; sh: f64
      renderer_get_text_extents(r, cstring(&sep_buf[0]), &sw, &sh)
      renderer_draw_text(r, x, y, cstring(&sep_buf[0]))
      x += sw + 4
      if cfg.separator_color != "" {
        fr, fg, fb := hex_to_floats(cfg.font_color)
        renderer_set_font_color(r, fr, fg, fb)
      }
    }
    first_visible = false

    if segs[i].color != "" {
      sr, sg, sb := hex_to_floats(segs[i].color)
      renderer_set_font_color(r, sr, sg, sb)
    }

    if is_logo {
      icon_sz := cfg.logo_size if cfg.logo_size > 0 else cfg.height - 8
      lw: i32
      renderer_draw_logo_w(r, cstring(raw_data(logo_name)), i32(x), &lw, i32(icon_sz))
      x += f64(lw) + f64(cfg.widget_gap)
    } else {
      tw: f64; th: f64
      renderer_get_text_extents(r, val, &tw, &th)
      renderer_draw_text(r, x, y, val)
      x += tw + f64(cfg.widget_gap)
    }

    if segs[i].color != "" {
      fr, fg, fb := hex_to_floats(cfg.font_color)
      renderer_set_font_color(r, fr, fg, fb)
    }
  }
}

measure_side :: proc(r: rawptr, segs: []Segment, cfg: ^BarConfig, cc: ^CpuCache, bc: ^BatteryCache, wd: ^WifiData) -> f64 {
  total: f64 = 0
  seg_bufs: [16]Buf512
  first_visible := true
  has_sep := len(cfg.separator_text) > 0

  sep_buf: [64]byte
  n := copy(sep_buf[:], cfg.separator_text)
  sep_buf[n] = 0

  for i in 0 ..< min(len(segs), 16) {
    val := resolve_source(segs[i].source, &seg_bufs[i], cc, bc, wd, segs[i].fmt)
    is_logo: bool
    logo_name: string
    #partial switch s in segs[i].source {
    case DataDistroLogo:
      is_logo = true
      logo_name = s.name
    }

    if !is_logo && cstr_empty(val) { continue }

    if !first_visible && has_sep {
      sw: f64; sh: f64
      renderer_get_text_extents(r, cstring(&sep_buf[0]), &sw, &sh)
      total += sw + 4
    }
    first_visible = false

    if is_logo {
      icon_sz := cfg.logo_size if cfg.logo_size > 0 else cfg.height - 8
      lw: i32
      renderer_get_logo_width(r, cstring(raw_data(logo_name)), &lw, i32(icon_sz))
      total += f64(lw) + f64(cfg.widget_gap)
    } else {
      tw: f64; th: f64
      renderer_get_text_extents(r, val, &tw, &th)
      total += tw + f64(cfg.widget_gap)
    }
  }
  return total
}

set_font_color_from_cfg :: proc(r: rawptr, cfg: ^BarConfig) {
  fr, fg, fb := hex_to_floats(cfg.font_color)
  renderer_set_font_color(r, fr, fg, fb)
}

run_bar :: proc(cfg: ^BarConfig) {
  r := renderer_create(i32(cfg.height), cstring(raw_data(cfg.bg_color)))
  if r == nil { return }
  defer renderer_destroy(r)

  renderer_set_font(r, cstring(raw_data(cfg.font_family)), i32(cfg.font_size))
  set_font_color_from_cfg(r, cfg)

  pollfd: PollFd
  last_sec: i64
  cc: CpuCache
  bc: BatteryCache
  wd: WifiData

  for {
    wl_fd := renderer_get_fd(r)
    pollfd.fd = wl_fd
    pollfd.events = POLLIN
    pollfd.revents = 0

    first := last_sec == 0
    timeout: i32 = 50 if first else 1000

    poll(&pollfd, 1, timeout)
    if pollfd.revents & POLLIN != 0 { renderer_dispatch(r) }

    width  := renderer_get_width(r)
    height := renderer_get_height(r)

    if first && (width <= 0 || height <= 0) {
      continue
    }

    cur_t: i64
    time(&cur_t)
    if !first && cur_t - last_sec < 1 {
      continue
    }
    last_sec = cur_t

    font_h: f64 = 20
    if len(cfg.center) > 0 {
      center_buf: Buf512
      cv := resolve_source(cfg.center[0].source, &center_buf, &cc, &bc, &wd, cfg.center[0].fmt)
      if !cstr_empty(cv) { renderer_get_text_extents(r, cv, nil, &font_h) }
    }
    center_total := measure_side(r, cfg.center[:], cfg, &cc, &bc, &wd)
    cx := (f64(width) - center_total) * 0.5
    cy := f64(height)/2 + font_h*0.35 + cfg.center_vy

    renderer_clear(r)

    if cfg.logo != "" {
      icon_sz := cfg.logo_size if cfg.logo_size > 0 else cfg.height - 8
      renderer_draw_logo(r, cstring(raw_data(cfg.logo)), 5, i32(icon_sz))
    }

    set_font_color_from_cfg(r, cfg)
    draw_side(r, cfg.center[:], cx, cy, cfg, &cc, &bc, &wd)

    wifi_w: i32
    if cfg.wifi_icon && get_wifi(&wd) {
      renderer_draw_wifi(r, wd.signal, cstring(&wd.ssid[0]), &wifi_w)
    }

    right_total := measure_side(r, cfg.right[:], cfg, &cc, &bc, &wd)
    rx := f64(width) - right_total - f64(wifi_w) - f64(cfg.right_pad)
    ry := f64(height)/2 + font_h*0.35 + cfg.right_vy
    set_font_color_from_cfg(r, cfg)
    draw_side(r, cfg.right[:], rx, ry, cfg, &cc, &bc, &wd)

    ly := f64(height)/2 + font_h*0.35 + cfg.left_vy
    set_font_color_from_cfg(r, cfg)
    draw_side(r, cfg.left[:], f64(cfg.left_pad), ly, cfg, &cc, &bc, &wd)

    renderer_frame(r)
  }
}

main :: proc() {
  context.allocator = runtime.default_allocator()

  mol_path: string
  if len(os.args) > 1 {
    if os.args[1] == "kill" {
      _ = system(cstring("(sleep 0.2 && pkill -x ribbon) &"))
      os.exit(0)
    }
    mol_path = os.args[1]
  } else {
    home_buf: Buf512
    home := os.get_env_buf(home_buf[:], "HOME")
    mol_path = fmt.aprintf("%s/.config/ribbon/config.rib", home)
  }

  path_buf: Buf512
  pn := copy(path_buf[:], mol_path)
  if pn < len(path_buf) { path_buf[pn] = 0 }

  fbuf: Buf4096
  s := fbuf[:]
  if !read_file(cstring(&path_buf[0]), &s) {
    panic("cannot read file")
  }
  n := 0
  for n < len(s) && s[n] != 0 { n += 1 }

  init_global_env()

  exprs := parse_all(string(s[:n]))
  for i in 0 ..< len(exprs) {
    eval(global_env, &exprs[i])
  }
}
