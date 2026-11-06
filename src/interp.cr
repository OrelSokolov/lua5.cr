# Runtime: metatable dispatch and native-call plumbing. Port of MoonSharp
# Runtime/. Execution itself lives in vm.cr (bytecode VM); this file keeps
# the shared runtime operations the VM, stdlib and interop all use.
module Lua
  # Raised by coroutine.yield to unwind to the resume boundary, carrying the
  # yielded values. Never a LuaError, so pcall/err handlers do not catch it;
  # the CALL/TAILCALL handlers in the VM intercept it (vm.cr) and stash the
  # suspended context for the next resume.
  class YieldSignal < Exception
    getter values : Array(LuaValue)

    def initialize(@values)
      super("yield")
    end
  end

  class Interp
    property globals : LuaTable
    getter string_lib : LuaTable
    getter string_meta : LuaTable
    property rng : Random = Random.new
    property chunkname : String = "chunk"
    property line : Int32 = 0
    # Index of the faulting instruction, set by the VM slow paths alongside
    # @line (ldebug.c); -1 = the error did not originate in bytecode.
    property vi_pc : Int32 = -1
    # xpcall message handler (5.1 L->errfunc): run once, at the raise point,
    # while the frames are still up so tracebacks see the raising stack.
    property err_handler : LuaValue = nil
    # Thread-global environment (5.1 setfenv(0, t)): default env for chunks
    # compiled while it is set; nil = the interpreter's globals table.
    property default_env : LuaTable? = nil
    # debug.setmetatable registry: metatables for primitive types ("number",
    # "boolean", "nil", "function", "thread", "userdata" fallback)
    property type_mts = Hash(String, LuaTable?).new

    def initialize
      @globals = LuaTable.new
      @string_lib = LuaTable.new
      @string_meta = LuaTable.new
      @string_meta.raw_set("__index", @string_lib)
      Stdlib::Base.install(self)
      Stdlib::MathLib.install(self)
      Stdlib::TableLib.install(self)
      Stdlib::StringLib.install(self)
      Stdlib::OsLib.install(self)
      Stdlib::OsLib.install(self)
      Stdlib::IoLib.install(self)
      Stdlib::Coroutine.install(self)
      Stdlib::DebugLib.install(self)
      Stdlib::PackageLib.install(self)
    end

    # --- entry points ---

    # Compile a chunk into a callable closure. The chunk's environment is
    # the thread-global env (5.1: what setfenv(0, t) changes).
    def compile(src : String, chunkname : String = "chunk") : LuaClosure
      @chunkname = chunkname
      block = Parser.new(Lexer.new(src, chunkname).tokens, chunkname).parse_chunk
      proto = Compiler.new(chunkname, src).compile_main(block)
      cl = LuaClosure.new(proto, [] of UpValue)
      cl.env = @default_env
      cl
    end

    # Run a chunk; returns its `return` values.
    def run(src : String, chunkname : String = "chunk") : Array(LuaValue)
      call(compile(src, chunkname), [] of LuaValue)
    end

    # Convenience for specs/tools: evaluate a single expression.
    def self.eval(src : String) : LuaValue
      new.run("return #{src}", "spec")[0]?
    end

    def native(name : String, &fn : NativeFn)
      @globals.raw_set(name, LuaFunction.new(name, fn))
    end

    # The closure `level` VM frames out from a native call (1 = the Lua
    # function that called the native, 2 = its caller, ...). For setfenv/
    # getfenv level semantics and debug.getinfo.
    def caller_closure(level : Int32) : LuaClosure?
      return nil if level < 1
      idx = @fsize - level
      return nil if idx < 0 || idx >= @fsize
      @frames[idx]?.try &.closure
    end

    # --- error helpers ---

    def raise_lua(msg : String)
      # position info from the running frame: a chunk loaded by loadstring
      # must not inherit the outer chunk's name (5.1 addinfo)
      if @fsize > 0
        cn = @frames[@fsize - 1].closure.proto.chunkname
        raise LuaError.new("#{Lua.short_src(cn)}:#{@line}: #{msg}")
      end
      raise LuaError.new("#{Lua.short_src(@chunkname)}:#{@line}: #{msg}")
    end

    # Chunkname of the running frame (5.1 addinfo), falling back to the
    # interpreter-level chunkname outside any frame.
    def cur_chunkname : String
      @fsize > 0 ? @frames[@fsize - 1].closure.proto.chunkname : @chunkname
    end

    # Roots for the Lua-graph mark phase (Lua.gc_full): everything the
    # interpreter itself holds. Stale VM registers must be cleared
    # beforehand (gc_clear_stale) — they are not roots.
    def gc_roots(&) : Nil
      yield @globals
      yield @string_meta
      @type_mts.each_value { |mt| yield mt if mt }
      yield @io_input
      yield @io_output
      yield @err_handler
      yield @default_env
      yield @current_co
      i = 0
      while i < @fsize
        fr = @frames[i]
        yield fr.closure
        fr.varargs.each { |v| yield v }
        i += 1
      end
      @stack.each { |v| yield v }
    end

    # PUC protects VM-stack slots only up to each frame's live window
    # (ci->top / L->top); everything above is junk that must not pin
    # objects for the conservative Boehm scan. The live window of every
    # non-top frame is capped by its callee's base, so one clear from
    # the TOP frame's limit to the stack end covers all junk. With
    # call_site the limit is the pending CALL's argument window (the
    # ci->top analog); otherwise the frame's full register window.
    def gc_clear_stale(call_site : Bool) : Nil
      return if @fsize == 0
      fr = @frames[@fsize - 1]
      limit : Int32
      if call_site
        ins = fr.closure.proto.code[{fr.pc - 1, 0}.max]?
        if ins && ins.op.call?
          limit = ins.b == -1 ? fr.top : fr.base + ins.a + ins.b + 1
        else
          limit = fr.top
        end
      else
        limit = fr.base + fr.closure.proto.max_stack
      end
      i = {limit, 0}.max
      while i < @stack.size
        @stack[i] = nil
        i += 1
      end
    end

    # Line for an error() position: level 1 = where error() was called
    # (the current frame), level 2 = its caller, ...
    def err_line(level : Int32) : Int32
      idx = @fsize - {level, 1}.max
      return @line if idx < 0
      fr = @frames[idx]
      fr.closure.proto.lines[{fr.pc - 1, 0}.max]? || @line
    end

    def arg_error(idx : Int32, fname : String, expected : String)
      raise_lua("bad argument ##{idx} to '#{fname}' (#{expected})")
    end

    # --- argument coercion helpers for native libs ---

    def num!(args : Array(LuaValue), idx : Int32, fname : String) : Float64
      v = args[idx]?
      if n = Lua.tonumber(v)
        n
      else
        arg_error(idx + 1, fname, "number expected, got #{Lua.type_name(v)}")
      end
    end

    def str!(args : Array(LuaValue), idx : Int32, fname : String) : String
      v = args[idx]?
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      else
        arg_error(idx + 1, fname, "string expected, got #{Lua.type_name(v)}")
      end
    end

    def table!(args : Array(LuaValue), idx : Int32, fname : String) : LuaTable
      v = args[idx]?
      if v.is_a?(LuaTable)
        v
      else
        arg_error(idx + 1, fname, "table expected, got #{Lua.type_name(v)}")
      end
    end

    def func!(args : Array(LuaValue), idx : Int32, fname : String) : LuaValue
      v = args[idx]?
      if v.is_a?(LuaClosure) || v.is_a?(LuaFunction) || (v.is_a?(LuaTable) && metafield(v, "__call")) || (v.is_a?(LuaUserData) && metafield(v, "__call"))
        v
      else
        arg_error(idx + 1, fname, "function expected, got #{Lua.type_name(v)}")
      end
    end

    # --- number parsing/formatting (5.1: numbers are doubles) ---

    def lua_tostring(v : LuaValue) : String
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      when Nil     then "nil"
      when Bool    then v.to_s
      when LuaTable, LuaUserData
        if mm = metafield(v, "__tostring")
          r = call(mm, [v] of LuaValue)[0]?
          unless r.is_a?(String)
            raise_lua("'__tostring' must return a string")
          end
          r
        else
          Lua.repr_addr(v)
        end
      else
        Lua.repr_addr(v)
      end
    end

    # Base-library tostring (luaB_tostring): 5.1 returns the __tostring
    # result AS-IS (nil included) — only print/concat/format go through
    # luaL_tolstring and its type check.
    def tostring_value(v : LuaValue) : LuaValue
      case v
      when LuaTable, LuaUserData
        if mm = metafield(v, "__tostring")
          call(mm, [v] of LuaValue)[0]?
        else
          Lua.repr_addr(v)
        end
      else
        lua_tostring(v)
      end
    end

    # --- calls ---

    # Call any callable value; returns all results. Closures run in the
    # bytecode VM (vm.cr), which handles tail calls without growing the
    # Crystal stack. @call_depth marks the Crystal frame for coroutine
    # yield-legality checks (see yield_co).
    def call(f : LuaValue, args : Array(LuaValue)) : Array(LuaValue)
      @call_depth += 1
      begin
        case f
        when LuaFunction
          call_native(f, args)
        when LuaClosure
          run_vm(f, args)
        when LuaTable
          if mm = metafield(f, "__call")
            call(mm, ([f] of LuaValue).concat(args))
          else
            raise_lua("attempt to call a table value")
          end
        when LuaUserData
          if mm = metafield(f, "__call")
            call(mm, ([f] of LuaValue).concat(args))
          else
            raise_lua("attempt to call a userdata value")
          end
        when Nil
          raise_lua("attempt to call a nil value")
        else
          raise_lua("attempt to call a #{Lua.type_name(f)} value")
        end
      ensure
        @call_depth -= 1
      end
    end

    # Call a native (Crystal) function. Non-Lua Crystal exceptions raised
    # inside cross as Lua errors (catchable by pcall); LuaError passes
    # through untouched, value intact.
    def call_native(f : LuaFunction, args : Array(LuaValue)) : Array(LuaValue)
      f.fn.call(self, args)
    rescue e : LuaError
      raise e
    rescue e : YieldSignal
      raise e
    rescue e : Exception
      raise LuaError.new("(crystal) #{f.name}: #{e.class}: #{e.message || "error"}")
    end

    # --- indexing with metatables ---

    def metafield(v : LuaValue, name : String) : LuaValue
      case v
      when LuaTable
        mt = v.metatable
        mt ? mt.raw_get(name) : nil
      when String
        @string_meta.raw_get(name)
      when LuaUserData
        mt = v.metatable
        mt ? mt.raw_get(name) : nil
      else
        # debug.setmetatable can give any type a metatable
        if (mt = @type_mts[Lua.type_name(v)]?)
          mt ? mt.raw_get(name) : nil
        else
          nil
        end
      end
    end

    def getindex(obj : LuaValue, key : LuaValue, objreg : Int32 = -1) : LuaValue
      case obj
      when LuaTable
        v = obj.raw_get(key)
        return v unless v.nil?
        if idx = metafield(obj, "__index")
          case idx
          when LuaTable then getindex(idx, key)
          else               call(idx, [obj, key] of LuaValue)[0]?
          end
        else
          nil
        end
      when String
        # strings have no raw fields; their metatable's __index is the
        # string library table
        getindex(@string_lib, key)
      when LuaUserData
        if idx = metafield(obj, "__index")
          case idx
          when LuaTable then getindex(idx, key)
          else               call(idx, [obj, key] of LuaValue)[0]?
          end
        else
          nil
        end
      when Nil, Bool, Float64, LuaClosure, LuaFunction, LuaCoroutine
        # indexable only through debug.setmetatable
        if idx = metafield(obj, "__index")
          case idx
          when LuaTable then getindex(idx, key)
          else               call(idx, [obj, key] of LuaValue)[0]?
          end
        else
          typeerr("index", obj, objreg)
        end
      else
        typeerr("index", obj, objreg)
      end
    end

    def setindex(obj : LuaValue, key : LuaValue, val : LuaValue, objreg : Int32 = -1) : Nil
      cur = obj
      while cur.is_a?(LuaTable)
        if cur.has_key?(key)
          cur.raw_set(key, val)
          return
        end
        ni = metafield(cur, "__newindex")
        case ni
        when Nil
          cur.raw_set(key, val)
          return
        when LuaTable
          cur = ni
        else
          call(ni, [cur, key, val] of LuaValue)
          return
        end
      end
      if cur.is_a?(LuaUserData) || cur.is_a?(Nil) || cur.is_a?(Bool) ||
         cur.is_a?(Float64) || cur.is_a?(LuaClosure) || cur.is_a?(LuaFunction) || cur.is_a?(LuaCoroutine)
        ni = metafield(cur, "__newindex")
        if ni
          if ni.is_a?(LuaTable)
            setindex(ni, key, val)
          else
            call(ni, [cur, key, val] of LuaValue)
          end
          return
        end
      end
      typeerr("index", cur, objreg)
    end

    # --- equality / comparison / arithmetic (Runtime/ metatable dispatch) ---

    def lua_eq(l : LuaValue, r : LuaValue) : Bool
      if l.is_a?(Float64) && r.is_a?(Float64)
        l == r
      elsif l.is_a?(String) && r.is_a?(String)
        l == r
      elsif l.is_a?(Bool) && r.is_a?(Bool)
        l == r
      elsif l.class != r.class
        false
      else
        return true if Lua.ref_same(l, r)
        if (l.is_a?(LuaTable) && r.is_a?(LuaTable)) || (l.is_a?(LuaUserData) && r.is_a?(LuaUserData))
          mm = comp_mm(l, r, "__eq")
          return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?) if mm
        end
        false
      end
    end

    def raw_eq(l : LuaValue, r : LuaValue) : Bool
      if l.is_a?(Float64) && r.is_a?(Float64)
        l == r
      elsif l.is_a?(String) && r.is_a?(String)
        l == r
      elsif l.is_a?(Bool) && r.is_a?(Bool)
        l == r
      elsif l.class != r.class
        false
      else
        Lua.ref_same(l, r)
      end
    end

    ARITH_MM = {"+" => "__add", "-" => "__sub", "*" => "__mul", "/" => "__div", "%" => "__mod", "^" => "__pow"}

    def arith(op : String, l : LuaValue, r : LuaValue, lreg : Int32 = -1, rreg : Int32 = -1) : LuaValue
      a = Lua.tonumber(l)
      b = Lua.tonumber(r)
      if a && b
        case op
        when "+" then a + b
        when "-" then a - b
        when "*" then a * b
        when "/" then a / b
        when "%" then b == 0 ? Float64::NAN : a % b
        when "^" then a ** b
        else          raise_lua("unknown arith op #{op}")
        end
      else
        mm = metafield(l, ARITH_MM[op])
        mm = metafield(r, ARITH_MM[op]) if mm.nil?
        if mm
          call(mm, [l, r] of LuaValue)[0]?
        else
          bad = a.nil? ? l : r
          typeerr("perform arithmetic on", bad, a.nil? ? lreg : rreg)
        end
      end
    end

    def negate(v : LuaValue, reg : Int32 = -1) : LuaValue
      if n = Lua.tonumber(v)
        -n
      elsif mm = metafield(v, "__unm")
        call(mm, [v, v] of LuaValue)[0]?
      else
        typeerr("perform arithmetic on", v, reg)
      end
    end

    def lua_len(v : LuaValue, reg : Int32 = -1) : LuaValue
      case v
      when String then v.bytesize.to_f64
      when LuaTable, LuaUserData
        if mm = metafield(v, "__len")
          call(mm, [v] of LuaValue)[0]?
        elsif v.is_a?(LuaTable)
          v.raw_length.to_f64
        else
          typeerr("get length of", v, reg)
        end
      else
        typeerr("get length of", v, reg)
      end
    end

    def lua_concat(l : LuaValue, r : LuaValue, lreg : Int32 = -1, rreg : Int32 = -1) : LuaValue
      lok = l.is_a?(String) || l.is_a?(Float64)
      rok = r.is_a?(String) || r.is_a?(Float64)
      if lok && rok
        ls = to_concat_str(l)
        rs = to_concat_str(r)
        # 5.1 luaS_newlstr: size is checked against the string limit;
        # Crystal strings are Int32-indexed
        if ls.bytesize.to_i64 + rs.bytesize > Int32::MAX
          raise_lua("string length overflow")
        end
        ls + rs
      else
        mm = metafield(l, "__concat")
        mm = metafield(r, "__concat") if mm.nil?
        if mm
          call(mm, [l, r] of LuaValue)[0]?
        else
          bad = lok ? r : l
          typeerr("concatenate", bad, lok ? rreg : lreg)
        end
      end
    end

    private def to_concat_str(v : LuaValue) : String
      case v
      when String  then v
      when Float64 then Lua.fmt_num(v)
      else              raise_lua("attempt to concatenate a #{Lua.type_name(v)} value")
      end
    end

    # op is "<" or "<="
    def lua_compare(l : LuaValue, r : LuaValue, op : String) : Bool
      a = Lua.tonumber(l)
      b = Lua.tonumber(r)
      if a && b
        op == "<" ? a < b : a <= b
      elsif l.is_a?(String) && r.is_a?(String)
        c = Lua.strcmp(l, r)
        op == "<" ? c < 0 : c <= 0
      else
        mm = comp_mm(l, r, op == "<" ? "__lt" : "__le")
        if mm
          return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?)
        elsif op == "<="
          # 5.1 fallback: a <= b  as  not (b < a)
          ltm = comp_mm(l, r, "__lt")
          if ltm
            return !Lua.truthy(call(ltm, [r, l] of LuaValue)[0]?)
          end
        end
        raise_lua("attempt to compare #{Lua.type_name(l)} with #{Lua.type_name(r)}")
      end
    end

    # 5.1 get_compTM (lvm.c): a comparison metamethod applies only when BOTH
    # operands have it and it is the same function (or their metatables are
    # the same table) — otherwise the operation is primitive.
    private def comp_mm(l : LuaValue, r : LuaValue, name : String) : LuaValue
      lm = case l
           when LuaTable    then l.metatable
           when LuaUserData then l.metatable
           else                  return nil
           end
      rm = case r
           when LuaTable    then r.metatable
           when LuaUserData then r.metatable
           else                  return nil
           end
      return nil unless lm && rm
      lmm = lm.raw_get(name)
      return nil if lmm.nil?
      return lmm if lm.same?(rm)
      rmm = rm.raw_get(name)
      return nil if rmm.nil?
      Lua.ref_same(lmm, rmm) ? lmm : nil
    end

    # --- variable naming in runtime errors (5.1 ldebug.c) ---

    # luaG_typeerror: "attempt to <action> global 'x' (a nil value)", or the
    # bare form when no name can be attributed to the register.
    private def typeerr(action : String, v : LuaValue, reg : Int32) : NoReturn
      vi = varinfo(reg)
      if vi.empty?
        raise_lua("attempt to #{action} a #{Lua.type_name(v)} value")
      else
        raise_lua("attempt to #{action} #{vi} (a #{Lua.type_name(v)} value)")
      end
    end

    # "local 'x'" / "global 'x'" / ... for the value in register `reg` of the
    # running frame, or "" when unnamed.
    def varinfo(reg : Int32) : String
      if reg >= 0 && (pair = getobjname(reg, @vi_pc))
        "#{pair[0]} '#{pair[1]}'"
      else
        ""
      end
    end

    # getobjname: name the value in register `reg` of the current frame's
    # function, `lastpc` being the index of the faulting instruction. Local
    # debug info first, then the symbexec writer scan.
    def getobjname(reg : Int32, lastpc : Int32) : {String, String}?
      return nil if @fsize == 0 || lastpc < 0
      proto = @frames[@fsize - 1].closure.proto
      objname(proto, lastpc, reg)
    end

    private def objname(proto : Proto, lastpc : Int32, reg : Int32) : {String, String}?
      proto.loc_vars.each do |lv|
        if lv.reg == reg && lastpc >= lv.start_pc && lastpc <= lv.end_pc
          return {"local", lv.name}
        end
      end
      w = symb_writer(proto, lastpc, reg)
      return nil if w < 0
      ins = proto.code[w]
      case ins.op
      when .getglobal? then {"global", proto.consts[ins.b].as(String)}
      when .getupval?  then {"upvalue", (proto.upvals[ins.b]? || UpvalDesc.new("?", false, 0)).name}
      when .self?      then {"method", proto.consts[ins.c].as(String)}
      when .gettable?
        # field name: the key register's last writer must be a string LOADK
        # (this VM has no const-encoded GETTABLE operands)
        kw = symb_writer(proto, w, ins.c)
        if kw >= 0 && (ki = proto.code[kw]).op.loadk? && (s = proto.consts[ki.b]?).is_a?(String)
          {"field", s}
        end
      when .move?
        objname(proto, lastpc, ins.b) if ins.b < ins.a
      end
    end

    # Simplified 5.1 symbexec: forward scan recording the last instruction
    # that set `reg`, following forward jumps that stay below lastpc (so the
    # skipped branch of and/or does not shadow the taken path). Returns the
    # index of that instruction, or -1.
    private def symb_writer(proto : Proto, lastpc : Int32, reg : Int32) : Int32
      code = proto.code
      last = -1
      pc = 0
      while pc < lastpc
        ins = code[pc]
        op = ins.op
        a = ins.a
        case op
        when .loadnil?         then last = pc if a <= reg <= ins.b
        when .self?            then last = pc if reg == a || reg == a + 1
        when .tforcall?        then last = pc if reg >= a + 2
        when .call?, .tailcall? then last = pc if reg >= a # results/clobbers
        when .vararg?          then last = pc if reg >= a
        when .forprep?, .forloop? then last = pc if a <= reg <= a + 3
        when .jmp?, .jmpf?, .jmpt?
          # JMPF/JMPT test R[A] (the OP_TEST analogue): conditionally using a
          # register makes its provenance unknowable — drop the name
          last = pc if (op.jmpf? || op.jmpt?) && a == reg
          dest = pc + 1 + ins.b
          pc = dest - 1 if pc < dest && dest <= lastpc
        else
          last = pc if a == reg && writes_reg?(op)
        end
        pc += 1
      end
      last
    end

    # ops whose A operand is a plain destination register (5.1 testAMode)
    private def writes_reg?(op : Op) : Bool
      case op
      when .move?, .loadbool?, .loadk?, .getglobal?, .getupval?, .gettable?,
           .newtable?, .add?, .sub?, .mul?, .div?, .mod?, .pow?, .unm?,
           .not?, .len?, .concat?, .eq?, .neq?, .lt?, .le?, .closure?
        true
      else
        false
      end
    end
  end
end
