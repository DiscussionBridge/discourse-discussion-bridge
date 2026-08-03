# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::TrustedOriginsValidator do
  fab!(:service_user) { Fabricate(:user, username: "bridge_service") }
  fab!(:category)
  fab!(:tag) { Fabricate(:tag, name: "bridge-alpha") }

  it "accepts exact origins and rejects paths, credentials, and wildcards" do
    validator = DiscussionBridge::TrustedOriginsValidator.new

    expect(validator.valid_value?("https://astro.example.com|http://localhost:4321")).to eq(true)
    expect(validator.valid_value?("https://astro.example.com/articles")).to eq(false)
    expect(validator.valid_value?("https://user@example.com")).to eq(false)
    expect(validator.valid_value?("https://*.example.com")).to eq(false)
  end

  it "accepts only an available non-system operating identity" do
    validator = DiscussionBridge::ServiceUsernameValidator.new

    expect(validator.valid_value?(service_user.username)).to eq(true)
    expect(validator.valid_value?(Discourse.system_user.username)).to eq(false)
    expect(validator.valid_value?("missing-service-user")).to eq(false)
    expect(validator.valid_value?("")).to eq(true)
  end

  it "accepts an existing category or the incomplete zero value" do
    validator = DiscussionBridge::CategoryValidator.new

    expect(validator.valid_value?(category.id)).to eq(true)
    expect(validator.valid_value?(0)).to eq(true)
    expect(validator.valid_value?(99_999_999)).to eq(false)
  end

  it "requires every configured tag to exist" do
    validator = DiscussionBridge::TagsValidator.new

    expect(validator.valid_value?(tag.name)).to eq(true)
    expect(validator.valid_value?("#{tag.name}|missing-tag")).to eq(false)
    expect(validator.valid_value?("")).to eq(true)
  end

  it "accepts only valid forum-owned lane policy categories and tags" do
    validator = DiscussionBridge::LanePoliciesValidator.new
    valid = [{ lane: "docs", category_id: category.id, tags: [tag.name], visibility: "unlisted" }].to_json
    missing_category = [{ lane: "docs", category_id: 99_999_999, tags: [] }].to_json
    missing_tag = [{ lane: "docs", category_id: category.id, tags: ["missing-tag"] }].to_json

    expect(validator.valid_value?(valid)).to eq(true)
    expect(validator.valid_value?(missing_category)).to eq(false)
    expect(validator.valid_value?(missing_tag)).to eq(false)
  end
end
