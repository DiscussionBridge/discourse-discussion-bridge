# frozen_string_literal: true

RSpec.describe DiscussionBridge::EmbeddableOriginStatus do
  fab!(:category)

  it "reports readiness using Discourse Core's exact Embeddable Host rules" do
    EmbeddableHost.create!(host: "publisher.example", category: category)

    expect(described_class.for_origin("https://publisher.example")).to eq(
      origin: "https://publisher.example",
      embeddable: true,
    )
    expect(described_class.for_origin("https://other.publisher.example")).to eq(
      origin: "https://other.publisher.example",
      embeddable: false,
    )
  end

  it "honors Embeddable Host path restrictions" do
    EmbeddableHost.create!(
      host: "publisher.example",
      allowed_paths: "\\A/allowed",
      category: category,
    )

    expect(described_class.for_origin("https://publisher.example")).to eq(
      origin: "https://publisher.example",
      embeddable: false,
    )
  end
end
