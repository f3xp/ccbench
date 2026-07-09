#!/usr/bin/env ruby
# Inject test source files into a target of a classic (non-synchronized) Xcode
# project, using the `xcodeproj` gem bundled with CocoaPods.
#
# Usage: inject_tests.rb <project.xcodeproj> <target_name> <group_name> <file...>
# Files are added as references under <group_name> and to the target's compile
# sources build phase. Idempotent: existing references with the same path are
# removed first.
require 'xcodeproj'

project_path = ARGV[0]
target_name  = ARGV[1]
group_name   = ARGV[2]
files        = ARGV[3..] || []

project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == target_name }
abort("target not found: #{target_name}") unless target

group = project.main_group.find_subpath(group_name, true)
group.set_source_tree('SOURCE_ROOT')

added = 0
files.each do |path|
  abs = File.expand_path(path)
  # Remove any pre-existing reference to the same file (idempotency).
  project.files.select { |f| f.real_path.to_s == abs }.each do |f|
    f.build_files.each { |bf| bf.referrers.each { |r| r.remove_build_file(bf) rescue nil } }
    f.remove_from_project
  end
  ref = group.new_reference(abs)
  target.add_file_references([ref])
  added += 1
end

project.save
puts "injected #{added} file(s) into #{target_name}"
