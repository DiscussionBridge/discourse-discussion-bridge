# frozen_string_literal: true

require "json"

module DiscussionBridge
  class OperatorCanonicalJson
    class InvalidValue < ArgumentError; end

    class StrictHash < Hash
      def []=(key, value)
        raise InvalidValue, "canonical JSON object keys must be unique" if key?(key)

        super
      end
    end

    def self.parse(value)
      raise InvalidValue, "canonical JSON input must be UTF-8" unless
        value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?

      JSON.parse(value, object_class: StrictHash)
    rescue JSON::ParserError
      raise InvalidValue, "canonical JSON input is invalid"
    end

    def self.generate(value)
      case value
      when Hash
        keys = value.keys.map(&:to_s)
        raise InvalidValue, "canonical JSON object keys must be unique strings" unless keys.uniq.length == keys.length

        "{#{keys.sort_by { |key| key.encode(Encoding::UTF_16BE).bytes }.map { |key| "#{generate(key)}:#{generate(fetch(value, key))}" }.join(",")}}"
      when Array
        "[#{value.map { |entry| generate(entry) }.join(",")}]"
      when String
        utf8 = value.encode(Encoding::UTF_8)
        raise InvalidValue, "canonical JSON strings must be valid I-JSON" unless
          utf8.valid_encoding? && utf8.each_codepoint.none? { |codepoint| noncharacter?(codepoint) }

        JSON.generate(utf8)
      when Integer
        raise InvalidValue, "canonical JSON number exceeds I-JSON precision" if value.abs > 9_007_199_254_740_991

        value.to_s
      when Float
        raise InvalidValue, "canonical JSON number must be finite" unless value.finite?
        canonical_float(value)
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

    def self.noncharacter?(codepoint)
      codepoint.between?(0xFDD0, 0xFDEF) || (codepoint & 0xFFFE) == 0xFFFE
    end
    private_class_method :noncharacter?

    def self.canonical_float(value)
      return "0" if value.zero?

      sign = value.negative? ? "-" : ""
      mantissa, exponent = value.abs.to_s.downcase.split("e", 2)
      integral, fractional = mantissa.split(".", 2)
      digits = (integral + fractional.to_s).sub(/0+\z/, "")
      decimal_position = integral.length + (exponent ? Integer(exponent, 10) : 0)
      if value.abs >= 1e-6 && value.abs < 1e21
        rendered = if decimal_position <= 0
          "0.#{"0" * -decimal_position}#{digits}"
        elsif decimal_position >= digits.length
          digits + ("0" * (decimal_position - digits.length))
        else
          "#{digits[0, decimal_position]}.#{digits[decimal_position..]}"
        end
        return sign + rendered
      end

      fraction = digits[1..]
      scientific = digits[0] + (!fraction.to_s.empty? ? ".#{fraction}" : "")
      canonical_exponent = decimal_position - 1
      "#{sign}#{scientific}e#{canonical_exponent >= 0 ? "+" : ""}#{canonical_exponent}"
    end
    private_class_method :canonical_float
  end
end
