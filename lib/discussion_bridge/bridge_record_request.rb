# frozen_string_literal: true

require "json"
require "digest"
require "date"
require "time"
require "nokogiri"

module DiscussionBridge
  module BridgeRecordRequest
    MAX_JSON_BYTES = 65_536
    MAX_CONTENT_HTML_BYTES = 49_152
    MAX_SAFE_INTEGER = 9_007_199_254_740_991
    MAX_TOPIC_ID = 9_223_372_036_854_775_807
    REQUIRED_KEYS = %w[
      direction external_id canonical_url title content_html published presentation_mode
      source_revision source_revision_sequence source_created_at source_updated_at
      content_disposition source_content_bytes source_content_sha256 correlation_id
    ].freeze
    ALLOWED_KEYS = (REQUIRED_KEYS + %w[
      lane adapter_id adapter_version visibility source_authors primary_source_author_id
      existing_topic_id read_more_url
    ]).freeze
    TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\z/

    def self.call(parameters)
      raw = parameters.is_a?(ActionController::Parameters) ? parameters.to_unsafe_h : parameters
      fail_with("validation_failed") unless raw.is_a?(Hash)
      raw = raw.stringify_keys
      fail_with("unknown_field") unless (raw.keys - ALLOWED_KEYS).empty?
      fail_with("validation_failed") unless (REQUIRED_KEYS - raw.keys).empty?
      fail_with("request_too_large") if JSON.generate(bridge_record: raw).bytesize > MAX_JSON_BYTES
      fail_with("direction_denied") unless raw["direction"] == "to_discourse"
      fail_with("validation_failed") unless raw["published"] == true
      fail_with("validation_failed") unless %w[simple full interactive].include?(raw["presentation_mode"])
      { "external_id" => 255, "canonical_url" => 2048, "title" => 1024,
        "source_revision" => 255, "correlation_id" => 200 }.each do |key, maximum|
        string!(raw[key], maximum)
      end
      unless raw["title"].length.between?(SiteSetting.min_topic_title_length, SiteSetting.max_topic_title_length)
        fail_with("validation_failed")
      end
      canonical!(raw["canonical_url"])
      html = raw["content_html"]
      unless html.is_a?(String) && html.valid_encoding? && !html.strip.empty? &&
          html.bytesize <= MAX_CONTENT_HTML_BYTES && !/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.match?(html)
        fail_with("validation_failed")
      end
      integer!(raw["source_revision_sequence"], 1, MAX_SAFE_INTEGER)
      integer!(raw["source_content_bytes"], 0, MAX_SAFE_INTEGER)
      fail_with("validation_failed") unless raw["source_content_sha256"].is_a?(String) &&
        /\A[a-f0-9]{64}\z/.match?(raw["source_content_sha256"])
      created = timestamp!(raw["source_created_at"])
      updated = timestamp!(raw["source_updated_at"])
      fail_with("validation_failed") if updated < created
      case raw["content_disposition"]
      when "complete"
        fail_with("validation_failed") if raw.key?("read_more_url")
        unless raw["source_content_bytes"] == html.bytesize &&
            raw["source_content_sha256"] == Digest::SHA256.hexdigest(html)
          fail_with("integrity_failed")
        end
      when "excerpt"
        fail_with("validation_failed") unless raw["source_content_bytes"] > html.bytesize
        excerpt!(html, raw["canonical_url"], raw["read_more_url"])
      else
        fail_with("validation_failed")
      end
      { "lane" => 64, "adapter_id" => 100, "adapter_version" => 100,
        "primary_source_author_id" => 255 }.each do |key, maximum|
        string!(raw[key], maximum) if raw.key?(key)
      end
      fail_with("validation_failed") if raw.key?("lane") && !LanePolicies::LANE_PATTERN.match?(raw["lane"])
      fail_with("validation_failed") if raw.key?("visibility") && raw["visibility"] != "unlisted"
      integer!(raw["existing_topic_id"], 1, MAX_TOPIC_ID) if raw.key?("existing_topic_id")
      authors!(raw)
      raw.symbolize_keys
    end

    def self.timestamp!(value)
      fail_with("malformed_value") unless value.is_a?(String) && TIMESTAMP_PATTERN.match?(value)
      fail_with("malformed_value") if value[11, 2].to_i > 23 || value[14, 2].to_i > 59 || value[17, 2].to_i > 59
      fail_with("malformed_value") unless Date.valid_date?(value[0, 4].to_i, value[5, 2].to_i, value[8, 2].to_i)
      # DateTime retains arbitrary fractional precision; storage retains the wire string.
      DateTime.iso8601(value)
    rescue Date::Error
      fail_with("malformed_value")
    end

    def self.string!(value, maximum)
      unless value.is_a?(String) && value.valid_encoding? && !value.strip.empty? &&
          value.bytesize <= maximum && !AdapterRequestBoundary::CONTROL_PATTERN.match?(value)
        fail_with("validation_failed")
      end
    end

    def self.integer!(value, minimum, maximum)
      fail_with("validation_failed") unless value.is_a?(Integer) && value.between?(minimum, maximum)
    end

    def self.canonical!(url)
      normalized = CanonicalSource.call(connection_id: "source-validation", source_url: url).source_url
      fail_with("validation_failed") unless normalized == url
    end

    def self.authors!(raw)
      unless raw.key?("source_authors")
        fail_with("validation_failed") if raw.key?("primary_source_author_id")
        return
      end
      authors = raw["source_authors"]
      fail_with("validation_failed") unless authors.is_a?(Array) && authors.length <= 20
      ids = []
      normalized = authors.map do |author|
        fields = %w[source_author_id source_author_name source_author_url]
        fail_with("unknown_field") unless author.is_a?(Hash) && author.keys.sort == fields.sort
        string!(author["source_author_id"], 255)
        string!(author["source_author_name"], 200)
        string!(author["source_author_url"], 2048)
        canonical!(author["source_author_url"])
        ids << author["source_author_id"]
        # Native authorship keeps its retained internal representation. The wire
        # accepts only current contract names, never the old internal keys.
        { "id" => author["source_author_id"], "name" => author["source_author_name"],
          "profile_url" => author["source_author_url"] }
      end
      fail_with("validation_failed") unless ids.uniq.length == ids.length
      if raw.key?("primary_source_author_id") && !ids.include?(raw["primary_source_author_id"])
        fail_with("validation_failed")
      end
      raw["source_authors"] = normalized
    end

    def self.excerpt!(html, canonical_url, read_more_url)
      fail_with("validation_failed") unless read_more_url == canonical_url
      fragment = Nokogiri::HTML5.fragment(html, max_errors: 1, max_tree_depth: 65)
      fail_with("validation_failed") unless fragment.errors.empty?
      elements = fragment.css("*")
      fail_with("validation_failed") if elements.size > 1024
      elements.each do |element|
        depth = element.ancestors.count(&:element?) + 1
        stylesheet = element.name == "link" && element["rel"].to_s.split.any? { |rel| rel.downcase == "stylesheet" }
        fail_with("validation_failed") if depth > 64 || %w[style script base].include?(element.name) || stylesheet
      end
      notice, paragraph = fragment.element_children.to_a.last(2)
      fail_with("validation_failed") unless text_paragraph?(notice) && /excerpt/i.match?(notice.text)
      unless paragraph&.name == "p" && paragraph.attribute_nodes.empty? && html_element?(paragraph)
        fail_with("validation_failed")
      end
      children = paragraph.children.reject { |node| node.text? && node.text.strip.empty? }
      link = children.first
      unless children.one? && link.element? && link.name == "a" && html_element?(link) &&
          link.attribute_nodes.map(&:name) == ["href"] && link["href"] == canonical_url &&
          link.children.any? && link.children.all?(&:text?) && normalize_text(link.text) == "Read More"
        fail_with("validation_failed")
      end
    rescue ArgumentError
      fail_with("validation_failed")
    end

    def self.html_element?(node)
      node.namespace&.href.nil? || node.namespace.href == "http://www.w3.org/1999/xhtml"
    end

    def self.text_paragraph?(node)
      node&.name == "p" && html_element?(node) && node.attribute_nodes.empty? &&
        node.children.any? && node.children.all?(&:text?)
    end

    def self.normalize_text(value)
      value.gsub(/[[:space:]]+/, " ").strip
    end

    def self.fail_with(code)
      raise AdapterRequestBoundary::Error.new(code)
    end
    private_class_method :string!, :integer!, :canonical!, :authors!, :excerpt!,
                         :html_element?, :text_paragraph?, :normalize_text, :fail_with
  end
end
