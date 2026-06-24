package main

/* ================================================================
 * data.odin — equivalent of data.ml
 *
 * Data source resolution: maps source names and shell commands
 * to display strings.
 * ================================================================ */

/* ── helpers ───────────────────────────────────────────────── */
read_file :: proc(path: cstring, buf: ^[]byte) -> bool {
  f := fopen(path, "r")
  if f == nil { return false }
  defer fclose(f)
  n := fread(raw_data(buf^), 1, u64(len(buf^)-1), f)
  buf^[n] = 0
  return true
}

run_cmd :: proc(cmd: cstring, buf: ^Buf512) -> cstring {
  buf[0] = 0
  f := popen(cmd, "r")
  if f == nil { return cstring(&buf[0]) }
  defer pclose(f)
  if fgets(&buf[0], i32(len(buf)), f) != nil {
    i := 0
    for i < len(buf) && buf[i] != 0 {
      if buf[i] == '\n' { buf[i] = 0; break }
      i += 1
    }
  }
  return cstring(&buf[0])
}

/* advance past whitespace */
skip_sp :: proc(s: []byte, i: ^int) {
  for i^ < len(s) && (s[i^] == ' ' || s[i^] == '\t') { i^ += 1 }
}

/* parse decimal integer */
parse_int :: proc(s: []byte, i: ^int) -> i64 {
  v: i64 = 0
  for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' {
    v = v * 10 + i64(s[i^] - '0')
    i^ += 1
  }
  return v
}

/* advance to next line */
next_line :: proc(s: []byte, i: ^int) {
  for i^ < len(s) && s[i^] != '\n' { i^ += 1 }
  if i^ < len(s) { i^ += 1 }
}

/* ── clock ─────────────────────────────────────────────────── */
get_clock :: proc(buf: ^Buf512) -> cstring {
  t: i64
  time(&t)
  tm: Buf256
  localtime_r(&t, &tm)
  h := ([^]i32)(&tm)[2]
  m := ([^]i32)(&tm)[1]
  snprintf(&buf[0], u64(len(buf)), cstring("%02d:%02d"), h, m)
  return cstring(&buf[0])
}

/* ── cpu ───────────────────────────────────────────────────── */
CpuCache :: struct {
  prev_total: i64,
  prev_idle:  i64,
  prev_sec:   i64,
  acc_total:  i64,
  acc_used:   i64,
  last_pct:   i64,
  has_pct:    bool,
}

get_cpu :: proc(buf: ^Buf512, cc: ^CpuCache) -> cstring {
  file: Buf4096
  s := file[:]
  if !read_file(cstring("/proc/stat"), &s) {
    return cstring("CPU?")
  }

  i := 0
  for i < len(s) {
    if i + 4 < len(s) && s[i] == 'c' && s[i+1] == 'p' && s[i+2] == 'u' && s[i+3] == ' ' {
      i += 4
      skip_sp(s, &i)

      nums: [8]i64
      count := 0
      for count < 8 && i < len(s) && s[i] >= '0' && s[i] <= '9' {
        nums[count] = parse_int(s, &i)
        count += 1
        skip_sp(s, &i)
      }
      if count < 4 { break }

      total := nums[0] + nums[1] + nums[2] + nums[3]
      for j := 4; j < count; j += 1 { total += nums[j] }
      idle := nums[3]

      cur_t: i64
      time(&cur_t)

      if cc.prev_total == 0 {
        cc.prev_total = total
        cc.prev_idle  = idle
        cc.prev_sec   = cur_t
        return cstring("")
      }

      dt := total - cc.prev_total
      du := (total - idle) - (cc.prev_total - cc.prev_idle)

      if dt > 0 {
        cc.acc_total += dt
        cc.acc_used  += du
        cc.prev_total = total
        cc.prev_idle  = idle
        cc.prev_sec   = cur_t
      }

      if cc.acc_total >= 2000 {
        pct := (cc.acc_used * 100) / cc.acc_total
        cc.last_pct = pct
        cc.has_pct = true
        cc.acc_total = 0
        cc.acc_used  = 0
        snprintf(&buf[0], u64(len(buf)), cstring("%d%%"), pct)
        return cstring(&buf[0])
      }

      if cc.has_pct {
        snprintf(&buf[0], u64(len(buf)), cstring("%d%%"), cc.last_pct)
        return cstring(&buf[0])
      }
      break
    }
    next_line(s, &i)
  }
  return cstring("")
}

/* ── memory ────────────────────────────────────────────────── */
get_memory :: proc(buf: ^Buf512) -> cstring {
  file: Buf4096
  s := file[:]
  if !read_file(cstring("/proc/meminfo"), &s) {
    return cstring("MEM?")
  }

  total, available: i64
  ftotal, favail: bool

  i := 0
  for i < len(s) {
    col := i
    for col < len(s) && s[col] != ':' { col += 1 }
    if col >= len(s) { break }

    ks := i
    for ks < col && (s[ks] == ' ' || s[ks] == '\t') { ks += 1 }

    val_s := col + 1
    skip_sp(s, &val_s)
    v := parse_int(s, &val_s)

    key_str := string(s[ks:col])
    if key_str == "MemTotal"     { total = v;     ftotal = true }
    if key_str == "MemAvailable" { available = v; favail = true }

    i = val_s
    next_line(s, &i)
  }

  if ftotal && favail && total > 0 {
    used_kb := total - available
    used_gb  := f64(used_kb) / 1048576.0
    total_gb := f64(total) / 1048576.0
    snprintf(&buf[0], u64(len(buf)), cstring("%.1f/%.1fG"), used_gb, total_gb)
    return cstring(&buf[0])
  }
  return cstring("MEM?")
}

/* ── battery ───────────────────────────────────────────────── */
BatteryCache :: struct {
  capacity: i32,
  status:   string,
  updated:  i64,
}

get_battery :: proc(buf: ^Buf512, bc: ^BatteryCache) -> cstring {
  cur_t: i64
  time(&cur_t)
  if cur_t - bc.updated < 1 && bc.capacity > 0 {
    snprintf(&buf[0], u64(len(buf)), cstring("%d%%"), bc.capacity)
    return cstring(&buf[0])
  }

  bats := []cstring{cstring("/sys/class/power_supply/BAT0/uevent"), cstring("/sys/class/power_supply/BAT1/uevent")}
  for bat_path in bats {
    f: Buf4096
    s := f[:]
    if !read_file(bat_path, &s) { continue }

    cap: i32 = 0
    stat: string = ""
    j := 0
    for j < len(s) {
      eol := j
      for eol < len(s) && s[eol] != '\n' { eol += 1 }
      line_str := string(s[j:eol])

      if len(line_str) >= 22 && line_str[:22] == "POWER_SUPPLY_CAPACITY=" {
        cap = 0
        for idx := 22; idx < len(line_str); idx += 1 {
          c := line_str[idx]
          if c >= '0' && c <= '9' { cap = cap * 10 + i32(c - '0') }
        }
      }
      if len(line_str) >= 20 && line_str[:20] == "POWER_SUPPLY_STATUS=" {
        stat = line_str[20:]
      }

      j = eol + 1
    }

    bc.updated  = cur_t
    bc.capacity = cap
    if stat == "Charging" {
      bc.status = "↑"
    } else if stat == "Discharging" {
      bc.status = "↓"
    } else {
      bc.status = "—"
    }

    if cap > 0 {
      snprintf(&buf[0], u64(len(buf)), cstring("%d%%"), cap)
      return cstring(&buf[0])
    }
  }

  bc.updated = cur_t
  bc.capacity = 0
  return cstring("")
}

get_battery_state :: proc(buf: ^Buf512, bc: ^BatteryCache) -> cstring {
  cur_t: i64
  time(&cur_t)
  if cur_t - bc.updated >= 1 || bc.capacity <= 0 {
    // trigger cache refresh
    temp: Buf512
    get_battery(&temp, bc)
  }
  if bc.capacity > 0 {
    n := copy(buf[:], bc.status)
    if n < len(buf) { buf[n] = 0 }
    return cstring(&buf[0])
  }
  return cstring("")
}

/* ── distro ────────────────────────────────────────────────── */
get_distro :: proc(buf: ^Buf512) -> cstring {
  file: Buf4096
  s := file[:]
  if !read_file(cstring("/etc/os-release"), &s) {
    return cstring("linux")
  }

  i := 0
  for i < len(s) {
    eol := i
    for eol < len(s) && s[eol] != '\n' { eol += 1 }
    if eol - i > 3 && s[i] == 'I' && s[i+1] == 'D' && s[i+2] == '=' {
      vs := i + 3
      ve := eol
      if ve > vs && s[vs] == '"' { vs += 1 }
      if ve > vs && s[ve-1] == '"' { ve -= 1 }
      if ve - vs < len(buf)-1 {
        j := 0
        for pos := vs; pos < ve; pos += 1 {
          if s[pos] != '"' && s[pos] != '\'' {
            buf[j] = s[pos]
            j += 1
          }
        }
        buf[j] = 0
      }
      return cstring(&buf[0])
    }
    i = eol + 1
  }
  return cstring("linux")
}

get_distro_logo :: proc() -> string {
  file: Buf4096
  s := file[:]
  if !read_file(cstring("/etc/os-release"), &s) {
    return "linux"
  }

  id := ""
  i := 0
  for i < len(s) {
    eol := i
    for eol < len(s) && s[eol] != '\n' { eol += 1 }
    if eol - i > 3 && s[i] == 'I' && s[i+1] == 'D' && s[i+2] == '=' {
      vs := i + 3
      ve := eol
      if ve > vs && s[vs] == '"' { vs += 1 }
      if ve > vs && s[ve-1] == '"' { ve -= 1 }
      id = string(s[vs:ve])
      break
    }
    i = eol + 1
  }

  switch id {
  case "nixos": return "nix-snowflake"
  case "ubuntu": return "ubuntu"
  case "debian": return "debian"
  case "arch": return "arch"
  case "fedora": return "fedora"
  case "void": return "void"
  }
  return "linux"
}

/* ── wifi ──────────────────────────────────────────────────── */
WifiData :: struct {
  signal: i32,
  ssid:   Buf256,
  updated: i64,
}

get_wifi :: proc(wd: ^WifiData) -> bool {
  cur_t: i64
  time(&cur_t)
  if cur_t - wd.updated < 2 && wd.signal > 0 { return true }

  cmd := cstring("nmcli -t -f IN-USE,SIGNAL,SSID dev wifi 2>/dev/null | grep '^\\*' | head -1")
  f := popen(cmd, "r")
  if f == nil { return false }
  defer pclose(f)

  line: Buf512
  if fgets(&line[0], i32(len(line)), f) == nil { return false }

  l := line[:]
  if len(l) < 2 || l[0] != '*' { return false }

  /* format: *:55:MySSID\n  (terse, colon-separated) */
  i := 1
  if i < len(l) && l[i] == ':' { i += 1 }  /* skip colon after * */

  /* parse signal */
  sig: i32 = 0
  for i < len(l) && l[i] >= '0' && l[i] <= '9' {
    sig = sig * 10 + i32(l[i] - '0')
    i += 1
  }
  wd.signal = sig

  /* skip colon after signal */
  if i < len(l) && l[i] == ':' { i += 1 }

  /* read SSID */
  j := 0
  for i < len(l) && l[i] != 0 && l[i] != '\n' && j < 255 {
    wd.ssid[j] = l[i]
    j += 1
    i += 1
  }
  wd.ssid[j] = 0
  wd.updated = cur_t
  return true
}

has_ethernet :: proc() -> bool {
  cmd := cstring("nmcli -t -f TYPE con show --active 2>/dev/null | grep '^ethernet:' | head -1")
  f := popen(cmd, "r")
  if f == nil { return false }
  defer pclose(f)
  line: Buf256
  return fgets(&line[0], i32(len(line)), f) != nil
}

/* ── volume ────────────────────────────────────────────────── */
get_volume :: proc(buf: ^Buf512) -> cstring {
  cmd_buf: Buf512
  cmd := "wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{printf \"%d%%\", $2 * 100}'"
  n := copy(cmd_buf[:], cmd)
  cmd_buf[n] = 0
  return run_cmd(cstring(&cmd_buf[0]), buf)
}

/* ── resolve: source → string ──────────────────────────────── */
apply_format :: proc(buf: ^Buf512, raw: cstring, fmt: string) -> cstring {
  if fmt == "" || fmt == "{}" { return raw }
  raw_buf: Buf512
  n := copy(raw_buf[:], string(raw))
  raw_str := string(raw_buf[:n])
  brace := -1
  for i in 0 ..< len(fmt) {
    if fmt[i] == '{' && i+1 < len(fmt) && fmt[i+1] == '}' {
      brace = i
      break
    }
  }
  if brace < 0 {
    n := copy(buf[:], fmt)
    if n < len(buf) { buf[n] = 0 }
    return cstring(&buf[0])
  }
  prefix := fmt[:brace]
  suffix := fmt[brace+2:]
  w := 0
  for w < len(prefix) && w < len(buf)-1 {
    buf[w] = prefix[w]
    w += 1
  }
  for ri := 0; ri < len(raw_str) && w < len(buf)-1; ri += 1 {
    buf[w] = raw_str[ri]
    w += 1
  }
  for si := 0; si < len(suffix) && w < len(buf)-1; si += 1 {
    buf[w] = suffix[si]
    w += 1
  }
  buf[w] = 0
  return cstring(&buf[0])
}

resolve_source :: proc(source: DataSource, buf: ^Buf512, cpu_cache: ^CpuCache, bat_cache: ^BatteryCache, wifi_data: ^WifiData, fmt: string = "") -> cstring {
  raw: cstring
  switch s in source {
  case DataInline:
    n := copy(buf[:], s.text)
    if n < len(buf) { buf[n] = 0 }
    raw = cstring(&buf[0])
  case DataClock:
    raw = get_clock(buf)
  case DataCpu:
    raw = get_cpu(buf, cpu_cache)
  case DataMemory:
    raw = get_memory(buf)
  case DataBattery:
    raw = get_battery(buf, bat_cache)
  case DataBatteryState:
    raw = get_battery_state(buf, bat_cache)
  case DataDistro:
    raw = get_distro(buf)
  case DataDistroLogo:
    raw = cstring("")
  case DataWifi:
    if get_wifi(wifi_data) {
      snprintf(&buf[0], u64(len(buf)), cstring("%s %d%%"), cstring(&wifi_data.ssid[0]), wifi_data.signal)
      raw = cstring(&buf[0])
    } else if has_ethernet() {
      raw = cstring("eth")
    } else {
      raw = cstring("")
    }
  case DataVolume:
    raw = get_volume(buf)
  case DataCmd:
    cmd_buf: Buf512
    n := copy(cmd_buf[:], s.command)
    if n < len(cmd_buf) { cmd_buf[n] = 0 }
    raw = run_cmd(cstring(&cmd_buf[0]), buf)
  }
  return apply_format(buf, raw, fmt)
}
