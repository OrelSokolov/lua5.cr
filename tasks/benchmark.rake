# frozen_string_literal: true

# ————— benchmark:<vm> — run the suite on one interpreter —————

def vm_env(vm)
  { "LUA_PATH" => File.join(SUITE, "?.lua;;") }.merge(VMS.fetch(vm)[:env] || {})
end

def startup_overhead(vm) # min of 5 empty runs, subtracted from every bench
  cmd = VMS.fetch(vm)[:bin]
  empty = File.join(BENCH_DIR, "results", ".empty.lua")
  FileUtils.mkdir_p(File.dirname(empty))
  File.write(empty, "")
  5.times.map do
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    system(vm_env(vm), *cmd, empty, out: File::NULL, err: File::NULL)
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end.min
end

def run_suite(vm)
  conf = VMS.fetch(vm)
  cmd  = conf[:bin]
  abort "Missing interpreter #{cmd.first} — see bench/vendor (build Lua/LuaJIT first)." unless File.executable?(cmd.first)

  reps    = (ENV["BENCH_REPS"]    || 3).to_i
  timeout = (ENV["BENCH_TIMEOUT"] || (vm == "clua" ? 120 : 300)).to_i
  overhead = startup_overhead(vm)
  puts "#{conf[:label]}: reps=#{reps} timeout=#{timeout}s startup-overhead=#{overhead.round(4)}s"

  results = {}
  BENCHES.each do |name, param|
    file = File.join(SUITE, "#{name}.lua")
    times, sha, status = [], nil, "ok"
    reps.times do
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, _err, pst = Open3.capture3(vm_env(vm), "timeout", "-k", "5", timeout.to_s,
                                      *cmd, file, param, binmode: true)
      dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      if pst.exitstatus == 124
        status = "timeout"
      elsif !pst.success?
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
      "cpu"     => File.read("/proc/cpuinfo")[/model name\s*:\s*(.+)/, 1].to_s.strip,
      "reps"    => reps, "timeout" => timeout,
      "rev"     => Dir.chdir(REPO_ROOT) { `git rev-parse --short HEAD 2>/dev/null`.strip },
    },
    "results"  => results,
  }))
  puts "wrote #{dir}"
end

def build_clua!
  need = !File.executable?(CLUA_BIN) || ENV["REBUILD"] == "1"
  return unless need
  FileUtils.mkdir_p(File.dirname(CLUA_BIN))
  sh "crystal build --release --no-debug src/cli.cr -o #{CLUA_BIN}", chdir: REPO_ROOT
end

namespace :benchmark do
  %w[lua jitlua].each do |vm|
    desc "Run bench suite on #{VMS.fetch(vm)[:label]}"
    task(vm.to_sym) { run_suite(vm) }
  end

  desc "Run bench suite on the Crystal interpreter (builds bin/lua5 if missing)"
  task :clua do
    build_clua!
    run_suite("clua")
  end
end
