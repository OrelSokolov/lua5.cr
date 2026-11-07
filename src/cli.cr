# CLI: run a Lua file. Usage: bin/lua5 script.lua [script-args...]
# Script-args are exposed as the global `arg` table (arg[0] = script path,
# arg[1..] = args) — the same convention as lua/luajit CLIs (benchmarks
# from LuaJIT-test-cleanup read their sizes from arg[1]).
require "./lua5"

# Boehm collection-frequency knob not exposed by Crystal's LibGC bindings
# (see below for why it matters).
@[Link("gc")]
private lib LibGC
  fun set_free_space_divisor = GC_set_free_space_divisor(divisor : UInt32)
end

unless path = ARGV[0]?
  STDERR.puts "usage: lua5 script.lua [args...]"
  exit 1
end

interp = Lua::Interp.new

# Boehm collects when free heap drops below live*divisor: short-lived
# interpreter garbage (call buffers, strings) makes the default (1)
# trigger constant stop-the-world marks. A roomier divisor trades some
# RSS for far fewer collections — process-level CLI policy, library
# embedding keeps Boehm defaults. Override with LUA5_GC_DIVISOR=1.
if d = ENV["LUA5_GC_DIVISOR"]?.try(&.to_i?)
  LibGC.set_free_space_divisor(d.to_u32) unless d < 1
else
  LibGC.set_free_space_divisor(4)
end

argt = Lua::LuaTable.new
argt.raw_set(0.0, path)
ARGV[1..].each_with_index { |a, i| argt.raw_set((i + 1).to_f64, a) }
interp.globals.raw_set("arg", argt)

begin
  # 5.1: file chunks are named "@path" (short_src/error positions)
  interp.run(File.read(path), "@#{path}")
rescue e : Lua::LuaError
  STDERR.puts "lua5: #{e.message}"
  exit 1
rescue e : Lua::SyntaxError
  STDERR.puts "lua5: #{e.message}"
  exit 1
end
