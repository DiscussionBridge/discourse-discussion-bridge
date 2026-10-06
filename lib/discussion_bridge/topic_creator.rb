# frozen_string_literal: true

module DiscussionBridge
  class TopicCreator
    Creation = Data.define(:topic, :post_creator)

    def call(request:, policy:)
      actor = User.find(policy.operating_actor_id)
      author = User.find(policy.effective_actor_id)
      source_url = CanonicalSource.call(
        connection_id: request.fetch(:connection_id),
        source_url: request.fetch(:source_url),
      ).source_url
      creator = PostCreator.new(
        actor,
        title: request.fetch(:title),
        raw: self.class.companion_post(
          source_url: source_url,
          content_html: request.fetch(:content_html),
          source_authors: request[:source_authors],
          generate_topic_toc: request.fetch(:generate_topic_toc, false),
        ),
        category: policy.effective_category_id,
        tags: policy.effective_tags,
        visible: false,
        guardian: actor.guardian,
        skip_jobs: true,
      )
      post = creator.create!
      if post.user_id != author.id
        PostOwnerChanger.new(
          post_ids: [post.id],
          topic_id: post.topic_id,
          new_owner: author,
          acting_user: actor,
          skip_revision: true,
        ).change_owner!
      end
      Creation.new(topic: post.topic.reload, post_creator: creator)
    end

    def after_commit(creation)
      creation.post_creator.enqueue_jobs
    end

    def update(request:, policy:, record:)
      actor = User.find(policy.operating_actor_id)
      first_post = record.topic&.first_post
      raise ArgumentError, "bridge record topic is unavailable" unless first_post

      source_url = CanonicalSource.call(
        connection_id: request.fetch(:connection_id),
        source_url: request.fetch(:source_url),
      ).source_url
      revised = PostRevisor.new(first_post).revise!(
        actor,
        {
          title: request.fetch(:title),
          raw: self.class.companion_post(
            source_url: source_url,
            content_html: request.fetch(:content_html),
            source_authors: request[:source_authors],
            generate_topic_toc: request.fetch(:generate_topic_toc, false),
          ),
          edit_reason: "DiscussionBridge source revision #{request.fetch(:source_revision)}",
        },
        bypass_rate_limiter: true,
      )
      raise ActiveRecord::RecordInvalid, first_post unless revised || first_post.errors.empty?

      first_post.reload
    end

    def self.companion_post(source_url:, content_html:, source_authors:, generate_topic_toc:)
      credit = SourceAuthorship.credit_html(source_authors)
      parts = [PortableContent.to_discourse_raw(content_html)]
      parts.unshift('<div data-theme-toc="true"></div>') if generate_topic_toc &&
        PortableContent.toc_eligible?(content_html)
      parts << credit if credit.present?
      parts << "---\n\nOriginally published at [#{source_url}](#{source_url})"
      parts.join("\n\n")
    end
  end
end
