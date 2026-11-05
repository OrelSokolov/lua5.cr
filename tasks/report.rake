# frozen_string_literal: true

# ————— benchmark:report — comparison table from bench/results/ —————

def bold(s) = $stdout.tty? ? "\e[1m#{s}\e[0m" : s

# vm → { json:, file: } of its newest results file (timestamped names sort)
def latest_runs
  Dir[File.join(RESULTS, "*-*.json")].sort.group_by { |f|
    File.basename(f).sub(/\A\d{8}-\d{6}-/, "").sub(/\.json\z/, "")
  }.transform_values { |files| { json: JSON.parse(File.read(files.last)), file: files.last } }
end

desc "Comparison table (bench × interpreter) from bench/results/, latest run per vm"
namespace :benchmark do
  task :report do
  require "terminal-table"

  runs = latest_runs
  abort "No results in #{RESULTS}/ — run `rake benchmark:lua benchmark:jitlua` first." if runs.empty?

  vms    = %w[lua jitlua clua].select { |v| runs.key?(v) }
  labels = vms.to_h { |v| [v, VMS.fetch(v)[:label]] }

  puts
  puts "Min-of-N wall time, seconds (bold — fastest per bench; ! — output differs from luajit):"
  table = Terminal::Table.new do |t|
    cols = ["bench", *vms.map { |v| labels[v] }]
    cols << "51/jit" if vms.include?("jitlua") && vms.include?("lua")
    cols << "clua/jit" if vms.include?("jitlua") && vms.include?("clua")
    t.headings = cols
    t.align_column(0, :left)
    (1...cols.size).each { |i| t.align_column(i, :right) }

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
        if vms.include?("lua") && jit
          row << format("%.1fx", runs.dig("lua", :json, "results", name, "min").fdiv(jit))
        end
        if vms.include?("clua") && (c = runs.dig("clua", :json, "results", name, "min")) && jit
          row << format("%.1fx", c.fdiv(jit))
        end
      end
      t.add_row(row)
    end

    t.add_separator
    t.add_row(["rev", *vms.map { |v| runs[v][:json].dig("metadata", "rev").to_s.then { |r| r.empty? ? "—" : r } }])
  end
  puts table
  puts
  vms.each { |v| puts "  #{labels[v]}: #{runs[v][:file]}" }
  puts
  end
end
