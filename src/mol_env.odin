package main

/* ================================================================
 * mol_env.odin — equivalent of env.ml
 *
 * Environment is a linked list of (name, expr) bindings.
 * ================================================================ */

Env :: struct {
  name:  string,
  value: Expr,
  next:  ^Env,
}

empty_env :: proc() -> ^Env {
  return nil
}

extend_env :: proc(env: ^Env, name: string, value: Expr) -> ^Env {
  e := new(Env)
  e^ = Env{name = name, value = value, next = env}
  return e
}

lookup_env :: proc(env: ^Env, name: string) -> (Expr, bool) {
  for e := env; e != nil; e = e.next {
    if e.name == name { return e.value, true }
  }
  return {}, false
}
