# Crystal↔Lua interop — the whole point of lua5.cr. Port of MoonSharp
# Interop/ (StandardUserDataDescriptor / AutoDescriptiveUserData) onto
# Crystal macros + compile-time reflection instead of .NET reflection.
#
# Full layer (PLAN.md, phase 4):
#   @[LuaMethod]      — instance methods, overloads dispatch by arg types
#   @[LuaProperty]    — getters/setters visible as Lua fields
#   @[LuaConstructor] — `Klass.new(...)` from Lua
#   inheritance       — superclass methods via __index chains
#   converters        — both directions, nilable, Array↔table; add your
#                       own by defining more arg_t/ret overloads
#   error model       — Lua errors and Crystal exceptions cross the
#                       boundary losslessly in both directions
#
# No C boundary anywhere: methods receive/return Crystal values directly,
# Lua errors are Crystal exceptions, and every object lives in the shared
# Boehm heap.

annotation LuaMethod; end
annotation LuaProperty; end
annotation LuaConstructor; end

module Lua
  module Interop
    # --- overload dispatch (luabind match_signature style) ---

    # Argument kinds a signature can require (compile-time generated).
    KIND_ANY = 0
    KIND_NUM = 1
    KIND_INT = 2
    KIND_STR = 3
    KIND_BOOL = 4
    KIND_TABLE = 5
    KIND_OBJ = 6 # any exposed userdata
    NILABLE = 16 # OR'ed in: also accepts nil / a missing argument

    class Overload
      getter fn : NativeFn
      getter kinds : Array(Int32) # one per parameter
      getter min_args : Int32
      getter label : String

      def initialize(@fn, @kinds, @min_args, @label)
      end

      def max_args : Int32
        @kinds.size
      end

      # -1 = no match; otherwise the higher the better (exact > any).
      def match_score(argn : Int32, args : Array(LuaValue)) : Int32
        return -1 if argn < @min_args || argn > max_args
        score = 0
        @kinds.each_with_index do |k, i|
          kind = k & ~NILABLE
          v = args[i + 1]?
          if v.nil?
            return -1 unless k & NILABLE > 0 || i >= argn
            score += 1
          else
            score += kind_score(kind, v)
          end
        end
        score
      end

      private def kind_score(kind : Int32, v : LuaValue) : Int32
        case kind
        when KIND_ANY then 1
        when KIND_NUM then v.is_a?(Float64) ? 2 : -1
        when KIND_INT
          v.is_a?(Float64) && v == v.trunc ? 2 : -1
        when KIND_STR   then v.is_a?(String) ? 2 : -1
        when KIND_BOOL  then v.is_a?(Bool) ? 2 : -1
        when KIND_TABLE then v.is_a?(LuaTable) ? 2 : -1
        when KIND_OBJ   then v.is_a?(LuaUserData) ? 2 : -1
        else                 1
        end
      end
    end

    # One exposed Crystal class. Keyed by class *name*: instantiating
    # Hash(Object.class, ...) next to Interp crashes the Crystal 1.21
    # compiler (verified minimal repro: `h = {} of Object.class => Int32;
    # Interp.new`), so we avoid class objects as hash keys entirely.
    class ClassDef
      property overloads = {} of String => Array(Overload)
      property getters = {} of String => NativeFn
      property setters = {} of String => NativeFn
      property ctors = [] of Overload
      property parent : String? = nil
      property new_fn : NativeFn? = nil

      def initialize(@name : String)
      end

      getter name : String

      def add_method(name : String, ol : Overload) : Nil
        (overloads[name] ||= [] of Overload) << ol
      end
    end

    REGISTRY = {} of String => ClassDef
    METHODS_TABLES = {} of String => LuaTable

    def self.class_def(klass_name : String) : ClassDef
      REGISTRY[klass_name] ||= ClassDef.new(klass_name)
    end

    def self.register_parent(klass_name : String, parent_name : String?) : Nil
      class_def(klass_name).parent = parent_name
      METHODS_TABLES.delete(klass_name) # rebuild chains lazily
    end

    def self.register_method(klass_name : String, name : String,
                             kinds : Array(Int32), min_args : Int32, fn : NativeFn) : Nil
      class_def(klass_name).add_method(name,
        Overload.new(fn, kinds, min_args, "#{klass_name}.#{name}"))
      METHODS_TABLES.delete(klass_name)
    end

    def self.register_getter(klass_name : String, name : String, fn : NativeFn) : Nil
      class_def(klass_name).getters[name] = fn
      METHODS_TABLES.delete(klass_name)
    end

    def self.register_setter(klass_name : String, name : String, fn : NativeFn) : Nil
      class_def(klass_name).setters[name] = fn
      METHODS_TABLES.delete(klass_name)
    end

    def self.register_ctor(klass_name : String,
                           kinds : Array(Int32), min_args : Int32, fn : NativeFn) : Nil
      class_def(klass_name).ctors << Overload.new(fn, kinds, min_args, "#{klass_name}.new")
    end

    def self.set_new_fn(klass_name : String, fn : NativeFn) : Nil
      class_def(klass_name).new_fn = fn
    end

    # Pick the best-matching overload and run it; loud error otherwise.
    # A single overload runs directly so its converter errors stay precise.
    def self.dispatch(label : String, ols : Array(Overload),
                      interp : Interp, args : Array(LuaValue)) : Array(LuaValue)
      return ols.first.fn.call(interp, args) if ols.size == 1
      argn = args.size - 1 # args[0] is self/new
      best : Overload? = nil
      best_score = -1
      ols.each do |ol|
        s = ol.match_score(argn, args)
        if s > best_score
          best = ol
          best_score = s
        end
      end
      if ol = best
        ol.fn.call(interp, args)
      else
        raise LuaError.new("bad arguments to '#{label}' (no overload matches #{argn} argument(s))")
      end
    end

    # The class's methods table, shared by all instances (state lives in
    # args[0]); the superclass table is chained via its own __index.
    def self.methods_table(klass_name : String) : LuaTable
      METHODS_TABLES[klass_name]? || build_methods_table(klass_name)
    end

    private def self.build_methods_table(klass_name : String) : LuaTable
      cd = class_def(klass_name)
      tbl = LuaTable.new
      cd.overloads.each do |name, ols|
        label = "#{klass_name}.#{name}"
        tbl.raw_set(name, LuaFunction.new(label, ->(i2 : Interp, args : Array(LuaValue)) {
          dispatch(label, ols, i2, args)
        }))
      end
      if parent = cd.parent
        if parent != klass_name && REGISTRY[parent]?
          pmt = methods_table(parent)
          mt = LuaTable.new
          mt.raw_set("__index", pmt)
          tbl.metatable = mt
        end
      end
      METHODS_TABLES[klass_name] = tbl
      tbl
    end

    # Getters live in their own chained table so the userdata __index
    # function can call them (a table __index would yield the function
    # object itself, not the property value).
    private def self.getter_table(klass_name : String) : LuaTable
      cd = class_def(klass_name)
      tbl = LuaTable.new
      cd.getters.each do |name, fn|
        tbl.raw_set(name, LuaFunction.new("#{klass_name}.#{name}", fn))
      end
      if parent = cd.parent
        if parent != klass_name && REGISTRY[parent]?
          pgt = getter_table(parent)
          mt = LuaTable.new
          mt.raw_set("__index", pgt)
          tbl.metatable = mt
        end
      end
      tbl
    end

    # Property setter by name, walking the superclass chain.
    def self.setter_for(klass_name : String, key : String) : NativeFn?
      cd = REGISTRY[klass_name]?
      while cd
        if fn = cd.setters[key]?
          return fn
        end
        parent = cd.parent
        cd = (parent && parent != klass_name) ? REGISTRY[parent]? : nil
      end
      nil
    end

    # Wrap a Crystal object: LuaUserData with a metatable whose __index
    # function resolves property getters (calling them) and methods
    # (returning the callable), chained to superclasses; __newindex routes
    # property setters.
    def self.wrap(obj : Exposable) : LuaUserData
      u = LuaUserData.new(obj)
      klass_name = obj.class.name
      if REGISTRY[klass_name]?
        mt = LuaTable.new
        ilabel = "#{klass_name}.__index"
        methods = methods_table(klass_name)
        getters = getter_table(klass_name)
        mt.raw_set("__index", LuaFunction.new(ilabel, ->(i2 : Interp, args : Array(LuaValue)) {
          key = args[1]?
          if key.is_a?(String) && (g = i2.getindex(getters, key))
            gf = g.as(LuaFunction)
            return gf.fn.call(i2, [args[0]?] of LuaValue)
          end
          [i2.getindex(methods, key)] of LuaValue
        }))
        cd = class_def(klass_name)
        has_setters = cd.setters.any? || has_setter_in_chain?(klass_name)
        if has_setters
          nlabel = "#{klass_name}.__newindex"
          mt.raw_set("__newindex", LuaFunction.new(nlabel, ->(i2 : Interp, args : Array(LuaValue)) {
            key = args[1]?
            k = key.is_a?(String) ? key : Lua.repr_addr(key)
            if fn = setter_for(klass_name, k)
              fn.call(i2, [args[0]?, args[2]?] of LuaValue)
            else
              i2.raise_lua("no settable property '#{k}' on #{klass_name}")
            end
          }))
        end
        u.metatable = mt
      end
      u
    end

    private def self.has_setter_in_chain?(klass_name : String) : Bool
      cd = REGISTRY[klass_name]?
      while cd
        return true unless cd.setters.empty?
        parent = cd.parent
        cd = (parent && parent != klass_name) ? REGISTRY[parent]? : nil
      end
      false
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
    # Extend the set for your own types by adding arg_t overloads.
    # `nilable = true` (generated for `T?` restrictions) also accepts a
    # missing/nil argument.

    def self.arg_t(args : Array(LuaValue), i : Int32, t : String.class, nilable = false) : String
      v = args[i]?
      return v if v.is_a?(String)
      raise LuaError.new("bad argument ##{i}: string expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Int32.class, nilable = false) : Int32
      v = args[i]?
      if v.is_a?(Float64) && v == v.trunc
        return v.to_i32
      end
      raise LuaError.new("bad argument ##{i}: integer expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Int64.class, nilable = false) : Int64
      v = args[i]?
      if v.is_a?(Float64) && v == v.trunc
        return v.to_i64
      end
      raise LuaError.new("bad argument ##{i}: integer expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Float64.class, nilable = false) : Float64
      v = args[i]?
      if v.is_a?(Float64)
        return v
      end
      raise LuaError.new("bad argument ##{i}: number expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Bool.class, nilable = false) : Bool
      v = args[i]?
      return v if v.is_a?(Bool)
      raise LuaError.new("bad argument ##{i}: boolean expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : LuaTable.class, nilable = false) : LuaTable
      v = args[i]?
      return v if v.is_a?(LuaTable)
      raise LuaError.new("bad argument ##{i}: table expected, got #{Lua.type_name(v)}")
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : LuaUserData.class, nilable = false) : LuaUserData
      v = args[i]?
      return v if v.is_a?(LuaUserData)
      raise LuaError.new("bad argument ##{i}: userdata expected, got #{Lua.type_name(v)}")
    end

    # Generic fallback: an exposed Crystal class as parameter — unwraps
    # the userdata, loud error on a foreign object.
    def self.arg_t(args : Array(LuaValue), i : Int32, t : T.class, nilable = false) : T forall T
      v = args[i]?
      if v.is_a?(LuaUserData) && (o = v.obj.as?(T))
        return o
      end
      raise LuaError.new("bad argument ##{i}: #{T} expected, got #{Lua.type_name(v)}")
    end

    # `T?` variants: accept a missing/nil argument, return T?.
    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : String.class) : String?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Int32.class) : Int32?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Int64.class) : Int64?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Float64.class) : Float64?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Bool.class) : Bool?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : LuaTable.class) : LuaTable?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : LuaUserData.class) : LuaUserData?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : T.class) : T? forall T
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Array(String).class) : Array(String)?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Array(Float64).class) : Array(Float64)?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    def self.arg_t_opt(args : Array(LuaValue), i : Int32, t : Array(LuaValue).class) : Array(LuaValue)?
      v = args[i]?
      return nil if v.nil?
      arg_t(args, i, t)
    end

    # Array(T) ← table array part (1..#t), converting every element.
    def self.arg_t(args : Array(LuaValue), i : Int32, t : Array(String).class, nilable = false) : Array(String)
      table_elements(args, i, "Array(String)").map(&.as(String))
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Array(Float64).class, nilable = false) : Array(Float64)
      table_elements(args, i, "Array(Float64)").map { |v| v.as(Float64) }
    end

    def self.arg_t(args : Array(LuaValue), i : Int32, t : Array(LuaValue).class, nilable = false) : Array(LuaValue)
      table_elements(args, i, "Array(LuaValue)")
    end

    private def self.table_elements(args : Array(LuaValue), i : Int32, want : String) : Array(LuaValue)
      v = args[i]?
      unless v.is_a?(LuaTable)
        raise LuaError.new("bad argument ##{i}: table expected for #{want}, got #{Lua.type_name(v)}")
      end
      n = v.raw_length
      vals = Array(LuaValue).new(n)
      (1..n).each do |k|
        e = v.raw_get(k.to_f64)
        raise LuaError.new("bad argument ##{i}: hole at index #{k} in #{want} source table") if e.nil?
        vals << e
      end
      # holes past the border: array keys exist beyond the 1..n prefix
      v.raw_keys.each do |k|
        if k.is_a?(Float64) && (ki = k.trunc) && ki == k && ki > n
          raise LuaError.new("bad argument ##{i}: hole at index #{n + 1} in #{want} source table")
        end
      end
      vals
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
      elsif v.is_a?(Array(Float64)) || v.is_a?(Array(String)) || v.is_a?(Array(Int32)) ||
            v.is_a?(Array(Int64)) || v.is_a?(Array(Bool)) || v.is_a?(Array(LuaValue))
        [ret_array(v)] of LuaValue
      elsif v.is_a?(Exposable)
        [wrap(v)] of LuaValue
      else
        raise LuaError.new("cannot convert return value #{v.class} to a Lua value")
      end
    end

    def self.ret_array(v) : LuaTable
      t = LuaTable.new
      v.each_with_index do |e, i|
        t.raw_set((i + 1).to_f64, to_lua(e))
      end
      t
    end

    # Single value → Lua value (used by ret_array); same rules as ret.
    def self.to_lua(v) : LuaValue
      case v
      when Nil, Bool, Float64, String, LuaTable, LuaClosure, LuaFunction, LuaUserData
        v
      when Int32, Int64, Int16, Int8, UInt8, UInt16, UInt32, UInt64
        v.to_f64
      when Array(Float64), Array(String), Array(Int32), Array(Int64), Array(Bool), Array(LuaValue)
        ret_array(v)
      when Exposable
        wrap(v)
      else
        raise LuaError.new("cannot convert #{v.class} to a Lua value")
      end
    end
  end

  class Interp
    # Expose a Crystal object as a Lua global (its class must be `expose`d).
    def expose_object(name : String, obj : Exposable) : Nil
      @globals.raw_set(name, Interop.wrap(obj))
    end

    # Expose a Crystal class as a global table with a callable `new`
    # (the class must be `expose`d and have @[LuaConstructor] initializes).
    def expose_class(global_name : String, klass : T.class) : Nil forall T
      cd = Interop.class_def(klass.name)
      unless new_fn = cd.new_fn
        raise LuaError.new("class #{klass} has no exposed constructor (annotate initialize with @[LuaConstructor])")
      end
      table = LuaTable.new
      table.raw_set("new", LuaFunction.new("#{global_name}.new", new_fn))
      table.raw_set("__name", klass.name)
      @globals.raw_set(global_name, table)
    end
  end
end

# expose Klass — register the full interop surface of Klass:
# @[LuaMethod] methods (overloads dispatched by argument types),
# @[LuaProperty] getters/setters, @[LuaConstructor] initializes, and the
# superclass chain (when the superclass is exposed too).
#
# Argument conversion follows the method's type restrictions (String,
# Int32, Int64, Float64, Bool, Array(String|Float64|LuaValue), nilable
# variants via `T?`, and any exposed class as a userdata parameter);
# unrestricted parameters accept any Lua value. Return values convert
# via Lua::Interop.ret (void => no values).
macro expose(klass)
  {% k = klass.resolve %}
  {% found = 0 %}
  {% for m in k.methods %}
    {% if m.annotation(LuaMethod) || m.annotation(LuaProperty) || m.annotation(LuaConstructor) %}
      {% found = found + 1 %}
    {% end %}
  {% end %}
  {% if found == 0 %}
    {% raise "expose: no @[LuaMethod]/@[LuaProperty]/@[LuaConstructor] found in #{k}" %}
  {% end %}

  # Constructors: own annotated initializes, or the nearest ancestor's
  # (subclasses stay constructible without re-declaring initialize).
  {% ctor_defs = k.methods.select { |m| m.annotation(LuaConstructor) } %}
  {% if ctor_defs.empty? %}
    {% for a in k.ancestors %}
      {% if ctor_defs.empty? %}
        {% inherited = a.methods.select { |m| m.annotation(LuaConstructor) } %}
        {% if !inherited.empty? %}{% ctor_defs = inherited %}{% end %}
      {% end %}
    {% end %}
  {% end %}
  {% for m in ctor_defs %}
    {% if m.name.stringify != "initialize" %}
      {% raise "expose: @[LuaConstructor] is only valid on initialize (#{k}##{m.name})" %}
    {% end %}
  {% end %}

  class ::{{k}}
    include Lua::Exposable
    {% for m in ctor_defs %}
      # public forwarder: initialize is protected, generated ctor procs
      # call this one from outside
      def __lua_init({{ m.args.map { |a| a.name.id.stringify + (a.restriction ? " : " + a.restriction.stringify : "") }.join(", ").id }})
        initialize({{ m.args.map(&.name.id).join(", ").id }})
      end
    {% end %}
  end

  {% sk = k.superclass %}
  {% if sk && sk.stringify != "Reference" && sk.stringify != "Object" && sk.stringify != "Nil" %}
    Lua::Interop.register_parent({{k.stringify}}, {{sk.stringify}})
  {% else %}
    Lua::Interop.register_parent({{k.stringify}}, nil)
  {% end %}

  {% for m in k.methods %}
    {% if m.annotation(LuaMethod) %}
      {% if m.splat_index %}
        {% raise "expose: splat parameters are not supported (#{k}##{m.name})" %}
      {% end %}
      {% kinds = [] of Int32 %}
      {% min_args = 0 %}
      {% for arg in m.args %}
        {% if arg.restriction %}
          {% rs = arg.restriction.stringify %}
          {% nilable = rs =~ /\?\z/ || rs =~ /\|\s*::?Nil\z/ %}
          {% base = rs.gsub(/\?\z/, "").gsub(/\s*\|\s*::?Nil\z/, "") %}
          {% kind = base == "String" ? 3 : (base == "Int32" || base == "Int64") ? 2 : base == "Float64" ? 1 : base == "Bool" ? 4 : (base == "Lua::LuaTable" || base == "LuaTable" || base =~ /\AArray\(/) ? 5 : (base == "Lua::LuaUserData" || base == "LuaUserData") ? 6 : 0 %}
          {% kinds << (kind + (nilable ? 16 : 0)) %}
          {% if arg.default_value.nil? && !nilable %}{% min_args = min_args + 1 %}{% end %}
        {% else %}
          {% kinds << 0 %}
          {% if arg.default_value.nil? %}{% min_args = min_args + 1 %}{% end %}
        {% end %}
      {% end %}
      Lua::Interop.register_method({{k.stringify}}, {{m.name.stringify}}, {% if kinds.empty? %}[] of Int32{% else %}{{kinds}}{% end %}, {{min_args}},
        ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
          slf = Lua::Interop.self_of(args, {{k}})
          # the rescue passthrough defeats Crystal's NoReturn proc-body
          # cleanup ("can't execute ...") for methods that always raise
          begin
            {% if m.args.empty? %}
              Lua::Interop.ret(slf.{{m.name.id}})
            {% else %}
              {% call_args = "" %}
            {% for arg, ai in m.args %}
              {% sep = call_args.empty? ? "" : ", " %}
              {% if arg.restriction %}
                {% rs2 = arg.restriction.stringify %}
                {% nil2 = rs2 =~ /\?\z/ || rs2 =~ /\|\s*::?Nil\z/ %}
                {% base2 = rs2.gsub(/\?\z/, "").gsub(/\s*\|\s*::?Nil\z/, "") %}
                {% if nil2 %}
                  {% call_args = call_args + sep + "Lua::Interop.arg_t_opt(args, #{ai + 1}, #{base2.id})" %}
                {% else %}
                  {% call_args = call_args + sep + "Lua::Interop.arg_t(args, #{ai + 1}, #{rs2.id})" %}
                {% end %}
              {% else %}
                {% call_args = call_args + sep + "(args[#{ai + 1}]?)" %}
              {% end %}
            {% end %}
            Lua::Interop.ret(slf.{{m.name.id}}({{call_args.id}}))
          {% end %}
          rescue e : Exception
            raise e
          end
        })
    {% end %}
    {% if m.annotation(LuaProperty) %}
      {% if m.name.stringify =~ /=$/ %}
        {% prop = m.name.stringify.gsub(/=$/, "").id %}
        Lua::Interop.register_setter({{k.stringify}}, {{prop.stringify}}, ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
          slf = Lua::Interop.self_of(args, {{k}})
          begin
            {% set_arg = "(args[1]?)" %}
          {% if m.args.size == 1 && m.args[0].restriction %}
            {% rs3 = m.args[0].restriction.stringify %}
            {% if rs3 =~ /\?\z/ || rs3 =~ /\|\s*::?Nil\z/ %}
              {% set_arg = "Lua::Interop.arg_t(args, 1, #{rs3.gsub(/\?\z/, "").gsub(/\s*\|\s*::?Nil\z/, "").id}, true)" %}
            {% else %}
              {% set_arg = "Lua::Interop.arg_t(args, 1, #{rs3.id})" %}
            {% end %}
          {% end %}
          slf.{{m.name.id}}({{set_arg.id}})
          [] of Lua::LuaValue
          rescue e : Exception
            raise e
          end
        })
      {% else %}
        Lua::Interop.register_getter({{k.stringify}}, {{m.name.stringify}}, ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
          slf = Lua::Interop.self_of(args, {{k}})
          begin
            Lua::Interop.ret(slf.{{m.name.id}})
          rescue e : Exception
            raise e
          end
        })
      {% end %}
    {% end %}
  {% end %}

  {% for m in ctor_defs %}
    {% kinds = [] of Int32 %}
    {% min_args = 0 %}
    {% for arg in m.args %}
      {% if arg.restriction %}
        {% rs = arg.restriction.stringify %}
        {% nilable = rs =~ /\?\z/ || rs =~ /\|\s*::?Nil\z/ %}
        {% base = rs.gsub(/\?\z/, "").gsub(/\s*\|\s*::?Nil\z/, "") %}
        {% kind = base == "String" ? 3 : (base == "Int32" || base == "Int64") ? 2 : base == "Float64" ? 1 : base == "Bool" ? 4 : (base == "Lua::LuaTable" || base == "LuaTable" || base =~ /\AArray\(/) ? 5 : (base == "Lua::LuaUserData" || base == "LuaUserData") ? 6 : 0 %}
        {% kinds << (kind + (nilable ? 16 : 0)) %}
        {% if arg.default_value.nil? && !nilable %}{% min_args = min_args + 1 %}{% end %}
      {% else %}
        {% kinds << 0 %}
        {% if arg.default_value.nil? %}{% min_args = min_args + 1 %}{% end %}
      {% end %}
    {% end %}
    Lua::Interop.register_ctor({{k.stringify}}, {% if kinds.empty? %}[] of Int32{% else %}{{kinds}}{% end %}, {{min_args}},
      ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
        obj = {{k}}.allocate
        begin
        {% init_args = "" %}
        {% for arg, ai in m.args %}
          {% sep = init_args.empty? ? "" : ", " %}
          {% if arg.restriction %}
            {% rs2 = arg.restriction.stringify %}
            {% nil2 = rs2 =~ /\?\z/ || rs2 =~ /\|\s*::?Nil\z/ %}
            {% base2 = rs2.gsub(/\?\z/, "").gsub(/\s*\|\s*::?Nil\z/, "") %}
            {% if nil2 %}
              {% init_args = init_args + sep + "Lua::Interop.arg_t_opt(args, #{ai + 1}, #{base2.id})" %}
            {% else %}
              {% init_args = init_args + sep + "Lua::Interop.arg_t(args, #{ai + 1}, #{rs2.id})" %}
            {% end %}
          {% else %}
            {% init_args = init_args + sep + "(args[#{ai + 1}]?)" %}
          {% end %}
        {% end %}
        obj.as({{k}}).__lua_init({{init_args.id}})
        [Lua::Interop.wrap(obj)] of Lua::LuaValue
        rescue e : Exception
          raise e
        end
      })
  {% end %}

  # Klass.new(...) from Lua: dispatch over @[LuaConstructor] overloads.
  Lua::Interop.set_new_fn({{k.stringify}}, ->(interp : Lua::Interp, args : Array(Lua::LuaValue)) : Array(Lua::LuaValue) {
    cd = Lua::Interop.class_def({{k.stringify}})
    ctors = cd.ctors
    if ctors.empty?
      interp.raise_lua("class {{k}} has no @[LuaConstructor]")
    end
    Lua::Interop.dispatch("{{k}}.new", ctors, interp, ([nil] of Lua::LuaValue).concat(args))
  })
end
