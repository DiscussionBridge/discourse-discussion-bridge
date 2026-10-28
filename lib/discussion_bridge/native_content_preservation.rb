# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  # Compare actual parsed source facilities with the cooked native post. This
  # observes structural/data loss; it neither executes source nor proves browser
  # behavior, provider support or arbitrary component equivalence.
  module NativeContentPreservation
    class Loss < PortableContent::PreparationUnavailable
      attr_reader :losses, :diagnostic_kind

      def initialize(losses, diagnostic_kind: "observed_content_loss")
        @losses = losses.freeze
        @diagnostic_kind = diagnostic_kind
        super("Native preparation removed or changed article facilities/data")
      end
    end

    class ArticleUnavailable < Loss
      def initialize
        super([{ "kind" => "required_native_article_unavailable", "element" => nil,
          "attribute" => nil, "count" => 1 }], diagnostic_kind: "article_unavailable")
      end
    end

    CONTROLS = %w[form input button select textarea option optgroup fieldset legend label details summary].freeze
    CONTROL_ATTRIBUTES = %w[id name type value action method enctype target for form formaction formmethod formenctype formtarget accept-charset min max step pattern placeholder autocomplete rows cols minlength maxlength size].freeze
    CONTROL_FLAGS = %w[checked selected multiple required open novalidate].freeze
    MEDIA = %w[audio video iframe embed object].freeze
    MEDIA_ATTRIBUTES = %w[poster preload crossorigin controlslist allow sandbox type].freeze
    MEDIA_FLAGS = %w[controls autoplay loop muted playsinline allowfullscreen].freeze
    URL_ATTRIBUTES = %w[action formaction src poster data].freeze
    Inventory = Data.define(:counts, :observed)

    def self.verify!(source_html:, cooked_html:, source_url:, native_url:, owned_generated_link: false)
      # This describes required receiver output/evidence, not source eligibility
      # or a definition of truly absent native source. Do not strip prose/type.
      unless cooked_html.is_a?(String) && !cooked_html.empty? &&
          cooked_html.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        raise ArticleUnavailable.new
      end
      expected = facilities(source_html, source_url, owned_generated_link: owned_generated_link)
      return if expected.empty?
      observed = facilities(cooked_html, native_url, observed: true)
      missing = {}
      expected.each do |key, count|
        difference = count - observed.fetch(key, 0)
        next unless difference.positive?
        # Digest values remain private, never diagnostics/program bodies.
        descriptor = key.first(3)
        missing[descriptor] = missing.fetch(descriptor, 0) + difference
      end
      return if missing.empty?
      losses = missing.map do |(kind, element, attribute), count|
        { "kind" => kind, "element" => safe_name(element),
          "attribute" => attribute && safe_name(attribute), "count" => count }
      end
      raise Loss.new(losses)
    end

    def self.facilities(html, base_url, owned_generated_link: false, observed: false)
      counts = Inventory.new(Hash.new(0), observed)
      fragment = PortableContent.article_fragment(html)
      fragment.traverse do |node|
        next unless node.element?
        if node.name == "script"
          add(counts, "script_structure_removed_or_changed", node, nil,
            [node["type"], reference(node["src"], base_url)])
          unless node.text.empty?
            add(counts, "script_nonempty_data_removed_or_changed", node, nil,
              [node["type"], reference(node["src"], base_url), node.text])
          end
        end
        node.attribute_nodes.each do |attribute|
          next if attribute.value.empty?
          if attribute.name.start_with?("on")
            add(counts, "nonempty_on_attribute_removed_or_changed", node, attribute.name, attribute.value)
          elsif attribute.name.start_with?("data-") && !(owned_generated_link && owned_link_marker?(node, attribute))
            add(counts, "nonempty_attribute_data_removed_or_changed", node, attribute.name, attribute.value)
          end
        end
        control(counts, node, base_url) if CONTROLS.include?(node.name)
        media(counts, node, base_url) if MEDIA.include?(node.name)
        if node.name == "track"
          add(counts, "media_track_removed_or_changed", node, nil,
            [reference(node["src"], base_url), node["kind"], node["srclang"], node["label"], node.key?("default")])
        end
      end
      counts.counts
    end
    private_class_method :facilities

    def self.control(counts, node, base_url)
      add(counts, "control_structure_removed", node, nil, true)
      CONTROL_ATTRIBUTES.each do |name|
        next unless node.key?(name) && !node[name].empty?
        value = URL_ATTRIBUTES.include?(name) ? reference(node[name], base_url) : node[name]
        add(counts, "control_attribute_removed_or_changed", node, name, value)
      end
      CONTROL_FLAGS.each do |name|
        add(counts, "control_flag_removed", node, name, true) if node.key?(name)
      end
      # Native disabling/read-only changes actual control capability even when
      # the element and text survive. This is observed state, not source policy.
      %w[disabled readonly].each do |name|
        add(counts, "control_state_changed", node, name, node.key?(name))
      end
      if %w[textarea option summary legend label].include?(node.name) && !node.text.empty?
        add(counts, "control_nonempty_data_removed_or_changed", node, nil, node.text)
      end
    end
    private_class_method :control

    def self.media(counts, node, base_url)
      add(counts, "media_structure_removed", node, nil, true)
      if %w[audio video].include?(node.name)
        # Native direct-src -> child-source normalization can retain the same
        # actual player target. Do not demand an identical wrapper spelling.
        sources = node.css("source[src]").map { |source| [source["src"], source["type"]] }
        sources << [node["src"], nil] if node["src"]
        sources.each do |url, type|
          target = reference(url, base_url)
          add(counts, "media_source_removed_or_changed", node, "src", target)
          add(counts, "media_source_type_removed_or_changed", node, "type", [target, type]) if type && !type.empty?
        end
      else
        attribute = node.name == "object" ? "data" : "src"
        add(counts, "media_source_removed_or_changed", node, attribute, reference(node[attribute], base_url)) if node[attribute]
      end
      MEDIA_ATTRIBUTES.each do |name|
        next unless node[name] && !node[name].empty?
        value = URL_ATTRIBUTES.include?(name) ? reference(node[name], base_url) : node[name]
        add(counts, "media_attribute_removed_or_changed", node, name, value)
      end
      MEDIA_FLAGS.each do |name|
        add(counts, "media_flag_removed", node, name, true) if node.key?(name)
      end
    end
    private_class_method :media

    def self.reference(value, base_url)
      value && PortableContent.resolve_reference(value, base_url)
    end
    private_class_method :reference

    def self.add(inventory, kind, node, attribute, value)
      # Existing explicit DOM bindings cannot be satisfied by the same handler/
      # payload moved to another identified control. Additional native IDs do
      # not themselves remove a source facility: observed subsets cover those.
      anchor = %w[id name for].map { |name| node[name] }
      contexts = if inventory.observed
        (0...8).map { |mask| anchor.each_with_index.map { |part, index| (mask & (1 << index)).zero? ? nil : part } }.uniq
      else
        [anchor]
      end
      contexts.each do |context|
        key = [kind, node.name, attribute, Digest::SHA256.hexdigest(JSON.generate([context, value]))]
        inventory.counts[key] += 1
      end
    end
    private_class_method :add

    def self.owned_link_marker?(node, attribute)
      # Contract-owned generated Read More metadata is intentionally tracked in
      # managed native RAW. It is not an authored article data payload.
      node.name == "p" && attribute.name == "data-discussionbridge-generated" && attribute.value == "read-more"
    end
    private_class_method :owned_link_marker?

    def self.safe_name(value)
      value.to_s.gsub(/[^a-zA-Z0-9_:.-]/, "_")[0, 64]
    end
    private_class_method :safe_name
  end
end
