# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::EmbedRouteAttestation do
  fab!(:topic)
  fab!(:mapping) do
    DiscussionBridgeConnection.create!(
      connection_id: "astro",
      canonical_source_url: "https://example.com/article",
      source_identity_digest: Digest::SHA256.hexdigest("astro\nhttps://example.com/article"),
      state: "complete",
      topic_id: topic.id,
      effective_actor_id: topic.user_id,
      requested_visibility: "unlisted",
      effective_visibility: "unlisted",
      requested_state: {},
      effective_state: {},
    )
  end

  it "authenticates issuance separately from its bounded live/current mapping check" do
    freeze_time do
      token = described_class.issue(
        mapping: mapping,
        class_name: DiscussionBridge::CommentsOnlyPresenter::CSS_CLASS,
      )
      payload = described_class.authenticated_payload(token)

      expect(payload).to include(
        "mapping_id" => mapping.id,
        "mapping_updated_at" => mapping.updated_at.utc.iso8601(6),
      )
      expect(described_class.live_payload?(payload)).to eq(true)
      expect(described_class.verify(token)).to be_present

      travel described_class::MAX_AGE + 1.second
      expect(described_class.authenticated_payload(token)).to eq(payload)
      expect(described_class.live_payload?(payload)).to eq(false)
      expect(described_class.verify(token)).to be_nil
    end
  end


  it "owns the exact final presentation-class invariant at issue and verify" do
    reserved = DiscussionBridge::CommentsOnlyPresenter::CSS_CLASS
    ["operator-theme", "#{reserved} #{reserved}"].each do |class_name|
      expect do
        described_class.issue(mapping: mapping, class_name: class_name)
      end.to raise_error(ArgumentError, /invalid attestation class/)
    end

    ["operator-theme", "#{reserved} #{reserved}"].each do |class_name|
      token = described_class.__send__(:verifier).generate(
        {
          "mapping_id" => mapping.id,
          "topic_id" => mapping.topic_id,
          "mapping_updated_at" => mapping.updated_at.utc.iso8601(6),
          "class_name" => class_name,
          "issued_at" => Time.zone.now.utc.iso8601(6),
        },
        purpose: described_class::PURPOSE,
      )

      expect(described_class.verify(token)).to be_nil
    end
  end
end
