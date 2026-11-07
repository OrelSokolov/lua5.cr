# frozen_string_literal: true

require "tempfile"

# ————— benchmark:report — comparison table from bench/results/ —————

def bold(s)
  $stdout.tty? ? "\e[1m#{s}\e[0m" : s
end

def plain(s)
  s.gsub(/\e\[\d+m/, "")
end

# vm → { json:, file: } of its newest results file (timestamped names sort).
# Single-bench runs (rake benchmark:clua[fannkuch]) don't shadow full-suite
# runs: the newest file covering the whole BENCHES list wins; the newest
# file at all is the fallback when no full run exists for that vm.
def latest_runs
  Dir[File.join(RESULTS, "*-*.json")].sort.group_by { |f|
    File.basename(f).sub(/\A\d{8}-\d{6}-/, "").sub(/\.json\z/, "")
  }.transform_values { |files|
    full = files.reverse.find { |f|
      names = JSON.parse(File.read(f))["results"].keys
      BENCHES.map(&:first).all? { |b| names.include?(b) }
    } || files.last
    { json: JSON.parse(File.read(full)), file: full }
  }
end

desc "Comparison table (bench × interpreter) from bench/results/, latest run per vm"
namespace :benchmark do
  task :report do
  runs = latest_runs
  abort "No results in #{RESULTS}/ — run `rake benchmark:lua benchmark:jitlua` first." if runs.empty?

  vms    = %w[lua jitlua jitoff clua].select { |v| runs.key?(v) }
  labels = vms.to_h { |v| [v, VMS.fetch(v)[:label]] }

  puts
  puts "Min-of-N wall time, seconds (bold — fastest per bench; ! — output differs from luajit):"
  rows = []
  header = ["bench", *vms.map { |v| labels[v] }]
  header << "51/jit" if vms.include?("jitlua") && vms.include?("lua")
  header << "clua/jit" if vms.include?("jitlua") && vms.include?("clua")
  rows << header
  BENCHES.map(&:first).each do |name|
      row = [name]
      mins = vms.map { |v| r = runs[v][:json]["results"][name]; r && r["min"] }
      best = mins.compact.min
      vms.each_with_index do |v, i|
        r = runs[v][:json]["results"][name]
        if r.nil? || r["min"].nil?
          row << "—#{r['status'][0] if r && r['status'] != 'ok'}".strip # —t (timeout) / —e (err)
        else
          mark = ""
          # series prints its own elapsed time — its output never matches byte-wise
          if v != "jitlua" && name != "series" &&
             data = runs.dig("jitlua") and r2 = data[:json]["results"][name] and
             r2["output_sha"] != r["output_sha"]
            mark = " !"
          end
          cell = format("%.3f%s", r["min"], mark)
          row << (r["min"] == best ? bold(cell) : cell)
        end
      end
      if vms.include?("jitlua")
        jit = runs.dig("jitlua", :json, "results", name, "min")
        if vms.include?("lua") && jit && (l = runs.dig("lua", :json, "results", name, "min"))
          row << format("%.1fx", l.fdiv(jit))
        end
        if vms.include?("clua") && (c = runs.dig("clua", :json, "results", name, "min")) && jit
          row << format("%.1fx", c.fdiv(jit))
        end
      end
      rows << row
    end
    rows << ["rev", *vms.map { |v| runs[v][:json].dig("metadata", "rev").to_s.then { |r| r.empty? ? "—" : r } }]

    # ratio columns may be skipped per-row (missing jit min) — pad to header
    header_size = header.size
    rows.each { |r| r << "—" while r.size < header_size }

    # plain-text table: left-align first column, right-align the rest
    widths = rows.transpose.map { |col| col.map { |c| plain(c).length }.max }
    rows.each_with_index do |row, i|
      puts row.each_with_index.map { |c, j|
        pad = " " * (widths[j] - plain(c).length)
        j.zero? ? c + pad : pad + c
      }.join("  ")
      puts widths.map { |w| "-" * w }.join("  ") if i.zero?
    end
    puts
    vms.each { |v| puts "  #{labels[v]}: #{runs[v][:file]}" }
    puts
  end
end
