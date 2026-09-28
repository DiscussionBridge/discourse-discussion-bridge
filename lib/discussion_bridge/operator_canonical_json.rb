# frozen_string_literal: true

require "json"

module DiscussionBridge
  class OperatorCanonicalJson
    class InvalidValue < ArgumentError; end

    def self.generate(value)
      case value
      when Hash
        keys = value.keys.map(&:to_s)
        raise InvalidValue, "canonical JSON object keys must be unique strings" unless keys.uniq.length == keys.length

        "{#{keys.sort.map { |key| "#{JSON.generate(key)}:#{generate(fetch(value, key))}" }.join(",")}}"
      when Array
        "[#{value.map { |entry| generate(entry) }.join(",")}]"
      when String
        utf8 = value.encode(Encoding::UTF_8)
        raise InvalidValue, "canonical JSON strings must be valid UTF-8" unless utf8.valid_encoding?

        JSON.generate(utf8)
      when Integer
        value.to_s
      when TrueClass
        "true"
      when FalseClass
        "false"
      when NilClass
        "null"
      else
        raise InvalidValue, "canonical JSON contains an unsupported value"
      end
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      raise InvalidValue, "canonical JSON strings must be valid UTF-8"
    end

    def self.fetch(value, key)
      value.key?(key) ? value.fetch(key) : value.fetch(key.to_sym)
    end
    private_class_method :fetch
  end
end
