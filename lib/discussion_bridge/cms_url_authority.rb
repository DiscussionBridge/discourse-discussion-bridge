# frozen_string_literal: true

require "digest"
require "ipaddr"
require "json"

module DiscussionBridge
  class CmsUrlAuthority
    MANIFEST_SHA256 =
      "bd03b4691c944104bc2cb17a8566e062a765ec475dfb042798d2201181c09ed8"

    class Invalid < StandardError
    end

    Parts =
      Data.define(:raw_host, :ascii_host, :effective_port, :path, :query) do
        def facts
          {
            "rawHost" => raw_host,
            "asciiHost" => ascii_host,
            "effectivePort" => effective_port
          }.freeze
        end

        # Preserve the old key bytes for every previously accepted ASCII host.
        # An authority comparison is separate and must not re-key retained state.
        def legacy_key
          host = raw_host.ascii_only? ? raw_host.downcase : ascii_host
          "https://#{host}#{effective_port == 443 ? "" : ":#{effective_port}"}#{path.empty? ? "/" : path}#{query}"
        end

        def comparison_key
          "#{comparison_origin}#{path.empty? ? "/" : path}#{query}"
        end

        def comparison_origin
          "https://#{ascii_host}#{effective_port == 443 ? "" : ":#{effective_port}"}"
        end

        def origin_only?
          (path.empty? || path == "/") && query.nil?
        end
      end

    bundle = File.join(__dir__, "vendor/cms_idna")
    manifest_path = File.join(bundle, "MANIFEST.json")
    unless File.directory?(bundle) && !File.symlink?(bundle) &&
             File.file?(manifest_path) && !File.symlink?(manifest_path)
      raise "V4 private IDNA bundle inventory mismatch"
    end
    manifest_bytes = File.binread(manifest_path)
    unless Digest::SHA256.hexdigest(manifest_bytes) == MANIFEST_SHA256
      raise "V4 private IDNA manifest identity mismatch"
    end
    manifest = JSON.parse(manifest_bytes)
    unless manifest.fetch("format") == 1 &&
             manifest.fetch("unicode_version") == "17.0.0" &&
             manifest.fetch("uri_idna_commit") ==
               "29fadb2b73599c66db3202d62ceb1d25eefeca12"
      raise "V4 private IDNA bundle identity mismatch"
    end
    expected_members =
      manifest
        .fetch("members")
        .map do |member|
          relative = member.fetch("path")
          unless relative.is_a?(String) && !relative.empty? &&
                   !relative.start_with?("/") && !relative.include?(":") &&
                   !relative.include?("\\") &&
                   relative
                     .split("/")
                     .none? { |part|
                       part.empty? || part == "." || part == ".."
                     }
            raise "V4 private IDNA member path mismatch"
          end
          file = File.join(bundle, relative)
          unless File.file?(file) && !File.symlink?(file) &&
                   File.realpath(file).start_with?(
                     File.realpath(bundle) + "/"
                   ) && File.size(file) == member.fetch("bytes") &&
                   Digest::SHA256.file(file).hexdigest == member.fetch("sha256")
            raise "V4 private IDNA member identity mismatch"
          end
          relative
        end
    actual_members = []
    pending_directories = [[bundle, ""]]
    seen_directories = { File.realpath(bundle) => true }
    until pending_directories.empty?
      directory, prefix = pending_directories.pop
      Dir
        .children(directory)
        .each do |name|
          relative = prefix + name
          file = File.join(directory, name)
          if File.symlink?(file) ||
               !File.realpath(file).start_with?(File.realpath(bundle) + "/") ||
               (!File.file?(file) && !File.directory?(file))
            raise "V4 private IDNA bundle inventory mismatch"
          end
          if File.directory?(file)
            real_directory = File.realpath(file)
            if seen_directories[real_directory]
              raise "V4 private IDNA bundle inventory mismatch"
            end
            seen_directories[real_directory] = true
            pending_directories << [file, relative + "/"]
          elsif relative != "MANIFEST.json"
            actual_members << relative
          end
        end
    end
    unless expected_members.uniq.length == expected_members.length &&
             actual_members.sort == expected_members.sort
      raise "V4 private IDNA member inventory mismatch"
    end

    # Execute no dependency member until its pinned manifest, complete inventory
    # and every source byte have been checked. Never use an ambient IDNA/NFC gem.
    require_relative "vendor/cms_idna/uri/idna"
    unless CmsIdnaVendor::UNICODE_VERSION == "17.0.0" &&
             CmsIdnaNfc17::UNICODE_VERSION == "17.0.0"
      raise "V4 private IDNA bundle identity mismatch"
    end

    def self.parse(value, policy:)
      raise Invalid unless value.is_a?(String)
      text = value.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding? && !text.include?("\\") &&
               !text.match?(/[\p{Space}\p{Cc}\uFEFF]/) &&
               !text.match?(/%(?![a-f0-9]{2})/i)
        raise Invalid
      end
      match = %r{\Ahttps://([^/?#]+)([^?#]*)(\?[^#]*)?\z}i.match(text)
      raise Invalid unless match && !match[1].include?("@")
      authority = /\A(\[[^\]]+\]|[^:]+)(?::([0-9]*))?\z/.match(match[1])
      raise Invalid unless authority
      raw_host = authority[1]
      port = 443
      if authority[2] && !authority[2].empty?
        port = 0
        authority[2].each_byte do |digit|
          port = port * 10 + digit - 48
          raise Invalid if port > 65_535
        end
      end
      match[2]
        .split("/", -1)
        .each do |segment|
          raise Invalid if %w[. ..].include?(segment.gsub(/%2e/i, "."))
        end
      host =
        raw_host
          .b
          .gsub(/%([a-f0-9]{2})/i) { [$1.to_i(16)].pack("C") }
          .force_encoding(Encoding::UTF_8)
      raise Invalid unless host.valid_encoding?
      if raw_host.start_with?("[")
        raise Invalid unless raw_host.end_with?("]") && !raw_host.include?("%")
        address = IPAddr.new(raw_host[1...-1])
        raise Invalid unless address.ipv6?
        ascii_host = raw_host.downcase
      else
        raise Invalid if host.match?(%r{[\x00-\x20\x7f%#/:<>?@\[\]\\^|]})
        unless policy.fetch("id") == "db-url-uts46-17-1" &&
                 policy.fetch("unicode_version") ==
                   CmsIdnaVendor::UNICODE_VERSION &&
                 policy.fetch("unicode_version") ==
                   CmsIdnaNfc17::UNICODE_VERSION
          raise "V4 URL policy identity mismatch"
        end
        ascii_host =
          CmsIdnaVendor.to_ascii(
            host,
            check_hyphens: policy.fetch("check_hyphens"),
            check_bidi: policy.fetch("check_bidi"),
            check_joiners: policy.fetch("check_joiners"),
            use_std3_ascii_rules: policy.fetch("use_std3_ascii_rules"),
            transitional_processing: policy.fetch("transitional_processing"),
            verify_dns_length: policy.fetch("verify_dns_length"),
            ignore_invalid_punycode: policy.fetch("ignore_invalid_punycode")
          )
        if ascii_host.empty? ||
             ascii_host.match?(%r{[^\x21-\x7e]|[%#/:<>?@\[\]\\^|]})
          raise Invalid
        end
        ipv4_host!(ascii_host)
      end
      Parts.new(
        raw_host.freeze,
        ascii_host.freeze,
        port,
        match[2].freeze,
        match[3]&.freeze
      )
    rescue CmsIdnaVendor::Error, IPAddr::InvalidAddressError, EncodingError
      raise Invalid
    end

    def self.ipv4_number(value)
      return if value.empty?
      radix = 10
      if value.match?(/\A0x/i)
        value = value[2..]
        radix = 16
      elsif value.length >= 2 && value.start_with?("0")
        value = value[1..]
        radix = 8
      end
      return 0 if value.empty?
      pattern =
        radix == 16 ?
          /\A[a-f0-9]+\z/i :
          radix == 8 ? /\A[0-7]+\z/ : /\A[0-9]+\z/
      return unless value.match?(pattern)
      number = 0
      value.downcase.each_byte do |byte|
        digit = byte >= 97 ? byte - 87 : byte - 48
        return 4_294_967_296 if number > (4_294_967_295 - digit) / radix
        number = number * radix + digit
      end
      number
    end
    private_class_method :ipv4_number

    def self.ipv4_host!(host)
      parts = host.split(".", -1)
      parts.pop if parts.last == ""
      last = parts.last
      if last.nil? || (!last.match?(/\A[0-9]+\z/) && ipv4_number(last).nil?)
        return
      end
      raise Invalid if parts.length > 4
      parts.each_with_index do |part, index|
        number = ipv4_number(part)
        maximum = index == parts.length - 1 ? 256**(5 - parts.length) - 1 : 255
        raise Invalid if number.nil? || number > maximum
      end
    end
    private_class_method :ipv4_host!
  end
end
