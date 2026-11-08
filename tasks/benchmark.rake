# frozen_string_literal: true

# ————— benchmark:<vm> — run the suite on one interpreter —————

def vm_env(vm)
  { "LUA_PATH" => File.join(SUITE, "?.lua;;") }.merge(VMS.fetch(vm)[:env] || {})
end

# GNU timeout(1) is Linux-only; on macOS fall back to spawn + KILL polling.
HAS_TIMEOUT = system("command -v timeout >/dev/null 2>&1")

def cpu_model
  File.readable?("/proc/cpuinfo") ?
      File.read("/proc/cpuinfo")[/model name\s*:\s*(.+)/, 1].to_s.strip :
      `sysctl -n machdep.cpu.brand_string 2>/dev/null`.to_s.strip
rescue StandardError
  ""
end

# → [stdout, exit_code, timed_out?] — same contract with or without timeout(1).
def run_vm(env, timeout, bin, file, param)
  if HAS_TIMEOUT
    out, _err, pst = Open3.capture3(env, "timeout", "-k", "5", timeout.to_s,
                                    *bin, file, param, binmode: true)
    code = pst.exitstatus
    [out, code, code == 124]
  else
    out_f = Tempfile.new("lua5-bench")
    err_f = Tempfile.new("lua5-bench")
    pid = Process.spawn(env, *bin, file, param, out: out_f.path, err: err_f.path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    timed_out = false
    status = nil
    loop do
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      break if status
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        timed_out = true
        Process.kill("KILL", pid)
        _, status = Process.waitpid2(pid)
        break
      end
      sleep 0.02
    end
    out_f.rewind
    out = out_f.read
    out_f.close!
    err_f.close!
    [out, status&.exitstatus, timed_out]
  end
end

def startup_overhead(vm) # min of 5 empty runs, subtracted from every bench
  cmd = VMS.fetch(vm)[:bin]
  empty = File.join(Dir.tmpdir, "lua5-bench-empty.lua")
  FileUtils.mkdir_p(File.dirname(empty))
  File.write(empty, "")
  5.times.map do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    system(vm_env(vm), *cmd, empty, out: File::NULL, err: File::NULL)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end.min
end

def bench_path(name) # kernel'ы — в vendor-наборе, игровые — в bench/xray
  [File.join(SUITE, "#{name}.lua"), File.join(XRAY, "#{name}.lua")].find { |p| File.exist?(p) }
end

def run_suite(vm, filter = nil)
  conf = VMS.fetch(vm)
  cmd  = conf[:bin]
  abort "Missing interpreter #{cmd.first} — see bench/vendor (build Lua/LuaJIT first)." unless File.executable?(cmd.first)

  benches = filter ? BENCHES.select { |name, _param| name == filter } : BENCHES
  abort "Unknown bench '#{filter}'. Available: #{BENCHES.map(&:first).join(', ')}" if benches.empty? && filter

  reps    = (ENV["BENCH_REPS"]    || 3).to_i
  timeout = (ENV["BENCH_TIMEOUT"] || (vm == "clua" ? 120 : 300)).to_i
  overhead = startup_overhead(vm)
  puts "#{conf[:label]}: benches=#{benches.size} reps=#{reps} timeout=#{timeout}s startup-overhead=#{overhead.round(4)}s"

  results = {}
  benches.each do |name, param|
    file = bench_path(name) or abort "Bench script for '#{name}' not found in #{SUITE} nor #{XRAY}"
    times, sha, status = [], nil, "ok"
    reps.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, code, timed_out = run_vm(vm_env(vm), timeout, cmd, file, param)
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      if timed_out || code == 124
        status = "timeout"
      elsif code.nil? || !code.zero?
        status = "err"
      else
        times << [dt - overhead, 0.0].max
        sha = Digest::SHA256.hexdigest(out)
      end
    end
    results[name] = { "param" => param, "times" => times.map { |t| t.round(3) },
                      "min" => (times.min || nil)&.round(3), "output_sha" => sha,
                      "status" => times.empty? ? status : "ok" }
    min = results[name]["min"]
    puts format("  %-14s %s", name, min ? format("%8.3fs  %s", min, results[name]["status"]) : status)
  end

  FileUtils.mkdir_p(RESULTS)
  stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
  dir = File.join(RESULTS, "#{stamp}-#{vm}.json")
  File.write(dir, JSON.pretty_generate({
    "vm"       => vm,
    "complete" => results.values.any? { |r| r["status"] == "ok" },
    "metadata" => {
      "date"    => Time.now.utc.iso8601,
      "cpu"     => cpu_model,
      "reps"    => reps, "timeout" => timeout,
      "rev"     => Dir.chdir(REPO_ROOT) { `git rev-parse --short HEAD 2>/dev/null`.strip },
    },
    "results"  => results,
  }))
  puts "wrote #{dir}"
end

namespace :benchmark do
  %w[lua jitlua jitoff].each do |vm|
    desc "Run bench suite on #{VMS.fetch(vm)[:label]} (optional: one bench name)"
    task(vm.to_sym, [:bench]) do |_t, args|
      run_suite(vm, args[:bench])
    end
  end

  desc "Run bench suite on the Crystal interpreter (builds bin/lua5; optional: one bench name)"
  task :clua, [:bench] do |_t, args|
    # Build only when missing or REBUILD=1 — see tasks/build.rake
    Rake::Task["build:release"].invoke unless File.executable?(CLUA_BIN) && ENV["REBUILD"] != "1"
    run_suite("clua", args[:bench])
  end
end
