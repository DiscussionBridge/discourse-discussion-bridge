# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PolicyEvaluator do
  Settings = Data.define(:enabled, :endpoint_enabled, :connection_id, :trusted_origins, :service_username)
  Authority = Data.define(:allowed?, :reason, :category_id, :tags)
  LaneResolution = Data.define(:allowed, :reason)

  fab!(:actor, :user)

  let(:settings) do
    Settings.new(enabled: true, endpoint_enabled: true, connection_id: "astro", trusted_origins: "https://example.com|https://other.example", service_username: actor.username)
  end
  let(:request) { { connection_id: "astro", source_url: "https://example.com/article", visibility: "listed" } }

  it "keeps the requested visibility distinct from the forum-enforced unlisted state" do
    result = described_class.call(
      request: request,
      settings: settings,
      actor: actor,
      authority: Authority.new(allowed?: true, reason: "authorized", category_id: 3, tags: ["alpha"]),
    )
    expect(result.allowed).to eq(true)
    expect(result.requested_visibility).to eq("listed")
    expect(result.effective_visibility).to eq("unlisted")
    expect(result.effective_actor_id).to eq(actor.id)
    expect(result.effective_category_id).to eq(3)
    expect(result.effective_tags).to eq(["alpha"])
  end

  it "fails closed until category, tag, and Guardian authority is supplied" do
    result = described_class.call(request: request, settings: settings, actor: actor)
    expect(result.allowed).to eq(false)
    expect(result.reason).to eq("authorization_incomplete")
  end

  it "fails closed when the forum lane policy rejects the requested lane" do
    result = described_class.call(
      request: request,
      settings: settings,
      actor: actor,
      authority: Authority.new(allowed?: true, reason: "authorized", category_id: 3, tags: []),
      lane_resolution: LaneResolution.new(allowed: false, reason: "lane_denied"),
    )

    expect(result.allowed).to eq(false)
    expect(result.reason).to eq("lane_denied")
  end

  it "accepts each configured pipe-list origin after forum authorization" do
    second_origin = request.merge(source_url: "https://other.example/article")
    result = described_class.call(
      request: second_origin,
      settings: settings,
      actor: actor,
      authority: Authority.new(allowed?: true, reason: "authorized", category_id: 3, tags: []),
    )
    expect(result.allowed).to eq(true)
  end

  it "rejects an actor who is not the forum-configured service identity" do
    other_identity = settings.with(service_username: "some-other-service-user")
    result = described_class.call(request: request, settings: other_identity, actor: actor)

    expect(result.allowed).to eq(false)
    expect(result.reason).to eq("invalid_actor")
  end

  it "rejects disabled, unauthorized-origin, and system-actor requests without compatibility fallback" do
    disabled = settings.with(enabled: false)
    expect(described_class.call(request: request, settings: disabled, actor: actor).reason).to eq("plugin_disabled")
    expect(described_class.call(request: request.merge(source_url: "https://untrusted.example/article"), settings: settings, actor: actor).reason).to eq("origin_denied")
    system = User.find(Discourse::SYSTEM_USER_ID)
    result = described_class.call(request: request, settings: settings, actor: system)
    expect(result.reason).to eq("invalid_actor")
    expect(result.compatibility_mode).to eq(false)
  end
end
