package main

/* ================================================================
 * c_lib.odin — shared C standard library declarations
 *
 * All files in this package share these foreign declarations.
 * ================================================================ */

@(default_calling_convention="c")
foreign _ {
  fopen   :: proc(path: cstring, mode: cstring) -> rawptr ---
  fclose  :: proc(f: rawptr) -> i32 ---
  fread   :: proc(buf: rawptr, sz: u64, n: u64, f: rawptr) -> u64 ---
  fgets   :: proc(buf: [^]byte, n: i32, f: rawptr) -> rawptr ---
  popen   :: proc(cmd: cstring, mode: cstring) -> rawptr ---
  pclose  :: proc(f: rawptr) -> i32 ---
  snprintf :: proc(buf: [^]byte, sz: u64, fmt: cstring, #c_vararg args: ..any) -> i32 ---
  time    :: proc(t: rawptr) -> i64 ---
  localtime_r :: proc(t: ^i64, result: rawptr) -> rawptr ---
  poll    :: proc(fds: rawptr, nfds: u64, timeout: i32) -> i32 ---
  system  :: proc(cmd: cstring) -> i32 ---
}

POLLIN :: 1

PollFd :: struct {
  fd:      i32,
  events:  i16,
  revents: i16,
}

Buf256  :: [256]byte
Buf512  :: [512]byte
Buf4096 :: [4096]byte
