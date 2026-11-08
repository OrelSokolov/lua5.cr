# Engine-compatibility regressions: every fix here was surfaced by the
# VibeRay lua_run corpus (oracles/phase4/lua_run.vbc — pure-Lua gamedata
# scripts replayed against the xray engine's xrLuaJIT.so) and is pinned
# to a script that broke without it.
require "../src/lua5"
require "spec"

describe "engine LuaJIT compat" do
  it "short_src follows lj_debug_shortname" do
    # single line <= 48 chars: full; head kept (<= 45) + "..." past the limit
    Lua.short_src("a" * 42).should eq %([string "#{("a" * 42)}"])
    Lua.short_src("b" * 50).should eq %([string "#{"b" * 45}..."])
  end

  it "accepts xray C-style comments (// and /* */)" do
    i = Lua::Interp.new
    i.run("// line comment\nlocal x = 1 /* block\ncomment */\nreturn x", "t")[0].should eq 1
  end

  it "bytes >= 0x80 are identifier chars (lj_char LJ_CHAR_IDENT)" do
    # "copy of _test.script": cp1251 "Привет" on line 1 lexes as a NAME,
    # so the parser reaches line 2 and reports the assignment problem
    # there — LuaJIT: 2: '=' expected near 'sss'
    i = Lua::Interp.new
    i.compile("\xEF\xF0\xE8\xE2\xE5\xF2\r\nsss = 1\r\n", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain ":2: '=' expected near 'sss'"
  end

  it "non-call statement reports '=' expected at the offending token" do
    # mob_alife_control.script:43-44 — bare index expression followed by
    # the next statement
    i = Lua::Interp.new
    i.compile("a.b[\"x\"]\nc.d = 1", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain ":2: '=' expected near 'c'"
  end

  it "two names in a row report '=' expected at the second (lua_help)" do
    # lua_help.script:1 — "List of the classes exported to LUA"
    i = Lua::Interp.new
    i.compile("List of the classes", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain ":1: '=' expected near 'of'"
  end

  it "':'/'.' followed by a non-name reports '<name>' expected" do
    # test_ini.script:11-13 — trailing ':' at end of line, next token '.'
    i = Lua::Interp.new
    i.compile("self.object:spawn_ini():\n\n.def(\"x\")", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain ":3: '<name>' expected near '.'"
  end

  it "lexer errors do not preempt earlier syntax errors (streaming order)" do
    # gulag_radar_u.script (a .ltx picked up as a script): leading ';' is
    # an invalid statement start in 5.1 (LuaJIT handles it only under
    # LJ_52); the parser must stop at line 1, not trip on the '@' at
    # line 4 that a lex-ahead pass would hit first
    i = Lua::Interp.new
    i.compile(";-----\r\n;-- RADAR\r\n;-----\r\n[logic@rad_alarm]\r\n", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain ":1: unexpected symbol near ';'"
  end

  it "registers the jit global like LuaJIT's baseline stdlib" do
    i = Lua::Interp.new
    r = i.run("return type(jit), jit.version", "t")
    r[0].should eq "table"
    r[1].should eq "LuaJIT 2.1.0-beta3"
    # _g.script: `if (jit == nil) then profiler.setup_hook() end`
    i.run("return jit == nil", "t")[0].should be_false
  end

  it "has no implicit `arg` in vararg functions (no LUA_COMPAT_VARARG)" do
    i = Lua::Interp.new
    # bug7.script: tbl.func(unpack(arg)) must error, not silently call
    r = i.run("local f = function(...) return type(arg) end; return f()", "t")
    r[0].should eq "nil"
  end

  it "unpack(nil) raises with the called name" do
    i = Lua::Interp.new
    i.run("local t = unpack(nil)", "t")
    fail "expected error"
  rescue ex : Lua::LuaError
    ex.message.to_s.should contain "bad argument #1 to 'unpack' (table expected, got nil)"
  end

  it "gfind arg errors carry 'gfind', not 'gmatch'" do
    i = Lua::Interp.new
    i.run("string.gfind(nil, 'x')", "t")
    fail "expected error"
  rescue ex : Lua::LuaError
    ex.message.to_s.should contain "bad argument #1 to 'gfind'"
  end

  it "'for' limit message matches LuaJIT" do
    i = Lua::Interp.new
    i.run("for i = 1, nil do end", "t")
    fail "expected error"
  rescue ex : Lua::LuaError
    ex.message.to_s.should contain "'for' limit must be a number"
  end

  it "'table index is nil' carries the faulting position" do
    i = Lua::Interp.new
    i.run("local t = {}\n\nt[nil] = 1", "t")
    fail "expected error"
  rescue ex : Lua::LuaError
    ex.message.to_s.should contain ":3: table index is nil"
  end

  it "assignment evaluates the lhs index chain before the rhs" do
    i = Lua::Interp.new
    i.run("local function boom() error('rhs') end\ndb.storage[1] = boom()", "t")
    fail "expected error"
  rescue ex : Lua::LuaError
    # dialogs.script:246 — the 'db' index error must fire before the rhs
    ex.message.to_s.should contain "attempt to index global 'db'"
    ex.message.to_s.should_not contain "rhs"
  end

  it "rejects invalid escapes with the LuaJIT token" do
    i = Lua::Interp.new
    # Lua source: local ini_path = "\scripts\\" .. work  (gulag_general.script:888)
    i.compile("local ini_path = \"\\scripts\\\\\" .. work", "t")
    fail "expected SyntaxError"
  rescue ex : Lua::SyntaxError
    ex.message.to_s.should contain %(invalid escape sequence near '"')
  end

  it "math.random reproduces the engine's fixed-seed TW223 stream" do
    i = Lua::Interp.new
    # probed from the engine build (three runs, identical):
    # first draw 0.79420629243124, second draw random(100) = 70
    r = i.run("return math.random(), math.random(100)", "t")
    r[0].as(Float64).should be_close(0.79420629243124, 1e-13)
    r[1].as(Float64).should eq 70
  end

  it "math.random has no interval validation (xray lib_math.c)" do
    i = Lua::Interp.new
    i.run("return math.random(1, 0)", "t")[0].should eq 1
    i2 = Lua::Interp.new
    i2.run("return math.random(5, 5)", "t")[0].should eq 5
  end
end
