package main

import "core:fmt"

ExprKind :: enum u8 {
  Num,
  Sym,
  Bool,
  Str,
  List,
  Lambda,
}

Lambda :: struct {
  params: [dynamic]string,
  body:   ^Expr,
}

Expr :: struct {
  kind:   ExprKind,
  num:    i64,
  sym:    string,
  bool:   bool,
  list:   [dynamic]Expr,
  lambda: Lambda,
}

expr_num :: proc(n: i64) -> Expr {
  return Expr{kind = .Num, num = n}
}

expr_sym :: proc(s: string) -> Expr {
  return Expr{kind = .Sym, sym = s}
}

expr_str :: proc(s: string) -> Expr {
  return Expr{kind = .Str, sym = s}
}

expr_bool :: proc(b: bool) -> Expr {
  return Expr{kind = .Bool, bool = b}
}

expr_list :: proc(items: ..Expr) -> Expr {
  e := Expr{kind = .List}
  for item in items { append(&e.list, item) }
  return e
}

expr_cons :: proc(car: Expr, cdr: Expr) -> Expr {
  e := Expr{kind = .List}
  append(&e.list, car)
  if cdr.kind == .List {
    for item in cdr.list { append(&e.list, item) }
  } else {
    append(&e.list, cdr)
  }
  return e
}

expr_lambda :: proc(params: [dynamic]string, body: Expr) -> Expr {
  bp := new(Expr)
  bp^ = body
  return Expr{kind = .Lambda, lambda = Lambda{params = params, body = bp}}
}

string_of_expr :: proc(e: ^Expr) -> string {
  switch e.kind {
  case .Num: return fmt_int(e.num)
  case .Sym: return e.sym
  case .Str: return fmt.aprintf("\"%s\"", e.sym)
  case .Bool: return "#t" if e.bool else "#f"
  case .List:
    s: string = "("
    for i in 0 ..< len(e.list) {
      if i > 0 { s = fmt.aprintf("%s ", s) }
      s = fmt.aprintf("%s%s", s, string_of_expr(&e.list[i]))
    }
    return fmt.aprintf("%s)", s)
  case .Lambda: return "#<lambda>"
  }
  return "?"
}

fmt_int :: proc(n: i64) -> string {
  buf: [32]byte
  i := len(buf) - 1
  neg := n < 0
  v := n if !neg else -n
  if v == 0 { buf[i] = '0'; i -= 1 }
  for v > 0 {
    buf[i] = byte('0' + v % 10)
    v /= 10
    i -= 1
  }
  if neg { buf[i] = '-'; i -= 1 }
  return string(buf[i+1:])
}
