# frozen_string_literal: true

require "cgi"
require "securerandom"
require "uri"

module DiscussionBridge
  module PortableContent
    class PreparationUnavailable < StandardError
      attr_reader :diagnostic_code

      def initialize(message, diagnostic_code: "native_article_preparation_unavailable")
        @diagnostic_code = diagnostic_code
        super(message)
      end
    end

    # URL-valued navigation/media attributes, not an execution/safety allowlist.
    # Native sanitization/provider support remains a separate unresolved boundary.
    REFERENCE_ATTRIBUTES = {
      "a" => %w[href], "area" => %w[href], "img" => %w[src],
      "audio" => %w[src], "video" => %w[src poster], "source" => %w[src],
      "track" => %w[src], "iframe" => %w[src], "embed" => %w[src], "object" => %w[data],
    }.freeze
    SCHEME = /\A[A-Za-z][A-Za-z0-9+.-]*:/.freeze
    MERMAID_CLASSES = %w[language-mermaid lang-mermaid].freeze
    PURE_MATH = /\A(?:\$\$[^$]+\$\$|\$[^$]+\$)\z/m
    TOC_HEADING_SELECTOR = "h2, h3, h4, h5, h6"
    MINIMUM_TOC_HEADINGS = 2

    def self.toc_eligible?(content_html)
      article_fragment(content_html).css(TOC_HEADING_SELECTOR).length >= MINIMUM_TOC_HEADINGS
    end

    def self.to_discourse_raw(content_html, source_url: nil)
      fragment = article_fragment(content_html)
      resolve_references!(fragment, source_url)
      replacements = {}

      fragment.css("pre > code").each do |code|
        classes = code["class"].to_s.split
        if (classes & MERMAID_CLASSES).empty?
          native_classes = native_code_language_classes(classes)
          code["class"] = native_classes.join(" ") unless native_classes == classes
          next
        end
        source = CGI.unescapeHTML(code.text)
        next if source.include?("```")

        placeholder = "DISCUSSIONBRIDGE_MERMAID_#{SecureRandom.hex(16)}"
        replacements[placeholder] = "\n```mermaid\n#{source.rstrip}\n```\n"
        code.parent.replace(Nokogiri::XML::Text.new(placeholder, fragment.document))
      end

      fragment.css("p").each do |paragraph|
        # Converting aggregate text would erase link destinations, media,
        # captions and other meaning-bearing markup. Only a plain paragraph
        # containing one complete supported math expression is convertible.
        next unless paragraph.parent == fragment && paragraph.attribute_nodes.empty? && paragraph.children.all?(&:text?)
        text = paragraph.text.strip
        next unless PURE_MATH.match?(text)
        next unless text.delete("$").strip.length.positive?

        placeholder = "DISCUSSIONBRIDGE_MATH_#{SecureRandom.hex(16)}"
        replacements[placeholder] = "\n#{text}\n"
        paragraph.replace(Nokogiri::XML::Text.new(placeholder, fragment.document))
      end

      # Blank lines keep each top-level HTML block independent. Without them,
      # Markdown fences and math source inserted between HTML siblings remain
      # inside one CommonMark HTML block and are displayed literally.
      output = fragment.children.map(&:to_html).join("\n\n").strip
      replacements.each { |placeholder, source| output.sub!(placeholder, source) }
      output
    end

    def self.native_code_language_classes(classes)
      # Core accepts lang-* on native code HTML. Preserve code children/newlines;
      # do not infer a language or choose between conflicting/native markers.
      return classes if classes.any? { |name| name.start_with?("lang-") }

      markers = classes.select { |name| name.start_with?("language-") && name.length > 9 }.uniq
      return classes unless markers.length == 1

      marker = markers.first
      classes.map { |name| name == marker ? "lang-#{marker.delete_prefix("language-")}" : name }
    end
    private_class_method :native_code_language_classes

    def self.article_fragment(content_html)
      Nokogiri::HTML5.fragment(content_html)
    rescue ArgumentError, Nokogiri::XML::SyntaxError
      # Typed source/evidence is already validated. A parser preparation failure
      # here is a Bridge limitation, not an invented invalid-content predicate.
      raise PreparationUnavailable.new("Native article parser preparation unavailable", diagnostic_code: "native_article_parser_unavailable")
    end

    def self.resolve_reference(value, source_url)
      # Keep existing absolute reference spelling and source meaning. Recognizing
      # a scheme is not permission to execute/embed it or a provider grant.
      return value if SCHEME.match?(value)
      raise PreparationUnavailable.new("Relative reference has no captured source article URL", diagnostic_code: "captured_article_url_unavailable") unless source_url

      base = URI.parse(source_url)
      unless base.absolute? && base.host
        raise PreparationUnavailable.new("Captured source article URL is not a supported hierarchical base", diagnostic_code: "captured_article_base_unsupported")
      end
      base.merge(URI.parse(value)).to_s
    rescue URI::Error, Encoding::CompatibilityError
      raise PreparationUnavailable.new("Relative reference syntax cannot be preserved by the current URI converter", diagnostic_code: "reference_syntax_unsupported")
    end

    def self.resolve_references!(fragment, source_url)
      fragment.traverse do |node|
        next unless node.element?
        if node.name == "base"
          raise PreparationUnavailable.new("Document base overrides are not a supported captured article context", diagnostic_code: "document_base_override_unsupported")
        end
        node.attribute_nodes.each do |attribute|
          if REFERENCE_ATTRIBUTES.fetch(node.name, []).include?(attribute.name)
            attribute.value = resolve_reference(attribute.value, source_url)
          elsif %w[href src poster].include?(attribute.name) && !SCHEME.match?(attribute.value)
            raise PreparationUnavailable.new("Relative element references are not supported by the current converter", diagnostic_code: "element_reference_unsupported")
          elsif attribute.name == "srcset"
            attribute.value = resolve_srcset(attribute.value, source_url)
          end
        end
        check_css_references!(node["style"]) if node["style"]
        check_css_references!(node.text) if node.name == "style"
      end
      fragment
    end
    private_class_method :resolve_references!

    # Preserve candidate descriptors and separators; only URL tokens are copied
    # to their original source targets. Commas inside data/URL tokens stay intact.
    def self.resolve_srcset(value, source_url)
      output = value.dup
      replacements = []
      position = 0
      while position < value.length
        position += 1 while position < value.length && value[position].match?(/[\t\n\f\r ,]/)
        break if position == value.length
        start = position
        position += 1 while position < value.length && !value[position].match?(/[\t\n\f\r ]/)
        ending = position
        ending -= 1 while ending > start && value[ending - 1] == ","
        url = value[start...ending]
        raise PreparationUnavailable.new("Empty srcset candidate cannot be preserved", diagnostic_code: "srcset_candidate_unavailable") if url.empty?
        replacements << [start, ending, resolve_reference(url, source_url)]
        next if ending < position
        depth = 0
        while position < value.length
          character = value[position]
          depth += 1 if character == "("
          depth -= 1 if character == ")" && depth.positive?
          position += 1
          break if character == "," && depth.zero?
        end
        raise PreparationUnavailable.new("Unclosed srcset descriptor cannot be preserved", diagnostic_code: "srcset_descriptor_unsupported") unless depth.zero?
      end
      replacements.reverse_each { |start, ending, replacement| output[start...ending] = replacement }
      output
    end

    def self.check_css_references!(value)
      # CSS escape/function rules are not selected here. Do not claim relative
      # CSS targets were preserved by silently leaving them destination-relative.
      if value.include?("\\") || value.match?(/@import\b/i)
        raise PreparationUnavailable.new("CSS escape/import reference preparation is not supported", diagnostic_code: "css_escape_import_unsupported")
      end
      return unless value.match?(/url\s*\(/i)
      matches = value.scan(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)]*))\s*\)/i)
      if matches.length != value.scan(/url\s*\(/i).length ||
          matches.any? { |parts| !SCHEME.match?(parts.compact.first.to_s.strip) }
        raise PreparationUnavailable.new("Relative or unparsed CSS URL preparation is not supported", diagnostic_code: "css_reference_unsupported")
      end
    end
    private_class_method :check_css_references!
  end
end
