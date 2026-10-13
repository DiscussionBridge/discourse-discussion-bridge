# frozen_string_literal: true

module DiscussionBridge
  # Receiver wakeups only. Event arguments are not source snapshots or scope.
  # Persisted source capture/work belongs to CmsSourceLifecycle's bounded jobs.
  class CmsNativeObserver
    TOPIC_FIELDS = %w[title slug created_at category_id archetype visible deleted_at].freeze
    POST_FIELDS = %w[
      raw
      cooked
      version
      created_at
      updated_at
      user_id
      topic_id
      post_number
      deleted_at
      hidden
      hidden_reason_id
      post_type
      wiki
    ].freeze
    CONNECTION_BATCH_SIZE = 100

    def self.register(plugin)
      observer = self
      %i[post_created post_edited post_destroyed post_recovered post_owner_changed].each do |event|
        plugin.on(event) { |post, *_args| observer.post_event(post) }
      end
      %i[
        topic_created
        topic_destroyed
        topic_trashed
        topic_recovered
        topic_category_changed
      ].each { |event| plugin.on(event) { |topic, *_args| observer.topic_event(topic) } }
      plugin.on(:topic_status_updated) do |topic, status, _enabled, *_args|
        observer.topic_event(topic) if status.to_s == "visible"
      end
      plugin.on(:post_process_cooked) { |_document, post, *_args| observer.post_event(post) }
      %i[
        category_created
        category_updated
        category_destroyed
        user_updated
        user_destroyed
      ].each { |event| plugin.on(event) { |*_args| observer.connection_scans } }
      plugin.add_model_callback("Topic", :after_commit) { observer.topic_committed(self) }
      plugin.add_model_callback("Post", :after_commit) { observer.post_committed(self) }
      plugin.add_model_callback("SharedDraft", :after_commit) do
        observer.membership_committed(self)
      end
      plugin.add_model_callback("TopicEmbed", :after_commit) { observer.membership_committed(self) }
      nil
    end

    def self.topic_event(topic)
      defer_topics([topic.id])
    end

    def self.post_event(post)
      previous = post.saved_changes
      was_first = Array(previous["post_number"]).include?(1)
      return unless post.post_number == 1 || was_first
      defer_topics([post.topic_id, *Array(previous["topic_id"])])
    end

    def self.topic_committed(topic)
      return unless topic.destroyed? || (topic.saved_changes.keys & TOPIC_FIELDS).any?
      topic_event(topic)
    end

    def self.post_committed(post)
      return unless post.destroyed? || (post.saved_changes.keys & POST_FIELDS).any?
      post_event(post)
    end

    def self.membership_committed(record)
      previous = record.saved_changes
      fields = record.is_a?(TopicEmbed) ? %w[id topic_id post_id deleted_at] : %w[id topic_id]
      return unless record.destroyed? || (previous.keys & fields).any?
      ids = [record.topic_id, *Array(previous["topic_id"])]
      if record.is_a?(TopicEmbed)
        # Native eligibility excludes by first post ID. Read only the two
        # current/prior post identities; no post body or association rewrite.
        posts = native_ids([record.post_id, *Array(previous["post_id"])])
        ids.concat(Post.unscoped.where(id: posts).limit(2).pluck(:topic_id)) if posts.any?
      end
      defer_topics(ids)
    end

    def self.connection_scans
      return unless available?
      DB.after_commit do
        next unless available?
        each_connection_id { |id| CmsSourceLifecycle.wake_connection(id) }
      end
      nil
    end

    def self.defer_topics(values)
      ids = native_ids(values)
      return if ids.empty? || !available?
      DB.after_commit do
        next unless available?
        each_connection_id do |connection_id|
          ids.each do |topic_id|
            CmsSourceLifecycle.wake_connection(connection_id, topic_id: topic_id)
          end
        end
      end
      nil
    end

    def self.available?
      !Discourse.readonly_mode? && CmsSourceLifecycle.globally_enabled?
    end

    def self.each_connection_id
      DiscussionBridgeContentConnection
        .where(enabled: true)
        .where.not(cms_configuration: nil)
        .in_batches(of: CONNECTION_BATCH_SIZE) do |batch|
          batch.pluck(:id).each { |id| yield id.to_s }
        end
    end

    def self.native_ids(values)
      values
        .compact
        .filter_map do |value|
          CmsSourceLifecycle.native_id!(value).to_s
        rescue ArgumentError
          nil
        end
        .uniq
    end

    private_class_method :defer_topics, :available?, :each_connection_id, :native_ids
  end
end
