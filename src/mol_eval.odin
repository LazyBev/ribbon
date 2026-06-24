package main

/* ================================================================
 * mol_eval.odin — equivalent of eval.ml
 *
 * Evaluates .rib s-expressions, managing bar state.
 * ================================================================ */

import "base:runtime"
import "core:fmt"

/* ── global state ──────────────────────────────────────────── */
global_env: ^Env
bar_config:  BarConfig
bar_ready:   bool

/* ── initial builtins ──────────────────────────────────────── */
init_global_env :: proc() {
  global_env = nil
  funcs := [?]string{
    "+", "-", "*", "/", "car", "cdr", "cons", "list", "eq?",
    "display", "run",
    "bar.create", "bar.set-interval", "bar.set-font", "bar.set-background",
    "bar.systray", "bar.set-systray", "bar.pad", "bar.padding",
    "bar.separator", "bar.wifi-icon",
    "bar.set-format", "bar.set-left-vy", "bar.set-center-vy", "bar.set-right-vy",
    "bar.set-logo", "bar.set-logo-nf", "bar.set-logo-size", "bar.set-widget-gap", "bar.start",
    "when", "loop",
  }
  for name in funcs {
    global_env = extend_env(global_env, name, expr_sym(name))
  }
  keywords := [?]string{
    "size", "family", "font", "height",
    "colour", "color", "font-colour", "font-color",
    "clock", "cpu", "memory", "battery", "battery-state", "distro", "wifi", "volume",
    "distro-logo",
    "left", "center", "right", "systray",
    "text", "txt", "format", "fmt",
  }
  for name in keywords {
    global_env = extend_env(global_env, name, expr_sym(name))
  }
}

/* ── helpers ───────────────────────────────────────────────── */
arity_error :: proc(name: string, expected: string, got: int) {
  panic(fmt.aprintf("%s expects %s, got %d argument", name, expected, got))
}

type_error :: proc(name: string, expected: string, got: ^Expr) {
  panic(fmt.aprintf("%s expects %s, got: %s", name, expected, string_of_expr(got)))
}

expect_args :: proc(name: string, args: ^[dynamic]Expr, n: int) {
  if len(args) != n { arity_error(name, fmt_int(i64(n)), len(args)) }
}

expect_min_args :: proc(name: string, args: ^[dynamic]Expr, n: int) {
  if len(args) < n { arity_error(name, fmt.aprintf("at least %d", n), len(args)) }
}

get_num :: proc(name: string, e: ^Expr) -> i64 {
  if e.kind != .Num { type_error(name, "a number", e) }
  return e.num
}

get_str :: proc(name: string, e: ^Expr) -> string {
  if e.kind != .Str { type_error(name, "a string", e) }
  return e.sym
}

/* ── eval ──────────────────────────────────────────────────── */
eval :: proc(env: ^Env, expr: ^Expr) -> Expr {
  switch expr.kind {
  case .Num, .Bool, .Str:
    return expr^

  case .Sym:
    if v, ok := lookup_env(env, expr.sym); ok { return v }
    if v, ok := lookup_env(global_env, expr.sym); ok { return v }
    panic(fmt.aprintf("undefined: %s", expr.sym))

  case .List:
    if len(expr.list) == 0 { return expr^ }

    /* car of list must be a symbol for special forms/builtins */
    fn := &expr.list[0]
    if fn.kind != .Sym {
      /* evaluate as function application */
      fn_val := eval(env, fn)
      args := eval_all(env, expr.list[1:])
      return apply(env, &fn_val, &args)
    }

    name := fn.sym

    switch name {
    case "if":
      expect_args("if", &expr.list, 4) /* if test t e → list has 4 elements: if, test, t, e */
      if len(expr.list) != 4 { arity_error("if", "3 arguments (test then-expr else-expr)", len(expr.list)-1) }
      cond := eval(env, &expr.list[1])
      if cond.kind == .Bool && !cond.bool {
        return eval(env, &expr.list[3])
      }
      return eval(env, &expr.list[2])

    case "when":
      expect_args("when", &expr.list, 3) /* when test body */
      if len(expr.list) != 3 { arity_error("when", "2 arguments (test body)", len(expr.list)-1) }
      cond := eval(env, &expr.list[1])
      if cond.kind != .Bool || cond.bool {
        return eval(env, &expr.list[2])
      }
      return expr_sym("ok")

    case "define":
      if len(expr.list) < 3 || expr.list[1].kind != .Sym {
        panic("define expects: (define name value)")
      }
      v := eval(env, &expr.list[2])
      global_env = extend_env(global_env, expr.list[1].sym, v)
      return v

    case "lambda":
      if len(expr.list) < 2 || expr.list[1].kind != .List {
        panic("lambda expects: (lambda (params) body...)")
      }
      params: [dynamic]string
      for i in 0 ..< len(expr.list[1].list) {
        if expr.list[1].list[i].kind != .Sym {
          type_error("lambda", "symbols for parameter names", &expr.list[1].list[i])
        }
        append(&params, expr.list[1].list[i].sym)
      }
      body := expr_list(..expr.list[2:]) if len(expr.list) > 2 else expr_sym("ok")
      if len(expr.list) == 3 {
        return expr_lambda(params, expr.list[2])
      }
      /* multi-stmt body wrapped in begin */
      begin_expr := expr_list()
      for i := 2; i < len(expr.list); i += 1 {
        append(&begin_expr.list, expr.list[i])
      }
      return expr_lambda(params, begin_expr)

    case "begin":
      result := expr_sym("ok")
      for i := 1; i < len(expr.list); i += 1 {
        result = eval(env, &expr.list[i])
      }
      return result

    case "loop":
      if len(expr.list) < 2 || expr.list[1].kind != .Num {
        panic("loop expects: (loop delay-ms body...)")
      }
      delay_ms := i32(expr.list[1].num)
      for {
        for i := 2; i < len(expr.list); i += 1 {
          eval(env, &expr.list[i])
        }
        if delay_ms > 0 { poll(nil, 0, delay_ms) }
      }
      return expr_sym("ok")

    case "bar.set-left":
      if len(expr.list) < 2 { panic("bar.set-left expects at least 1 argument") }
      {
        segs: [dynamic]Segment
        cur_color := ""
        for i := 1; i < len(expr.list); i += 1 {
          e := expr.list[i]
          if e.kind == .Sym && e.sym == "colour" || e.kind == .Sym && e.sym == "color" {
            i += 1
            if i < len(expr.list) && expr.list[i].kind == .Str {
              cur_color = expr.list[i].sym
            }
          } else if e.kind == .Sym && (e.sym == "text" || e.sym == "txt") {
            i += 1
            if i < len(expr.list) && (expr.list[i].kind == .Str || expr.list[i].kind == .Sym) {
              append(&segs, Segment{source = DataInline{text = expr.list[i].sym}, color = cur_color})
              cur_color = ""
            }
          } else if e.kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.sym), color = cur_color, fmt = get_seg_format(e.sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) == 1 && e.list[0].kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.list[0].sym), color = cur_color, fmt = get_seg_format(e.list[0].sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) >= 3 {
            if e.list[1].kind == .Sym && (e.list[1].sym == "format" || e.list[1].sym == "fmt") {
              src_name := ""; if e.list[0].kind == .Sym { src_name = e.list[0].sym }
              fmt_str := ""; if e.list[2].kind == .Str || e.list[2].kind == .Sym { fmt_str = e.list[2].sym }
              append(&segs, Segment{source = source_from_name(src_name), color = cur_color, fmt = fmt_str})
              cur_color = ""
            }
          }
        }
        bar_config.left = segs[:]
      }
      return expr_sym("ok")

    case "bar.set-center":
      if len(expr.list) < 2 { panic("bar.set-center expects at least 1 argument") }
      {
        segs: [dynamic]Segment
        cur_color := ""
        for i := 1; i < len(expr.list); i += 1 {
          e := expr.list[i]
          if e.kind == .Sym && e.sym == "colour" || e.kind == .Sym && e.sym == "color" {
            i += 1
            if i < len(expr.list) && expr.list[i].kind == .Str {
              cur_color = expr.list[i].sym
            }
          } else if e.kind == .Sym && (e.sym == "text" || e.sym == "txt") {
            i += 1
            if i < len(expr.list) && (expr.list[i].kind == .Str || expr.list[i].kind == .Sym) {
              append(&segs, Segment{source = DataInline{text = expr.list[i].sym}, color = cur_color})
              cur_color = ""
            }
          } else if e.kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.sym), color = cur_color, fmt = get_seg_format(e.sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) == 1 && e.list[0].kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.list[0].sym), color = cur_color, fmt = get_seg_format(e.list[0].sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) >= 3 {
            if e.list[1].kind == .Sym && (e.list[1].sym == "format" || e.list[1].sym == "fmt") {
              src_name := ""; if e.list[0].kind == .Sym { src_name = e.list[0].sym }
              fmt_str := ""; if e.list[2].kind == .Str || e.list[2].kind == .Sym { fmt_str = e.list[2].sym }
              append(&segs, Segment{source = source_from_name(src_name), color = cur_color, fmt = fmt_str})
              cur_color = ""
            }
          }
        }
        bar_config.center = segs[:]
      }
      return expr_sym("ok")

    case "bar.set-right":
      if len(expr.list) < 2 { panic("bar.set-right expects at least 1 argument") }
      {
        segs: [dynamic]Segment
        cur_color := ""
        for i := 1; i < len(expr.list); i += 1 {
          e := expr.list[i]
          if e.kind == .Sym && e.sym == "colour" || e.kind == .Sym && e.sym == "color" {
            i += 1
            if i < len(expr.list) && expr.list[i].kind == .Str {
              cur_color = expr.list[i].sym
            }
          } else if e.kind == .Sym && (e.sym == "text" || e.sym == "txt") {
            i += 1
            if i < len(expr.list) && (expr.list[i].kind == .Str || expr.list[i].kind == .Sym) {
              append(&segs, Segment{source = DataInline{text = expr.list[i].sym}, color = cur_color})
              cur_color = ""
            }
          } else if e.kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.sym), color = cur_color, fmt = get_seg_format(e.sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) == 1 && e.list[0].kind == .Sym {
            append(&segs, Segment{source = source_from_name(e.list[0].sym), color = cur_color, fmt = get_seg_format(e.list[0].sym)})
            cur_color = ""
          } else if e.kind == .List && len(e.list) >= 3 {
            if e.list[1].kind == .Sym && (e.list[1].sym == "format" || e.list[1].sym == "fmt") {
              src_name := ""; if e.list[0].kind == .Sym { src_name = e.list[0].sym }
              fmt_str := ""; if e.list[2].kind == .Str || e.list[2].kind == .Sym { fmt_str = e.list[2].sym }
              append(&segs, Segment{source = source_from_name(src_name), color = cur_color, fmt = fmt_str})
              cur_color = ""
            }
          }
        }
        bar_config.right = segs[:]
      }
      return expr_sym("ok")

    case "bar.pad":
      if len(expr.list) < 3 || expr.list[1].kind != .Sym || expr.list[2].kind != .Num {
        panic("bar.pad expects: (bar.pad side pixels)")
      }
      side := expr.list[1].sym
      pad_n := int(expr.list[2].num)
      switch side {
      case "left":   bar_config.left_pad = pad_n
      case "center": bar_config.center_pad = pad_n
      case "right":  bar_config.right_pad = pad_n
      }
      return expr_sym("ok")

    case "bar.padding":
      if len(expr.list) < 4 || expr.list[1].kind != .Num || expr.list[2].kind != .List {
        panic("bar.padding expects: (pad pixels (bar.set-* ...))")
      }
      pad_n := expr.list[1].num
      inner_fn := &expr.list[2].list[0]
      if inner_fn.kind == .Sym {
        side: string
        switch inner_fn.sym {
        case "bar.set-left":   side = "left"
        case "bar.set-center": side = "center"
        case "bar.set-right":  side = "right"
        }
        if side != "" {
          switch side {
          case "left":   bar_config.left_pad = int(pad_n)
          case "center": bar_config.center_pad = int(pad_n)
          case "right":  bar_config.right_pad = int(pad_n)
          }
        }
      }
      return expr_sym("ok")

    case:
      /* function application */
      fn_val := eval(env, fn)
      args := eval_all(env, expr.list[1:])
      return apply(env, &fn_val, &args)
    }

  case .Lambda:
    return expr^
  }

  return expr^
}

eval_all :: proc(env: ^Env, exprs: []Expr) -> [dynamic]Expr {
  result: [dynamic]Expr
  for i in 0 ..< len(exprs) {
    append(&result, eval(env, &exprs[i]))
  }
  return result
}

/* ── apply ─────────────────────────────────────────────────── */
apply :: proc(env: ^Env, fn: ^Expr, args: ^[dynamic]Expr) -> Expr {
  if fn.kind != .Sym && fn.kind != .Lambda {
    panic(fmt.aprintf("not a function: %s", string_of_expr(fn)))
  }

  if fn.kind == .Lambda {
    lam := fn.lambda
    if len(lam.params) != len(args) {
      panic(fmt.aprintf("lambda expects %d arguments, got %d", len(lam.params), len(args)))
    }
    /* extend env with params */
    new_env := env
    for i in 0 ..< len(lam.params) {
      new_env = extend_env(new_env, lam.params[i], args[i])
    }
    return eval(new_env, lam.body)
  }

  name := fn.sym

  /* arithmetic */
  switch name {
  case "+":
    if len(args) < 1 { arity_error("+", "at least 1 number", len(args)) }
    sum: i64 = 0
    for i in 0 ..< len(args) { sum += get_num("+", &args[i]) }
    return expr_num(sum)

  case "*":
    if len(args) < 1 { arity_error("*", "at least 1 number", len(args)) }
    prod: i64 = 1
    for i in 0 ..< len(args) { prod *= get_num("*", &args[i]) }
    return expr_num(prod)

  case "-":
    if len(args) < 1 { arity_error("-", "at least 1 number", len(args)) }
    v := get_num("-", &args[0])
    for i := 1; i < len(args); i += 1 { v -= get_num("-", &args[i]) }
    return expr_num(v)

  case "/":
    if len(args) < 1 { arity_error("/", "at least 1 number", len(args)) }
    v := get_num("/", &args[0])
    for i := 1; i < len(args); i += 1 { v /= get_num("/", &args[i]) }
    return expr_num(v)

  case "car":
    expect_args("car", args, 1)
    if args[0].kind != .List || len(args[0].list) == 0 {
      type_error("car", "a non-empty list", &args[0])
    }
    return args[0].list[0]

  case "cdr":
    expect_args("cdr", args, 1)
    if args[0].kind != .List || len(args[0].list) == 0 {
      type_error("cdr", "a non-empty list", &args[0])
    }
    c := expr_list()
    for i := 1; i < len(args[0].list); i += 1 { append(&c.list, args[0].list[i]) }
    return c

  case "cons":
    expect_args("cons", args, 2)
    if args[1].kind != .List { type_error("cons", "a list as second argument", &args[1]) }
    c := expr_list(args[0])
    for i in 0 ..< len(args[1].list) { append(&c.list, args[1].list[i]) }
    return c

  case "list":
    c := expr_list()
    for a in args { append(&c.list, a) }
    return c

  case "eq?":
    expect_args("eq?", args, 2)
    if args[0].kind != args[1].kind { return expr_bool(false) }
    switch args[0].kind {
    case .Num:  return expr_bool(args[0].num == args[1].num)
    case .Sym, .Str: return expr_bool(args[0].sym == args[1].sym)
    case .Bool: return expr_bool(args[0].bool == args[1].bool)
    case .List: return expr_bool(false) /* structural eq not implemented */
    case .Lambda: return expr_bool(false)
    }
    return expr_bool(false)

  case "display":
    expect_args("display", args, 1)
    /* print to stdout */
    return expr_sym("ok")

  case "run":
    expect_args("run", args, 1)
    cmd := get_str("run", &args[0])
    buf: Buf512
    res := run_cmd(cstring(raw_data(cmd)), &buf)
    return expr_str(string(res))

  /* ── bar operations ──────────────────────────────────── */
  case "bar.create":
    expect_args("bar.create", args, 0)
    bar_config = default_config()
    bar_ready = true
    return expr_sym("ok")

  case "bar.set-interval":
    expect_args("bar.set-interval", args, 1)
    bar_config.interval = int(get_num("bar.set-interval", &args[0]))
    return expr_sym("ok")

  case "bar.set-font":
    expect_min_args("bar.set-font", args, 1)
    if args[0].kind == .Str || args[0].kind == .Sym {
      bar_config.font_family = args[0].sym
    }
    /* handle key-value pairs (skip args[0], it's the font family) */
    for i := 1; i+1 < len(args); i += 2 {
      if args[i].kind != .Str && args[i].kind != .Sym { continue }
      key := args[i].sym
      if key == "family" || key == "font" {
        if args[i+1].kind == .Str || args[i+1].kind == .Sym {
          bar_config.font_family = args[i+1].sym
        }
      }
      if key == "size" && args[i+1].kind == .Num {
        bar_config.font_size = int(args[i+1].num)
      }
    }
    return expr_sym("ok")

  case "bar.set-background":
    expect_min_args("bar.set-background", args, 1)
    for i := 0; i+1 < len(args); i += 2 {
      if args[i].kind != .Str { continue }
      key := args[i].sym
      if (key == "height" || key == "size") && args[i+1].kind == .Num {
        bar_config.height = int(args[i+1].num)
      }
      if key == "colour" || key == "color" {
        if args[i+1].kind == .Str { bar_config.bg_color = args[i+1].sym }
      }
      if key == "font-color" || key == "font-colour" {
        if args[i+1].kind == .Str { bar_config.font_color = args[i+1].sym }
      }
    }
    return expr_sym("ok")

  case "bar.systray", "bar.set-systray":
    if len(args) >= 1 && args[0].kind == .Bool {
      bar_config.systray = args[0].bool
    } else if len(args) == 0 {
      bar_config.systray = true
    }
    return expr_sym("ok")

  case "bar.set-logo", "bar.set-logo-nf":
    expect_args(name, args, 1)
    if args[0].kind == .Str || args[0].kind == .Sym {
      if args[0].kind == .Sym && args[0].sym == "distro" || args[0].kind == .Sym && args[0].sym == "distro-logo" {
        bar_config.logo = get_distro_logo()
      } else {
        bar_config.logo = args[0].sym
      }
    }
    return expr_sym("ok")

  case "bar.set-logo-size":
    expect_args(name, args, 1)
    if args[0].kind == .Num { bar_config.logo_size = int(args[0].num) }
    return expr_sym("ok")

  case "bar.set-widget-gap":
    expect_args(name, args, 1)
    if args[0].kind == .Num { bar_config.widget_gap = int(args[0].num) }
    return expr_sym("ok")

  case "bar.separator":
    if len(args) >= 1 && (args[0].kind == .Str || args[0].kind == .Sym) {
      bar_config.separator_text = args[0].sym
    }
    for i := 1; i+1 < len(args); i += 2 {
      if args[i].kind != .Str && args[i].kind != .Sym { continue }
      if (args[i].sym == "colour" || args[i].sym == "color") && (args[i+1].kind == .Str || args[i+1].kind == .Sym) {
        bar_config.separator_color = args[i+1].sym
      }
    }
    return expr_sym("ok")

  case "bar.wifi-icon":
    if len(args) >= 1 && args[0].kind == .Bool {
      bar_config.wifi_icon = args[0].bool
    }
    return expr_sym("ok")

  case "bar.set-format":
    expect_args("bar.set-format", args, 2)
    name_fmt := ""
    if args[0].kind == .Sym || args[0].kind == .Str { name_fmt = args[0].sym }
    fmt_str := ""
    if args[1].kind == .Str || args[1].kind == .Sym { fmt_str = args[1].sym }
    switch name_fmt {
    case "battery": bar_config.format_battery = fmt_str
    case "wifi":    bar_config.format_wifi = fmt_str
    }
    return expr_sym("ok")

  case "bar.set-left-vy":
    expect_args("bar.set-left-vy", args, 1)
    if args[0].kind == .Num { bar_config.left_vy = f64(args[0].num) }
    return expr_sym("ok")

  case "bar.set-center-vy":
    expect_args("bar.set-center-vy", args, 1)
    if args[0].kind == .Num { bar_config.center_vy = f64(args[0].num) }
    return expr_sym("ok")

  case "bar.set-right-vy":
    expect_args("bar.set-right-vy", args, 1)
    if args[0].kind == .Num { bar_config.right_vy = f64(args[0].num) }
    return expr_sym("ok")

  case "bar.start":
    expect_args("bar.start", args, 0)
    if !bar_ready { panic("bar.start requires (bar.create) first") }
    /* run the bar main loop */
    run_bar(&bar_config)
    return expr_sym("ok")
  }

  panic(fmt.aprintf("not a function: %s", name))
}

/* ── source name → DataSource ──────────────────────────────── */
source_from_name :: proc(name: string) -> DataSource {
  if len(name) > 0 && name[0] == '!' {
    return DataCmd{command = name[1:]}
  }
  switch name {
  case "clock":   return DataClock{}
  case "cpu":     return DataCpu{}
  case "memory":  return DataMemory{}
  case "battery": return DataBattery{}
  case "battery-state": return DataBatteryState{}
  case "distro":  return DataDistro{}
  case "distro-logo": return DataDistroLogo{name = get_distro_logo()}
  case "wifi":    return DataWifi{}
  case "volume":  return DataVolume{}
  }
  return DataCmd{command = name}
}

get_seg_format :: proc(name: string) -> string {
  switch name {
  case "battery": return bar_config.format_battery
  case "wifi":    return bar_config.format_wifi
  }
  return ""
}
