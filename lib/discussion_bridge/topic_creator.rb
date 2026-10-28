# frozen_string_literal: true

module DiscussionBridge
  class TopicCreator
    Creation = Data.define(:topic, :post_creator)

    def call(request:, policy:)
      actor = User.find(policy.operating_actor_id)
      author = User.find(policy.effective_actor_id)
      if actor.id != author.id && !actor.guardian.can_change_post_owner?
        raise Discourse::InvalidAccess
      end
      source_url =
        CanonicalSource.call(
          connection_id: request.fetch(:connection_id),
          source_url: request.fetch(:source_url),
        ).source_url
      creator =
        PostCreator.new(
          actor,
          title: request.fetch(:title),
          raw:
            companion_post(
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
      verify_preservation!(post, request, source_url)
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

    def source_raw(request)
      source_url =
        CanonicalSource.call(
          connection_id: request.fetch(:connection_id),
          source_url: request.fetch(:source_url),
        ).source_url
      TextCleaner.normalize_whitespaces(
        companion_post(
          source_url,
          request.fetch(:content_html),
          request[:source_authors],
          request.fetch(:generate_topic_toc, false),
        ),
      ).rstrip
    end

    def matches_source?(topic:, first_post:, request:, policy:)
      matches = topic.title == request.fetch(:title) && first_post.raw == source_raw(request) &&
        first_post.user_id == policy.effective_actor_id
      verify_preservation!(first_post, request, request.fetch(:source_url)) if matches
      matches
    end

    def update_denial(first_post:, policy:)
      actor = User.find(policy.operating_actor_id)
      return "native_edit_denied" unless actor.guardian.can_edit?(first_post)
      if first_post.user_id != policy.effective_actor_id && !actor.guardian.can_change_post_owner?
        return "native_author_change_denied"
      end
      nil
    end

    def update(topic:, first_post:, request:, policy:)
      actor = User.find(policy.operating_actor_id)
      fields = {}
      raw = source_raw(request)
      fields[:raw] = raw if raw != first_post.raw
      fields[:title] = request.fetch(:title) if request.fetch(:title) != topic.title
      if fields.present? && !first_post.revise(actor, fields, force_new_version: true)
        raise ArgumentError, "native source revision failed"
      end
      if first_post.user_id != policy.effective_actor_id
        PostOwnerChanger.new(
          post_ids: [first_post.id],
          topic_id: topic.id,
          new_owner: User.find(policy.effective_actor_id),
          acting_user: actor,
        ).change_owner!
      end
      first_post.reload
      topic.reload
      verify_preservation!(first_post, request, request.fetch(:source_url))
      topic
    end

    private

    def verify_preservation!(post, request, source_url)
      NativeContentPreservation.verify!(source_html: request.fetch(:content_html),
        cooked_html: post.cooked, source_url: source_url, native_url: post.topic.url,
        owned_generated_link: request.fetch(:owned_generated_link, false))
    end

    def companion_post(source_url, content_html, source_authors, generate_topic_toc)
      credit = SourceAuthorship.credit_html(source_authors)
      parts = [PortableContent.to_discourse_raw(content_html, source_url: source_url)]
      if generate_topic_toc && PortableContent.toc_eligible?(content_html)
        parts.unshift('<div data-theme-toc="true"></div>')
      end
      parts << credit if credit.present?
      parts << "---\n\nOriginally published at [#{source_url}](#{source_url})"
      parts.join("\n\n")
    end
  end
end
