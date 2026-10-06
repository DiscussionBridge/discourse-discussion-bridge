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
        raw: companion_post(
          source_url,
          request.fetch(:content_html),
          request[:source_authors],
          request.fetch(:generate_topic_toc, false),
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

    def update(record:, request:, policy:)
      topic = record.topic
      post = topic.first_post
      actor = User.find(policy.operating_actor_id)
      unless actor.guardian.can_edit?(topic) && actor.guardian.can_edit?(post)
        raise AdapterRequestBoundary::Error.new("policy_denied")
      end
      raw = companion_post(request.fetch(:source_url), request.fetch(:content_html),
                           request[:source_authors], request.fetch(:generate_topic_toc, false))
      # A changed source revision with identical native content does not need a
      # synthetic native edit. Never treat a failed revision as a successful one.
      return if topic.title == request.fetch(:title) && post.raw == raw
      revised = PostRevisor.new(post, topic).revise!(
        actor,
        { title: request.fetch(:title), raw: raw, edit_reason: "DiscussionBridge source revision update" },
        force_new_version: true,
      )
      raise AdapterRequestBoundary::Error.new("content_unsupported") unless revised
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Discourse::InvalidParameters
      raise AdapterRequestBoundary::Error.new("content_unsupported")
    end

    private

    def companion_post(source_url, content_html, source_authors, generate_topic_toc)
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
