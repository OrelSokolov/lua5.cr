# frozen_string_literal: true

# Interpreter benchmarks (see benchmark.md). Suite: Mike Pall's
# LuaJIT-test-cleanup (bench/vendor), timed per process, min-of-N.
#
#   rake build:release      # build bin/lua5 (--release --no-debug)
#   rake build:dev          # build bin/lua5 (dev, debug info)
#   rake benchmark:lua      # PUC Lua 5.1.5   (bench/vendor)
#   rake benchmark:jitlua   # LuaJIT 2.1 JIT  (bench/vendor)
#   rake benchmark:clua     # Crystal interpreter (bin/lua5, built on demand)
#   rake benchmark:report   # comparison table from bench/results/
#
# Env: BENCH_REPS (default 3), BENCH_TIMEOUT seconds (default: clua 120,
# others 300), REBUILD=1 to force-rebuild bin/lua5.
#
# Results: bench/results/<UTC-timestamp>-<vm>.json; report picks the
# latest file per vm.

require "fileutils"
require "json"
require "open3"
require "digest"
require "tmpdir"
require "time"

REPO_ROOT = File.expand_path(__dir__)
BENCH_DIR = File.join(REPO_ROOT, "bench")
VENDOR    = File.join(BENCH_DIR, "vendor")
SUITE     = File.join(VENDOR, "LuaJIT-test-cleanup", "bench")
XRAY      = File.join(BENCH_DIR, "xray")
RESULTS   = File.join(BENCH_DIR, "results")
CLUA_BIN  = File.join(REPO_ROOT, "bin", "lua5")

# name param — scaled from the suite's PARAM_x86.txt so plain Lua 5.1
# stays within seconds (full x86 params are tuned for LuaJIT).
BENCHES = [
  %w[nbody 2000000],
  %w[fannkuch 10],
  %w[spectral-norm 2500],
  %w[binary-trees 14],
  %w[nsieve 10],
  %w[mandelbrot 3000],
  %w[series 8000],
  %w[partialsums 10000000],
  %w[recursive-fib 38],
  %w[array3d 300],
  %w[fasta 4000000],
  %w[scimark-fft 20000],
  # bench/xray/*.lua — игровые сценарии по мотивам xray-16 (см. benchmark.md)
  %w[xr-update 4000],
  %w[events 20000],
  %w[oop 5000],
  %w[spawn 24000],
  %w[news 1000000],
  %w[sort-queue 2000],
  %w[veclib 3000],
  %w[coro-mgr 80000],
].freeze

VMS = {
  "lua"    => { label: "lua5.1", bin: [File.join(VENDOR, "lua-5.1.5", "src", "lua")] },
  "jitlua" => { label: "luajit",
                bin: [File.join(VENDOR, "luajit", "bin", "luajit")],
                env: { "LD_LIBRARY_PATH" => File.join(VENDOR, "luajit", "lib") } },
  "jitoff" => { label: "luajit-joff", # LuaJIT interpreter-only: the fair
                # "interpreter vs interpreter" baseline (see benchmark.md)
                bin: [File.join(VENDOR, "luajit", "bin", "luajit"), "-joff"],
                env: { "LD_LIBRARY_PATH" => File.join(VENDOR, "luajit", "lib") } },
  "clua"   => { label: "clua", bin: [CLUA_BIN] },
}.freeze

Dir.glob(File.join(REPO_ROOT, "tasks", "*.rake")).sort.each { |path| load path }
