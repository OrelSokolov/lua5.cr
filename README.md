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

## Status (Phase 1 — MVP)

- Full Lua 5.1 lexer + parser (plus LuaJIT `\x`/`\z` escapes), including the
  `ambiguous syntax` guard Lua itself has.
- Tree-walking interpreter (the same first stage MoonSharp had):
  closures/upvalues, varargs, multiple returns/assignments, **proper tail
  calls**, full metatable dispatch (`__index`/`__newindex` chains, arithmetic,
  `__concat`, `__eq`, `__lt`/`__le` with the 5.1 fallback, `__call`,
  `__tostring`, `__len`, `__unm`, protected metatables).
- Standard library: base (pcall/xpcall/error levels, select/unpack,
  next/pairs/ipairs, setmetatable, loadstring…), math, table, os (minimal),
  and string — including a faithful port of the lstrlib pattern engine
  (classes, quantifiers, `%b`, `%f` frontiers, backrefs, position/empty
  captures, find/match/gmatch/gsub, plain mode) and `string.format`.
- Interop MVP: `@[LuaMethod]` annotation + `expose Klass` macro + userdata
  wrappers. Constructors, inheritance and overloads → Phase 4.
- Coroutines, io/debug libs, require → Phase 2/3 (they fail loudly, not
  silently).

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

## Design notes

- Strings are byte arrays (all string ops are byte-wise), numbers are doubles
  printed with `%.14g` — 5.1 semantics.
- Lua errors are Crystal exceptions (`Lua::LuaError` carrying the error
  *value* — `error(table)` reaches `pcall` as the same table).
- Not yet implemented features raise loud errors, never silently degrade.
