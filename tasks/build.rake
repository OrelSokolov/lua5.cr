# frozen_string_literal: true

# ————— build:release / build:dev — build bin/lua5 (clua) —————

# The JIT (src/jit) links libLLVM via @[Link("LLVM")]. On Linux the linker
# finds it in the default library path; elsewhere (macOS/homebrew) the
# crystal linker needs LLVM_CONFIG + LIBRARY_PATH pointing at the prefix.
def clua_build_env
  llvm_bin = ENV["LLVM_CONFIG"]
  llvm_bin ||= ["/opt/homebrew/opt/llvm/bin/llvm-config", "llvm-config"].find do |cand|
    cand.start_with?("/") ? File.executable?(cand) : system("command -v #{cand} >/dev/null 2>&1")
  end
  return {} unless llvm_bin
  libdir = `#{llvm_bin} --libdir 2>/dev/null`.strip
  return {} if libdir.empty?
  { "LLVM_CONFIG" => llvm_bin, "LIBRARY_PATH" => libdir }
end

def build_clua!(*flags)
  FileUtils.mkdir_p(File.dirname(CLUA_BIN))
  cmd = ["crystal", "build", *flags, "src/cli.cr", "-o", CLUA_BIN].join(" ")
  sh clua_build_env, cmd, chdir: REPO_ROOT
end

namespace :build do
  desc "Build bin/lua5 (release: --release --no-debug — benchmarks/production)"
  task :release do
    build_clua!("--release", "--no-debug")
  end

  desc "Build bin/lua5 (dev: debug info, no --release — fast compile, slow run)"
  task :dev do
    build_clua!
  end
end
