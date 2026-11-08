# Lua values and runtime objects. Port of MoonSharp DataTypes/ (DynValue,
# Table, Closure, CallbackFunction) onto idiomatic Crystal: values are a
# plain union of reference types + immediates.
require "weak_ref"

module Lua
  alias LuaValue = Nil | Bool | Float64 | String | LuaTable | LuaClosure | LuaFunction | LuaUserData | LuaCoroutine

  EMPTY_VALS = [] of LuaValue

  # --- string interning (PUC luaS_newlstr analog) ---
  # Short strings (<= SHORT_STR_MAX bytes) get one canonical instance per
  # distinct content. LuaTable keeps string keys in an identity-hashed
  # store: a lookup is an object_id hash + pointer compare, no siphash
  # over the bytes and no memcmp (the dominant cost of field access).
  # Long strings stay by-value (stored in the union hash, compared by
  # bytes) — as in PUC, where only short strings are interned.
  SHORT_STR_MAX = 40
  @@istrs = Hash(String, String).new

  # Slot-home hash for the flat string-key store: a murmur3-style
  # finalizer over the key's address. A plain Fibonacci hash
  # ((addr * K) >> 32) is NOT good enough here: Crystal allocates
  # interned strings back-to-back (16-byte stride), and middle-bits of
  # adjacent products land on the same home — the whole key set packs
  # into one cluster and the JIT's 3-slot inline probe misses forever
  # (found on nbody: 180M helper calls). The finalizer spreads address
  # deltas into every bit; used by BOTH LuaTable#slot_idx and the JIT's
  # compile-time home (the key address is a constant there, so the
  # mixed home costs nothing in the emitted code).
  def self.slot_hash(addr : UInt64) : UInt64
    h = addr
    h ^= h >> 33
    h &*= 0xff51afd7ed558ccd_u64
    h ^= h >> 33
    h &*= 0xc4ceb9fe1a85ec53_u64
    h ^ (h >> 33)
  end

  def self.intern(s : String) : String
    return s if s.bytesize > SHORT_STR_MAX
    if c = @@istrs[s]?
      c
    else
      @@istrs[s] = s
      s
    end
  end

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

  # A weak-table entry cell. The value is held STRONGLY — liveness is
  # decided by our own precise mark phase over the Lua object graph
  # (Lua.gc_full), not by the collector: Boehm's conservative machine-
  # stack scan would pin dead objects forever. Entries whose weak side
  # is unmarked are dropped by the sweep, releasing the object after.
  class WCell
    property v : LuaValue

    def initialize(@v)
    end
  end

  # Mark state for the Lua-graph GC (Lua.gc_full): ids of visited
  # objects plus a worklist (no recursion — graphs can be deep).
  class GcMark
    getter seen = Set(UInt64).new
    @work = [] of LuaValue

    def mark(v : LuaValue) : Nil
      case v
      when LuaTable, LuaClosure, LuaCoroutine, LuaUserData, LuaFunction
        return unless seen.add?(v.object_id)
        @work << v
      end
    end

    def run : Nil
      until @work.empty?
        v = @work.pop
        case v
        when LuaTable      then v.gc_mark_children(self)
        when LuaClosure    then v.gc_mark_children(self)
        when LuaCoroutine  then v.gc_mark_children(self)
        when LuaUserData   then v.metatable.try { |mt| mark(mt) }
        end
      end
    end

    def marked?(v : LuaValue) : Bool
      case v
      when LuaTable, LuaClosure, LuaCoroutine, LuaUserData, LuaFunction
        seen.includes?(v.object_id)
      else
        true # immediates (and strings) are never collected
      end
    end
  end

  # One slot of LuaTable's string-key store: { String? key, LuaValue val }.
  # A nil key marks an empty slot; keys are canonical interned instances
  # compared by identity. Layout is fixed per build — the JIT probes
  # key/val at runtime-derived offsets (LuaTable#probe_offsets).
  struct SSlot
    property key : String? = nil
    property val : LuaValue = nil

    def initialize
    end

    # JIT layout probe (jit/compiler.cr Layout): struct size and field
    # byte offsets, probed once per process
    def self.field_offsets : {size: Int32, key: Int32, val: Int32}
      s = SSlot.new
      base = pointerof(s).address
      {size: sizeof(SSlot),
       key:  (pointerof(s.@key).address - base).to_i32!,
       val:  (pointerof(s.@val).address - base).to_i32!}
    end
  end

  class LuaTable
    getter metatable : LuaTable? = nil
    # weak-table state (__mode): when set, entries live in @weak as WeakBox
    # pairs — collectable sides go through WeakRef, so the Boehm GC reclaims
    # them and dead boxes read as nil until the collect pass compacts.
    @weak : Array({WCell, WCell})? = nil
    @weak_keys = false
    @weak_vals = false

    def metatable=(mt : LuaTable?)
      @metatable = mt
      Lua.refresh_weak(self)
    end

    # metatable assignment that bypasses weak/finalizer registration
    # (used for __gc stand-in objects)
    def metatable_no_reg=(mt : LuaTable?)
      @metatable = mt
    end
    # pairs-traversal hint: (key, index into raw_keys at return time). Lets
    # `next` continue after the caller erases the CURRENT key mid-loop —
    # the documented 5.1 use ("you may erase the key being visited").
    property next_hint_key : LuaValue = nil
    property next_hint_idx : Int32 = -1
    # Integer keys 1..n live in a flat raw buffer (the "array part", as in
    # PUC Lua); everything else — and integral keys past holes — in the hash.
    # Slots holding nil are holes: raw_get falls through to the hash part.
    # The array part covers one contiguous run base..base+n-1 (PUC Lua
    # always bases it at 1; we also grow from the first integral key, e.g.
    # 2..N in a sieve — the layout is unobservable). A hand-managed buffer
    # instead of Array(LuaValue): unchecked indexed access (no bounds
    # checks on the interpreter's hot path) and fixed field offsets the
    # JIT can inline against (probe_layout).
    @buf : Pointer(LuaValue) = Pointer(LuaValue).null
    @arr_base : Int32 = 1
    @arr_len : Int32 = 0
    @arr_cap : Int32 = 0
    @hash = Hash(LuaValue, LuaValue).new
    # String-key store: a flat identity-keyed open-addressing table (port
    # of luaH's string part) over canonical (interned) keys — the fast
    # path of field access (PUC luaH_getstr). Fixed SSlot layout the JIT
    # can inline a probe against (probe_offsets); inserts canonicalize
    # through Lua.intern; reads that identity-miss retry once with the
    # canonical instance (a by-value equal key may have entered through a
    # non-interned producer). Long strings (> SHORT_STR_MAX) stay
    # by-value in @hash. All other key types live in @hash.
    @slots : Pointer(SSlot) = Pointer(SSlot).null
    @smask : Int32 = 0 # slots-1 (power-of-two); 0 = table not allocated
    @scount : Int32 = 0
    # last computed #t; maintained by raw_set so the append pattern
    # (table.insert loops, SETLIST) stays amortized O(1) instead of
    # rescanning from 1 on every raw_length
    @len_cache : Int32 = 0

    def initialize
    end

    # --- string-key store (see @slots): flat open addressing, linear
    # probing, identity keys. The index function is reproduced verbatim
    # in JIT-compiled probes (jit/compiler.cr) — keep in sync:
    # Lua.slot_hash(addr) & mask (the murmur finalizer — see its
    # comment; a Fibonacci hash clusters adjacent string addresses into
    # one probe chain)
    private def slot_idx(addr : UInt64) : Int32
      (Lua.slot_hash(addr) & @smask.to_u64!).to_i32!
    end

    # identity probe; returns the slot index or -1
    private def slot_find(k : String) : Int32
      return -1 if @smask == 0
      i = slot_idx(k.as(Void*).address)
      while true
        sk = @slots[i].key
        return i if !sk.nil? && sk.not_nil!.same?(k)
        return -1 if sk.nil?
        i = (i + 1) & @smask
      end
    end

    def str_get(k : String) : LuaValue?
      i = slot_find(k)
      i < 0 ? nil : @slots[i].val
    end

    # insert/overwrite (non-nil val); canonicalizes the key on a fresh
    # insert; grows at 70% load
    def str_set(key : String, val : LuaValue) : Nil
      # grow at load 0.5: the JIT's inline probe covers 3 slots, and at
      # higher loads (0.7 kept 9 string fields in 16 slots, alpha 0.56) a
      # key or two always probes past 3 — every access then falls to the
      # helper (nbody's b.fx stores). 0.5 keeps distances <= 2 almost
      # always; the extra slots are 16B each.
      str_grow if (@scount + 1) * 2 > (@smask + 1)
      i = slot_find(key)
      if i < 0
        c = Lua.intern(key)
        unless c.same?(key)
          i = slot_find(c) # the canonical instance may already sit there
        end
        if i < 0
          j = c.same?(key) ? slot_find_empty(key) : slot_find_empty(c)
          ins = @slots[j]
          ins.key = c
          ins.val = val
          @slots[j] = ins
          @scount += 1
          return
        end
      end
      hit = @slots[i]
      hit.val = val
      @slots[i] = hit
    end

    private def slot_find_empty(k : String) : Int32
      i = slot_idx(k.as(Void*).address)
      while !@slots[i].key.nil?
        i = (i + 1) & @smask
      end
      i
    end

    private def str_grow : Nil
      nmask = @smask == 0 ? 7 : ((@smask + 1) * 2 - 1)
      obuf, omask = @slots, @smask
      nbuf = Pointer(SSlot).malloc(nmask + 1)
      (nmask + 1).times { |i| nbuf[i] = SSlot.new }
      @slots = nbuf
      @smask = nmask
      return if omask == 0
      (omask + 1).times do |i|
        oslot = obuf[i]
        unless oslot.key.nil?
          j = slot_find_empty(oslot.key.not_nil!)
          ins = nbuf[j]
          ins.key = oslot.key
          ins.val = oslot.val
          nbuf[j] = ins
        end
      end
    end

    # delete by identity (and by canonical instance — a by-value equal
    # key may sit under its interned twin); backward-shift deletion keeps
    # probe chains correct
    def str_del(key : String) : Nil
      if (i = slot_find(key)) >= 0
        del_at(i)
      end
      c = Lua.intern(key)
      if !c.same?(key) && (j = slot_find(c)) >= 0
        del_at(j)
      end
    end

    private def del_at(i : Int32) : Nil
      return if i < 0
      mask = @smask
      hole = i
      j = i
      while true
        j = (j + 1) & mask
        sk = @slots[j].key
        break if sk.nil?
        home = slot_idx(sk.not_nil!.as(Void*).address)
        # move slot j into the hole unless its home position lies
        # cyclically inside (hole, j]
        dist_j = (j - home) & mask
        dist_hole = (hole - home) & mask
        if dist_j > dist_hole
          moved = @slots[j]
          dst = @slots + hole
          hole_slot = @slots[hole]
          hole_slot.key = moved.key
          hole_slot.val = moved.val
          dst[0] = hole_slot
          cleared = @slots[j]
          cleared.key = nil
          cleared.val = nil
          @slots[j] = cleared
          hole = j
        end
      end
      cleared = @slots[hole]
      cleared.key = nil
      cleared.val = nil
      @slots[hole] = cleared
      @scount -= 1
    end
    # JIT layout probe (jit/compiler.cr Layout): byte offsets of the
    # fields the inlined GETTABLE/SETTABLE fast paths (numeric array part
    # and string-key flat table) read off the object pointer. Layout is
    # fixed per build; probed once per process.
    def probe_offsets : {mt: Int32, buf: Int32, base: Int32, len: Int32,
                         slots: Int32, smask: Int32,
                         slot_size: Int32, slot_key: Int32, slot_val: Int32}
      p = self.as(Void*).address
      so = SSlot.field_offsets
      {mt:    (pointerof(@metatable).address - p).to_i32!,
       buf:   (pointerof(@buf).address - p).to_i32!,
       base:  (pointerof(@arr_base).address - p).to_i32!,
       len:   (pointerof(@arr_len).address - p).to_i32!,
       slots: (pointerof(@slots).address - p).to_i32!,
       smask: (pointerof(@smask).address - p).to_i32!,
       slot_size: so[:size],
       slot_key:  so[:key],
       slot_val:  so[:val]}
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
      if k >= @arr_base && k < @arr_base + @arr_len
        @buf[k - @arr_base]
      else
        nil
      end
    end

    # grow the raw buffer to hold at least `min` slots; new slots are
    # nil-filled (unions must never hold garbage tags — the GC scans them)
    private def buf_grow(min : Int32) : Nil
      return if min <= @arr_cap
      nc = {@arr_cap * 2, min, 8}.max
      nb = Pointer(LuaValue).malloc(nc)
      @buf.copy_to(nb, @arr_len)
      i = @arr_len
      while i < nc
        nb[i] = nil.as(LuaValue)
        i += 1
      end
      @buf = nb
      @arr_cap = nc
    end

    # Float64 Lua key → Int32 iff integral and in range; nil otherwise.
    private def int_key(key : Float64) : Int32?
      return nil if key.nan? || key < -2147483648.0 || key > 2147483647.0
      t = key.trunc
      t == key ? t.to_i32 : nil
    end

    def raw_get(key : LuaValue) : LuaValue
      if wi = @weak
        wi.each do |(kb, vb)|
          return vb.v if Lua.weak_key_eq(kb.v, key)
        end
        return nil
      end
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
      elsif key.is_a?(String)
        # long strings are not interned (PUC semantics): by-value store
        if key.bytesize > Lua::SHORT_STR_MAX
          v = @hash[key]?
          return v.nil? ? nil : v
        end
        if (v = str_get(key)) != nil
          return v
        end
        # miss: a by-value equal key may be stored under its canonical
        # instance (a producer bypassed the intern choke points)
        c = Lua.intern(key)
        if !c.same?(key)
          if (v = str_get(c)) != nil
            return v
          end
        end
        return nil
      end
      v = @hash[key]?
      v.nil? ? nil : v
    end

    def raw_set(key : LuaValue, val : LuaValue) : Nil
      check_key(key)
      if wi = @weak
        idx = wi.index { |(kb, _vb)| Lua.weak_key_eq(kb.v, key) }
        if val.nil?
          wi.delete_at(idx) if idx
          return
        end
        item = {WCell.new(key), WCell.new(val)}
        if idx
          wi[idx] = item
        else
          wi << item
        end
        return
      end
      if key.is_a?(String)
        # long strings stay by-value (not interned — see @slots comment)
        if key.bytesize > Lua::SHORT_STR_MAX
          if val.nil?
            @hash.delete(key)
          else
            @hash[key] = val
          end
          return
        end
        if @smask == 0
          # first string-key insert: pull by-value string keys already
          # parked in @hash (rare: only between the array/hash split and
          # the first string-key insert)
          @hash.keys.each do |hk|
            if hk.is_a?(String) && !(hv = @hash[hk]?).nil?
              str_set(hk, hv)
              @hash.delete(hk)
            end
          end
        end
        if val.nil?
          str_del(key)
          return
        end
        str_set(key, val)
        return
      end
      if key.is_a?(Float64) && (k = int_key(key))
        @len_cache = k - 1 if val.nil? && k <= @len_cache
        if @arr_len > 0
          if k >= @arr_base && k < @arr_base + @arr_len
            @buf[k - @arr_base] = val # val may be nil: stays as a hole
            return
          elsif k == @arr_base + @arr_len && !val.nil?
            buf_grow(@arr_len + 1)
            @buf[@arr_len] = val
            @arr_len += 1
            migrate_from_hash
            return
          end
          if val.nil?
            @hash.delete(key) # (can only be absent)
            return
          end
        else
          if !val.nil?
            buf_grow(1)
            @buf[0] = val
            @arr_len = 1
            @arr_base = k
            migrate_from_hash
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
    private def migrate_from_hash : Nil
      loop do
        k = (@arr_base + @arr_len).to_f64
        v = @hash[k]?
        break if v.nil?
        @hash.delete(k)
        buf_grow(@arr_len + 1)
        @buf[@arr_len] = v
        @arr_len += 1
      end
    end

    # Contiguous integer fill (SETLIST): keys start..start+vals.size-1.
    # nils stay as holes at their positions (skipping them would shift keys).
    def raw_fill(start : Int32, vals : Array(LuaValue)) : Nil
      return if vals.empty?
      if @weak
        vals.each_with_index { |v, i| raw_set((start + i).to_f64, v) }
        return
      end
      if @arr_len > 0 && start == @arr_base + @arr_len
        buf_grow(@arr_len + vals.size)
        vals.each { |v| @buf[@arr_len] = v; @arr_len += 1 }
        migrate_from_hash
      elsif @arr_len == 0 && start >= 1
        buf_grow(vals.size)
        vals.each_with_index { |v, i| @buf[i] = v }
        @arr_len = vals.size
        @arr_base = start
        migrate_from_hash
      else
        vals.each_with_index { |v, i| raw_set((start + i).to_f64, v) }
      end
    end

    def has_key?(key : LuaValue) : Bool
      return false if key.nil?
      if wi = @weak
        return wi.any? { |(kb, _vb)| Lua.weak_key_eq(kb.v, key) }
      end
      if key.is_a?(Float64) && (k = int_key(key))
        v = arr_get(k)
        return true unless v.nil?
      elsif key.is_a?(String)
        if key.bytesize <= Lua::SHORT_STR_MAX
          return true unless str_get(key).nil?
          c = Lua.intern(key)
          return true if !c.same?(key) && !str_get(c).nil?
          return false
        end
      end
      @hash.has_key?(key)
    end

    # #t: 1..n while consecutive non-nil entries exist. Scans up from the
    # cached length; the guard restarts if the cache was over-optimistic.
    def raw_length : Int32
      if wi = @weak
        # contiguous integer keys 1..n (no cache: entries change at sweep)
        set = Set(Int32).new
        wi.each do |(kb, _vb)|
          k = kb.v
          if k.is_a?(Float64) && (i = int_key(k)) && i >= 1
            set << i
          end
        end
        n = 0
        while set.includes?(n + 1)
          n += 1
        end
        return n
      end
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
      if k >= @arr_base && k < @arr_base + @arr_len
        !@buf[k - @arr_base].nil?
      else
        @hash.has_key?(k.to_f64)
      end
    end

    def raw_keys : Array(LuaValue)
      if wi = @weak
        keys = [] of LuaValue
        wi.each { |(kb, _vb)| keys << kb.v }
        return keys
      end
      keys = Array(LuaValue).new(@arr_len + @hash.size)
      @arr_len.times { |i| keys << (@arr_base + i).to_f64 unless @buf[i].nil? }
      if @smask > 0
        (@smask + 1).times do |i|
          k = @slots[i].key
          keys << k unless k.nil?
        end
      end
      keys.concat(@hash.keys)
      keys
    end

    # (Re)read __mode from the metatable and move storage between the
    # strong (array+hash) and weak (WCell pair) representations. Called
    # on every metatable assignment and from the mark phase (5.1 reads
    # __mode at GC time). Mode flags only matter at sweep.
    def refresh_weak : Nil
      mode = nil
      if (mt = @metatable) && (m = mt.raw_get("__mode")).is_a?(String)
        mode = m
      end
      wk = !mode.nil? && mode.not_nil!.includes?('k')
      wv = !mode.nil? && mode.not_nil!.includes?('v')
      if wk || wv
        items = [] of {WCell, WCell}
        if wi = @weak
          wi.each { |(kb, vb)| items << {kb, vb} }
        else
          raw_keys.each do |k|
            v = raw_get(k)
            items << {WCell.new(k), WCell.new(v)} unless v.nil?
          end
          @hash.clear
          @smask = 0 # string-key flat table dies with the strong side
          @scount = 0
          @arr_len = 0 # keep @buf/@arr_cap for reuse; slots past len are never read
          @len_cache = 0
        end
        @weak = items
      else
        if wi = @weak
          @weak = nil # raw_set below must take the strong path
          wi.each do |(kb, vb)|
            raw_set(kb.v, vb.v)
          end
        end
        @weak = nil
      end
      @weak_keys = wk
      @weak_vals = wv
    end

    # sweep (Lua.gc_full): drop entries whose weak side is unmarked.
    def sweep(m : GcMark) : Nil
      return unless wi = @weak
      wi.reject! do |(kb, vb)|
        (@weak_keys && !m.marked?(kb.v)) || (@weak_vals && !m.marked?(vb.v))
      end
    end

    # is this a weak table (used to steer mark traversal)
    def weak? : Bool
      !@weak.nil?
    end

    # mark-phase traversal: strong sides propagate; weak sides do NOT
    # mark (an entry dies with its weak side even if it is the only
    # reference — 5.1 has no ephemerons)
    def gc_mark_children(m : GcMark) : Nil
      @metatable.try { |mt| m.mark(mt) }
      if wi = @weak
        wi.each do |(kb, vb)|
          m.mark(kb.v) unless @weak_keys
          m.mark(vb.v) unless @weak_vals
        end
        return
      end
      @arr_len.times { |i| m.mark(@buf[i]) }
      if @smask > 0
        (@smask + 1).times do |i|
          m.mark(@slots[i].val)
        end
      end
      @hash.each { |k, v| m.mark(k); m.mark(v) }
    end

    def weak_item_count : Int32
      @weak.try(&.size) || 0
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
  # Type-feedback bits (JIT.md §2, M3 remainder): per-pc mask of the
  # NON-number operand shapes the interpreter observed. A clean byte
  # means "numbers only seen here" — the JIT specializes mono-numeric
  # with deopt guards; set bits make it emit the polymorphic shape.
  FB_STR = 1_u8 # string operands (arith coercion, string compares)
  FB_OTH = 2_u8 # any other non-number shape (metamethods, mixed compares)
  # Table-op shapes (GETTABLE/SETTABLE/SELF) outside the speculated fast
  # path (non-table object, metatable, non-number/non-integral key, out-of-
  # bounds, string-probe miss): recorded by jit_deopt itself — a deopt on a
  # table op IS the sample. The next compile emits the polymorphic
  # helper-fallback variant at this pc (same as pre-M3.6 code).
  FB_TMISS = 4_u8

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

    # Type feedback side-table (see FB_STR/FB_OTH above): one mask byte
    # per instruction, lazily allocated on the first non-number shape.
    # Monotone — bits are only ever OR-ed in, so feedback-driven
    # recompiles converge (Lua::JIT.on_deopt).
    property feedback : Array(UInt8)? = nil

    def fb_record(pc : Int32, bits : UInt8) : Nil
      (@feedback ||= Array(UInt8).new(packed.size, 0_u8))[pc] |= bits
    end

    # Call-site feedback (JIT M5): per-CALL-pc last-seen callee Proto,
    # recorded by the interpreter's CALL handler. A monomorphic site lets
    # the JIT inline the callee body behind a closure-identity guard; a
    # polymorphic site just misses the guard and takes the normal call.
    property call_fb : Array(Proto?)? = nil

    def call_record(pc : Int32, target : Proto) : Nil
      (@call_fb ||= Array(Proto?).new(packed.size, nil))[pc] = target
    end

    # Same, for single-argument numeric builtins (math.* with fast1):
    # records the LuaFunction OBJECT — the inline fast1 call guards on its
    # identity, so a rebound site simply misses and takes the slow path.
    property fast1_fb : Array(LuaFunction?)? = nil

    def fast1_record(pc : Int32, target : LuaFunction) : Nil
      (@fast1_fb ||= Array(LuaFunction?).new(packed.size, nil))[pc] = target
    end

    def initialize(@chunkname)
    end

    # JIT layout probe (jit/compiler.cr Layout): byte offsets for the
    # inlined direct-call fast path.
    def probe_offsets : {num_params: Int32, vararg: Int32, max_stack: Int32}
      p = self.as(Void*).address
      {num_params: (pointerof(@num_params).address - p).to_i32!,
       vararg:    (pointerof(@vararg).address - p).to_i32!,
       max_stack: (pointerof(@max_stack).address - p).to_i32!}
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

    # JIT layout probe (jit/compiler.cr Layout): byte offsets of the cell
    # fields for the inlined GETUPVAL. @stack is a nilable REFERENCE —
    # Crystal stores reference-or-Nil as a plain pointer with nil = 0 (no
    # union tag), so machine code compares it against null and branches:
    # open cells read the shared value stack, closed ones the cached value.
    def probe_offsets : {stack: Int32, idx: Int32, value: Int32}
      base = self.as(UInt8*).address
      {stack: (pointerof(@stack).address - base).to_i32!,
       idx:   (pointerof(@idx).address - base).to_i32!,
       value: (pointerof(@value).address - base).to_i32!}
    end
  end

  class LuaClosure
    getter proto : Proto
    getter upvals : Array(UpValue)
    # Function environment (5.1 setfenv/getfenv): nil = interpreter globals.
    property env : LuaTable? = nil
    # JIT (JIT.md 1.2): calls since creation; crossing Lua::JIT::THRESHOLD
    # tiers the closure up (stub in M0).
    property hot : Int32 = 0
    # Machine code entry once the JIT compiled this closure (M1+).
    property compiled : Pointer(Void)? = nil
    # Type-feedback compile state: the feedback mask snapshot this
    # compile specialized on (nil = compiled against a clean table) and
    # the compile generation — recompiles after deopt drift are bounded
    # (Lua::JIT.on_deopt).
    property fb_snap : Array(UInt8)? = nil
    property fb_gen : Int32 = 0
    # M5 hot-call inline: callee protos this compile inlined, paired with
    # the callee feedback masks it specialized on (nil = no inlined
    # callees). A callee going polymorphic widens these snapshots and
    # forces a recompile that drops the inline (see JIT.feedback_widened?).
    property inline_snaps : Array({Proto, Array(UInt8)})? = nil

    def initialize(@proto, @upvals)
    end

    # JIT layout probe (jit/compiler.cr Layout): byte offsets of proto /
    # compiled for the inlined direct-call fast path. NOTE: @compiled is
    # `Pointer(Void)?` — a NILABLE POINTER, which Crystal lays out as a
    # 16-byte union { i32 tag, payload } (not pointer-with-nil-0), so the
    # probe returns the payload offset plus the Pointer(Void) type id the
    # fast path must tag-check.
    def probe_offsets : {proto: Int32, compiled: Int32, compiled_tag: Int32, upvals: Int32}
      base = self.as(UInt8*).address
      old = @compiled
      @compiled = Pointer(Void).new(0xDEADBEEF_u64)
      cell = pointerof(@compiled).as(Pointer(Int32))
      tag = cell.value
      @compiled = old
      {proto:        (pointerof(@proto).address - base).to_i32!,
       compiled:     (pointerof(@compiled).address - base + 8).to_i32!,
       compiled_tag: tag,
       upvals:       (pointerof(@upvals).address - base).to_i32!}
    end

    def gc_mark_children(m : GcMark) : Nil
      @env.try { |e| m.mark(e) }
      @upvals.each do |u|
        if s = u.stack
          m.mark(s[u.idx]? || nil)
        else
          m.mark(u.value)
        end
      end
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
    # thread environment (debug.setfenv): swapped in as the interpreter's
    # default env for the duration of each resume
    property env : LuaTable? = nil
    property stack : Array(LuaValue)
    property frames : Array(Frame)
    property fsize : Int32 = 0
    property entries = [] of Int32 # run_frames entry stack, saved on suspend
    # Open-upvalue registry + high-water mark, swapped with the stacks (a
    # coroutine's captures must not alias the resumer's stack slots).
    property open_upvals = [] of UpValue
    property open_max : Int32 = -1
    # Running native (C) calls of THIS state — the interpreter's list is
    # swapped with the stacks on resume (the resumer's natives belong to
    # the parent state, not to the coroutine's level walks).
    property native_stack = [] of NativeEntry
    # The CALL/TAILCALL site that raised YieldSignal (vm.cr), saved on
    # suspend: {frame, abs result register (-1: tail call), CALL C, tail?}.
    property yield_call : {Frame, Int32, Int32, Bool}? = nil
    property? first_resume = true
    # Hooks are per-state (5.1 lua_sethook/getthread): swapped with the
    # stacks on resume. err_death: frames are kept (not released) after an
    # error so debug.traceback(co) still walks them, 5.1-style.
    property hook : LuaValue = nil
    property hook_mask : Int32 = 0
    property hook_count : Int32 = 0
    property hook_countdown : Int32 = 0
    property? err_death = false

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
      @native_stack = [] of NativeEntry
    end

    def gc_mark_children(m : GcMark) : Nil
      m.mark(@fn)
      m.mark(@hook)
      @stack.each { |v| m.mark(v) }
      @frames.first(@fsize).each { |fr| m.mark(fr.closure); fr.varargs.each { |v| m.mark(v) } }
      @open_upvals.each do |u|
        if s = u.stack
          m.mark(s[u.idx]? || nil)
        else
          m.mark(u.value)
        end
      end
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
    # 5.1 ci->tailcalls: tail calls that reused this frame — each is a
    # "lost" level reported by debug level walks as what="tail".
    property tail_calls : Int32 = 0
    # OSR: set while this frame's code continues in the interpreter after
    # a deopt from machine code entered via osr_run — the deopt session
    # must not tier the same loop up again (infinite OSR/deopt cycle)
    property? osr_blocked : Bool = false
    # pc of the last executed instruction, maintained while line hooks run
    # (5.1 L->savedpc): persists across a coroutine suspension.
    property old_pc : Int32 = -1

    def initialize(@closure, @base, @top, @varargs)
    end
  end

  alias NativeFn = Interp, Array(LuaValue) -> Array(LuaValue)

  # A running native (C) call for debug level walks: the function, the Lua
  # frame count at its entry (interleaving point, 5.1 CallInfo order) and
  # its arguments (C-frame locals are "(*temporary)").
  alias NativeEntry = {LuaValue, Int32, Array(LuaValue)}

  class LuaFunction
    getter name : String
    getter fn : NativeFn
    # Fast single-argument numeric invoke (math.* style): when set and the
    # call site passes exactly one Float64, the JIT dispatch answers it
    # directly — no args/result arrays, no native-stack frame (JIT.md 1.4;
    # the interpreted path keeps the full call_native machinery).
    property fast1 : (Float64 -> Float64)? = nil

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

  # Wrapper for Crystal objects exposed to Lua (interop).
  class LuaUserData
    getter obj : Exposable
    getter metatable : LuaTable? = nil

    def initialize(@obj : Exposable)
    end

    def metatable=(mt : LuaTable?)
      @metatable = mt
      Lua.register_finalizer(self, mt)
    end

    def metatable_no_reg=(mt : LuaTable?)
      @metatable = mt
    end
  end

  # --- Lua-visible GC ---
  #
  # Memory reclamation is Boehm's (Crystal GC). Liveness SEMANTICS —
  # what 5.1 scripts observe — come from our own precise mark over the
  # Lua object graph (Lua.gc_full): Boehm's conservative machine-stack
  # scan pins dead objects in interpreter temporaries, so WeakRef-based
  # liveness would never settle. Weak-table entries and __gc
  # registrations are judged by the mark phase; sweeping drops the
  # entries (letting Boehm reclaim on a later pass) and runs finalizers
  # with the real object (still strongly registered until then).

  # an object registered for __gc finalization (userdata only, as 5.1;
  # held STRONGLY — finalizers get the real object and may resurrect)
  class FinalReg
    getter obj : LuaValue
    getter mt : LuaTable

    def initialize(@obj, @mt)
    end
  end

  @@weak_tables = [] of WeakRef(LuaTable)
  @@finalizers = [] of FinalReg
  @@gc_step_acc = 0
  @@gc_pause = 200
  @@gc_stepmul = 200
  # fake incremental step limit in "bytes" (dosteps in gc.lua)
  STEP_LIMIT = 200
  # set once any table turns weak: gates the loop back-edge GC
  @@weak_seen = false

  def self.weak_seen? : Bool
    @@weak_seen
  end

  # address of the static flag (monotonic: set once any table turns weak,
  # never cleared) — the JIT embeds it as a constant and loads the byte
  # inline on loop back-edges instead of calling jit_weakcheck
  def self.weak_seen_addr : UInt64
    pointerof(@@weak_seen).address
  end

  # any weak table still alive? (drives the loop back-edge GC; dead
  # registrations are pruned here). Cheap: the list is empty in the
  # common case.
  def self.weak_active? : Bool
    return false if @@weak_tables.empty?
    @@weak_tables.reject! { |w| w.value.nil? }
    !@@weak_tables.empty?
  end

  def self.weak_key_eq(a : LuaValue, b : LuaValue) : Bool
    if a.is_a?(Float64) && b.is_a?(Float64)
      a == b
    elsif a.is_a?(String) && b.is_a?(String)
      a == b
    elsif a.is_a?(Bool) && b.is_a?(Bool)
      a == b
    else
      a.class == b.class && ref_same(a, b)
    end
  end

  # metatable assignment on a table: migrate weak storage and keep the
  # weak-table / finalizer registries in sync
  def self.refresh_weak(t : LuaTable) : Nil
    mt = t.metatable
    mode = nil
    if mt && (m = mt.raw_get("__mode")).is_a?(String)
      mode = m
    end
    if mode && (mode.includes?('k') || mode.includes?('v'))
      @@weak_seen = true
      unless @@weak_tables.any? { |w| (t2 = w.value) && t2.same?(t) }
        @@weak_tables << WeakRef(LuaTable).new(t)
      end
    else
      @@weak_tables.reject! { |w| (t2 = w.value) && t2.same?(t) }
    end
    t.refresh_weak
  end

  # userdata with a metatable is registered for finalization; whether
  # __gc exists is decided at collect time (5.1 lgc separateudata)
  def self.register_finalizer(u : LuaUserData, mt : LuaTable?) : Nil
    @@finalizers.reject! { |f| f.obj.as(LuaUserData).same?(u) }
    @@finalizers << FinalReg.new(u, mt) if mt
  end

  def self.register_finalizer(t : LuaTable, mt : LuaTable?) : Nil
    # 5.1 finalizes userdata only; tables accepted quietly
  end

  # full mark-and-sweep over the Lua graph (collectgarbage() and the
  # weak-gated loop back-edges). Expects stale VM registers to be
  # cleared first (Interp#gc_clear_stale).
  def self.gc_full(i : Interp) : Nil
    m = GcMark.new
    i.gc_roots { |v| m.mark(v) }
    m.run
    # prune dead weak-table refs, re-read __mode, sweep entries
    @@weak_tables.reject! { |w| w.value.nil? }
    @@weak_tables.each do |w|
      t = w.value.not_nil!
      t.refresh_weak
      t.sweep(m)
    end
    # finalizers: dead registrations run __gc with the real object, in
    # reverse registration order; handler errors are ignored (5.1)
    dead = @@finalizers.select { |f| !m.marked?(f.obj) }
    unless dead.empty?
      @@finalizers.reject! { |f| !m.marked?(f.obj) }
      dead.reverse_each do |f|
        hh = f.mt.raw_get("__gc")
        h = hh
        if h.is_a?(LuaClosure) || h.is_a?(LuaFunction) || h.is_a?(LuaTable)
          begin
            i.call(h, [f.obj] of LuaValue)
          rescue e : LuaError
            # 5.1 luaC: errors inside __gc are only warned about
          end
        end
      end
    end
  end

  # 5.1 gcinfo/collectgarbage("count"): KB in use and byte remainder,
  # from the Boehm heap stats (live ~= heap - free)
  def self.gc_count : {Float64, Float64}
    s = GC.stats
    live = (s.heap_size.to_i64 - s.free_bytes.to_i64).clamp(0..).to_f64
    {(live / 1024).floor, live % 1024}
  end

  # fake incremental step (Boehm is non-incremental): advance the byte
  # counter; a "cycle" finishes every STEP_LIMIT bytes
  def self.gc_step(siz : Int32) : Bool
    @@gc_step_acc += {siz, 1}.max
    if @@gc_step_acc >= STEP_LIMIT
      @@gc_step_acc = 0
      true
    else
      false
    end
  end

  def self.gc_set_pause(v : Int32) : Int32
    old = @@gc_pause
    @@gc_pause = v
    old
  end

  def self.gc_set_stepmul(v : Int32) : Int32
    old = @@gc_stepmul
    @@gc_stepmul = v
    old
  end

  # spec/debug helper: live weak tables + registrations
  def self.gc_debug_counts : {Int32, Int32, Int32}
    wt = @@weak_tables.count { |w| !w.value.nil? }
    items = @@weak_tables.sum { |w| (t = w.value) ? t.weak_item_count : 0 }
    {wt, @@finalizers.size, items}
  end
end
