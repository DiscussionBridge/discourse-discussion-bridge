# frozen_string_literal: true

require "base64"
require "date"
require "digest"
require "json"
require "strscan"
require "time"
require "uri"

module DiscussionBridge
  module CmsProtocol
    SCHEMA_SHA256 =
      "8563a9b1346e3bf82635bd65a46bb1e25415a1003d7432f8fcb8c1c6e4f03c14"
    CONTRACT_SHA256 = "df31c5d2fc387a8b12b388438450eccd97966de34c82b1bf417634b21a36b495"
    contract_bytes = File.binread(File.join(__dir__, "cms_contract.json"))
    raise "V4 current normative identity mismatch" unless Digest::SHA256.hexdigest(contract_bytes) == CONTRACT_SHA256
    schema_bytes = File.binread(File.join(__dir__, "cms_protocol_types.json"))
    unless Digest::SHA256.hexdigest(schema_bytes) == SCHEMA_SHA256
      raise "V4 current schema identity mismatch"
    end
    freeze_tree =
      lambda do |value|
        if value.is_a?(Hash)
          value.each_value { |member| freeze_tree.call(member) }
        end
        value.each { |member| freeze_tree.call(member) } if value.is_a?(Array)
        value.freeze
      end
    SCHEMA = freeze_tree.call(JSON.parse(schema_bytes))
    ERRORS =
      SCHEMA
        .fetch("errors")
        .index_by { |error| error.fetch("code") }
        .freeze
    MAX_COUNTER = 9_007_199_254_740_991

    class Error < StandardError
      attr_reader :code

      def initialize(code)
        @code = code
        super(code)
      end
    end

    class StrictObject < Hash
      def []=(key, value)
        raise Error.new("invalid_json") if key?(key)
        super
      end
    end

    # Keep invalid numeric tokens as private values during typed traversal;
    # binary floating-point rounding cannot turn them into valid counters.
    InvalidNumber = Class.new

    def self.parse_json(raw, reject_negative_zero: true, type: nil)
      reject!("body_too_large") if raw.bytesize > 65_536
      raw = raw.dup.force_encoding(Encoding::UTF_8)
      unless raw.valid_encoding? && !raw.start_with?("\uFEFF")
        reject!("invalid_json")
      end
      value = JSON.parse(raw, object_class: StrictObject)
      reject!("invalid_json") unless value.is_a?(Hash)
      # Native JSON acceleration can ignore decimal_class. After full syntax
      # validation, bind each exact numeric lexeme to its parsed tree position
      # without relying on any global JSON parser override or float conversion.
      value = exact_numeric_tree(StringScanner.new(raw), value)
      if type
        validate!(type, value)
      elsif reject_negative_zero
        raw
          .scan(/"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/m)
          .each do |token|
            next if token.getbyte(0) == 34
            validate_integer_lexeme!(token)
          end
      end
      value
    rescue JSON::ParserError, EncodingError
      reject!("invalid_json")
    end

    def self.exact_numeric_tree(scanner, value)
      scanner.skip(/[\x20\x09\x0a\x0d]*/)
      case scanner.peek(1)
      when "{"
        scanner.getch
        result = {}
        scanner.skip(/[\x20\x09\x0a\x0d]*/)
        unless scanner.peek(1) == "}"
          loop do
            key_token = scanner.scan(/"(?:[^"\\]|\\.)*"/m)
            key = JSON.parse("[#{key_token}]").first
            scanner.skip(/[\x20\x09\x0a\x0d]*/)
            scanner.getch # Colon already established by whole-document syntax.
            result[key] = exact_numeric_tree(scanner, value.fetch(key))
            scanner.skip(/[\x20\x09\x0a\x0d]*/)
            break unless scanner.peek(1) == ","
            scanner.getch
            scanner.skip(/[\x20\x09\x0a\x0d]*/)
          end
        end
        scanner.getch
        result
      when "["
        scanner.getch
        result = []
        scanner.skip(/[\x20\x09\x0a\x0d]*/)
        unless scanner.peek(1) == "]"
          loop do
            result << exact_numeric_tree(scanner, value.fetch(result.length))
            scanner.skip(/[\x20\x09\x0a\x0d]*/)
            break unless scanner.peek(1) == ","
            scanner.getch
          end
        end
        scanner.getch
        result
      when '"'
        scanner.scan(/"(?:[^"\\]|\\.)*"/m)
        value
      else
        token = scanner.scan(/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/)
        unless token
          scanner.scan(/true|false|null/)
          return value
        end
        begin
          validate_integer_lexeme!(token)
        rescue Error
          InvalidNumber.new.freeze
        end
      end
    end
    private_class_method :exact_numeric_tree

    # Numeric CMS fields are bounded unsigned integers or integer enums.
    # Reject exact fractions before binary float rounding or underflow loses
    # their value. Exponents never cause an unbounded power allocation.
    def self.validate_integer_lexeme!(token)
      reject!("invalid_field") if token.start_with?("-")
      mantissa, exponent_text = token.split(/[eE]/, 2)
      whole, fraction = mantissa.split(".", 2)
      digits = (whole + fraction.to_s).sub(/\A0+/, "")
      return 0 if digits.empty?
      exponent_text ||= "0"
      exponent_digits = exponent_text.sub(/\A[+-]/, "").sub(/\A0+/, "")
      reject!("invalid_field") if exponent_digits.length > 6
      power = exponent_text.to_i - fraction.to_s.length
      if power.negative?
        places = -power
        if places > digits.length || digits[-places, places].match?(/[1-9]/)
          reject!("invalid_field")
        end
        digits = digits[0, digits.length - places]
      else
        if digits.length + power > MAX_COUNTER.to_s.length
          reject!("invalid_field")
        end
        digits += "0" * power
      end
      digits = digits.sub(/\A0+/, "")
      if digits.length > MAX_COUNTER.to_s.length ||
           (
             digits.length == MAX_COUNTER.to_s.length &&
               digits > MAX_COUNTER.to_s
           )
        reject!("invalid_field")
      end
      digits.to_i
    end

    def self.validate!(name, value)
      validate_shape!(name, value)
      validate_semantics!(name, value)
      value
    end

    def self.validate_shape!(name, value)
      type = SCHEMA.fetch("types").fetch(name)
      case type.fetch("kind")
      when "object"
        reject!("invalid_field") unless value.is_a?(Hash)
        fields = type.fetch("fields")
        fields.each do |key, field|
          unless value.key?(key)
            reject!("invalid_field") if field["required"]
            next
          end
          next if value[key].nil? && field["nullable"]
          validate_shape!(field.fetch("type"), value[key])
        end
        reject!("unknown_field") if (value.keys - fields.keys).any?
      when "tagged_union"
        reject!("invalid_field") unless value.is_a?(Hash)
        branch = type.fetch("variants")[value[type.fetch("field")]]
        reject!("invalid_field") unless branch
        validate_shape!(branch, value)
      when "array"
        reject!("invalid_field") unless value.is_a?(Array)
        if type["minimum_items"] && value.size < type["minimum_items"]
          reject!("invalid_field")
        end
        if type["maximum_items"] && value.size > type["maximum_items"]
          reject!("invalid_field")
        end
        value.each { |item| validate_shape!(type.fetch("items"), item) }
        if type["unique_items"]
          if value.map { |item| semantic_identity(item) }.uniq.size !=
               value.size
            reject!("invalid_field")
          end
        end
      when "integer"
        valid =
          (value.is_a?(Integer) || value.is_a?(Float)) && value.finite? &&
            value == value.to_i &&
            !(value.is_a?(Float) && value.zero? && (1.0 / value).negative?) &&
            value >= type.fetch("minimum") && value <= type.fetch("maximum")
        reject!("invalid_field") unless valid
      when "boolean"
        reject!("invalid_field") unless value == true || value == false
      when "enum"
        unless type
                 .fetch("values")
                 .any? { |item|
                   same_type =
                     item.class == value.class ||
                       (item.is_a?(Numeric) && value.is_a?(Numeric))
                   same_type && item == value
                 }
          reject!("invalid_field")
        end
      when "string"
        validate_string!(name, type, value)
      else
        raise "Unsupported frozen CMS type grammar"
      end
      value
    end

    def self.validate_string!(name, type, value)
      reject!("invalid_field") unless value.is_a?(String)
      value = value.dup.force_encoding(Encoding::UTF_8)
      reject!("invalid_field") unless value.valid_encoding?
      if type["utf8_minimum_bytes"] &&
           value.bytesize < type["utf8_minimum_bytes"]
        reject!("invalid_field")
      end
      if type["utf8_maximum_bytes"] &&
           value.bytesize > type["utf8_maximum_bytes"]
        reject!("invalid_field")
      end
      if type["control_characters"] == "reject"
        reject!("invalid_field") if value.match?(/\p{Cc}/)
      end
      if %w[OpaqueId Revision Label Title].include?(name)
        reject!("invalid_field") if value.match?(/\A\p{Space}*\z/)
      end
      if type["pattern"]
        pattern = type.fetch("pattern").sub(/^\^/, "\\A").sub(/\$$/, "\\z")
        reject!("invalid_field") unless Regexp.new(pattern).match?(value)
      end
      case name
      when "UUID"
        if value == "00000000-0000-0000-0000-000000000000"
          reject!("invalid_field")
        end
      when "CoreId"
        reject!("invalid_field") if value.to_i > 9_223_372_036_854_775_807
      when "Instant"
        unless value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/)
          reject!("invalid_field")
        end
        year, month, day, hour, minute, second =
          value.scan(/\d+/).first(6).map(&:to_i)
        unless Date.valid_date?(year, month, day, Date::GREGORIAN) &&
                 hour < 24 && minute < 60 && second < 60
          reject!("invalid_field")
        end
      when "Url"
        url_key(value)
      when "Base64"
        decoded = Base64.strict_decode64(value)
        reject!("invalid_field") unless Base64.strict_encode64(decoded) == value
      when "Base64Url"
        reject!("invalid_field") unless value.match?(/\A[A-Za-z0-9_-]*\z/)
        decoded = Base64.urlsafe_decode64(value)
        unless Base64.urlsafe_encode64(decoded, padding: false) == value
          reject!("invalid_field")
        end
      end
      if type["decoded_bytes"]
        decoded = Base64.urlsafe_decode64(value)
        unless decoded.bytesize == type["decoded_bytes"] &&
                 Base64.urlsafe_encode64(decoded, padding: false) == value
          reject!("invalid_field")
        end
      end
    rescue ArgumentError, URI::InvalidURIError
      reject!("invalid_field")
    end

    # Value-local constraints only. Receiver authority, expected stored state,
    # native locks/ownership and actual public proof are separate obligations.
    def self.validate_semantics!(name, value)
      type = SCHEMA.fetch("types").fetch(name)
      case type.fetch("kind")
      when "object"
        type
          .fetch("fields")
          .each do |key, field|
            if value.key?(key) && !value[key].nil?
              validate_semantics!(field.fetch("type"), value[key])
            end
          end
        if value["source_created_at"] && value["source_updated_at"]
          if value["source_updated_at"] < value["source_created_at"]
            reject!("invalid_field")
          end
        end
      when "array"
        value.each { |item| validate_semantics!(type.fetch("items"), item) }
      when "tagged_union"
        validate_semantics!(
          type.fetch("variants").fetch(value.fetch(type.fetch("field"))),
          value
        )
      end

      case name
      when "SourceAuthors"
        if value.map { |author| author.fetch("id") }.uniq.size != value.size
          reject!("invalid_field")
        end
      when "ToRecord"
        if value.key?("primary_source_author_id")
          unless Array(value["source_authors"]).any? { |author|
                   author["id"] == value["primary_source_author_id"]
                 }
            reject!("invalid_field")
          end
        end
        if value.fetch("representation").fetch("kind") == "full"
          body = value.fetch("content_html").b
          unless body.bytesize == value.fetch("source_content_bytes") &&
                   Digest::SHA256.hexdigest(body) ==
                     value.fetch("source_content_sha256")
            reject!("content_hash_mismatch")
          end
        elsif value.fetch("representation").fetch("kind") == "generated_excerpt"
          CmsGeneratedExcerpt.validate_record!(value)
        end
      when "SourceFeedQuery"
        if value.fetch("stream") == "changes" && !value.key?("cursor")
          reject!("invalid_field")
        end
      when "SourceFeed"
        if value.fetch("stream") == "initial"
          if value["next_cursor"].nil? == value["checkpoint_cursor"].nil?
            reject!("invalid_field")
          end
        else
          reject!("invalid_field") if value["checkpoint_cursor"].nil?
        end
      when "ContentChunk"
        length = Base64.strict_decode64(value.fetch("content_base64")).bytesize
        ending = value.fetch("offset") + length
        if length > 32_768 || ending > MAX_COUNTER ||
             ending > value.fetch("content_bytes")
          reject!("invalid_field")
        end
        if value["next_offset"].nil?
          reject!("invalid_field") unless ending == value.fetch("content_bytes")
        else
          unless value.fetch("next_offset") == ending &&
                   ending > value.fetch("offset") &&
                   ending < value.fetch("content_bytes")
            reject!("invalid_field")
          end
        end
      when "Policy"
        unless (value.fetch("selection") == "categories") ==
                 value.fetch("category_ids").any?
          reject!("invalid_field")
        end
        if (
             value.fetch("include_topic_ids") & value.fetch("exclude_topic_ids")
           ).any?
          reject!("invalid_field")
        end
      when "Connection"
        origin = URI.parse(value.fetch("destination_origin"))
        unless ["", "/"].include?(origin.path) && origin.query.nil?
          reject!("invalid_field")
        end
      when "Work"
        reject!("invalid_field") if value["last_failure_code"] == "content_preservation_unavailable"
        unless (value.fetch("action") == "withdraw") ==
                 value["source_revision"].nil?
          reject!("invalid_field")
        end
        reject!("invalid_field") if value.fetch("attempt") > 3
      when "Lease"
        unless value.fetch("lease_generation") ==
                 value.fetch("work").fetch("lease_generation") &&
                 value.fetch("expires_at") > value.fetch("server_time")
          reject!("invalid_field")
        end
      when "Failure", "Error"
        reject!("invalid_field") if name == "Failure" && value.fetch("code") == "content_preservation_unavailable"
        error = ERRORS.fetch(value.fetch("code"))
        if name == "Error" &&
             value.fetch("retryable") != error.fetch("retryable")
          reject!("invalid_field")
        end
        delay = value.fetch("retry_after_seconds")
        if delay && (!error.fetch("retryable") || delay < 1 || delay > 3_600)
          reject!("invalid_field")
        end
      when "PublishedVerification"
        unless value.fetch("source_content_sha256") ==
                 value.fetch("representation").fetch("source_content_sha256")
          reject!("invalid_field")
        end
      when "SourceUrlMoveFinalize"
        if value.fetch("new_source_revision") ==
             value.fetch("expected_source_revision") ||
             value.fetch("verification").fetch("source_revision") !=
               value.fetch("new_source_revision")
          reject!("invalid_field")
        end
      when "AttentionPreparedTransaction"
        valid_preparation = (value.fetch("action") == "withdraw") == value["source_revision"].nil? &&
             value.fetch("native_result").fetch("kind") == value.fetch("action") &&
             value["deployment_id"].nil? == value["deployed_at"].nil? &&
             (value["deployed_at"].nil? || value["deployed_at"] >= value.fetch("prepared_at"))
        unless valid_preparation
          reject!("invalid_field")
        end
      when "AttentionInspection", "AttentionRecovery"
        work = value.fetch("work")
        mapping = value.fetch("mapping")
        source = value["source"]
        matching_identity = work.fetch("mapping_id") == mapping.fetch("mapping_id") &&
             work.fetch("source_id") == mapping.fetch("source_id") &&
             (work.fetch("action") != "publish_revision" || source) &&
             (!source || source.fetch("source_id") == work.fetch("source_id") &&
               (work.fetch("action") != "publish_revision" || source.fetch("source_revision") == work.fetch("source_revision")))
        unless matching_identity
          reject!("identity_conflict")
        end
        if name == "AttentionInspection"
          reject!("invalid_field") unless work.fetch("state") == "attention"
          prepared = value["prepared_transaction"]
          if prepared && %w[work_id action source_revision policy_revision lease_generation].any? { |key| prepared[key] != work[key] }
            reject!("identity_conflict")
          end
        else
          unless work.fetch("work_id") != value.fetch("predecessor_work_id") &&
               work.fetch("attempt_cycle") != value.fetch("predecessor_attempt_cycle") &&
               work.fetch("state") == "pending" && work.fetch("attempt") == 0 &&
               work["retry_at"].nil? && work["last_failure_code"].nil?
            reject!("invalid_field")
          end
          if value.fetch("mode") == "settle_restored_baseline"
            baseline = value["native_baseline"]
            proof = value["verification"]
            unless baseline && proof && baseline.fetch("native_id") == proof.fetch("native_id") &&
                 baseline.fetch("canonical_url") == proof.fetch("url")
              reject!("invalid_field")
            end
          end
        end
      when "AttentionInspectionPage", "AttentionRecoveryPage"
        items = value.fetch("items")
        unless items.each_cons(2).all? { |left, right| right.fetch("sequence") > left.fetch("sequence") } &&
             (items.empty? ? !value.fetch("has_more") : value.fetch("next_after") == items.last.fetch("sequence"))
          reject!("invalid_field")
        end
      when "AttentionObservation"
        %w[ownership native_result verification].each do |field|
          item = value[field]
          if item && (value["native_id"].nil? || item.fetch("native_id") != value["native_id"])
            reject!("identity_conflict")
          end
        end
      when "AttentionInspectionResult"
        if value.fetch("status") == "ready" && (value["observed_at"].nil? || value.fetch("issue") != "none")
          reject!("invalid_field")
        end
      when "AttentionCheckSelections", "AttentionRetrySelections"
        key = name == "AttentionCheckSelections" ? "work_id" : "inspection_id"
        reject!("invalid_field") unless value.map { |item| item.fetch(key) }.uniq.size == value.size
      when "AttentionAdminItemResult"
        if value.fetch("status") == "queued" && (value["inspection_id"].nil? || value["recovery_id"].nil? ||
             value["successor_work_id"].nil? || value["successor_work_id"] == value.fetch("work_id"))
          reject!("invalid_field")
        end
      when "ResolveResult"
        conflict = value.fetch("outcome") == "reconciliation_required"
        fields = %w[
          resource_id
          topic_id
          topic_url
          source_revision
          synchronized_at
        ]
        unless fields.all? { |field| value[field].nil? == conflict }
          reject!("invalid_field")
        end
        reasons = %w[
          identity_conflict
          canonical_url_conflict
          native_ownership_conflict
          adoption_unavailable
        ]
        unless reasons.include?(value.fetch("reason")) == conflict
          reject!("invalid_field")
        end
      end
      value
    end

    def self.validate_attention_feed_page!(type, page, after)
      reject!("invalid_field") if %w[AttentionInspectionPage AttentionRecoveryPage].exclude?(type)
      validate!("UInt", after)
      validate!(type, page)
      if page.fetch("items").any? { |item| item.fetch("sequence") <= after } ||
           page.fetch("items").empty? && page.fetch("next_after") != after
        reject!("invalid_field")
      end
      page
    end

    # Response-only code scope is distinct from its global enum membership.
    # Native controllers supply an exact declared route identity only for the
    # two corresponding actions; all other actions remain outside this grant.
    def self.validate_error_response!(route_id, value, status)
      validate!("Error", value)
      if value.fetch("code") == "content_preservation_unavailable" &&
           !%w[V4-02 V4-29].include?(route_id)
        reject!("invalid_field")
      end
      reject!("invalid_field") unless ERRORS.fetch(value.fetch("code")).fetch("http") == status
      value
    end

    def self.apply_defaults(name, value)
      validate!(name, value)
      apply_defaults_unchecked(name, value)
    end

    def self.apply_defaults_unchecked(name, value)
      type = SCHEMA.fetch("types").fetch(name)
      case type.fetch("kind")
      when "object"
        type
          .fetch("fields")
          .each_with_object({}) do |(key, field), result|
            if value.key?(key)
              result[key] = (
                if value[key].nil?
                  nil
                else
                  apply_defaults_unchecked(field.fetch("type"), value[key])
                end
              )
            elsif field.key?("default")
              result[key] = field.fetch("default")
            end
          end
      when "array"
        value.map { |item| apply_defaults_unchecked(type.fetch("items"), item) }
      when "tagged_union"
        apply_defaults_unchecked(
          type.fetch("variants").fetch(value.fetch(type.fetch("field"))),
          value
        )
      else
        value
      end
    end
    private_class_method :apply_defaults_unchecked

    def self.semantic_tree(value)
      case value
      when InvalidNumber
        reject!("invalid_field")
      when Hash
        value.keys.sort.to_h { |key| [key, semantic_tree(value.fetch(key))] }
      when Array
        value.map { |item| semantic_tree(item) }
      when Float
        value.finite? && value == value.to_i ? value.to_i : value
      else
        value
      end
    end

    def self.semantic_identity(value)
      JSON.generate(semantic_tree(value))
    end

    def self.url_key(value)
      reject!("invalid_field") if value.match?(/%(?![0-9a-fA-F]{2})/)
      uri = URI.parse(value)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? &&
               uri.fragment.nil?
        reject!("invalid_field")
      end
      path = uri.path.presence || "/"
      if path
           .split("/")
           .any? { |segment|
             %w[. ..].include?(URI::DEFAULT_PARSER.unescape(segment))
           }
        reject!("invalid_field")
      end
      port = uri.port == 443 ? "" : ":#{uri.port}"
      query = uri.query.nil? ? "" : "?#{uri.query}"
      "https://#{uri.host.downcase}#{port}#{path}#{query}"
    rescue URI::InvalidURIError
      reject!("invalid_field")
    end

    def self.instant(value)
      value&.utc&.iso8601(3)
    end

    def self.ownership_hash(receipt)
      validate!("NativeOwnershipReceipt", receipt)
      fields =
        SCHEMA.fetch("types").fetch("NativeOwnershipReceipt").fetch("fields")
      bytes =
        fields
          .keys
          .map do |key|
            value = receipt.fetch(key)
            if value.nil?
              [0xffff_ffff].pack("N")
            else
              integer =
                SCHEMA
                  .fetch("types")
                  .fetch(fields.fetch(key).fetch("type"))
                  .fetch("kind") == "integer"
              text = integer ? value.to_i.to_s : value.to_s
              [text.bytesize].pack("N") + text.b
            end
          end
          .join
          .b
      Digest::SHA256.hexdigest(bytes)
    end

    def self.reject!(code)
      raise Error.new(code)
    end
  end
end
