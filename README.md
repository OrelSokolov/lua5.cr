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

## Scope: luabind for Crystal, not a LuaJIT replacement

This project was created specifically for a game engine. It will **never
catch up to LuaJIT**, and that is by design: LuaJIT's speed comes from a
tight C core with manual memory control, while here every Lua value is a
Crystal object traced by the conservative Boehm GC — the collector is a
hard ceiling no amount of codegen work removes. LuaJIT numbers in the
table below are context, not a target.

Performance was planned at the level of the **original PUC Lua 5.1
interpreter** — that baseline is met (and somewhat exceeded on compute
kernels). The point of this integration is **luabind functionality**:
scripts calling Crystal classes directly over a shared GC and a shared
exception model. In a game engine that removes the extra C layers a
traditional binding stack needs (Crystal → C shim → Lua C API → Lua) —
engine code and script code talk to each other directly.

## ROADMAP: performance work

Measured 2026-11-07, Apple M5, `bench/results/` (min of 3 runs, same suite
as `rake benchmark:*`). References: PUC Lua 5.1.5 (C interpreter), LuaJIT 2.1
(C trace JIT), both re-measured the same day.

| bench | lua5.1, s | clua (Crystal JIT), s | LuaJIT, s | clua vs lua5.1 |
|---|---|---|---|---|
| nbody | 2.081 | 2.645 | 0.092 | 1.27× slower |
| spectral-norm | 6.520 | 3.105 | 0.165 | 2.10× faster |
| array3d | 3.542 | 3.442 | 0.071 | 1.03× faster |
| mandelbrot | 2.833 | 1.282 | 0.283 | 2.21× faster |
| fannkuch | 1.242 | 0.576 | 0.143 | 2.16× faster |
| recursive-fib | 1.866 | 1.049 | 0.139 | 1.78× faster |
| partialsums | 0.830 | 0.736 | 0.116 | 1.13× faster |
| binary-trees | 0.649 | 0.659 | 0.165 | ~par |
| nsieve | 0.881 | 0.398 | 0.136 | 2.21× faster |
| series | 0.400 | 0.404 | 0.115 | ~par |
| fasta | 1.565 | 2.517 | 0.562 | 1.61× slower |
| scimark-fft | 10.573 | 7.448 | 0.620 | 1.42× faster |

9 of 12 benches are at parity with or faster than PUC Lua 5.1 (session
start: 3 of 12; e.g. nbody 5.40→2.65s, mandelbrot 3.76→1.28s, array3d
5.89→3.44s, scimark-fft 12.95→7.45s).

What landed (see JIT.md §5, M3.2):

1. **IR optimization pipeline in ORC** (`LLVMRunPasses`, `default<O2>`):
   mem2reg/GVN/LICM over the generated IR. Critical prerequisite — the
   module now gets the host DataLayout/triple set *before* any pass runs;
   a bare context sizes `{i32,i64}` as 12 bytes (payload at +4) while
   codegen later stamps the arm64 layout (payload at +8), so running
   passes on an un-stamped module miscompiles every struct access.
2. **Inlined loop back-edge gates**: the per-iteration
   `jit_loopedge`/`jit_weakcheck` helper calls became inline loads — the
   upvalue-open check reads `Interp#open_max` directly, the weak check
   reads a static monotonic flag byte (`Lua.weak_seen_addr`).
3. **Direct JIT→JIT calls**: every condition `jit_call_dispatch` checks
   (closure tag, machine-code entry, arity, no coroutine/hooks, depth
   budget, stack window) is emitted as inline loads; the callee is called
   natively without the Crystal helper. Stack bookkeeping goes through
   JIT mirrors on Interp (`jit_stack_buf`/`jit_stack_cap`, maintained by
   `ensure_stack` — the single growth point).
4. **Flat string-key table + inlined identity probe**: `@strs : Hash` was
   replaced by a hand-rolled open-addressing table over interned keys
   (port of luaH's string part, fixed `SSlot` layout). GETTABLE/SETTABLE
   with a constant string key (tracked from LOADK through MOVE) and SELF
   emit the whole probe inline: compile-time home index, 3 slots, nil
   metatable guard — a field access costs ~6 loads, no runtime call.
5. **Loop-carried SSA for numeric-for controls**: ctrl/limit/step live in
   phi nodes across the loop instead of being reloaded from value-stack
   slots every FORLOOP iteration (two-level phi: loop head + FORLOOP
   merge; OSR entries feed the head phis through raw-load blocks).
   Innermost loops only — an OSR entry into a nested loop head bypasses
   the enclosing head, whose phi would then read a stale register
   (dominance violation, caught by module verification).

Remaining costs, in impact order:

1. **GC/allocation-bound benches** (fasta 1.61×, binary-trees ~par) — the
   conservative Boehm GC is the hard ceiling; needs a precise GC, out of
   scope for this phase.
2. **nbody 1.27×** — remaining per-iteration guard traffic on numeric
   loops: non-innermost loops keep their slot reloads (see 5. above), and
   loop bodies with helper calls still reload operands after every call.
3. **Values still round-trip through stack slots at loop boundaries**
   (deopt-anywhere invariant); register allocation + snapshot deopt would
   lift numeric kernels further.

### Targets

The goal is **5× faster than PUC Lua 5.1** on compute kernels (DoD of
phase 5 in PLAN.md). Current status vs that goal:

| Category | Now | Realistic ceiling |
|---|---|---|
| Numeric kernels, no tables | 2.1–2.2× vs lua5.1 | 5–8× |
| Table-heavy (array3d, nbody) | 1.03–1.27× | 4–6× |
| Call-heavy (recursive-fib) | 1.8× | 6–8× |
| GC-bound (fasta, binary-trees) | ~par–1.61× | 2.5–3.5× (Boehm ceiling) |

### Work plan (effort/impact order)

1. **Type feedback + guard elimination** (M3 remainder) — guards only at
   region/loop entry; extend loop phis to non-innermost loops (needs
   phis at every merge point, i.e. partial SSA construction).
2. **Keep values in registers between instructions + snapshot-based
   deopt** — slots-as-truth is a deopt-simplicity choice, not a GC
   requirement.
3. **Hot-call inlining** (M5) — direct calls are in place; inlining the
   bodies is the next step.
4. GC-bound benches only move meaningfully with a precise GC — out of
   scope for this phase.

## Design notes

- Strings are byte arrays (all string ops are byte-wise), numbers are doubles
  printed with `%.14g` — 5.1 semantics.
- Lua errors are Crystal exceptions (`Lua::LuaError` carrying the error
  *value* — `error(table)` reaches `pcall` as the same table).
- Not yet implemented features raise loud errors, never silently degrade.
