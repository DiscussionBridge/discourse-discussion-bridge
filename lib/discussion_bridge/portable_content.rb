# frozen_string_literal: true

require "cgi"
require "securerandom"

module DiscussionBridge
  module PortableContent
    MERMAID_CLASSES = %w[language-mermaid lang-mermaid].freeze
    MATH_DELIMITER = /(?:\A|[^$])\${1,2}[^$]+\${1,2}(?:\z|[^$])/m

    def self.to_discourse_raw(content_html)
      fragment = Nokogiri::HTML5.fragment(content_html)
      replacements = {}

      fragment.css("pre > code").each do |code|
        next if (code["class"].to_s.split & MERMAID_CLASSES).empty?
        source = CGI.unescapeHTML(code.text)
        next if source.include?("```")

        placeholder = "DISCUSSIONBRIDGE_MERMAID_#{SecureRandom.hex(16)}"
        replacements[placeholder] = "\n```mermaid\n#{source.rstrip}\n```\n"
        code.parent.replace(Nokogiri::XML::Text.new(placeholder, fragment.document))
      end

      fragment.css("p").each do |paragraph|
        text = paragraph.text
        next unless MATH_DELIMITER.match?(text)

        placeholder = "DISCUSSIONBRIDGE_MATH_#{SecureRandom.hex(16)}"
        replacements[placeholder] = "\n#{text.strip}\n"
        paragraph.replace(Nokogiri::XML::Text.new(placeholder, fragment.document))
      end

      # Blank lines keep each top-level HTML block independent. Without them,
      # Markdown fences and math source inserted between HTML siblings remain
      # inside one CommonMark HTML block and are displayed literally.
      output = fragment.children.map(&:to_html).join("\n\n").strip
      replacements.each { |placeholder, source| output.sub!(placeholder, source) }
      output
    end
  end
end
