package main

import "core:fmt"

TokenKind :: enum u8 {
  LParen,
  RParen,
  String,
  Symbol,
}

Token :: struct {
  kind:  TokenKind,
  start: int,
  end:   int,
}

tokenize :: proc(s: string, allocator := context.allocator) -> ([]Token, bool) {
  tokens := make([dynamic]Token, allocator)
  i := 0
  for i < len(s) {
    c := s[i]
    if c == '(' || c == ')' {
      append(&tokens, Token{kind = .LParen if c == '(' else .RParen, start = i, end = i + 1})
      i += 1
    } else if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i += 1
    } else if c == '"' {
      j := i + 1
      for j < len(s) && s[j] != '"' { j += 1 }
      if j < len(s) { j += 1 }
      append(&tokens, Token{kind = .String, start = i, end = j})
      i = j
    } else if c == ';' {
      for i < len(s) && s[i] != '\n' { i += 1 }
    } else if c == '/' && i + 1 < len(s) && s[i + 1] == '*' {
      i += 2
      for i + 1 < len(s) && !(s[i] == '*' && s[i + 1] == '/') { i += 1 }
      if i < len(s) { i += 2 }
    } else if c == '!' && i + 1 < len(s) && s[i + 1] == '"' {
      j := i + 2
      for j < len(s) && s[j] != '"' { j += 1 }
      if j < len(s) { j += 1 }
      append(&tokens, Token{kind = .Symbol, start = i, end = j})
      i = j
    } else {
      j := i + 1
      for j < len(s) && s[j] != ' ' && s[j] != '(' && s[j] != ')' && s[j] != '\t' && s[j] != '\n' && s[j] != '\r' && s[j] != ';' {
        j += 1
      }
      append(&tokens, Token{kind = .Symbol, start = i, end = j})
      i = j
    }
  }
  return tokens[:], true
}

parse_error :: proc(msg: string) -> ! {
  panic(msg)
}

parse_tokens :: proc(s: string, tokens: []Token, pos: ^int) -> Expr {
  if pos^ >= len(tokens) { parse_error("unexpected EOF") }

  t := tokens[pos^]
  pos^ += 1

  switch t.kind {
  case .LParen:
    return parse_list(s, tokens, pos)
  case .RParen:
    parse_error("unexpected ')'")
  case .String, .Symbol:
    return atom(s[t.start:t.end])
  }
  unreachable()
}

parse_list :: proc(s: string, tokens: []Token, pos: ^int) -> Expr {
  e := Expr{kind = .List}

  for pos^ < len(tokens) && tokens[pos^].kind != .RParen {
    append(&e.list, parse_tokens(s, tokens, pos))
  }

  if pos^ >= len(tokens) { parse_error("unclosed paren") }
  pos^ += 1

  return e
}

atom :: proc(s: string) -> Expr {
  if s == "#t" { return expr_bool(true) }
  if s == "#f" { return expr_bool(false) }
  if len(s) > 2 && s[0] == '!' && s[1] == '"' && s[len(s)-1] == '"' {
    return expr_sym(fmt.aprintf("!%s", s[2:len(s)-1]))
  }
  if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
    return expr_str(s[1:len(s)-1])
  }
  n: i64
  ok := false
  if len(s) > 0 {
    start := 0
    neg := false
    if s[0] == '-' { neg = true; start = 1 }
    if start < len(s) {
      v: i64 = 0
      valid := true
      for i := start; i < len(s); i += 1 {
        if s[i] >= '0' && s[i] <= '9' {
          v = v * 10 + i64(s[i] - '0')
        } else {
          valid = false
          break
        }
      }
      if valid {
        n = -v if neg else v
        ok = true
      }
    }
  }
  if ok { return expr_num(n) }
  return expr_sym(s)
}

parse :: proc(s: string) -> Expr {
  tokens, ok := tokenize(s)
  if !ok { parse_error("tokenization failed") }
  pos: int
  result := parse_tokens(s, tokens, &pos)
  for pos < len(tokens) {
    if tokens[pos].kind != .RParen && tokens[pos].kind != .LParen {
      parse_error("trailing tokens")
    }
    pos += 1
  }
  return result
}

parse_all :: proc(s: string) -> [dynamic]Expr {
  tokens, ok := tokenize(s)
  if !ok { return [dynamic]Expr{} }
  result: [dynamic]Expr
  pos: int
  for pos < len(tokens) {
    append(&result, parse_tokens(s, tokens, &pos))
  }
  return result
}
