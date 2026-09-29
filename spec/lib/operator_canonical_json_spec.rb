# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorCanonicalJson do
  it "emits JCS-compatible finite number forms" do
    expect(described_class.generate(1.0)).to eq("1")
    expect(described_class.generate(-0.0)).to eq("0")
    expect(described_class.generate(0.000001)).to eq("0.000001")
    expect(described_class.generate(0.0000001)).to eq("1e-7")
    expect(described_class.generate(1e20)).to eq("100000000000000000000")
    expect(described_class.generate(1e21)).to eq("1e+21")
    expect(described_class.generate(333_333_333.33333329)).to eq("333333333.3333333")
  end

  it "rejects duplicate normalized keys and values outside the I-JSON domain" do
    invalid = [
      { "scope" => 1, scope: 2 },
      9_007_199_254_740_992,
      Float::NAN,
      Float::INFINITY,
      "reserved noncharacter \uFDD0",
      "plane noncharacter \u{10FFFF}",
    ]
    invalid.each do |value|
      expect { described_class.generate(value) }.to raise_error(
        DiscussionBridge::OperatorCanonicalJson::InvalidValue,
      )
    end
  end

  it "strictly rejects duplicate JSON object keys before canonicalization" do
    expect do
      described_class.parse('{"scope":1,"scope":2}')
    end.to raise_error(DiscussionBridge::OperatorCanonicalJson::InvalidValue)
  end
end
