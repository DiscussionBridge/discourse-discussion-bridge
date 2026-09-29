# frozen_string_literal: true

require "rails_helper"

describe DiscussionBridge::OperatorEntitlementVerifier do
  fab!(:admin)

  let(:enrollment) do
    DiscussionBridgeOperatorEnrollment.instance.tap do |record|
      record.update!(
        enabled: true,
        forum_id: "dbf_11111111111111111111111111111111",
        provider_id: "dbp_11111111111111111111111111111111",
        provider_name: "DiscussionBridge",
      )
    end
  end

  let(:vector) do
    {
      "entitlement_version" => 1,
      "entitlement_id" => "dbe_11111111111111111111111111111111",
      "provider_id" => "dbp_11111111111111111111111111111111",
      "provider_name" => "DiscussionBridge",
      "forum_id" => "dbf_11111111111111111111111111111111",
      "issuer_id" => "dbi_11111111111111111111111111111111",
      "issued_at" => "2026-09-27T18:00:00Z",
      "not_before" => "2026-09-27T18:00:00Z",
      "expires_at" => "2027-09-27T18:00:00Z",
      "grace_until" => "2027-10-04T18:00:00Z",
      "scopes" => %w[observe_health observe_publication retry_retryable_work],
      "key_id" => "discussionbridge-operator-2026-01",
      "signature" => "CoWk_EEtcpo-d8IT32Ak2nMFIkn8XfsWOoHzKoGGerbc-Dw7R6e1w9McdDHeWRiv9VNgsJ06upJu1OAUlLg_AA",
    }
  end

  let(:canonical_vector) do
    '{"entitlement_id":"dbe_11111111111111111111111111111111","entitlement_version":1,"expires_at":"2027-09-27T18:00:00Z","forum_id":"dbf_11111111111111111111111111111111","grace_until":"2027-10-04T18:00:00Z","issued_at":"2026-09-27T18:00:00Z","issuer_id":"dbi_11111111111111111111111111111111","key_id":"discussionbridge-operator-2026-01","not_before":"2026-09-27T18:00:00Z","provider_id":"dbp_11111111111111111111111111111111","provider_name":"DiscussionBridge","scopes":["observe_health","observe_publication","retry_retryable_work"]}'
  end

  before do
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: vector.fetch("issuer_id"),
      key_id: vector.fetch("key_id"),
      public_key_base64url: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo",
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
  end

  it "matches and verifies the released Alpha.21 Ed25519 test vector idempotently" do
    expect(DiscussionBridge::OperatorCanonicalJson.generate("ASCII".b)).to eq('"ASCII"')
    expect(
      DiscussionBridge::OperatorCanonicalJson.generate(vector.except("signature")),
    ).to eq(canonical_vector)

    entitlement = described_class.call(
      payload: vector,
      enrollment: enrollment,
      actor: admin,
      at: Time.iso8601("2026-09-27T18:00:00Z"),
    )
    replay = described_class.call(
      payload: vector,
      enrollment: enrollment,
      actor: admin,
      at: Time.iso8601("2026-09-27T18:00:00Z"),
    )

    expect(replay.id).to eq(entitlement.id)
    expect(DiscussionBridgeOperatorEntitlement.count).to eq(1)
    expect(entitlement.payload_sha256).to eq(
      Digest::SHA256.hexdigest(described_class::SIGNING_DOMAIN + canonical_vector),
    )
  end

  it "rejects exact replay after the stored entitlement is revoked or replaced" do
    entitlement = described_class.call(
      payload: vector,
      enrollment: enrollment,
      actor: admin,
      at: Time.iso8601("2026-09-27T18:00:00Z"),
    )

    entitlement.update!(state: "revoked", revoked_at: Time.iso8601("2026-09-27T18:01:00Z"))
    expect do
      described_class.call(
        payload: vector,
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:02:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_revoked")
    }

    entitlement.update!(state: "replaced", replaced_by_entitlement_id: "dbe_22222222222222222222222222222222")
    expect do
      described_class.call(
        payload: vector,
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:03:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_replaced")
    }
  end

  it "verifies the signature before reporting semantic claim failures" do
    stale_signature = vector.merge("forum_id" => "dbf_22222222222222222222222222222222")

    expect do
      described_class.call(
        payload: stale_signature,
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_invalid_signature")
    }
  end

  it "reports exact semantic failures only after a valid signature" do
    key = OpenSSL::PKey.generate_key("ED25519")
    issuer_id = "dbi_22222222222222222222222222222222"
    key_id = "generated-key"
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: issuer_id,
      key_id: key_id,
      public_key_base64url: raw_public_key(key),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    payload = signed_payload(
      key,
      vector.except("signature").merge(
        "entitlement_id" => "dbe_22222222222222222222222222222222",
        "forum_id" => "dbf_22222222222222222222222222222222",
        "issuer_id" => issuer_id,
        "key_id" => key_id,
      ),
    )

    expect do
      described_class.call(
        payload: payload,
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_wrong_forum")
    }
  end

  it "fails closed for unknown scopes and a retired issuing key" do
    key = OpenSSL::PKey.generate_key("ED25519")
    trusted_key = DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: "dbi_33333333333333333333333333333333",
      key_id: "retiring-key",
      public_key_base64url: raw_public_key(key),
      retire_at: Time.iso8601("2026-09-28T00:00:00Z"),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    claims = vector.except("signature").merge(
      "entitlement_id" => "dbe_33333333333333333333333333333333",
      "issuer_id" => trusted_key.issuer_id,
      "key_id" => trusted_key.key_id,
      "scopes" => ["unbounded_access"],
    )

    expect do
      described_class.call(
        payload: signed_payload(key, claims),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("scope_denied")
    }

    claims["scopes"] = ["observe_health"]
    expect do
      described_class.call(
        payload: signed_payload(key, claims),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-28T00:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_invalid_signature")
    }
  end

  it "enforces not-before, grace expiry, and the maximum signed lifetime" do
    key = OpenSSL::PKey.generate_key("ED25519")
    issuer_id = "dbi_88888888888888888888888888888888"
    key_id = "time-bound-key"
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: issuer_id,
      key_id: key_id,
      public_key_base64url: raw_public_key(key),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    base = vector.except("signature").merge(
      "issuer_id" => issuer_id,
      "key_id" => key_id,
      "scopes" => ["observe_health"],
    )

    not_yet_valid = base.merge(
      "entitlement_id" => "dbe_88888888888888888888888888888881",
      "issued_at" => "2026-09-27T18:00:00Z",
      "not_before" => "2026-09-28T18:00:00Z",
      "expires_at" => "2026-09-29T18:00:00Z",
      "grace_until" => "2026-09-30T18:00:00Z",
    )
    expect do
      described_class.call(
        payload: signed_payload(key, not_yet_valid),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T19:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_not_yet_valid")
    }

    expired = base.merge(
      "entitlement_id" => "dbe_88888888888888888888888888888882",
      "issued_at" => "2026-09-25T18:00:00Z",
      "not_before" => "2026-09-25T18:00:00Z",
      "expires_at" => "2026-09-26T18:00:00Z",
      "grace_until" => "2026-09-27T18:00:00Z",
    )
    expect do
      described_class.call(
        payload: signed_payload(key, expired),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T19:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_expired")
    }

    overlong = base.merge(
      "entitlement_id" => "dbe_88888888888888888888888888888883",
      "issued_at" => "2026-09-27T18:00:00Z",
      "not_before" => "2026-09-27T18:00:00Z",
      "expires_at" => "2027-09-27T18:00:01Z",
      "grace_until" => "2027-09-27T18:00:01Z",
    )
    expect do
      described_class.call(
        payload: signed_payload(key, overlong),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-09-27T18:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_invalid_signature")
    }
  end

  it "rejects a correctly signed impossible calendar date" do
    key = OpenSSL::PKey.generate_key("ED25519")
    DiscussionBridgeOperatorTrustedKey.create!(
      issuer_id: "dbi_99999999999999999999999999999999",
      key_id: "invalid-calendar",
      public_key_base64url: raw_public_key(key),
      enrolled_by: admin,
      enrolled_at: Time.zone.now,
    )
    claims = vector.except("signature").merge(
      "issuer_id" => "dbi_99999999999999999999999999999999",
      "key_id" => "invalid-calendar",
      "issued_at" => "2026-02-30T00:00:00Z",
      "not_before" => "2026-02-30T00:00:00Z",
      "expires_at" => "2026-03-03T00:00:00Z",
      "grace_until" => "2026-03-03T00:00:00Z",
    )

    expect do
      described_class.call(
        payload: signed_payload(key, claims),
        enrollment: enrollment,
        actor: admin,
        at: Time.iso8601("2026-03-02T01:00:00Z"),
      )
    end.to raise_error(described_class::VerificationError) { |error|
      expect(error.code).to eq("entitlement_invalid_signature")
    }
  end

  def raw_public_key(key)
    raw = OpenSSL::ASN1.decode(key.public_to_der).value.last.value
    Base64.urlsafe_encode64(raw, padding: false)
  end

  def signed_payload(key, claims)
    canonical = DiscussionBridge::OperatorCanonicalJson.generate(claims)
    signature = key.sign(nil, described_class::SIGNING_DOMAIN + canonical)
    claims.merge("signature" => Base64.urlsafe_encode64(signature, padding: false))
  end
end
