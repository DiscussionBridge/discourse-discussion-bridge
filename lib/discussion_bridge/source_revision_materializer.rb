# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  class SourceRevisionMaterializer
    Result = Data.define(:revision, :reason)

    def self.call(record:, connection:, force_revision: false)
      new(record: record, connection: connection).call(force_revision: force_revision)
    end

    def self.unavailability_reason(record:, connection:)
      new(record: record, connection: connection).unavailability_reason
    end

    def initialize(record:, connection:)
      @record = record
      @connection = connection
    end

    def call(force_revision: false)
      reason = unavailability_reason
      return Result.new(revision: nil, reason: reason) if reason

      revision = nil
      @record.with_lock do
        payload = source_payload
        fingerprint = Digest::SHA256.hexdigest(JSON.generate(fingerprint_payload(payload)))
        revision = @record.source_revisions.where(fingerprint: fingerprint)
          .order(source_revision_sequence: :desc).first unless force_revision
        unless revision
          sequence = next_sequence
          source_revision = "post:#{first_post.id}:version:#{sequence}"
          content_html = payload.fetch(:content_html)
          revision = @record.source_revisions.create!(
            source_revision: source_revision,
            source_revision_sequence: sequence,
            fingerprint: fingerprint,
            topic_url: payload.fetch(:topic_url),
            title: payload.fetch(:title),
            source_created_at: payload.fetch(:source_created_at),
            source_updated_at: payload.fetch(:source_updated_at),
            source_authors: payload.fetch(:source_authors),
            categories: payload.fetch(:categories),
            tags: payload.fetch(:tags),
            presentation_mode: payload.fetch(:presentation_mode),
            content_html: content_html,
            byte_length: content_html.bytesize,
            content_sha256: Digest::SHA256.hexdigest(content_html),
            network_provenance: nil,
          )
        end
        synchronize_record!(revision)
        PublicationWorkRegistry.ensure_revision!(
          record: @record,
          connection: @connection,
          revision: revision,
        )
      end
      Result.new(revision: revision, reason: nil)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def unavailability_reason
      return "policy_removed" unless @connection.enabled && @connection.allows_direction?("from_discourse")
      return "operator_hold" if @record.state == "attention"
      return "operator_hold" if PublicationControl.excluded?(
        connection: @connection,
        topic_id: @record.topic_id,
      )
      return "scope_removed" unless @connection.allows_lane?(@record.lane)

      binding = source_binding
      return "scope_removed" unless binding && @connection.allows_origin?(binding.canonical_url)

      current_topic = topic
      return "source_deleted" unless current_topic && current_topic.deleted_at.nil?

      post = first_post
      return "source_deleted" unless post && post.deleted_at.nil?
      return "source_unpublished" unless current_topic.visible

      nil
    end

    private

    def fingerprint_payload(payload)
      payload.merge(
        source_created_at: payload.fetch(:source_created_at).utc.iso8601(6),
        source_updated_at: payload.fetch(:source_updated_at).utc.iso8601(6),
      )
    end

    def source_payload
      content_html = first_post.cooked.to_s
      raise AdapterRequestBoundary::Error, "content_unsupported" unless content_html.valid_encoding?
      raise AdapterRequestBoundary::Error, "content_unsupported" if
        content_html.bytesize > SourcePublicationProtocol::MAXIMUM_SOURCE_CONTENT_BYTES

      {
        topic_url: absolute_topic_url,
        title: topic.title,
        source_created_at: first_post.created_at,
        source_updated_at: first_post.updated_at,
        source_authors: source_authors,
        categories: source_categories,
        tags: source_tags,
        presentation_mode: presentation_mode,
        content_html: content_html,
      }
    end

    def source_authors
      user = first_post.user
      return [] unless user

      [
        {
          "source_author_id" => "discourse:user:#{user.id}",
          "source_author_name" => user.name.presence || user.username,
          "source_author_url" => "#{Discourse.base_url}/u/#{user.username}",
        },
      ]
    end

    def source_categories
      category = topic.category
      return [] unless category

      [
        {
          "source_category_id" => "discourse:category:#{category.id}",
          "source_category_name" => category.name,
          "source_parent_category_id" => category.parent_category_id ?
            "discourse:category:#{category.parent_category_id}" : nil,
        },
      ]
    end

    def source_tags
      topic.tags.order(:name).limit(101).map do |tag|
        {
          "source_tag_id" => "discourse:tag:#{tag.name}",
          "source_tag_name" => tag.name,
        }
      end.tap do |tags|
        raise AdapterRequestBoundary::Error, "content_unsupported" if tags.length > 100
      end
    end

    def presentation_mode
      stored = source_binding&.presentation_mode.presence || @record.presentation_mode.presence
      return stored if ConnectionCapability::PRESENTATION_MODES.include?(stored)

      modes = Array(@connection.destination_policies).filter_map do |policy|
        policy.stringify_keys["presentation_mode"]
      end.uniq
      return modes.first if modes.one? && ConnectionCapability::PRESENTATION_MODES.include?(modes.first)

      raise AdapterRequestBoundary::Error, "temporarily_unavailable"
    end

    def next_sequence
      values = [@record.source_revision_sequence.to_i]
      values << @record.source_revisions.maximum(:source_revision_sequence).to_i
      values << @record.source_revocations.maximum(:source_revision_sequence).to_i
      [values.max + 1, first_post.version.to_i, 1].max
    end

    def synchronize_record!(revision)
      @record.update!(
        title: revision.title,
        source_revision: revision.source_revision,
        source_revision_sequence: revision.source_revision_sequence,
        source_created_at: revision.source_created_at,
        source_updated_at: revision.source_updated_at,
        presentation_mode: revision.presentation_mode,
        content_disposition: "complete",
        source_content_bytes: revision.byte_length,
        source_content_sha256: revision.content_sha256,
        delivered_content_sha256: revision.content_sha256,
      )
    end

    def source_binding
      @source_binding ||= @record.content_bindings.find do |binding|
        binding.content_connection_id == @connection.id &&
          binding.role == "presentation" && binding.state == "active"
      end
    end

    def topic
      @topic ||= Topic.unscoped.find_by(id: @record.topic_id)
    end

    def first_post
      @first_post ||= Post.unscoped.find_by(topic_id: @record.topic_id, post_number: 1)
    end

    def absolute_topic_url
      relative = topic.url
      relative.start_with?("http://", "https://") ? relative : "#{Discourse.base_url}#{relative}"
    end
  end
end
