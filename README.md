# lua5.cr - luabind layer for crystal with Lua interpreter itself

Lua 5.1 interpreter written entirely in Crystal — a module-by-module port of
[MoonSharp](https://github.com/moonsharp-devs/moonsharp) (C#). No native Lua,
no C API, no FFI boundary.

The end goal is not "yet another Lua": it is a **luabind for Crystal
objects**. Scripts call Crystal classes directly, with a shared GC and a
shared exception model — the class of bugs that C-API bindings produce
(SIGSEGV in `strcmp` when a script passes `nil` where a string was expected)
is impossible by construction.

See **PLAN.md** for the roadmap (phases: MVP → full 5.1/LuaJIT compat →
bytecode VM → full interop layer → optional JIT) and the MoonSharp module
mapping.

## Status

- Full Lua 5.1 lexer + parser (plus LuaJIT `\x`/`\z` escapes), including the
  `ambiguous syntax` guard Lua itself has.
- Tree-walking interpreter (the same first stage MoonSharp had):
  closures/upvalues, varargs, multiple returns/assignments, **proper tail
  calls**, full metatable dispatch (`__index`/`__newindex` chains, arithmetic,
  `__concat`, `__eq`, `__lt`/`__le` with the 5.1 fallback, `__call`,
  `__tostring`, `__len`, `__unm`, protected metatables).
- Standard library: base (pcall/xpcall/error levels, select/unpack,
  next/pairs/ipairs, setmetatable, loadstring…), math, table, os, io,
  and string — including a faithful port of the lstrlib pattern engine
  (classes, quantifiers, `%b`, `%f` frontiers, backrefs, position/empty
  captures, find/match/gmatch/gsub, plain mode) and `string.format`.
- Full **debug library**: getinfo/getlocal/setlocal, upvalue access,
  traceback (of coroutines too), and **hooks** — `debug.sethook/gethook`
  with line/call/return/count events, per coroutine; level walks count
  native (C) frames and lost tail calls (`what="tail"`) like Lua 5.1.
- Bytecode VM with proper tail calls and coroutines (own stacks, yield
  semantics of 5.1); weak tables and `__gc` over a precise Lua-graph mark.
- Interop: `@[LuaMethod]` annotation + `expose Klass` macro + userdata
  wrappers; constructors, inheritance and overloads included.

## Usage

```crystal
require "lua5"

interp = Lua::Interp.new
interp.run("print('hello')")        # hello
Lua.eval("1 + 2")                   # => 3.0
```

Expose Crystal objects (no C boundary — methods get Crystal values and
raise/return Crystal values):

```crystal
class Task
  @[LuaMethod]
  def bump(amount : Int32) : Int32
    @priority += amount
  end
end

expose Task

interp = Lua::Interp.new
interp.expose_object("task", Task.new("write docs", 1))
interp.run("task:bump(41)")         # mutates the Crystal object in place
```

CLI:

```
crystal build src/cli.cr -o bin/lua5
bin/lua5 script.lua
```

## Tests

```
crystal spec          # unit specs + interop + conformance/*.lua runner
crystal run examples/interop_demo.cr
```

## ROADMAP: closing the JIT performance gap

Measured 2026-11-07, Apple M5, `bench/results/` (min of 3 runs, same suite
as `rake benchmark:*`). References: PUC Lua 5.1.5 (C interpreter), LuaJIT 2.1
(C trace JIT).

| bench | lua5.1, s | clua (Crystal JIT), s | LuaJIT, s | clua vs lua5.1 |
|---|---|---|---|---|
| nbody | 3.24 | 10.12 | 0.157 | 3.1× slower |
| spectral-norm | 9.69 | 12.59 | 0.255 | 1.3× slower |
| array3d | 5.32 | 11.80 | 0.111 | 2.2× slower |
| mandelbrot | 4.20 | 6.98 | 0.427 | 1.7× slower |
| fannkuch | 1.77 | 3.46 | 0.204 | 2.0× slower |
| recursive-fib | 2.76 | 2.25 | 0.206 | 1.2× faster |
| partialsums | 1.30 | 1.72 | 0.156 | 1.3× slower |
| binary-trees | 0.92 | 1.20 | 0.25 | 1.3× slower |
| fasta | 2.48 | 4.54 | 0.874 | 1.8× slower |

Today the JIT is a "compiler-shaped interpreter": it removes the dispatch
switch but keeps everything else. The known costs, in impact order:

1. **Values live in stack slots, not registers.** Every instruction loads
   its 16-byte union operands from the shared value stack and stores the
   result back (GC invariant 1.3 in JIT.md). LuaJIT keeps loop variables in
   FP registers for the whole trace.
2. **A tag guard on every operand of every arithmetic op** — no type
   feedback yet (M3), so redundant guards are never eliminated.
3. **LLVM ORC runs with no IR optimization pipeline** — the default
   transform is a no-op, so the scratch/cur_stack/cur_top allocas stay in
   memory (no mem2reg, GVN, LICM).
4. **GETTABLE/SETTABLE/SELF always call a Crystal helper** — bounds-checked
   array indexing plus a hash lookup per access, no inline caches.
5. **Every CALL goes through the `jit_dispatch_call` helper** — no direct
   JIT→JIT machine calls, no hot-call inlining (M4/M5).
6. **A helper call on every loop back-edge** (`jit_loopedge`/`jit_weakcheck`).
7. The Crystal runtime itself is slower than C (bounds-checked arrays,
   conservative Boehm GC, 16-byte values vs LuaJIT's 8-byte NaN-boxing).

### Targets

The goal is **5× faster than PUC Lua 5.1** on compute kernels. This is
achievable — it means landing within 2–4× of LuaJIT, which the architecture
allows. Per category:

| Category | Now | Realistic ceiling (full M3–M5) |
|---|---|---|
| Numeric kernels, no tables | 1.6× over own interpreter | **5–8× vs lua5.1** |
| Table-heavy (array3d, nbody) | 2–3× slower than lua5.1 | **4–6× vs lua5.1** |
| Call-heavy (recursive-fib) | 1.2× faster | **6–8× vs lua5.1** |
| GC/allocation-bound (fasta, binary-trees) | 1.3–1.8× slower | **2.5–3.5× vs lua5.1** |

The GC-bound category has a hard ceiling: LuaJIT itself is only 2.8–3.7×
faster than lua5.1 there, so 5× would mean outperforming LuaJIT — blocked
by Boehm (conservative, no precise incremental collection; NaN-boxing is
impossible because a pointer in the NaN pattern is invisible to the
conservative scanner). Geomean over the whole suite: ~3–4× vs lua5.1
realistic, 5× borderline.

### Work plan (effort/impact order)

1. **Enable an IR optimization pipeline in ORC** (`IRTransformLayer` with
   -O2) — near-free, removes the scratch-alloca traffic.
2. **Keep values in registers between instructions + snapshot-based
   deopt** — Boehm scans registers conservatively, so references in
   registers are already visible; slots-as-truth is a deopt-simplicity
   choice, not a GC requirement. Largest single win on numeric kernels.
3. **Type feedback + guard elimination** (M3) — guards only at region/loop
   entry.
4. **Inline caches for GETTABLE/SETTABLE + array-part fast path** — hits
   the worst gaps (array3d, nbody at 64–106× vs LuaJIT).
5. **Direct JIT→JIT calls, hot-call inlining** (M4/M5); drop the per-iteration
   `loopedge`/`weakcheck` helpers.
6. GC-bound benches only move meaningfully with a precise GC — out of
   scope for this phase.

## Design notes

- Strings are byte arrays (all string ops are byte-wise), numbers are doubles
  printed with `%.14g` — 5.1 semantics.
- Lua errors are Crystal exceptions (`Lua::LuaError` carrying the error
  *value* — `error(table)` reaches `pcall` as the same table).
- Not yet implemented features raise loud errors, never silently degrade.
