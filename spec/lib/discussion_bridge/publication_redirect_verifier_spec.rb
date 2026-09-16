# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::PublicationRedirectVerifier do
  let(:old_url) { "https://astro.example.com/old/" }
  let(:new_url) { "https://astro.example.com/new/" }
  let(:verifier) { described_class.new(old_url: old_url, new_url: new_url) }

  it "accepts only an exact permanent redirect to a public destination" do
    allow(verifier).to receive(:probe).and_return([301, "/new/"], [200, nil])
    expect(verifier.call).to eq(301)
  end

  it "rejects temporary redirects, wrong targets, and unavailable destinations" do
    allow(verifier).to receive(:probe).and_return([302, "/new/"])
    expect { verifier.call }.to raise_error(ArgumentError, /permanent redirect/)

    allow(verifier).to receive(:probe).and_return([301, "/elsewhere/"])
    expect { verifier.call }.to raise_error(ArgumentError, /different destination/)

    allow(verifier).to receive(:probe).and_return([308, "/new/"], [404, nil])
    expect { verifier.call }.to raise_error(ArgumentError, /not publicly available/)
  end

  it "rejects other origins and non-HTTPS URLs before any request" do
    unsafe = described_class.new(old_url: old_url, new_url: "https://other.example.com/new/")
    expect(unsafe).not_to receive(:probe)
    expect { unsafe.call }.to raise_error(ArgumentError, /same origin/)

    insecure = described_class.new(old_url: "http://astro.example.com/old/", new_url: new_url)
    expect(insecure).not_to receive(:probe)
    expect { insecure.call }.to raise_error(ArgumentError, /HTTPS/)
  end
end
