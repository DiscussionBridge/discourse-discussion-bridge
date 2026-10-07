# frozen_string_literal: true

module DiscussionBridge
  module SourceConnectionScope
    def self.revision(connection)
      scope = { "platform" => connection.platform,
        "directions" => Array(connection.allowed_directions).sort,
        "lanes" => Array(connection.allowed_lanes).sort,
        "origins" => Array(connection.allowed_origins).sort }
      "policy:#{NativeSourceRevisionCapture.fingerprint(scope)}"
    end
  end
end
