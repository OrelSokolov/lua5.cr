# package library: require with loaders (port of loadlib.c's ll_require +
# ll_module/ll_seeall). C loaders are absent (no dynamic loading in Crystal),
# so package.cpath exists as a string but never matches. require looks in
# package.preload, then package.path templates ("?" → module name, all
# occurrences), with modules cached in package.loaded.
module Lua
  module Stdlib
    module PackageLib
      DEFAULT_PATH = "./?.lua"

      def self.install(i : Interp)
        loaded = LuaTable.new
        preload = LuaTable.new
        package = LuaTable.new
        package.raw_set("loaded", loaded)
        package.raw_set("preload", preload)
        package.raw_set("path", env_path("LUA_PATH", DEFAULT_PATH))
        package.raw_set("cpath", env_path("LUA_CPATH", ""))

        # no C-library support: loadlib always fails with the 5.1-style
        # triple (nil, message, "absent")
        package.raw_set("loadlib", LuaFunction.new("package.loadlib", ->(_i2 : Interp, _args : Array(LuaValue)) {
          [nil, "dynamic libraries not enabled; check your Lua installation", "absent"] of LuaValue
        }))
        i.globals.raw_set("package", package)

        # built-in modules resolve through package.loaded, like 5.1
        {"_G", "string", "math", "table", "io", "os", "debug",
         "coroutine", "package"}.each do |n|
          v = i.globals.raw_get(n)
          loaded.raw_set(n, v) unless v.nil?
        end

        sentinel = LuaCoroutine.new(nil) # unique marker, never a real result

        i.native("require") do |i2, args|
          name = i2.str!(args, 0, "require")
          unless (v = loaded.raw_get(name)).nil? || v == false
            next [v] of LuaValue
          end
          if loaded.raw_get(name) == sentinel
            i2.raise_lua("loop or previous error loading module '#{name}'")
          end

          loader : LuaValue
          if (pre = preload.raw_get(name)).is_a?(LuaClosure) || pre.is_a?(LuaFunction)
            loader = pre
          else
            fname = name.gsub('.', "/")
            msg = "module '#{name}' not found: no field in package.preload for '#{name}'"
            tmpls = path_templates(i2, package)
            tmpls.each { |t| msg += "\n\tno file '#{t.gsub('?', fname)}'" }
            file = search_path(i2, name, tmpls)
            unless file
              # 5.1 lists every attempted template in the error message
              i2.raise_lua(msg)
            end
            loader = i2.compile(File.read(file), file)
          end

          loaded.raw_set(name, sentinel)
          res = i2.call(loader, [name] of LuaValue)
          loaded.raw_set(name, res[0]?) unless res[0]?.nil?
          v = loaded.raw_get(name)
          if v == sentinel
            loaded.raw_set(name, true)
            next [true] of LuaValue
          end
          [v] of LuaValue
        end

        i.native("module") do |i2, args|
          modname = i2.str!(args, 0, "module")
          m = loaded.raw_get(modname)
          unless m.is_a?(LuaTable)
            # create (or find) the global t.a.b chain
            m = LuaTable.new
            t = i2.globals
            parts = modname.split('.')
            parts.each_with_index do |part, k|
              last = k == parts.size - 1
              nxt = t.raw_get(part)
              if last
                if nxt.is_a?(LuaTable)
                  m = nxt
                elsif nxt.nil?
                  t.raw_set(part, m)
                else
                  i2.raise_lua("name conflict for module '#{modname}'")
                end
              else
                unless nxt.is_a?(LuaTable)
                  i2.raise_lua("name conflict for module '#{modname}'") unless nxt.nil?
                  nxt = LuaTable.new
                  t.raw_set(part, nxt)
                end
                t = nxt
              end
            end
            loaded.raw_set(modname, m)
          end
          # initialize unless it already is an initialized module
          unless m.as(LuaTable).raw_get("_NAME")
            m.as(LuaTable).raw_set("_NAME", modname)
            m.as(LuaTable).raw_set("_M", m)
            m.as(LuaTable).raw_set("_PACKAGE",
              (dot = modname.rindex('.')) ? modname[0, dot + 1] : "")
          end
          # run in the module's table: setfenv on the calling function
          if cl = i2.caller_closure(1)
            cl.env = m.as(LuaTable)
          else
            i2.raise_lua("module: no calling function")
          end
          # apply options (package.seeall, importers, ...)
          (args.size > 1 ? args[1..] : ([] of LuaValue)).each do |opt|
            i2.call(opt, [m] of LuaValue)
          end
          [] of LuaValue
        end

        package.raw_set("seeall", LuaFunction.new("package.seeall", ->(i2 : Interp, args : Array(LuaValue)) {
          t = i2.table!(args, 0, "seeall")
          mt = t.metatable
          if mt.nil?
            mt = LuaTable.new
            t.metatable = mt
          end
          mt.raw_set("__index", i2.globals)
          [] of LuaValue
        }))
      end

      # 5.1 setpath: env var with ";;" → insert the default among the entries
      private def self.env_path(envname : String, default : String) : String
        path = ENV[envname]?
        return default unless path
        path.split(';').map { |e| e.empty? ? default : e }.join(';')
      end

      private def self.path_templates(i2 : Interp, package : LuaTable) : Array(String)
        p = package.raw_get("path")
        p.is_a?(String) ? p.split(';').reject(&.empty?) : ["./?.lua"]
      end

      private def self.search_path(i2 : Interp, name : String, templates : Array(String)) : String?
        # 5.1 ll_searchpath: module dots become directory separators
        fname = name.gsub('.', "/")
        templates.each do |tmpl|
          file = tmpl.gsub('?', fname)
          return file if File.file?(file)
        end
        nil
      end
    end
  end
end
