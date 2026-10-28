# frozen_string_literal: true

module DiscussionBridge
  # Native storage/administration bounds; this is not a transport grammar.
  module NativeConstraints
    MAX_TITLE_BYTES = 1024
    MAX_ADAPTER_ID_BYTES = 100
    MAX_CORRELATION_ID_BYTES = 200
  end
end
