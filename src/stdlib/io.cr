# io library: file streams over Crystal IO (io.open/io.tmpfile, f:read/
# write/seek/lines/close), default input/output streams, io.lines —
# a port of liolib.c.
module Lua
  module Stdlib
    module IoLib
      # A Lua file handle (FILE*): userdata shell over a Crystal IO, with the
      # shared file metatable (__index = methods, __tostring, __gc).
      class LuaFile
        include Exposable
        getter name : String
        getter? closed : Bool = false
        getter? std : Bool
        # what the open mode allows; buffered Crystal IO hides EBADF, so
        # wrong-direction read/write is checked here (5.1 returns
        # nil, strerror(errno), errno)
        getter? readable : Bool
        getter? writable : Bool
        # setvbuf("line") emulation: pending bytes are held here until a
        # newline (observable through a second handle on the same file)
        @line_buf = ""
        property? line_mode = false
        @h : IO?

        def initialize(@name, @h : IO, @std : Bool = false,
                       @readable : Bool = true, @writable : Bool = true)
        end

        def write_out(i2 : Interp, v : LuaValue, k : Int32, fname : String) : Nil
          s = Stdlib::IoLib.to_write_str(i2, v, k, fname)
          return unless h = handle
          if line_mode?
            if nl = s.rindex('\n')
              @line_buf += s[0..nl]
              h << @line_buf
              h.flush # visible through other handles immediately
              @line_buf = s[(nl + 1)..]
            else
              @line_buf += s
            end
          else
            h << s
          end
        end

        # flush pending line-buffered bytes and the Crystal buffer
        def flush_pending : Nil
          return unless h = handle
          unless @line_buf.empty?
            h << @line_buf
            @line_buf = ""
          end
          h.flush
        end

        def setvbuf_mode(mode : String) : Nil
          if mode == "no" || mode == "full"
            flush_pending
            @line_mode = false
          elsif mode == "line"
            @line_mode = true
          end
        end

        # io.type(v): "file", "closed file", or nil for non-files
        def self.io_type(v : Lua::LuaValue) : String?
          return nil unless v.is_a?(Lua::LuaUserData) && (f = v.obj.as?(LuaFile))
          f.closed? ? "closed file" : "file"
        end

        def handle : IO?
          closed? ? nil : @h
        end

        def close : Nil
          return if closed?
          if (h = @h) && !@line_buf.empty?
            h << @line_buf
            @line_buf = ""
          end
          @closed = true
          @h.try &.close
        end
      end

      def self.install(i : Interp)
        methods = LuaTable.new
        mt = LuaTable.new
        mt.raw_set("__index", methods)
        methods.raw_set("write", LuaFunction.new("file:write", ->(i2 : Interp, args : Array(LuaValue)) {
          f, ud = file!(i2, args, "write")
          if !f.writable?
            [nil, "Bad file descriptor", 9.0] of LuaValue
          elsif f.handle
            begin
              (1...args.size).each { |k| f.write_out(i2, args[k], k, "write") }
              [ud] of LuaValue
            rescue e : IO::Error | File::Error
              # 5.1 luaL_fileresult: nil, message, errno
              [nil, e.message || "io error", 1.0] of LuaValue
            end
          else
            i2.raise_lua("attempt to use a closed file")
          end
        }))
        methods.raw_set("read", LuaFunction.new("file:read", ->(i2 : Interp, args : Array(LuaValue)) {
          f, _ = file!(i2, args, "read")
          if !f.readable?
            [nil] of LuaValue
          elsif h = f.handle
            begin
              do_read(i2, h, args, 1, "read")
            rescue e : IO::Error | File::Error
              # e.g. reading a write-mode handle: 5.1 yields nils
              [nil] of LuaValue
            end
          else
            i2.raise_lua("attempt to use a closed file")
          end
        }))
        methods.raw_set("seek", LuaFunction.new("file:seek", ->(i2 : Interp, args : Array(LuaValue)) {
          f, _ = file!(i2, args, "seek")
          h = f.handle || i2.raise_lua("attempt to use a closed file")
          whence = args.size > 1 && (w = args[1]?).is_a?(String) ? w : "cur"
          off = args.size > 2 ? i2.num!(args, 2, "seek") : 0.0
          h.flush
          sk = case whence
               when "set" then IO::Seek::Set
               when "cur" then IO::Seek::Current
               when "end" then IO::Seek::End
               else
                 i2.arg_error(2, "seek", "invalid whence '#{whence}'")
                 IO::Seek::Current
               end
          h.seek(off.to_i64, sk)
          [h.pos.to_f64] of LuaValue
        }))
        methods.raw_set("close", LuaFunction.new("file:close", ->(i2 : Interp, args : Array(LuaValue)) {
          f, _ = file!(i2, args, "close")
          # 5.1 tofile: a closed handle errors instead of closing twice
          i2.raise_lua("attempt to use a closed file") if f.closed?
          f.close
          [true] of LuaValue
        }))
        methods.raw_set("flush", LuaFunction.new("file:flush", ->(_i2 : Interp, args : Array(LuaValue)) {
          f, _ = file!(_i2, args, "flush")
          f.flush_pending
          [] of LuaValue
        }))
        # setvbuf: only the line/no distinction is observable (data
        # visibility through another handle); "full" behaves like "no"
        methods.raw_set("setvbuf", LuaFunction.new("file:setvbuf", ->(i2 : Interp, args : Array(LuaValue)) {
          f, ud = file!(i2, args, "setvbuf")
          mode = args[1]?.is_a?(String) ? args[1].as(String) : "full"
          i2.arg_error(2, "setvbuf", "invalid mode '#{mode}'") unless {"no", "line", "full"}.includes?(mode)
          f.setvbuf_mode(mode)
          [ud] of LuaValue
        }))
        methods.raw_set("lines", LuaFunction.new("file:lines", ->(_i2 : Interp, args : Array(LuaValue)) {
          f, _ = file!(_i2, args, "lines")
          h = f.handle || raise Lua::LuaError.new("attempt to use a closed file")
          iter = LuaFunction.new("lines_iter", ->(_i3 : Interp, _a : Array(LuaValue)) {
            (l = read_line(h)) ? [l] of LuaValue : [] of LuaValue
          })
          [iter] of LuaValue
        }))
        mt.raw_set("__tostring", LuaFunction.new("__tostring", ->(_i2 : Interp, args : Array(LuaValue)) {
          t = LuaFile.io_type(args[0]?)
          v = args[0]?.as(LuaUserData)
          # 5.1 io_tostring: closed handles print no address
          [t == "file" ? "file (0x#{v.object_id.to_s(16)})" : "file (closed)"] of LuaValue
        }))
        mt.raw_set("__gc", LuaFunction.new("__gc", ->(i2 : Interp, args : Array(LuaValue)) {
          f = args[0]?
          if f.is_a?(LuaUserData) && (fl = f.obj.as?(LuaFile))
            fl.close
            [] of LuaValue
          elsif f.nil?
            i2.raise_lua("bad argument #1 to '__gc' (FILE* expected, got no value)")
          else
            i2.arg_error(1, "__gc", "FILE* expected, got #{Lua.type_name(f)}")
          end
        }))

        stdin = wrap(LuaFile.new("stdin", STDIN, std: true, writable: false), mt)
        stdout = wrap(LuaFile.new("stdout", STDOUT, std: true, readable: false), mt)
        stderr = wrap(LuaFile.new("stderr", STDERR, std: true, readable: false), mt)
        i.io_input = stdin
        i.io_output = stdout

        tbl = LuaTable.new
        tbl.raw_set("stdin", stdin)
        tbl.raw_set("stdout", stdout)
        tbl.raw_set("stderr", stderr)

        tbl.raw_set("type", LuaFunction.new("io.type", ->(_i2 : Interp, args : Array(LuaValue)) {
          [LuaFile.io_type(args[0]?)] of LuaValue
        }))

        tbl.raw_set("open", LuaFunction.new("io.open", ->(i2 : Interp, args : Array(LuaValue)) {
          path = i2.str!(args, 0, "open")
          mode = args.size > 1 && (m = args[1]?).is_a?(String) ? m.delete("bt") : "r"
          begin
            h = File.open(path, mode)
            f = LuaFile.new(path, h,
              readable: mode.includes?('r') || mode.includes?('+'),
              writable: mode.includes?('w') || mode.includes?('a') || mode.includes?('+'))
            i2.io_open_files << f
            [wrap(f, mt)] of LuaValue
          rescue e : Exception
            [nil, "#{path}: #{e.message || "cannot open"}", 2.0] of LuaValue
          end
        }))

        tbl.raw_set("tmpfile", LuaFunction.new("io.tmpfile", ->(_i2 : Interp, _args : Array(LuaValue)) {
          # in-memory: nothing in the suite needs tmpfile disk persistence
          [wrap(LuaFile.new("tmpfile", IO::Memory.new), mt)] of LuaValue
        }))

        tbl.raw_set("write", LuaFunction.new("io.write", ->(i2 : Interp, args : Array(LuaValue)) {
          # default stdout goes through write_out so embedders can redirect
          out = i2.io_output
          if out.is_a?(LuaUserData) && out.same?(stdout)
            s = String.build do |b|
              (0...args.size).each { |k| b << to_write_str(i2, args[k], k, "io.write") }
            end
            i2.write_out(s)
            [out] of LuaValue
          elsif out.is_a?(LuaUserData) && (f = out.obj.as?(LuaFile)) && f.handle
            (0...args.size).each { |k| f.write_out(i2, args[k], k, "io.write") }
            [out] of LuaValue
          else
            i2.raise_lua("attempt to use a closed file")
          end
        }))

        tbl.raw_set("flush", LuaFunction.new("io.flush", ->(i2 : Interp, _args : Array(LuaValue)) {
          if (v = i2.io_output).is_a?(LuaUserData) && (f = v.obj.as?(Lua::Stdlib::IoLib::LuaFile))
            f.flush_pending
          end
          [] of LuaValue
        }))

        tbl.raw_set("read", LuaFunction.new("io.read", ->(i2 : Interp, args : Array(LuaValue)) {
          if (v = i2.io_input).is_a?(LuaUserData) && (f = v.obj.as?(LuaFile)) && (h = f.handle)
            do_read(i2, h, args, 0, "io.read")
          else
            i2.raise_lua("attempt to use a closed file")
          end
        }))

        tbl.raw_set("input", LuaFunction.new("io.input", ->(i2 : Interp, args : Array(LuaValue)) {
          # io.input([file]): no arg = return the current input stream
          i2.io_input = set_stream(i2, args, mt, "r") unless args.empty?
          [i2.io_input] of LuaValue
        }))
        tbl.raw_set("output", LuaFunction.new("io.output", ->(i2 : Interp, args : Array(LuaValue)) {
          i2.io_output = set_stream(i2, args, mt, "w") unless args.empty?
          [i2.io_output] of LuaValue
        }))

        tbl.raw_set("close", LuaFunction.new("io.close", ->(i2 : Interp, args : Array(LuaValue)) {
          v = args[0]? || i2.io_output
          if v.is_a?(LuaUserData) && (f = v.obj.as?(LuaFile))
            i2.raise_lua("attempt to use a closed file") if f.closed?
            f.close
            [true] of LuaValue
          else
            i2.arg_error(1, "close", "file expected")
          end
        }))

        tbl.raw_set("lines", LuaFunction.new("io.lines", ->(i2 : Interp, args : Array(LuaValue)) {
          if (nm = args[0]?).is_a?(String)
            h = open_raise(i2, nm, "r")
            file = LuaFile.new(nm, h)
            i2.io_open_files << file
            iter = LuaFunction.new("lines_iter", ->(_i3 : Interp, _a : Array(LuaValue)) {
              if (l = read_line(h))
                [l] of LuaValue
              else
                file.close
                [] of LuaValue
              end
            })
            [iter] of LuaValue
          elsif (v = i2.io_input).is_a?(LuaUserData) && (f = v.obj.as?(LuaFile)) && (ih = f.handle)
            iter = LuaFunction.new("lines_iter", ->(_i3 : Interp, _a : Array(LuaValue)) {
              (l = read_line(ih)) ? [l] of LuaValue : [] of LuaValue
            })
            [iter] of LuaValue
          else
            i2.raise_lua("attempt to use a closed file")
          end
        }))

        i.globals.raw_set("io", tbl)
      end

      # --- helpers ---

      def self.wrap(f : LuaFile, mt : LuaTable) : LuaUserData
        ud = LuaUserData.new(f)
        ud.metatable = mt
        ud
      end

      # self argument of a file method
      def self.file!(i2 : Interp, args : Array(LuaValue), fname : String) : {LuaFile, LuaUserData}
        v = args[0]?
        if v.is_a?(LuaUserData) && (f = v.obj.as?(LuaFile))
          {f, v}
        elsif v.nil?
          i2.raise_lua("bad argument #1 to '#{fname}' (file expected, got no value)")
        else
          i2.arg_error(1, fname, "file expected, got #{Lua.type_name(v)}")
        end
      end

      def self.open_raise(i2 : Interp, name : String, mode : String) : IO
        File.open(name, mode)
      rescue e : Exception
        i2.raise_lua("#{name}: #{e.message || "cannot open"}")
      end

      def self.set_stream(i2 : Interp, args : Array(LuaValue), mt : LuaTable, mode : String) : LuaValue
        a = args[0]?
        if a.nil?
          i2.raise_lua("bad argument #1 (file expected, got no value)")
        elsif a.is_a?(String)
          f = LuaFile.new(a, open_raise(i2, a, mode),
            readable: mode.includes?('r'), writable: !mode.includes?('r'))
          i2.io_open_files << f
          wrap(f, mt)
        elsif a.is_a?(LuaUserData) && (f = a.obj.as?(LuaFile))
          a
        else
          i2.arg_error(1, mode == "r" ? "input" : "output", "filename or file expected")
        end
      end

      def self.to_write_str(i2 : Interp, v : LuaValue, k : Int32, fname : String) : String
        case v
        when String  then v
        when Float64 then Lua.fmt_num(v)
        else
          i2.arg_error(k + 1, fname, "string expected, got #{Lua.type_name(v)}")
        end
      end

      def self.write_val(i2 : Interp, h : IO, v : LuaValue, k : Int32, fname : String) : Nil
        h << to_write_str(i2, v, k, fname)
      end

      # byte-safe line read: strips the trailing \n and any \r before it
      def self.read_line(h : IO) : String?
        l = h.gets(chomp: true)
        if l && l.ends_with?("\r")
          l = l.rchop
        end
        l
      end

      def self.peek_byte(h : IO) : Int32?
        p = h.peek
        return nil if p.nil? || p.empty?
        p[0].to_i
      rescue
        nil
      end

      def self.read_number(h : IO) : Float64?
        buf = IO::Memory.new
        while (b = peek_byte(h)) && (b == 0x20 || (0x09 <= b <= 0x0D))
          h.read_byte
        end
        while (b = peek_byte(h)) && numchar?(b.to_u8)
          buf.write_byte(h.read_byte.not_nil!)
        end
        Lua.parse_number(buf.to_s)
      end

      def self.numchar?(b : UInt8) : Bool
        (0x30 <= b <= 0x39) || # digits
          b == 0x2B || b == 0x2D || b == 0x2E || # + - .
          (0x61 <= b <= 0x7A) || (0x41 <= b <= 0x5A) # eExXaAfF...
      end

      def self.do_read(i2 : Interp, h : IO, args : Array(LuaValue), base : Int32, fname : String) : Array(LuaValue)
        out = [] of LuaValue
        k = base
        while k < args.size
          fv = args[k]
          case fv
          when Float64
            n = fv.to_i
            i2.arg_error(k + 1, fname, "number has no integer representation") if n < 0
            if n == 0
              # 5.1 test_eof: "" mid-file, nil at eof
              out << (peek_byte(h).nil? ? nil : "")
            else
              buf = Bytes.new(n)
              got = 0
              # IO#read may be short (buffer boundary / partial syscall):
              # fread semantics — loop until n bytes or eof
              while got < n
                r = h.read(buf[got..])
                break if r == 0
                got += r
              end
              out << (got > 0 ? String.new(buf[0, got]) : nil)
            end
          when String
            f = fv.starts_with?('*') ? fv[1..] : fv
            # 5.1 matches only the first format char ("*all" == "*a")
            case f[0]?
            when 'a' then out << h.gets_to_end
            when 'l' then out << read_line(h)
            when 'n' then out << read_number(h)
            else          i2.arg_error(k + 1, fname, "invalid format '#{fv}'")
            end
          else
            i2.arg_error(k + 1, fname, "invalid format")
          end
          k += 1
        end
        out << read_line(h) if args.size == base # default: "*l"
        out
      end
    end
  end

  class Interp
    # current default streams (LuaUserData file handles)
    property io_input : LuaValue = nil
    property io_output : LuaValue = nil
    # every real file ever opened (io.open / io.input(name) / io.lines(name));
    # collectgarbage closes the ones still open — our stand-in for 5.1's
    # __gc-based file finalization
    property io_open_files = [] of Stdlib::IoLib::LuaFile

    def gc_close_files : Nil
      keep_in = io_input.is_a?(LuaUserData) ? io_input.as(LuaUserData).obj.as?(Stdlib::IoLib::LuaFile) : nil
      keep_out = io_output.is_a?(LuaUserData) ? io_output.as(LuaUserData).obj.as?(Stdlib::IoLib::LuaFile) : nil
      @io_open_files.each do |f|
        next if f.std? || f.closed? || f.same?(keep_in) || f.same?(keep_out)
        f.close
      end
      @io_open_files.reject! &.closed?
    end
  end
end
