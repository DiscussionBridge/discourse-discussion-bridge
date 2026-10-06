# frozen_string_literal: true

require "digest"

class DiscussionBridgeContentConnection < ActiveRecord::Base
  self.table_name = "discussion_bridge_content_connections"

  PLATFORMS = %w[astro discourse ghost hugo statamic wordpress].freeze
  DIRECTIONS = %w[to_discourse from_discourse].freeze
  PUBLIC_ID_PATTERN = DiscussionBridge::AdapterRequestBoundary::CONNECTION_ID_PATTERN
  MAX_ORIGINS = 50
  MAX_LANES = 50
  AUTHORSHIP_MODES = %w[fixed mapped].freeze
  UNMAPPED_AUTHOR_POLICIES = %w[fallback hold].freeze

  has_many :content_bindings,
           class_name: "DiscussionBridgeContentBinding",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :bridge_records, through: :content_bindings
  has_many :source_authors,
           class_name: "DiscussionBridgeSourceAuthor",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :source_snapshots,
           class_name: "DiscussionBridgeSourceSnapshot",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :source_revocations,
           class_name: "DiscussionBridgeSourceRevocation",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :platform_catalogs,
           class_name: "DiscussionBridgePlatformCatalog",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :publication_works,
           class_name: "DiscussionBridgePublicationWork",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :publication_overrides,
           class_name: "DiscussionBridgePublicationOverride",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  belongs_to :author_user, class_name: "User", optional: true

  validates :public_id, :name, :platform, :secret_digest, presence: true
  validates :public_id, format: { with: PUBLIC_ID_PATTERN }, uniqueness: true
  validates :name, length: { maximum: 120 }, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS }
  validates :authorship_mode, inclusion: { in: AUTHORSHIP_MODES }
  validates :unmapped_author_policy, inclusion: { in: UNMAPPED_AUTHOR_POLICIES }
  validates :secret_digest, length: { is: 64 }
  validates :adapter_id, :adapter_version, length: { maximum: 100 }, allow_nil: true
  validate :scopes_are_valid
  validate :author_user_is_usable
  validate :default_category_is_available
  validate :alpha21_capability_state_is_valid
  validate :discourse_network_state_is_valid
  validate :platform_is_immutable, on: :update

  def effective_author
    default_username = SiteSetting.discussion_bridge_default_author_username.to_s.presence ||
      SiteSetting.discussion_bridge_service_username.to_s
    author_user || User.find_by(
      username_lower: default_username.downcase,
    )
  end

  def self.issue!(attributes)
    secret = SecureRandom.urlsafe_base64(32, false)
    connection = create!(
      attributes.merge(
        public_id: "dbc_#{SecureRandom.hex(12)}",
        secret_digest: Digest::SHA256.hexdigest(secret),
      ),
    )
    [connection, secret]
  end

  def rotate_secret!
    secret = SecureRandom.urlsafe_base64(32, false)
    update!(secret_digest: Digest::SHA256.hexdigest(secret))
    secret
  end

  def authenticate_secret?(secret)
    return false unless secret.is_a?(String) && secret.bytesize.between?(32, 256)

    ActiveSupport::SecurityUtils.secure_compare(
      secret_digest,
      Digest::SHA256.hexdigest(secret),
    )
  end

  def allows_direction?(direction)
    Array(allowed_directions).include?(direction.to_s)
  end

  def allows_lane?(lane)
    lanes = Array(allowed_lanes)
    lanes.empty? ? lane.blank? : lanes.include?(lane.to_s)
  end

  def allows_origin?(url)
    source = DiscussionBridge::CanonicalSource.call(connection_id: public_id, source_url: url)
    uri = URI.parse(source.source_url)
    origin = "#{uri.scheme}://#{uri.host}"
    origin += ":#{uri.port}" unless uri.port == uri.default_port
    Array(allowed_origins).include?(origin)
  rescue ArgumentError, URI::InvalidURIError
    false
  end

  private

  def platform_is_immutable
    errors.add(:platform, "cannot be changed after creation") if will_save_change_to_platform?
  end

  def alpha21_capability_state_is_valid
    unless policy_revision.nil? || DiscussionBridge::ConnectionCapability.valid_policy_revision?(policy_revision)
      errors.add(:policy_revision, "is invalid")
    end
    unless destination_policies == [] || DiscussionBridge::ConnectionCapability.valid_destination_policies?(destination_policies)
      errors.add(:destination_policies, "do not match the Adapter Protocol")
    end
    if destination_policies.present? &&
        !DiscussionBridge::ConnectionCapability.policies_within_connection_scope?(self)
      errors.add(:destination_policies, "exceed the connection direction or platform scope")
    end
  end

  def discourse_network_state_is_valid
    values = [network_peer_forum_id, network_relationship]
    if !network_enabled && values.any?(&:present?)
      errors.add(:network_enabled, "must be enabled when network peer configuration is present")
      return
    end
    return unless network_enabled

    errors.add(:platform, "must be discourse for a network connection") unless platform == "discourse"
    unless DiscussionBridge::DiscourseNetworkProtocol::FORUM_ID_PATTERN.match?(network_peer_forum_id.to_s)
      errors.add(:network_peer_forum_id, "is invalid")
    end
    if DiscussionBridge::DiscourseNetworkProtocol::RELATIONSHIPS.exclude?(network_relationship)
      errors.add(:network_relationship, "is invalid")
    end
    unless Array(destination_policies).any? do |policy|
      policy.stringify_keys["profile"] == "discourse_as_publisher"
    end
      errors.add(:destination_policies, "must include discourse_as_publisher")
    end
  end

  def default_category_is_available
    return if default_category_id.blank? || Category.exists?(id: default_category_id)

    errors.add(:default_category_id, "must identify an existing Discourse category")
  end

  def author_user_is_usable
    return if author_user.nil?
    return if author_user.active? && !author_user.staged? && !author_user.suspended? &&
      !author_user.silenced? && author_user.id != Discourse::SYSTEM_USER_ID

    errors.add(:author_user, "must be an active non-system Discourse user")
  end

  def scopes_are_valid
    origins = Array(allowed_origins)
    normalized = origins.map { |origin| DiscussionBridge::CanonicalSource.origin(origin) }
    errors.add(:allowed_origins, "must contain between 1 and #{MAX_ORIGINS} origins") unless
      origins.length.between?(1, MAX_ORIGINS)
    errors.add(:allowed_origins, "must be unique canonical origins") unless
      normalized == origins && normalized.uniq == origins
  rescue ArgumentError
    errors.add(:allowed_origins, "contains an invalid origin")
  ensure
    directions = Array(allowed_directions)
    errors.add(:allowed_directions, "is invalid") unless directions.any? &&
      directions.uniq == directions && (directions - DIRECTIONS).empty?

    lanes = Array(allowed_lanes)
    errors.add(:allowed_lanes, "is invalid") unless lanes.length <= MAX_LANES && lanes.uniq == lanes &&
      lanes.all? { |lane| DiscussionBridge::LanePolicies::LANE_PATTERN.match?(lane.to_s) }
  end
end

# == Schema Information
#
# Table name: discussion_bridge_content_connections
#
#  id                                    :bigint           not null, primary key
#  adapter_version                       :string(100)
#  allowed_directions                    :jsonb            not null
#  allowed_lanes                         :jsonb            not null
#  allowed_origins                       :jsonb            not null
#  authorship_mode                       :string(32)       default("fixed"), not null
#  catalog_required                      :boolean          default(FALSE), not null
#  destination_policies                  :jsonb            not null
#  enabled                               :boolean          default(TRUE), not null
#  generate_topic_toc                    :boolean          default(FALSE), not null
#  last_seen_at                          :datetime
#  name                                  :string(120)      not null
#  network_enabled                       :boolean          default(FALSE), not null
#  network_relationship                  :string(32)
#  platform                              :string(32)       not null
#  platform_catalog_refresh_requested_at :datetime
#  policy_revision                       :string(255)
#  secret_digest                         :string(64)       not null
#  unmapped_author_policy                :string(32)       default("fallback"), not null
#  created_at                            :datetime         not null
#  updated_at                            :datetime         not null
#  adapter_id                            :string(100)
#  author_user_id                        :bigint
#  default_category_id                   :bigint
#  network_peer_forum_id                 :string(36)
#  public_id                             :string(64)       not null
#
# Indexes
#
#  idx_db_content_connections_author            (author_user_id)
#  idx_db_content_connections_default_category  (default_category_id)
#  idx_db_content_connections_name              (name) UNIQUE
#  idx_db_content_connections_network_peer      (network_peer_forum_id,network_relationship)
#  idx_db_content_connections_platform          (platform)
#  idx_db_content_connections_public_id         (public_id) UNIQUE
#
