# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  class TopicPublicationState
    Result = Data.define(
      :source_revision,
      :publication_revision,
      :policy_revision,
      :destination,
      :eligibility,
    )

    def self.for_topic(connection:, topic:)
      eligibility = PublicationTopicScope.eligibility(connection, topic)
      post = topic.first_post
      source_revision = post && PublicationTopicScope.revision(topic, post: post)
      destination = eligibility[:eligible] ? DestinationMapping.resolve(connection: connection, topic: topic) : {
        state: "attention",
        reasons: [eligibility.fetch(:reason)],
        catalog_revision: connection.platform_catalog_revision,
        mapping_revision: connection.destination_mapping_revision,
      }
      destination = apply_source_limits(destination, topic) if eligibility[:eligible]
      policy_revision = self.policy_revision(connection)
      source = adapter_source(topic)
      canonical = {
        "topic_id" => topic.id,
        "source_revision" => source_revision,
        "source" => source,
        "category_id" => topic.category_id,
        "tag_ids" => topic.tags.map(&:id).sort,
        "eligibility" => eligibility,
        "policy_revision" => policy_revision,
        "destination" => stringify(destination),
      }
      Result.new(
        source_revision: source_revision,
        publication_revision: Digest::SHA256.hexdigest(JSON.generate(deep_sort(canonical))),
        policy_revision: policy_revision,
        destination: stringify(destination),
        eligibility: eligibility,
      )
    end

    def self.adapter_source(topic)
      post = topic.first_post
      username = post&.user&.username.to_s
      relative_url = topic.url.to_s
      topic_url = relative_url.start_with?("/") ? "#{Discourse.base_url}#{relative_url}" : relative_url
      {
        "title" => topic.title.to_s,
        "topic_url" => topic_url,
        "cooked_sha256" => Digest::SHA256.hexdigest(post&.cooked.to_s),
        "author" => {
          "username" => username,
          "name" => post&.user&.name.presence || username,
          "profile_url" => username.present? ? "#{Discourse.base_url}/u/#{username}" : nil,
        },
      }
    end

    def self.policy_revision(connection)
      value = {
        "forum_publication_enabled" => connection.forum_publication_enabled,
        "publication_category_mode" => connection.publication_category_mode,
        "publication_category_ids" => Array(connection.publication_category_ids).sort,
        "publication_excluded_category_ids" => Array(connection.publication_excluded_category_ids).sort,
        "publication_tag_mode" => connection.publication_tag_mode,
        "publication_tag_ids" => Array(connection.publication_tag_ids).sort,
        "publication_excluded_tag_ids" => Array(connection.publication_excluded_tag_ids).sort,
        "publication_include_unlisted" => connection.publication_include_unlisted,
        "mapping_revision" => connection.destination_mapping_revision,
        "catalog_adapter_id" => connection.platform_catalog_adapter_id,
        "catalog_adapter_version" => connection.platform_catalog_adapter_version,
      }
      Digest::SHA256.hexdigest(JSON.generate(value))
    end

    def self.for_revocation(connection:, record:)
      topic = record.topic
      return for_topic(connection: connection, topic: topic) if topic

      policy_revision = self.policy_revision(connection)
      canonical = {
        "resource_id" => record.resource_id,
        "topic_id" => record.topic_id,
        "eligibility" => { eligible: false, reason: "topic_missing" },
        "policy_revision" => policy_revision,
      }
      Result.new(
        source_revision: nil,
        publication_revision: Digest::SHA256.hexdigest(JSON.generate(canonical)),
        policy_revision: policy_revision,
        destination: {
          "state" => "attention",
          "reasons" => ["topic_missing"],
          "catalog_revision" => connection.platform_catalog_revision,
          "mapping_revision" => connection.destination_mapping_revision,
        },
        eligibility: { eligible: false, reason: "topic_missing" },
      )
    end

    def self.destination_matches?(expected, actual)
      stringify(expected) == stringify(actual)
    end

    def self.apply_source_limits(destination, topic)
      value = stringify(destination)
      return value unless value["state"] == "ready"

      limits = value["limits"].is_a?(Hash) ? value["limits"] : {}
      reasons = Array(value["reasons"])
      title_limit = limits["title_bytes"].to_i
      content_limit = limits["content_bytes"].to_i
      reasons << "source_title_too_large" if title_limit.positive? && topic.title.to_s.bytesize > title_limit
      cooked = topic.first_post&.cooked.to_s
      reasons << "source_content_too_large" if content_limit.positive? && cooked.bytesize > content_limit
      reasons << "source_content_empty" unless source_content_present?(cooked)
      value["state"] = "attention" if reasons.any?
      value["reasons"] = reasons.uniq
      value
    end

    def self.source_content_present?(cooked)
      fragment = Nokogiri::HTML5.fragment(cooked)
      fragment.text.to_s.strip.present? || fragment.css("img").any?
    rescue Nokogiri::SyntaxError
      false
    end

    def self.stringify(value)
      value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
      case value
      when Hash then value.to_h { |key, item| [key.to_s, stringify(item)] }
      when Array then value.map { |item| stringify(item) }
      else value
      end
    end

    def self.deep_sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, deep_sort(value[key])] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    private_class_method :apply_source_limits, :source_content_present?, :stringify, :deep_sort
  end
end
