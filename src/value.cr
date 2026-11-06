# Lua values and runtime objects. Port of MoonSharp DataTypes/ (DynValue,
# Table, Closure, CallbackFunction) onto idiomatic Crystal: values are a
# plain union of reference types + immediates.
module Lua
  alias LuaValue = Nil | Bool | Float64 | String | LuaTable | LuaClosure | LuaFunction | LuaUserData | LuaCoroutine

  EMPTY_VALS = [] of LuaValue

  def self.type_name(v : LuaValue) : String
    case v
    when Nil            then "nil"
    when Bool           then "boolean"
    when Float64        then "number"
    when String         then "string"
    when LuaTable       then "table"
    when LuaClosure     then "function"
    when LuaFunction    then "function"
    when LuaUserData    then "userdata"
    when LuaCoroutine   then "thread"
    else                     "no value"
    end
  end

  def self.truthy(v : LuaValue) : Bool
    !v.nil? && v != false
  end

  # Reference identity for reference-type values (== cannot be used:
  # LuaTable has no custom ==, but the union includes value types).
  def self.ref_same(l : LuaValue, r : LuaValue) : Bool
    case l
    when LuaTable      then r.is_a?(LuaTable) && l.same?(r)
    when LuaClosure    then r.is_a?(LuaClosure) && l.same?(r)
    when LuaFunction   then r.is_a?(LuaFunction) && l.same?(r)
    when LuaUserData   then r.is_a?(LuaUserData) && l.same?(r)
    when LuaCoroutine  then r.is_a?(LuaCoroutine) && l.same?(r)
    else                    l.nil? && r.nil?
    end
  end

  def self.tonumber(v : LuaValue) : Float64?
    case v
    when Float64 then v
    when String  then parse_number(v)
    else              nil
    end
  end

  def self.parse_number(s : String) : Float64?
    t = s.strip
    return nil if t.empty?
    if t.size > 2 && (t.starts_with?("0x") || t.starts_with?("0X"))
      t[2..].to_i64?(16).try &.to_f64
    elsif (n = t.to_f64?)
      n
    elsif looks_like_number?(t)
      # strtod semantics: well-formed but out of range → ±inf
      t.starts_with?('-') ? Float64::INFINITY * -1 : Float64::INFINITY
    end
  end

  # Byte-oriented numeric-syntax check ("^-?d+.?d*([eE][+-]?d+)?$"); no
  # Crystal Regex — it validates UTF-8 and raises on binary strings.
  private def self.looks_like_number?(t : String) : Bool
    b = t.to_slice
    i = 0
    i += 1 if b[0]? == 0x2D # '-'
    digits = 0
    while d = b[i]?
      break unless 0x30 <= d <= 0x39
      digits += 1
      i += 1
    end
    return false if digits == 0
    if b[i]? == 0x2E # '.'
      i += 1
      while d = b[i]?
        break unless 0x30 <= d <= 0x39
        digits += 1
        i += 1
      end
    end
    if (e = b[i]?) && (e == 0x65 || e == 0x45) # e E
      i += 1
      i += 1 if (s = b[i]?) && (s == 0x2B || s == 0x2D) # + -
      edigits = 0
      while d = b[i]?
        break unless 0x30 <= d <= 0x39
        edigits += 1
        i += 1
      end
      return false if edigits == 0
    end
    i == b.size && digits > 0
  end

  # Lua prints numbers with LUAI_NUMFFORMAT ("%.14g").
  def self.fmt_num(v : Float64) : String
    return "inf"  if v == Float64::INFINITY
    return "-inf" if v == -Float64::INFINITY
    return "nan"  if v.nan?
    "%.14g" % v
  end

  # --- errors (port of MoonSharp Errors/) ---

  # Runtime Lua error; `value` is what travels to pcall (string, table, ...).
  class LuaError < Exception
    # set when an xpcall message handler has already processed this error
    # (5.1 runs it once, at the raise point, before unwinding)
    property? msgh_done : Bool = false
    property value : LuaValue

    def initialize(@value : LuaValue, msg : String? = nil)
      super(msg || Lua.err_display(@value))
    end
  end

  def self.err_display(v : LuaValue) : String
    case v
    when String then v
    when Nil    then "nil"
    else
      Lua.repr_addr(v)
    end
  end

  # Bytewise string ordering (5.1 luaV_strcmp): Lua strings are byte
  # arrays; Crystal's String#<=> decodes codepoints and raises on
  # invalid UTF-8, so comparisons must go through raw bytes.
  def self.strcmp(a : String, b : String) : Int32
    ab = a.to_slice
    bb = b.to_slice
    n = ab.size < bb.size ? ab.size : bb.size
    i = 0
    while i < n
      d = ab[i].to_i32 - bb[i].to_i32
      return d < 0 ? -1 : 1 if d != 0
      i += 1
    end
    ab.size <=> bb.size
  end

  def self.repr_addr(v : LuaValue) : String
    case v
    when LuaTable      then "table: 0x#{v.object_id.to_s(16)}"
    when LuaClosure    then "function: 0x#{v.object_id.to_s(16)}"
    when LuaFunction   then "function: builtin: 0x#{v.object_id.to_s(16)}"
    when LuaUserData   then "userdata: 0x#{v.object_id.to_s(16)}"
    when LuaCoroutine  then "thread: 0x#{v.object_id.to_s(16)}"
    else                    v.to_s
    end
  end

  # --- table ---

  class LuaTable
    property metatable : LuaTable? = nil
    # pairs-traversal hint: (key, index into raw_keys at return time). Lets
    # `next` continue after the caller erases the CURRENT key mid-loop —
    # the documented 5.1 use ("you may erase the key being visited").
    property next_hint_key : LuaValue = nil
    property next_hint_idx : Int32 = -1
    # Integer keys 1..n live in a flat array (the "array part", as in PUC
    # Lua); everything else — and integral keys past holes — in the hash.
    # Slots holding nil are holes: raw_get falls through to the hash part.
    # The array part covers one contiguous run base..base+n-1 (PUC Lua
    # always bases it at 1; we also grow from the first integral key, e.g.
    # 2..N in a sieve — the layout is unobservable).
    @arr : Array(LuaValue)? = nil
    @arr_base : Int32 = 1
    @hash = Hash(LuaValue, LuaValue).new
    # last computed #t; maintained by raw_set so the append pattern
    # (table.insert loops, SETLIST) stays amortized O(1) instead of
    # rescanning from 1 on every raw_length
    @len_cache : Int32 = 0

    def initialize
    end

    def check_key(key : LuaValue)
      if key.nil?
        raise LuaError.new("table index is nil")
      end
      if key.is_a?(Float64) && key.nan?
        raise LuaError.new("table index is NaN")
      end
    end

    private def arr_get(k : Int32) : LuaValue
      a = @arr
      if a && k >= @arr_base && k < @arr_base + a.size
        a[k - @arr_base]
      else
        nil
      end
    end

    # Float64 Lua key → Int32 iff integral and in range; nil otherwise.
    private def int_key(key : Float64) : Int32?
      return nil if key.nan? || key < -2147483648.0 || key > 2147483647.0
      t = key.trunc
      t == key ? t.to_i32 : nil
    end

    def raw_get(key : LuaValue) : LuaValue
      # nil/NaN keys read as nil (luaH_get returns nilobject); only
      # ASSIGNMENT rejects them (check in raw_set)
      if key.is_a?(Float64)
        if key.nan?
          return nil
        elsif (k = int_key(key))
          v = arr_get(k)
          return v unless v.nil?
        end
      elsif key.nil?
        return nil
      end
      v = @hash[key]?
      v.nil? ? nil : v
    end

    def raw_set(key : LuaValue, val : LuaValue) : Nil
      check_key(key)
      if key.is_a?(Float64) && (k = int_key(key))
        @len_cache = k - 1 if val.nil? && k <= @len_cache
        if a = @arr
          if k >= @arr_base && k < @arr_base + a.size
            a[k - @arr_base] = val # val may be nil: stays as a hole
            return
          elsif k == @arr_base + a.size && !val.nil?
            a << val
            migrate_from_hash(a)
            return
          end
          if val.nil?
            @hash.delete(key) # (can only be absent)
            return
          end
        else
          if !val.nil?
            a = [val] of LuaValue
            @arr = a
            @arr_base = k
            migrate_from_hash(a)
            return
          end
        end
      end
      if val.nil?
        @hash.delete(key)
      else
        @hash[key] = val
      end
    end

    # Pull consecutive integer keys that were parked in the hash (set before
    # the array part reached them) into the array part.
    private def migrate_from_hash(a : Array(LuaValue)) : Nil
      loop do
        k = (@arr_base + a.size).to_f64
        v = @hash[k]?
        break if v.nil?
        @hash.delete(k)
        a << v
      end
    end

    # Contiguous integer fill (SETLIST): keys start..start+vals.size-1.
    # nils stay as holes at their positions (skipping them would shift keys).
    def raw_fill(start : Int32, vals : Array(LuaValue)) : Nil
      return if vals.empty?
      if (a = @arr) && start == @arr_base + a.size
        vals.each { |v| a << v }
        migrate_from_hash(a)
      elsif @arr.nil? && start >= 1
        a = vals.dup
        @arr = a
        @arr_base = start
        migrate_from_hash(a)
      else
        vals.each_with_index { |v, i| raw_set((start + i).to_f64, v) }
      end
    end

    def has_key?(key : LuaValue) : Bool
      return false if key.nil?
      if key.is_a?(Float64) && (k = int_key(key))
        v = arr_get(k)
        return true unless v.nil?
      end
      @hash.has_key?(key)
    end

    # #t: 1..n while consecutive non-nil entries exist. Scans up from the
    # cached length; the guard restarts if the cache was over-optimistic.
    def raw_length : Int32
      n = @len_cache
      n = 0 if n > 0 && !slot_filled?(n)
      loop do
        break unless slot_filled?(n + 1)
        n += 1
      end
      @len_cache = n
      n
    end

    private def slot_filled?(k : Int32) : Bool
      if (a = @arr) && k >= @arr_base && k < @arr_base + a.size
        !a[k - @arr_base].nil?
      else
        @hash.has_key?(k.to_f64)
      end
    end

    def raw_keys : Array(LuaValue)
      keys = Array(LuaValue).new((@arr.try(&.size) || 0) + @hash.size)
      if a = @arr
        base = @arr_base
        a.each_with_index { |v, i| keys << (base + i).to_f64 unless v.nil? }
      end
      keys.concat(@hash.keys)
      keys
    end
  end

  # --- bytecode (see vm.cr for the compiler and the dispatch loop) ---

  enum Op : UInt8
    MOVE      # A: R[A] = R[B]                                  (B: src)
    LOADNIL   # A..A+B = nil
    LOADBOOL  # R[A] = (B != 0)
    LOADK     # R[A] = K[B]
    GETGLOBAL # R[A] = G[K[B]]            (K[B] is a String)
    SETGLOBAL # G[K[B]] = R[A]
    GETUPVAL  # R[A] = U[B]
    SETUPVAL  # U[B] = R[A]
    GETTABLE  # R[A] = R[B][R[C]]
    SETTABLE  # R[A][R[B]] = R[C]
    SELF      # R[A+1] = R[B]; R[A] = R[B][K[C]]          (K[C] is a String)
    NEWTABLE  # R[A] = {}
    SETLIST   # R[A][C+1..C+B] = R[A+1..A+B]; B == -1: up to top
    ADD       # R[A] = R[B] + R[C]   (metatable-dispatched, string coercion)
    SUB
    MUL
    DIV
    MOD
    POW
    UNM       # R[A] = -R[B]
    NOT       # R[A] = not R[B]
    LEN       # R[A] = #R[B]
    CONCAT    # R[A] = R[A] .. .. .. R[B]   (right-fold)
    EQ        # R[A] = (R[B] == R[C])
    NEQ       # R[A] = (R[B] ~= R[C])
    LT        # R[A] = (R[B] < R[C])
    LE        # R[A] = (R[B] <= R[C])
    JMP       # pc += B
    JMPF      # pc += B unless truthy(R[A])
    JMPT      # pc += B if truthy(R[A])
    CALL      # call R[A]; B = #args (-1: to top); C = #results (-1: all, 0: none)
    TAILCALL  # return R[A](args at A+1..); B as CALL
    RETURN    # return R[A..A+B-1]; B == -1: to top, 0: none
    VARARG    # R[A..] = varargs; B as CALL's C (-1: all + top, n: exact, 0: none)
    CLOSURE   # R[A] = closure over P[B], upvalues resolved here
    CLOSE     # close upvalues at registers >= A
    FORPREP   # numeric-for setup at A..A+2; jump B if the loop never runs
    FORLOOP   # numeric-for step+test at A; jump B to body start
    TFORCALL  # generic-for at A (f, s, ctrl), C control vars at A+3..; jump B back
  end

  struct Inst
    property op : Op
    property a : Int32
    property b : Int32
    property c : Int32

    def initialize(@op : Op, @a : Int32 = 0, @b : Int32 = 0, @c : Int32 = 0)
    end
  end

  # How a nested function's upvalue is resolved at CLOSURE time.
  class UpvalDesc
    getter name : String
    # true: `index` is a register of the enclosing function;
    # false: `index` is an upvalue of the enclosing function.
    getter? from_stack : Bool
    getter index : Int32

    def initialize(@name, @from_stack, @index)
    end
  end

  # Debug info: a local's live range (5.1 LocVar), for debug.getlocal and
  # variable naming in error messages. `reg` is the 0-based R index.
  class LocVar
    getter name : String
    getter reg : Int32
    getter start_pc : Int32
    property end_pc : Int32

    def initialize(@name, @reg, @start_pc, @end_pc)
    end
  end

  # Compiled function body. `code` holds readable Insts while compiling;
  # `packed` is the execution form — one UInt64 per instruction
  # (op:8 | a:16s | b:20s | c:20s) — half the fetch traffic of the 16-byte
  # struct and the fixed encoding the JIT will consume.
  class Proto
    property code = [] of Inst
    property packed = [] of UInt64
    property lines = [] of Int32 # line per instruction, for error messages
    property consts = [] of LuaValue
    property protos = [] of Proto
    property upvals = [] of UpvalDesc
    # Debug info (5.1 Proto#locvars): local names for debug.getlocal and
    # for variable names in runtime error messages.
    property loc_vars = [] of LocVar
    # 5.1 linedefined: line of the function keyword (0 for main chunks);
    # lastlinedefined: line of the closing 'end'
    property linedefined : Int32 = 0
    property lastlinedefined : Int32 = 0
    # Source text the proto was compiled from (all protos of a chunk share
    # it). Not real bytecode: string.dump returns this and load recompiles.
    property src : String = ""
    property num_params : Int32 = 0
    property? vararg : Bool = false
    # 5.1 compat (LUA_COMPAT_VARARG): implicit local `arg` table for
    # vararg functions; the VM builds it at frame entry.
    property? needs_arg : Bool = false
    property max_stack : Int32 = 2
    getter chunkname : String

    def initialize(@chunkname)
    end
  end

  # A captured local: either "open" (still a slot in the shared VM stack)
  # or "closed" (a cell of its own, after its scope exited).
  class UpValue
    property stack : Array(LuaValue)?
    property idx : Int32
    property value : LuaValue = nil

    def initialize(@stack, @idx)
    end
  end

  class LuaClosure
    getter proto : Proto
    getter upvals : Array(UpValue)
    # Function environment (5.1 setfenv/getfenv): nil = interpreter globals.
    property env : LuaTable? = nil

    def initialize(@proto, @upvals)
    end
  end

  # A coroutine: its own value stack + frame buffer, swapped into the
  # interpreter on resume (PLAN phase 3: value-stack per coroutine, no
  # Crystal fibers). Suspended state is exactly the saved VM state.
  class LuaCoroutine
    enum Status
      Suspended
      Running
      Normal
      Dead
    end

    getter fn : LuaValue
    property status : Status = Status::Suspended
    property stack : Array(LuaValue)
    property frames : Array(Frame)
    property fsize : Int32 = 0
    property entries = [] of Int32 # run_frames entry stack, saved on suspend
    # Open-upvalue registry + high-water mark, swapped with the stacks (a
    # coroutine's captures must not alias the resumer's stack slots).
    property open_upvals = [] of UpValue
    property open_max : Int32 = -1
    # The CALL/TAILCALL site that raised YieldSignal (vm.cr), saved on
    # suspend: {frame, abs result register (-1: tail call), CALL C, tail?}.
    property yield_call : {Frame, Int32, Int32, Bool}? = nil
    property? first_resume = true

    def initialize(@fn)
      @stack = Array(LuaValue).new(256, nil.as(LuaValue))
      @frames = [] of Frame
    end

    # Drop the saved state once dead — the stacks can be large.
    def release : Nil
      @stack = Array(LuaValue).new(0, nil.as(LuaValue))
      @frames = [] of Frame
      @fsize = 0
      @entries = [] of Int32
      @open_upvals = [] of UpValue
      @open_max = -1
    end
  end

  # One VM call frame. Registers live in the shared Interp stack at
  # base..top; R[0] is the closure itself, params follow at R[1..].
  class Frame
    property closure : LuaClosure
    property base : Int32
    property pc : Int32 = 0
    property top : Int32
    property varargs : Array(LuaValue)
    # C operand of the CALL that pushed this frame (-1/0/n).
    property want : Int32 = -1

    def initialize(@closure, @base, @top, @varargs)
    end
  end

  alias NativeFn = Interp, Array(LuaValue) -> Array(LuaValue)

  class LuaFunction
    getter name : String
    getter fn : NativeFn

    def initialize(@name, @fn)
    end
  end

  # Marker module included (by the `expose` macro) into every class whose
  # instances can flow into Lua. Also the ivar type for LuaUserData#obj —
  # Crystal forbids Object/Reference as instance variable types.
  module Exposable
  end

  # Payload for newproxy() userdata — no Crystal-side behavior, only the
  # Lua-visible userdata shell with its (possibly shared) metatable.
  class ProxyMarker
    include Exposable
  end

  # Wrapper for a Crystal object exposed to Lua (interop).
  class LuaUserData
    property obj : Exposable
    property metatable : LuaTable? = nil

    def initialize(@obj : Exposable)
    end
  end
end
