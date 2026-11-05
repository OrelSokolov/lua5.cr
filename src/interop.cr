# Crystal↔Lua interop — the whole point of lua5.cr. Port of MoonSharp
# Interop/ (StandardUserDataDescriptor / AutoDescriptiveUserData) onto
# Crystal macros + compile-time reflection instead of .NET reflection.
#
# This MVP slice: annotate instance methods with @[LuaMethod], call
# `expose Klass`, then pass instances into Lua via `interp.expose_object`.
# Full layer (constructors, inheritance, overloads) — Phase 4 of PLAN.md.
#
# No C boundary anywhere: methods receive/return Crystal values directly,
# Lua errors are Crystal exceptions, and every object lives in the shared
# Boehm heap.

annotation LuaMethod; end

module Lua
  module Interop
    # Keyed by class *name*: instantiating Hash(Object.class, ...) next to
    # Interp crashes the Crystal 1.21 compiler (verified minimal repro:
    # `h = {} of Object.class => Int32; Interp.new`), so we avoid class
    # objects as hash keys entirely.
    REGISTRY = {} of String => Hash(String, NativeFn)

    def self.register_method(klass_name : String, name : String, fn : NativeFn) : Nil
      (REGISTRY[klass_name] ||= {} of String => NativeFn)[name] = fn
    end

    # Wrap a Crystal object: LuaUserData whose metatable __index maps method
    # names to LuaFunctions receiving the userdata as their first argument.
    def self.wrap(obj : Exposable) : LuaUserData
      u = LuaUserData.new(obj)
      if methods = REGISTRY[obj.class.name]?
        mtbl = LuaTable.new
        methods.each do |n, f|
          mtbl.raw_set(n, LuaFunction.new("#{obj.class}.#{n}", f))
        end
        mt = LuaTable.new
        mt.raw_set("__index", mtbl)
        u.metatable = mt
      end
      u
    end

    def self.self_of(args : Array(LuaValue), klass : T.class) : T forall T
      u = args[0]?
      if u.is_a?(LuaUserData) && (o = u.obj.as?(T))
        o
      else
        raise LuaError.new("bad self argument (expected #{T}, got #{Lua.type_name(u)})")
      end
    end

    # --- typed argument converters (used by generated code) ---

    def self.arg_t(args : Array(LuaValue), i : Int32, t : String.class) : String
      v = args[i]?
      return v if v.is_a?(String)
      raise LuaError.new("bad argument ##{i}: string expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Int32.class) : Int32
      v = args[i]?
      if v.is_a?(Float64) && v == v.trunc
        return v.to_i32
      end
      raise LuaError.new("bad argument ##{i}: integer expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Int64.class) : Int64
      v = args[i]?
      if v.is_a?(Float64) && v == v.trunc
        return v.to_i64
      end
      raise LuaError.new("bad argument ##{i}: integer expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Float64.class) : Float64
      v = args[i]?
      if v.is_a?(Float64)
        return v
      end
      raise LuaError.new("bad argument ##{i}: number expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Bool.class) : Bool
      v = args[i]?
      return v if v.is_a?(Bool)
      raise LuaError.new("bad argument ##{i}: boolean expected, got #{Lua.type_name(v)}")
    end

    # Return-value conversion; exposed objects get wrapped as userdata —
    # Crystal object graphs flow into Lua. (Explicit is_a? chains: case
    # narrowing misbehaves on unions that mix modules and generic types.)
    def self.ret(v) : Array(LuaValue)
      if v.nil?
        [] of LuaValue
      elsif v.is_a?(Bool) || v.is_a?(Float64) || v.is_a?(String) ||
            v.is_a?(LuaTable) || v.is_a?(LuaClosure) || v.is_a?(LuaFunction) || v.is_a?(LuaUserData)
        [v] of LuaValue
      elsif v.is_a?(Int32 | Int64 | Int16 | Int8 | UInt8 | UInt32 | UInt16 | UInt64)
        [v.to_f64] of LuaValue
      elsif v.is_a?(Exposable)
        [wrap(v)] of LuaValue
      else
        raise LuaError.new("cannot convert return value #{v.class} to a Lua value")
      end
    end
  end

  class Interp
    # Expose a Crystal object as a Lua global (its class must be `expose`d).
    def expose_object(name : String, obj : Exposable) : Nil
      @globals.raw_set(name, Interop.wrap(obj))
    end
  end
end

# expose Klass — register all @[LuaMethod] instance methods of Klass.
#
# Argument conversion follows the method's type restrictions (String, Int32,
# Int64, Float64, Bool); unrestricted parameters pass the raw LuaValue.
# Return values convert via Lua::Interop.ret (void => no values).
macro expose(klass)
  {% k = klass.resolve %}
  {% found = 0 %}
  {% for m in k.methods %}
    {% if m.annotation(LuaMethod) %}
      {% found = found + 1 %}
    {% end %}
  {% end %}
  {% if found == 0 %}
    {% raise "expose: no @[LuaMethod] methods found in #{k}" %}
  {% end %}
  class ::{{k}}
    include Lua::Exposable
  end
  {% for m in k.methods %}
    {% if m.annotation(LuaMethod) %}
      Lua::Interop.register_method({{k.stringify}}, {{m.name.stringify}}, ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
        slf = Lua::Interop.self_of(args, {{k}})
        {% if m.args.empty? %}
          Lua::Interop.ret(slf.{{m.name.id}})
        {% else %}
          Lua::Interop.ret(slf.{{m.name.id}}(
            {% for arg, ai in m.args %}
              {% if arg.restriction %}
                Lua::Interop.arg_t(args, {{ai + 1}}, {{arg.restriction}})
              {% else %}
                (args[{{ai + 1}}]?)
              {% end %}
              {% unless ai == m.args.size - 1 %},{% end %}
            {% end %}
          ))
        {% end %}
      })
    {% end %}
  {% end %}
end
