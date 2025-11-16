# frozen_string_literal: true

# Benchmark script to compare sequential vs parallel file indexing
require "bundler/setup"
require "ruby-lsp"
require "benchmark"
require_relative "lib/ruby_lsp/ruby_lsp_guesser/variable_index"
require_relative "lib/ruby_lsp/ruby_lsp_guesser/ast_visitor"
require "prism"
require "etc"

# Get all Ruby files in the project (similar to what LSP would index)
def indexable_files
  # Get Ruby files from common gem locations
  require "rubygems"
  gem_paths = Gem.path.flat_map do |gem_path|
    Dir.glob("#{gem_path}/gems/*/lib/**/*.rb")
  end

  # Get Ruby files from current project
  project_files = Dir.glob("lib/**/*.rb")

  # Create URI-like objects
  all_files = (gem_paths + project_files).map do |path|
    Struct.new(:full_path).new(File.expand_path(path))
  end

  all_files.uniq(&:full_path)
end

# Sequential processing (original version)
def sequential_indexing(indexable_uris)
  RubyLsp::Guesser::VariableIndex.instance.clear

  indexable_uris.each do |uri|
    file_path = uri.full_path
    next unless file_path && File.exist?(file_path)

    source = File.read(file_path)
    result = Prism.parse(source)
    visitor = RubyLsp::Guesser::ASTVisitor.new(file_path)
    result.value.accept(visitor)
  rescue StandardError
    # Silent error handling
  end
end

# Parallel processing (new version)
def parallel_indexing(indexable_uris, worker_count)
  RubyLsp::Guesser::VariableIndex.instance.clear

  queue = Thread::Queue.new
  indexable_uris.each { |uri| queue << uri }
  worker_count.times { queue << :stop }

  workers = worker_count.times.map do
    Thread.new do
      loop do
        uri = queue.pop
        break if uri == :stop

        begin
          file_path = uri.full_path
          next unless file_path && File.exist?(file_path)

          source = File.read(file_path)
          result = Prism.parse(source)
          visitor = RubyLsp::Guesser::ASTVisitor.new(file_path)
          result.value.accept(visitor)
        rescue StandardError
          # Silent error handling
        end
      end
    end
  end

  workers.each(&:join)
end

# Main benchmark
puts "Ruby LSP Guesser - File Indexing Benchmark"
puts "=" * 60

indexable_uris = indexable_files
file_count = indexable_uris.size
puts "Files to index: #{file_count}"
puts "CPU cores: #{Etc.nprocessors}"
puts "=" * 60
puts

# Warmup
puts "Warming up..."
RubyLsp::Guesser::VariableIndex.instance.clear
puts

# Sequential benchmark
puts "Running sequential indexing..."
sequential_time = Benchmark.realtime do
  sequential_indexing(indexable_uris)
end
puts "Sequential time: #{sequential_time.round(2)}s"
puts

# Parallel benchmarks with different worker counts
[2, 4, 8, Etc.nprocessors].uniq.sort.each do |workers|
  next if workers > Etc.nprocessors

  puts "Running parallel indexing with #{workers} workers..."
  parallel_time = Benchmark.realtime do
    parallel_indexing(indexable_uris, workers)
  end

  speedup = sequential_time / parallel_time
  puts "Parallel time (#{workers} workers): #{parallel_time.round(2)}s"
  puts "Speedup: #{speedup.round(2)}x"
  puts "Efficiency: #{(speedup / workers * 100).round(1)}%"
  puts
end

# Summary
puts "=" * 60
puts "SUMMARY"
puts "=" * 60

optimal_workers = [Etc.nprocessors, 8].min
puts "Testing optimal configuration (#{optimal_workers} workers)..."
optimal_time = Benchmark.realtime do
  parallel_indexing(indexable_uris, optimal_workers)
end

speedup = sequential_time / optimal_time
time_saved = sequential_time - optimal_time

puts "Sequential: #{sequential_time.round(2)}s"
puts "Parallel (#{optimal_workers} workers): #{optimal_time.round(2)}s"
puts "Speedup: #{speedup.round(2)}x"
puts "Time saved: #{time_saved.round(2)}s (#{(time_saved / sequential_time * 100).round(1)}% faster)"
