# frozen_string_literal: true

workflow_paths = Dir[File.expand_path("../.github/workflows/*.{yml,yaml}", __dir__)].sort
abort "No CI workflows found" if workflow_paths.empty?

errors = []
workflow_paths.each do |path|
  File.readlines(path, chomp: true).each_with_index do |line, index|
    next unless (match = line.match(/^\s*(?:-\s*)?uses:\s*([^#\s]+?)(?:\s*#.*)?$/))

    reference = match[1]
    next if reference.start_with?("./")

    revision = reference.split("@", 2)[1]
    errors << "#{path}:#{index + 1}: action is not pinned to a 40-character commit" unless
      revision&.match?(/\A[0-9a-f]{40}\z/)
  end
end

entrypoint = File.read(File.expand_path("../.github/workflows/discourse-plugin.yml", __dir__))
pinned_workflow = File.read(File.expand_path("../.github/workflows/discourse-plugin-pinned.yml", __dir__))
errors << "Discourse core_ref is not immutable" unless
  entrypoint.match?(/^\s*core_ref:\s*[0-9a-f]{40}\s*$/)
errors << "Adapter Protocol checkout is not immutable" unless
  entrypoint.match?(/^\s*ref:\s*72b3925316e1cb68788e34d0fe2037e0681780af\s*$/)
errors << "Discourse test container is not digest-pinned" unless
  entrypoint.match?(/container:\s*discourse\/discourse_test:slim-browsers@sha256:[0-9a-f]{64}\s*$/)
errors << "CI uses the movable ubuntu-latest runner label" if
  workflow_paths.any? { |path| File.read(path).include?("ubuntu-latest") }
errors << "Entrypoint runner label is not the declared Ubuntu release" unless
  entrypoint.match?(/^\s*runs-on:\s*ubuntu-24\.04\s*$/) &&
    entrypoint.match?(/^\s*runs_on:\s*ubuntu-24\.04\s*$/)
errors << "Reusable workflow runner default is not the declared Ubuntu release" unless
  pinned_workflow.match?(/^\s*default:\s*["']ubuntu-24\.04["']\s*$/)
errors << "Every CI job must record runner image provenance" unless
  (entrypoint.scan(/^\s*- name: Record runner image provenance\s*$/).length +
    pinned_workflow.scan(/^\s*- name: Record runner image provenance\s*$/).length) == 4 &&
    workflow_paths.all? do |path|
      workflow = File.read(path)
      workflow.include?("ImageOS") && workflow.include?("ImageVersion") &&
        workflow.include?("runner_image_provenance=GitHub Set up job log") &&
        workflow.include?("GITHUB_STEP_SUMMARY")
    end
errors << "Compatibility workflow may override the immutable Discourse core_ref" if
  pinned_workflow.match?(/release\/\d{4}\.\d+|release\/\#\{|BASE_REF[^\n]*core_ref/i)
errors << "CI downloads a mutable Playwright/browser runtime" if
  pinned_workflow.match?(/\bplaywright\s+install\b/)
errors << "CI does not use the browser cache baked into the pinned Discourse test image" unless
  pinned_workflow.match?(/^\s*PLAYWRIGHT_BROWSERS_PATH:\s*\/home\/discourse\/\.cache\/ms-playwright\s*$/)
errors << "CI may download mutable pre-built Core assets" unless
  pinned_workflow.match?(/^\s*export DISCOURSE_DOWNLOAD_PRE_BUILT_ASSETS=0\s*$/)

%w[Gemfile.lock pnpm-lock.yaml].each do |lockfile|
  errors << "#{lockfile} is required" unless File.file?(File.expand_path("../#{lockfile}", __dir__))
end

abort errors.join("\n") if errors.any?

puts "CI actions, source inputs, container, and dependency locks are immutable"
