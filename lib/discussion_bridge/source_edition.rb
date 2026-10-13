# frozen_string_literal: true

require "digest"
require "json"

module DiscussionBridge
  class SourceEdition
    class Unavailable < StandardError
    end
    class InvalidForumName < StandardError
    end
    Edition = Data.define(:title, :content_html, :topic_url, :source)
    BATCH_SIZE = 100
    SOURCE_COLUMNS = %w[
      topics.id
      topics.title
      topics.slug
      topics.created_at
      posts.id
      posts.post_number
      posts.version
      posts.created_at
      posts.updated_at
      posts.raw
      posts.cooked
      users.username
      users.username_lower
      users.name
    ].freeze

    def self.for_topic(topic_id)
      edition = nil
      each_edition([topic_id]) { |_id, value| edition = value }
      edition
    end

    def self.editions(topic_ids)
      values = {}
      each_edition(topic_ids) { |id, value| values[id] = value.source.fetch(:edition) }
      values
    end

    def self.forum_name
      value =
        ENV["DISCUSSIONBRIDGE_FORUM_NAME"].presence ||
          SiteSetting.discussion_bridge_forum_name.presence || SiteSetting.title
      value = value.strip
      unless value.valid_encoding? && value.present? && value.bytesize <= 200 &&
               !value.match?(/[\x00-\x1f\x7f]/)
        raise InvalidForumName
      end
      value
    end

    def self.publicly_available?(topic)
      anonymous = Guardian.new(nil)
      !SiteSetting.login_required && topic && !topic.private_message? && topic.deleted_at.nil? &&
        anonymous.can_see?(topic) && !SharedDraft.exists?(topic_id: topic.id) &&
        !DiscussionBridgeBridgeRecord.exists?(direction: "to_discourse", topic_id: topic.id) &&
        topic.first_post && topic.first_post.deleted_at.nil? &&
        anonymous.can_see?(topic.first_post) &&
        !TopicEmbed.with_deleted.exists?(post_id: topic.first_post.id)
    end

    def self.withdrawn_edition(record)
      withdrawal_editions([[record.resource_id, record.topic_id, record.updated_at]]).fetch(
        record.resource_id,
      )
    end

    def self.withdrawal_editions(records)
      timestamps = {}
      records
        .map { |row| row[1] }
        .compact
        .uniq
        .each_slice(BATCH_SIZE) do |batch|
          Topic
            .unscoped
            .left_joins(:category)
            .where(id: batch)
            .pluck("topics.id", "topics.updated_at", "topics.deleted_at", "categories.updated_at")
            .each { |row| timestamps[row.first] = row.drop(1).compact.max }
          Post
            .unscoped
            .where(topic_id: batch, post_number: 1)
            .pluck(:topic_id, :updated_at, :deleted_at)
            .each do |id, updated_at, deleted_at|
              timestamps[id] = [timestamps[id], updated_at, deleted_at].compact.max
            end
        end
      records.to_h do |resource_id, topic_id, fallback|
        [
          resource_id,
          Digest::SHA256.hexdigest(
            JSON.generate(
              ["withdrawn", resource_id, topic_id, timestamp(timestamps[topic_id] || fallback)],
            ),
          ),
        ]
      end
    end

    def self.each_edition(topic_ids)
      return if SiteSetting.login_required

      name = forum_name
      origin = Discourse.base_url
      topic_ids
        .compact
        .uniq
        .each_slice(BATCH_SIZE) do |batch|
          # One SQL statement reads the native title, body, dates and author from
          # one database snapshot. Do not mix an earlier eager-loaded topic with a
          # first post or author retrieved after an edit.
          rows =
            Post
              .unscoped
              .joins(topic: :category)
              .left_joins(:user)
              .where(topic_id: batch, post_number: 1, deleted_at: nil)
              .where.not(cooked: [nil, ""])
              .where(topics: { deleted_at: nil }, categories: { read_restricted: false })
              .where.not(topics: { archetype: Archetype.private_message })
              .where.not(
                topic_id:
                  DiscussionBridgeBridgeRecord
                    .where(direction: "to_discourse")
                    .where.not(topic_id: nil)
                    .select(:topic_id),
              )
              .where.not(topic_id: SharedDraft.select(:topic_id))
              .where.not(id: TopicEmbed.with_deleted.select(:post_id))
              .pluck(*SOURCE_COLUMNS)
          # A public topic does not imply that its first post is publicly
          # readable: native moderation can hide that post independently. Use
          # native post permission checks before exporting its snapshot.
          posts =
            Post.where(id: rows.map { |row| row[4] }).includes(topic: :category).index_by(&:id)
          anonymous = Guardian.new(nil)
          rows.each do |row|
            post = posts[row[4]]
            next unless post && anonymous.can_see?(post.topic) && anonymous.can_see?(post)

            topic_id,
            title,
            slug,
            topic_created_at,
            post_id,
            post_number,
            post_version,
            created_at,
            updated_at,
            raw,
            cooked,
            username,
            username_lower,
            author_name =
              row
            topic_url = Topic.url(topic_id, slug)
            source = {
              platform: "discourse",
              origin: origin,
              forum_name: name,
              topic_id: topic_id,
              topic_url: topic_url,
              post_id: post_id,
              post_number: post_number,
              post_version: post_version,
              revision: "post:#{post_id}:version:#{post_version}",
              created_at: timestamp(created_at),
              updated_at: timestamp(updated_at),
              author: {
                username: username,
                name: author_name.presence || username,
                profile_url: username_lower ? "#{origin}/u/#{username_lower}" : nil,
              },
            }
            source[:edition] = Digest::SHA256.hexdigest(
              JSON.generate(
                [
                  source[:platform],
                  origin,
                  name,
                  topic_id,
                  topic_url,
                  title,
                  timestamp(topic_created_at),
                  post_id,
                  post_number,
                  post_version,
                  timestamp(created_at),
                  timestamp(updated_at),
                  raw,
                  cooked,
                  username,
                  username_lower,
                  author_name.presence || username,
                ],
              ),
            )
            yield(
              topic_id,
              Edition.new(title: title, content_html: cooked, topic_url: topic_url, source: source)
            )
          end
        end
    end
    private_class_method :each_edition

    def self.timestamp(value)
      value&.utc&.iso8601(6)
    end
    private_class_method :timestamp
  end
end
