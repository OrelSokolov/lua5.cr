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
#   rake matrix:build        # build images for all cells
#   rake matrix              # run the suite in every cell + summary table
#   rake matrix:run[21]      # one cell (or: MATRIX=21 rake matrix:run)
#   rake matrix:shell[21]    # interactive shell inside a cell
#
# Env:
#   MATRIX_LLVM  cell list (default "17 18 19 20 21"; Crystal 1.21 stdlib
#                bindings gate LLVM <= 21)
#   MATRIX_CMD   command per cell (default "crystal spec")
#   CRYSTAL_IMAGE  base image tag (default crystallang/crystal:1.21)

require "open3"

MATRIX_DIR = File.join(REPO_ROOT, "docker", "matrix")

def matrix_env(name, fallback)
  v = ENV[name]
  v.nil? || v.empty? ? fallback : v
end

CRYSTAL_IMG = matrix_env("CRYSTAL_IMAGE", "crystallang/crystal:1.21")

def matrix_cells
  raw = matrix_env("MATRIX_LLVM", matrix_env("MATRIX", "17 18 19 20 21"))
  raw.split
end

def matrix_image(llvm)
  "lua5-matrix:llvm#{llvm}"
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

def matrix_build!(llvm)
  tag = matrix_image(llvm)
  sh "docker", "build",
     "--build-arg", "CRYSTAL=#{CRYSTAL_IMG}",
     "--build-arg", "LLVM=#{llvm}",
     "-t", tag, MATRIX_DIR or raise "docker build failed for #{tag}"
end

def matrix_run(llvm, cmd = matrix_cmd)
  system("docker", "run", *matrix_docker_args, matrix_image(llvm), "sh", "-c", cmd)
end

namespace :matrix do
  desc "Build per-LLVM docker images (MATRIX_LLVM=…, CRYSTAL_IMAGE=…)"
  task :build do
    matrix_cells.each { |llvm| matrix_build!(llvm) }
  end

  desc "Run the suite in one cell: rake matrix:run[21] (MATRIX_CMD=… to override)"
  task :run, [:llvm] do |_t, args|
    llvm = args[:llvm] || ENV["MATRIX"] || matrix_cells.first
    abort "cell llvm#{llvm} has no image; run rake matrix:build first" unless matrix_image?(matrix_image(llvm))
    cmd = matrix_cmd
    puts "==> #{matrix_image(llvm)}: #{cmd}"
    exit 1 unless matrix_run(llvm, cmd)
  end

  desc "Interactive shell in a cell: rake matrix:shell[21]"
  task :shell, [:llvm] do |_t, args|
    llvm = args[:llvm] || ENV["MATRIX"] || matrix_cells.first
    abort "cell llvm#{llvm} has no image; run rake matrix:build first" unless matrix_image?(matrix_image(llvm))
    exec "docker", "run", "-it", *matrix_docker_args, matrix_image(llvm)
  end
end

desc "Run the suite in every matrix cell, print a summary (nonzero exit if any cell is red)"
task :matrix do
  results = matrix_cells.to_h { |llvm| [llvm, nil] }
  matrix_cells.each do |llvm|
    matrix_build!(llvm) unless matrix_image?(matrix_image(llvm))
    puts "\n==> #{matrix_image(llvm)}: #{matrix_cmd}"
    results[llvm] = matrix_run(llvm)
  end
  puts "\n==> matrix summary (#{matrix_cmd})"
  failed = []
  results.each do |llvm, ok|
    puts format("  llvm%-3s %s", llvm, ok ? "PASS" : "FAIL")
    failed << llvm unless ok
  end
  exit 1 if failed.any?
end
