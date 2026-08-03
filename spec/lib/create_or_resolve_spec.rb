# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::CreateOrResolve do
  OrchestrationPolicy = Data.define(
    :allowed,
    :reason,
    :effective_actor_id,
    :effective_visibility,
    :effective_category_id,
    :effective_tags,
  )
  OrchestrationReservation = Data.define(:state, :topic_id)
  OrchestrationMapping = Data.define(:topic_id)
  OrchestrationCommit = Data.define(:mapping, :creation)

  class FakeRepository
    attr_reader :failures

    def initialize(reservation:, mapping: OrchestrationMapping.new(topic_id: 101))
      @reservation = reservation
      @mapping = mapping
      @failures = []
    end

    def reserve!(**)
      @reservation
    end

    def commit!(after_mapping: nil, **)
      creation = yield
      after_mapping&.call(@mapping, creation)
      OrchestrationCommit.new(mapping: @mapping, creation: creation)
    end

    def fail!(reservation:, error:)
      @failures << [reservation, error]
    end
  end

  class FakeCreator
    attr_reader :calls, :after_commits

    def initialize(topic: Object.new, error: nil, after_commit_error: nil)
      @topic = topic
      @error = error
      @after_commit_error = after_commit_error
      @calls = 0
      @after_commits = []
    end

    def call(**)
      @calls += 1
      raise @error if @error

      @topic
    end

    def after_commit(creation)
      @after_commits << creation
      raise @after_commit_error if @after_commit_error
    end
  end

  let(:request) do
    {
      connection_id: "astro",
      source_url: "https://example.com/article",
      visibility: "listed",
      correlation_id: "request-1",
    }
  end
  let(:policy) do
    OrchestrationPolicy.new(
      allowed: true,
      reason: "forum_policy_applied",
      effective_actor_id: 42,
      effective_visibility: "unlisted",
      effective_category_id: 3,
      effective_tags: ["alpha"],
    )
  end
  let(:audit) { [] }
  let(:audit_writer) { ->(result) { audit << result } }

  it "resolves an idempotent retry without creating another topic" do
    repository = FakeRepository.new(reservation: OrchestrationReservation.new(state: "complete", topic_id: 100))
    creator = FakeCreator.new
    result = described_class.call(request: request, policy: policy, repository: repository, topic_creator: creator, audit_writer: audit_writer)
    expect(result.outcome).to eq("resolved")
    expect(result.topic_id).to eq(100)
    expect(creator.calls).to eq(0)
    expect(audit.length).to eq(1)
  end

  it "returns reconciliation_required for a uniqueness conflict" do
    repository = FakeRepository.new(reservation: OrchestrationReservation.new(state: "conflict", topic_id: nil))
    creator = FakeCreator.new
    result = described_class.call(request: request, policy: policy, repository: repository, topic_creator: creator, audit_writer: audit_writer)
    expect(result.outcome).to eq("reconciliation_required")
    expect(result.topic_id).to be_nil
    expect(creator.calls).to eq(0)
  end

  it "reserves the identity before creating and committing a topic" do
    reservation = OrchestrationReservation.new(state: "reserved", topic_id: nil)
    repository = FakeRepository.new(reservation: reservation)
    creator = FakeCreator.new
    result = described_class.call(request: request, policy: policy, repository: repository, topic_creator: creator, audit_writer: audit_writer)
    expect(result.outcome).to eq("created")
    expect(result.topic_id).to eq(101)
    expect(creator.calls).to eq(1)
    expect(creator.after_commits.length).to eq(1)
  end

  it "marks the reservation failed when topic creation raises" do
    reservation = OrchestrationReservation.new(state: "reserved", topic_id: nil)
    repository = FakeRepository.new(reservation: reservation)
    creator = FakeCreator.new(error: StandardError.new("creation failed"))
    expect do
      described_class.call(
        request: request,
        policy: policy,
        repository: repository,
        topic_creator: creator,
        audit_writer: audit_writer,
      )
    end.to raise_error(StandardError, "creation failed")
    expect(repository.failures.one?).to eq(true)
    expect(repository.failures.first.first).to eq(reservation)
    expect(repository.failures.first.last).to be_a(StandardError)
  end

  it "keeps the committed created result truthful when post-commit jobs fail" do
    reservation = OrchestrationReservation.new(state: "reserved", topic_id: nil)
    repository = FakeRepository.new(reservation: reservation)
    creator = FakeCreator.new(after_commit_error: StandardError.new("enqueue failed"))

    result = described_class.call(
      request: request,
      policy: policy,
      repository: repository,
      topic_creator: creator,
      audit_writer: audit_writer,
    )

    expect(result).to have_attributes(outcome: "created", topic_id: 101)
    expect(audit.one?).to eq(true)
    expect(audit.first).to have_attributes(outcome: "created", topic_id: 101)
  end

  it "records rejection and never calls the topic creator" do
    denied = policy.with(allowed: false, reason: "origin_denied")
    creator = FakeCreator.new
    result = described_class.call(request: request, policy: denied, repository: nil, topic_creator: creator, audit_writer: audit_writer)
    expect(result.outcome).to eq("rejected")
    expect(result.reason).to eq("origin_denied")
    expect(creator.calls).to eq(0)
  end
end
