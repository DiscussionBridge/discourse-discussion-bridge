# frozen_string_literal: true

class DiscussionBridgeOperatorTrustedKey < ActiveRecord::Base
  self.table_name = "discussion_bridge_operator_trusted_keys"

  ISSUER_ID_PATTERN = /\Adbi_[a-f0-9]{32}\z/
  KEY_ID_PATTERN = /\A[^\x00-\x1f\x7f]{1,200}\z/
  BASE64URL_PATTERN = /\A[A-Za-z0-9_-]+\z/

  belongs_to :enrolled_by, class_name: "User"

  validates :issuer_id, format: { with: ISSUER_ID_PATTERN }
  validates :key_id, format: { with: KEY_ID_PATTERN }
  validates :issuer_id, uniqueness: { scope: :key_id }
  validates :public_key_base64url, format: { with: BASE64URL_PATTERN }
  validate :public_key_is_canonical_ed25519

  def available_for_issuance?(at: Time.zone.now)
    may_issue? && revoked_at.nil? && (retire_at.nil? || at < retire_at)
  end

  private

  def public_key_is_canonical_ed25519
    raw = DiscussionBridge::OperatorEncoding.decode_base64url(public_key_base64url, expected_bytes: 32)
    errors.add(:public_key_base64url, "must be a canonical 32-byte Ed25519 public key") unless raw
  end
end

# == Schema Information
#
# Table name: discussion_bridge_operator_trusted_keys
#
#  id                   :bigint           not null, primary key
#  enrolled_at          :datetime         not null
#  may_issue            :boolean          default(TRUE), not null
#  public_key_base64url :string(64)       not null
#  retire_at            :datetime
#  revoked_at           :datetime
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  enrolled_by_id       :bigint           not null
#  issuer_id            :string(36)       not null
#  key_id               :string(200)      not null
#
# Indexes
#
#  idx_db_operator_trusted_keys_identity  (issuer_id,key_id) UNIQUE
#
