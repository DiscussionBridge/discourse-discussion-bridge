# frozen_string_literal: true

module DiscussionBridge
  class TopicCreator
    Creation = Data.define(:topic, :post_creator)

    def call(request:, policy:)
      actor = User.find(policy.effective_actor_id)
      source_url = CanonicalSource.call(
        connection_id: request.fetch(:connection_id),
        source_url: request.fetch(:source_url),
      ).source_url
      creator = PostCreator.new(
        actor,
        title: request.fetch(:title),
        raw: companion_post(source_url),
        category: policy.effective_category_id,
        tags: policy.effective_tags,
        visible: false,
        guardian: actor.guardian,
        skip_jobs: true,
      )
      post = creator.create!
      Creation.new(topic: post.topic, post_creator: creator)
    end

    def after_commit(creation)
      creation.post_creator.enqueue_jobs
    end

    private

    def companion_post(source_url)
      "This is a companion discussion topic for the original entry at [#{source_url}](#{source_url})"
    end
  end
end
