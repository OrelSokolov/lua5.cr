# Lua values and runtime objects. Port of MoonSharp DataTypes/ (DynValue,
# Table, Closure, CallbackFunction) onto idiomatic Crystal: values are a
# plain union of reference types + immediates.
module Lua
  alias LuaValue = Nil | Bool | Float64 | String | LuaTable | LuaClosure | LuaFunction | LuaUserData

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
    when LuaTable    then r.is_a?(LuaTable) && l.same?(r)
    when LuaClosure  then r.is_a?(LuaClosure) && l.same?(r)
    when LuaFunction then r.is_a?(LuaFunction) && l.same?(r)
    when LuaUserData then r.is_a?(LuaUserData) && l.same?(r)
    else                  l.nil? && r.nil?
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
    else
      t.to_f64?
    end
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
    getter value : LuaValue

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

  def self.repr_addr(v : LuaValue) : String
    case v
    when LuaTable    then "table: 0x#{v.object_id.to_s(16)}"
    when LuaClosure  then "function: 0x#{v.object_id.to_s(16)}"
    when LuaFunction then "function: builtin: 0x#{v.object_id.to_s(16)}"
    when LuaUserData then "userdata: 0x#{v.object_id.to_s(16)}"
    else                  v.to_s
    end
  end

  # Non-local exits for the tree interpreter.
  class ReturnSignal < Exception
    property values : Array(LuaValue) = [] of LuaValue
  end

  class BreakSignal < Exception
  end

  # Proper tail call: `return f(args)` unwinds one interpreter frame and
  # re-enters Interp#call in a loop instead of recursing.
  class TailCallSignal < Exception
    property fn : LuaValue
    property args : Array(LuaValue)

    def initialize(@fn, @args)
      super("tail call")
    end
  end

  # --- table ---

  class LuaTable
    property metatable : LuaTable? = nil
    @hash = Hash(LuaValue, LuaValue).new

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

    def raw_get(key : LuaValue) : LuaValue
      check_key(key)
      v = @hash[key]?
      v.nil? ? nil : v
    end

    def raw_set(key : LuaValue, val : LuaValue) : Nil
      check_key(key)
      if val.nil?
        @hash.delete(key)
      else
        @hash[key] = val
      end
    end

    def has_key?(key : LuaValue) : Bool
      !key.nil? && @hash.has_key?(key)
    end

    # #t: 1..n while consecutive keys exist.
    def raw_length : Int32
      n = 0
      while @hash.has_key?((n + 1).to_f64)
        n += 1
      end
      n
    end

    def raw_keys : Array(LuaValue)
      @hash.keys
    end
  end

  # --- functions ---

  class LuaClosure
    getter proto : AST::FuncE
    getter env : Env

    def initialize(@proto, @env)
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

  # Wrapper for a Crystal object exposed to Lua (interop).
  class LuaUserData
    property obj : Exposable
    property metatable : LuaTable? = nil

    def initialize(@obj : Exposable)
    end
  end

  # --- environments ---

  # A local slot; closures capture the cell, not the value.
  class Cell
    property value : LuaValue = nil
  end

  class Env
    property varargs : Array(LuaValue)? = nil
    @vars = {} of String => Cell

    def initialize(@parent : Env? = nil, @func_env = false)
    end

    def func_env? : Bool
      @func_env
    end

    def define(name : String, val : LuaValue) : Nil
      c = Cell.new
      c.value = val
      @vars[name] = c
    end

    def find(name : String) : Cell?
      e : Env? = self
      while e
        if c = e.@vars[name]?
          return c
        end
        e = e.@parent
      end
      nil
    end

    def find_varargs : Array(LuaValue)?
      e : Env? = self
      while e
        return e.varargs if e.func_env?
        e = e.@parent
      end
      nil
    end
  end
end
