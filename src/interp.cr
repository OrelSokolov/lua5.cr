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
      Stdlib::IoLib.install(self)
      Stdlib::PackageLib.install(self)
      Stdlib::Coroutine.install(self)
    end

    # --- entry points ---

    # Compile a chunk into a callable closure.
    def compile(src : String, chunkname : String = "chunk") : LuaClosure
      @chunkname = chunkname
      block = Parser.new(Lexer.new(src, chunkname).tokens, chunkname).parse_chunk
      proto = Compiler.new(chunkname).compile_main(block)
      LuaClosure.new(proto, [] of UpValue)
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

    # --- error helpers ---

    def raise_lua(msg : String)
      raise LuaError.new("#{@chunkname}:#{@line}: #{msg}")
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
        nil
      end
    end

    def getindex(obj : LuaValue, key : LuaValue) : LuaValue
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
      when Nil
        raise_lua("attempt to index a nil value")
      else
        raise_lua("attempt to index a #{Lua.type_name(obj)} value")
      end
    end

    def setindex(obj : LuaValue, key : LuaValue, val : LuaValue) : Nil
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
      if cur.is_a?(LuaUserData)
        ni = metafield(cur, "__newindex")
        if ni
          call(ni, [cur, key, val] of LuaValue)
          return
        end
      end
      if cur.nil?
        raise_lua("attempt to index a nil value")
      else
        raise_lua("attempt to index a #{Lua.type_name(cur)} value")
      end
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
          mm = metafield(l, "__eq")
          mm = metafield(r, "__eq") if mm.nil?
          if mm
            return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?)
          end
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

    def arith(op : String, l : LuaValue, r : LuaValue) : LuaValue
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
          raise_lua("attempt to perform arithmetic on a #{Lua.type_name(bad)} value")
        end
      end
    end

    def negate(v : LuaValue) : LuaValue
      if n = Lua.tonumber(v)
        -n
      elsif mm = metafield(v, "__unm")
        call(mm, [v, v] of LuaValue)[0]?
      else
        raise_lua("attempt to perform arithmetic on a #{Lua.type_name(v)} value")
      end
    end

    def lua_len(v : LuaValue) : LuaValue
      case v
      when String then v.bytesize.to_f64
      when LuaTable, LuaUserData
        if mm = metafield(v, "__len")
          call(mm, [v] of LuaValue)[0]?
        elsif v.is_a?(LuaTable)
          v.raw_length.to_f64
        else
          raise_lua("attempt to get length of a userdata value")
        end
      else
        raise_lua("attempt to get length of a #{Lua.type_name(v)} value")
      end
    end

    def lua_concat(l : LuaValue, r : LuaValue) : LuaValue
      lok = l.is_a?(String) || l.is_a?(Float64)
      rok = r.is_a?(String) || r.is_a?(Float64)
      if lok && rok
        to_concat_str(l) + to_concat_str(r)
      else
        mm = metafield(l, "__concat")
        mm = metafield(r, "__concat") if mm.nil?
        if mm
          call(mm, [l, r] of LuaValue)[0]?
        else
          bad = lok ? r : l
          raise_lua("attempt to concatenate a #{Lua.type_name(bad)} value")
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
        c = l <=> r
        op == "<" ? c < 0 : c <= 0
      else
        mm = metafield(l, op == "<" ? "__lt" : "__le")
        mm = metafield(r, op == "<" ? "__lt" : "__le") if mm.nil?
        if mm
          return Lua.truthy(call(mm, [l, r] of LuaValue)[0]?)
        elsif op == "<="
          # 5.1 fallback: a <= b  as  not (b < a)
          ltm = metafield(l, "__lt")
          ltm = metafield(r, "__lt") if ltm.nil?
          if ltm
            return !Lua.truthy(call(ltm, [r, l] of LuaValue)[0]?)
          end
        end
        raise_lua("attempt to compare #{Lua.type_name(l)} with #{Lua.type_name(r)}")
      end
    end
  end
end
