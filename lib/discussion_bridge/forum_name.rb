# frozen_string_literal: true

module DiscussionBridge
  module ForumName
    class Invalid < StandardError
    end

    def self.validate!(value, allow_blank: false)
      raise Invalid unless value.is_a?(String)
      value = value.dup.force_encoding(Encoding::UTF_8)
      unless value.valid_encoding? && value.bytesize <= 200 &&
               !value.match?(/\p{Cc}/) &&
               (allow_blank || !value.match?(/\A\p{Space}*\z/))
        raise Invalid
      end
      value
    end
  end
end

