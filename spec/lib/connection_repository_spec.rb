# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::ConnectionRepository do
  RepositoryPolicy = Data.define(
    :effective_actor_id,
    :effective_visibility,
    :effective_category_id,
    :effective_tags,
    :reason,
  )

  fab!(:actor, :user)
  fab!(:category)
  let(:repository) { described_class.new }
  let(:canonical) do
    DiscussionBridge::CanonicalSource.call(
      connection_id: "astro",
      source_url: "https://example.com/article",
    )
  end
  let(:request) { { visibility: "listed", lane: "articles" } }
  let(:policy) do
    RepositoryPolicy.new(
      effective_actor_id: actor.id,
      effective_visibility: "unlisted",
      effective_category_id: category.id,
      effective_tags: [],
      reason: "forum_policy_applied",
    )
  end

  it "durably reserves the source identity before a topic can be created" do
    reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    record = DiscussionBridgeConnection.find(reservation.record_id)

    expect(reservation.state).to eq("reserved")
    expect(record).to have_attributes(
      state: "reserved",
      topic_id: nil,
      source_identity_digest: canonical.identity_digest,
      effective_visibility: "unlisted",
    )
    expect(record.reservation_token).to eq(reservation.token)
  end

  it "makes a concurrent reservation observable as a conflict without creating a topic" do
    first = repository.reserve!(canonical: canonical, request: request, policy: policy)
    second = repository.reserve!(canonical: canonical, request: request, policy: policy)

    expect(first.state).to eq("reserved")
    expect(second.state).to eq("conflict")
    expect(Topic.where(id: second.topic_id)).to be_empty
    expect(DiscussionBridgeConnection.where(source_identity_digest: canonical.identity_digest).count).to eq(1)
  end

  it "resolves the completed mapping on a later retry" do
    reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    topic = Fabricate(:topic, user: actor, category: category, visible: false)
    Fabricate(:post, topic: topic, user: actor, post_number: 1)
    creation = Struct.new(:topic).new(topic)
    repository.commit!(reservation: reservation) { creation }

    retry_reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    expect(retry_reservation).to have_attributes(state: "complete", topic_id: topic.id)
  end

  it "returns reconciliation_required state without mutation for an unusable completed mapping" do
    reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    topic = Fabricate(:topic, user: actor, category: category, visible: false)
    Fabricate(:post, topic: topic, user: actor, post_number: 1)
    repository.commit!(reservation: reservation) { Struct.new(:topic).new(topic) }
    topic.update!(deleted_at: Time.zone.now)

    retry_reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)

    expect(retry_reservation).to have_attributes(
      state: "conflict",
      topic_id: nil,
      reason: "mapping_topic_deleted",
    )
    expect(DiscussionBridgeConnection.find(reservation.record_id)).to have_attributes(
      state: "complete",
      topic_id: topic.id,
    )
  end

  it "distinguishes a deleted first post from a missing first post" do
    reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    topic = Fabricate(:topic, user: actor, category: category, visible: false)
    first_post = Fabricate(:post, topic: topic, user: actor, post_number: 1)
    repository.commit!(reservation: reservation) { Struct.new(:topic).new(topic) }
    first_post.update_column(:deleted_at, Time.zone.now)

    retry_reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)

    expect(retry_reservation).to have_attributes(
      state: "conflict",
      topic_id: nil,
      reason: "mapping_first_post_deleted",
    )
  end

  it "consumes an operator-authorized retry and invalidates the old reservation token" do
    original = repository.reserve!(canonical: canonical, request: request, policy: policy)
    record = DiscussionBridgeConnection.find(original.record_id)
    record.update!(retry_authorized_at: Time.zone.now, retry_authorized_by_id: actor.id)

    replacement = repository.reserve!(canonical: canonical, request: request, policy: policy)

    expect(replacement).to have_attributes(state: "reserved", record_id: record.id)
    expect(replacement.token).not_to eq(original.token)
    expect(record.reload).to have_attributes(
      state: "reserved",
      reservation_token: replacement.token,
      retry_authorized_at: nil,
      retry_authorized_by_id: nil,
    )
    expect { repository.commit!(reservation: original) { Struct.new(:topic).new(Fabricate(:topic)) } }
      .to raise_error(DiscussionBridgeConnection::IdentityConflict)
  end

  it "rolls mapping completion back when the required audit callback fails" do
    reservation = repository.reserve!(canonical: canonical, request: request, policy: policy)
    topic = Fabricate(:topic)
    creation = Struct.new(:topic).new(topic)

    expect do
      repository.commit!(reservation: reservation, after_mapping: ->(*) { raise "audit unavailable" }) { creation }
    end.to raise_error(RuntimeError, "audit unavailable")

    expect(DiscussionBridgeConnection.find(reservation.record_id)).to have_attributes(
      state: "reserved",
      topic_id: nil,
      reservation_token: reservation.token,
    )
  end
end
