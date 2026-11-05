# Minimal require: module lookup along LUA_PATH (";;" = default), loaded
# chunks cached in package.loaded. The full loader machinery (package.path,
# loaders, preload) is Phase 2 per PLAN.md — this is enough for scripts and
# the benchmarks (scimark-fft requires scimark_lib).
module Lua
  module Stdlib
    module PackageLib
      def self.install(i : Interp)
        loaded = LuaTable.new
        package = LuaTable.new
        package.raw_set("loaded", loaded)
        i.globals.raw_set("package", package)

        i.native("require") do |i2, args|
          name = i2.str!(args, 0, "require")
          if (v = loaded.raw_get(name)) && !v.nil?
            next [v] of LuaValue
          end

          file = search_path(i2, name)
          unless file
            i2.raise_lua("module '#{name}' not found: no field in LUA_PATH")
          end

          vals = i2.run(File.read(file), file)
          v = vals[0]? || true
          loaded.raw_set(name, v)
          [v] of LuaValue
        end
      end

      private def self.search_path(i2 : Interp, name : String) : String?
        path = ENV["LUA_PATH"]? || "?.lua"
        # ";;" inserts the default path — drop the empty entry, keep the rest.
        candidates = path.split(';').reject(&.empty?).map do |tmpl|
          tmpl.gsub('?', name)
        end
        candidates.find { |c| File.file?(c) }
      end
    end
  end
end
