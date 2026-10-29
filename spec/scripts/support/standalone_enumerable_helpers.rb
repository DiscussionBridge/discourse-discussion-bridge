# frozen_string_literal: true

abort "Standalone helpers must never replace native Rails methods" if defined?(Rails::Application)

# Framework conveniences for explicit standalone author-test seams only.
# These do not boot Rails or establish native database/permission evidence.
module Enumerable
  def exclude?(value) = include?(value) == false

  def index_by
    indexed = {}
    each { |entry| indexed[yield(entry)] = entry }
    indexed
  end
end
