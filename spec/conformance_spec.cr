require "./spec_helper"

# Conformance: every .lua file under spec/conformance must run to completion
# (they are assert-based). This mirrors the "run the file, check exit code"
# loop used against real lua5.1-tests.
Dir[File.join(__DIR__, "conformance", "*.lua")].sort.each do |path|
  it "runs #{File.basename(path)}" do
    interp = Lua::Interp.new
    src = File.read(path)
    begin
      interp.run(src, File.basename(path))
    rescue e : Lua::LuaError
      fail("LuaError in #{File.basename(path)}: #{e.message}")
    rescue e : Lua::SyntaxError
      fail("SyntaxError in #{File.basename(path)}: #{e.message}")
    end
  end
end
