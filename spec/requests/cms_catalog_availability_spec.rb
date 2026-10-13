# frozen_string_literal: true

# HELD, NOT RUN. Root controller/helper/coordinator integration is required.
require "rails_helper"
require_relative "../support/cms_catalog_availability_fixture"

describe DiscussionBridge::CmsCatalogController do
  include_context "CMS catalog availability native author fixture"

  def finalize_http(upload, input)
    post "/discussion-bridge/v2/catalog/uploads/#{upload}/finalize.json",
         params: JSON.generate(input),
         headers: {
           "X-DiscussionBridge-Connection" => @cms_connection.public_id,
           "X-DiscussionBridge-Secret" => @cms_secret,
           "CONTENT_TYPE" => "application/json",
         }
  end

  it "accepts loss with actual live attention and no public/native absence claim" do
    cms_claim!
    upload, input = cms_begin([])
    source = cms_first_post.reload.attributes
    finalize_http(upload, input)
    expect(response).to have_http_status(:ok)
    DiscussionBridge::CmsProtocol.validate!("CatalogResponse", response.parsed_body)
    expect(response.parsed_body.fetch("items")).to eq([])
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body.include?(@cms_secret)).to eq(false)
    expect(@cms_work.reload.state).to eq("attention")
    expect(@cms_work.last_failure_code).to eq("catalog_entry_unavailable")
    expect(cms_first_post.reload.attributes).to eq(source)
    expect(@cms_mapping.reload.publicly_verified_at).to be_nil
  end

  it "returns failure and retains the previous catalog if live effect fails before commit" do
    cms_claim!
    upload, input = cms_begin([])
    before_revision = cms_issue.availability.catalog_revisions.fetch("authors")
    before_work = @cms_work.reload.attributes.deep_dup
    allow(DiscussionBridge::CmsCatalogAvailabilityLifecycle).to receive(
      :new,
    ).and_wrap_original do |original, *args, **kwargs|
      original.call(
        *args,
        **kwargs,
        permanent_failure:
          lambda do |work, code|
            @cms_coordinator.fail_catalog_metadata!(work, code: code)
            DiscussionBridge::CmsProtocol.reject!("storage_exhausted")
          end,
      )
    end
    finalize_http(upload, input)
    expect(response).to have_http_status(:insufficient_storage)
    expect(response.parsed_body).to include("code" => "storage_exhausted", "core_fallback" => false)
    expect(cms_issue.availability.catalog_revisions.fetch("authors")).to eq(before_revision)
    expect(@cms_work.reload.attributes).to eq(before_work)
    expect(
      DiscussionBridgeCmsMutationReceipt.where(
        route: "catalog_finalize",
        mutation_id: input.fetch("mutation_id"),
      ).count,
    ).to eq(0)
  end
end
