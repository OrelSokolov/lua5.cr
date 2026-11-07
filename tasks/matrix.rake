# frozen_string_literal: true

# ————— matrix: per-LLVM isolated test cells (docker) —————
#
# The JIT's LLVM bindings compile against whatever llvm-config LLVM_CONFIG
# points at (tasks/build.rake), so the interesting local axis is the LLVM
# version. Each cell = one docker image (official Crystal image + llvm-NN-dev,
# see docker/matrix/Dockerfile) running the spec suite against a read-only
# bind mount of this repo. Nothing leaks back into the working tree; caches
# and temp binaries go to /tmp inside the container.
#
# A cell is "NN" (llvm NN on the default Crystal image) or "NN@image:tag"
# (on a specific one): the stdlib bindings cap the LLVM version, so newer
# LLVM cells ride a newer Crystal (1.21 gates LLVM <= 21, 1.22 gates <= 23).
# LLVM 22/23 are apt.llvm.org snapshots of not-yet-released toolchains —
# expect churn there; that is exactly what this matrix is for.
#
#   rake matrix:build        # build images for all cells
#   rake matrix              # run the suite in every cell + summary table
#   rake matrix:run[22]      # one cell (or: MATRIX=22 rake matrix:run)
#   rake matrix:shell[22]    # interactive shell inside a cell
#
# Env:
#   MATRIX_LLVM    cell list (see DEFAULT_MATRIX_CELLS below)
#   MATRIX_CMD     command per cell (default "crystal spec")
#   CRYSTAL_IMAGE  base image for bare "NN" cells (default
#                  crystallang/crystal:1.21)

MATRIX_DIR = File.join(REPO_ROOT, "docker", "matrix")

DEFAULT_MATRIX_CELLS = [
  "17", "18", "19", "20", "21",                            # crystal 1.21
  "22@crystallang/crystal:1.22",                           # crystal 1.22
  "23@crystallang/crystal:1.22",                           # crystal 1.22
].freeze

def matrix_env(name, fallback)
  v = ENV[name]
  v.nil? || v.empty? ? fallback : v
end

# cell "22@crystallang/crystal:1.22" -> {llvm: "22", img: "crystallang/crystal:1.22"}
def matrix_cell(cell)
  llvm, img = cell.split("@", 2)
  { llvm: llvm, img: img || matrix_env("CRYSTAL_IMAGE", "crystallang/crystal:1.21") }
end

def matrix_cells
  # MATRIX_LLVM defines the cell list; MATRIX only selects/filters cells
  # (rake matrix:run[22], MATRIX=22 rake matrix).
  matrix_env("MATRIX_LLVM", DEFAULT_MATRIX_CELLS.join(" ")).split
end

def matrix_find_cell(llvm)
  matrix_cells.find { |c| matrix_cell(c)[:llvm] == llvm.to_s } ||
    (abort "no matrix cell for llvm#{llvm} (see DEFAULT_MATRIX_CELLS / MATRIX_LLVM)")
end

def matrix_image(cell)
  c = matrix_cell(cell)
  tag = c[:img].delete_prefix("crystallang/crystal:").tr(".", "")
  "lua5-matrix:c#{tag}-llvm#{c[:llvm]}"
end

def matrix_cmd
  matrix_env("MATRIX_CMD", "crystal spec")
end

def matrix_docker_args
  [
    "--rm", "--network=none",
    "-v", "#{REPO_ROOT}:/src:ro",
    "-w", "/src",
    # read-only mount: redirect everything Crystal would write in $HOME/$PWD
    "-e", "HOME=/tmp",
    "-e", "CRYSTAL_CACHE_DIR=/tmp/.crystal",
  ]
end

def matrix_image?(tag)
  system("docker", "image", "inspect", tag, out: File::NULL, err: File::NULL)
end

def matrix_build!(cell)
  c = matrix_cell(cell)
  tag = matrix_image(cell)
  sh "docker", "build",
     "--build-arg", "CRYSTAL=#{c[:img]}",
     "--build-arg", "LLVM=#{c[:llvm]}",
     "-t", tag, MATRIX_DIR or raise "docker build failed for #{tag}"
end

def matrix_run(cell, cmd = matrix_cmd)
  system("docker", "run", *matrix_docker_args, matrix_image(cell), "sh", "-c", cmd)
end

namespace :matrix do
  desc "Build per-LLVM docker images (MATRIX_LLVM=…)"
  task :build do
    matrix_cells.each { |cell| matrix_build!(cell) }
  end

  desc "Run the suite in one cell: rake matrix:run[22] (MATRIX_CMD=… to override)"
  task :run, [:llvm] do |_t, args|
    cell = matrix_find_cell(args[:llvm] || ENV["MATRIX"] || matrix_cells.first)
    abort "cell #{matrix_image(cell)} has no image; run rake matrix:build first" unless matrix_image?(matrix_image(cell))
    puts "==> #{matrix_image(cell)}: #{matrix_cmd}"
    exit 1 unless matrix_run(cell)
  end

  desc "Interactive shell in a cell: rake matrix:shell[22]"
  task :shell, [:llvm] do |_t, args|
    cell = matrix_find_cell(args[:llvm] || ENV["MATRIX"] || matrix_cells.first)
    abort "cell #{matrix_image(cell)} has no image; run rake matrix:build first" unless matrix_image?(matrix_image(cell))
    exec "docker", "run", "-it", *matrix_docker_args, matrix_image(cell)
  end
end

desc "Run the suite in every matrix cell, print a summary (nonzero exit if any cell is red)"
task :matrix do
  cells = matrix_cells
  if filter = matrix_env("MATRIX", nil)
    cells = cells.select { |cell| matrix_cell(cell)[:llvm] == filter }
    abort "no matrix cell for llvm#{filter}" if cells.empty?
  end
  results = cells.to_h { |cell| [cell, nil] }
  cells.each do |cell|
    matrix_build!(cell) unless matrix_image?(matrix_image(cell))
    puts "\n==> #{matrix_image(cell)}: #{matrix_cmd}"
    results[cell] = matrix_run(cell)
  end
  puts "\n==> matrix summary (#{matrix_cmd})"
  failed = []
  results.each do |cell, ok|
    puts format("  %-28s %s", matrix_image(cell), ok ? "PASS" : "FAIL")
    failed << cell unless ok
  end
  exit 1 if failed.any?
end
