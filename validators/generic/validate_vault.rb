#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"

root = Pathname.new(ENV.fetch("VAULT_ROOT", ARGV.first || Dir.pwd)).expand_path
abort "Vault directory does not exist: #{root}" unless root.directory?

conflicts = Dir.glob(root.join("**/*").to_s, File::FNM_DOTMATCH).select do |path|
  basename = File.basename(path).downcase
  basename.include?("conflicted copy") || path.end_with?(".icloud")
end
abort "Vault contains sync-conflict or placeholder files" unless conflicts.empty?

puts "OK: generic Obsidian Vault at #{root}"
