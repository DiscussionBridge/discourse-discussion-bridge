# frozen_string_literal: true

require "digest"

class DiscussionBridgeContentConnection < ActiveRecord::Base
  self.table_name = "discussion_bridge_content_connections"

  PLATFORMS = %w[astro discourse ghost hugo statamic wordpress].freeze
  DIRECTIONS = %w[to_discourse from_discourse].freeze
  PUBLIC_ID_PATTERN = /\Adbc_[a-z0-9]{24}\z/
  MAX_ORIGINS = 50
  MAX_LANES = 50
  MAX_PUBLICATION_CATEGORY_IDS = 100
  MAX_PUBLICATION_TAG_IDS = 500
  PUBLICATION_CATEGORY_MODES = %w[only_selected all_except_selected].freeze
  PUBLICATION_TAG_MODES = %w[all only_selected all_except_selected].freeze
  AUTHORSHIP_MODES = %w[fixed mapped].freeze
  UNMAPPED_AUTHOR_POLICIES = %w[fallback hold].freeze
  PUBLICATION_SOURCE_PATH_PATTERN = /\A[a-z0-9]+(?:-[a-z0-9]+)*(?:\/[a-z0-9]+(?:-[a-z0-9]+)*)*\z/

  has_many :content_bindings,
           class_name: "DiscussionBridgeContentBinding",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :bridge_records, through: :content_bindings
  has_many :source_authors,
           class_name: "DiscussionBridgeSourceAuthor",
           foreign_key: :content_connection_id,
           dependent: :restrict_with_error
  has_many :publication_work_items,
           class_name: "DiscussionBridgePublicationWorkItem",
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
  validates :publication_category_mode, inclusion: { in: PUBLICATION_CATEGORY_MODES }
  validates :publication_tag_mode, inclusion: { in: PUBLICATION_TAG_MODES }
  validates :adapter_id, :adapter_version, length: { maximum: 100 }, allow_nil: true
  validate :scopes_are_valid
  validate :author_user_is_usable
  validate :default_category_is_available
  validate :publication_path_is_valid
  validate :publication_scope_is_valid

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

  def destination_mapping_current?
    destination_mapping_revision.present? && platform_catalog_revision.present? &&
      destination_mapping["catalog_revision"] == platform_catalog_revision &&
      platform_catalog_adapter_id == adapter_id &&
      platform_catalog_adapter_version == adapter_version
  end

  def mark_from_discourse_publications_pending!
    DiscussionBridgeBridgeRecord.joins(:content_bindings)
      .where(direction: "from_discourse")
      .where(publication_program: %w[forum_sync_pending forum_sync])
      .where(discussion_bridge_content_bindings: {
        content_connection_id: id, role: "presentation", state: "active",
      }).update_all(
        destination_state: "pending",
        pending_publication_revision: nil,
        pending_mapping_revision: destination_mapping_revision,
        pending_destination: {},
        updated_at: Time.zone.now,
      )
    publication_work_items.update_all(
      state: "queued",
      reason: "mapping_changed",
      available_at: Time.zone.now,
      lease_token: nil,
      claimed_at: nil,
      lease_expires_at: nil,
      completed_at: nil,
      updated_at: Time.zone.now,
    )
  end

  private

  def publication_scope_is_valid
    included = Array(publication_category_ids)
    excluded = Array(publication_excluded_category_ids)
    valid = ->(values, maximum) do
      values.length <= maximum && values.uniq == values &&
        values.all? { |value| value.is_a?(Integer) && value.positive? }
    end
    errors.add(:publication_category_ids, "is invalid") unless
      valid.call(included, MAX_PUBLICATION_CATEGORY_IDS)
    errors.add(:publication_excluded_category_ids, "is invalid") unless
      valid.call(excluded, MAX_PUBLICATION_CATEGORY_IDS)
    errors.add(:publication_category_ids, "overlaps excluded categories") if (included & excluded).any?
    configured = (included + excluded).uniq
    public_count = Category.where(id: configured, read_restricted: false).count
    errors.add(:publication_category_ids, "must identify existing public categories") unless
      public_count == configured.length
    if publication_category_mode == "only_selected"
      errors.add(:publication_category_ids, "must select at least one category") if included.empty?
      errors.add(:publication_excluded_category_ids, "must be empty in only-selected mode") if excluded.any?
    elsif included.any?
      errors.add(:publication_category_ids, "must be empty in all-except-selected mode")
    end

    included_tags = Array(publication_tag_ids)
    excluded_tags = Array(publication_excluded_tag_ids)
    errors.add(:publication_tag_ids, "is invalid") unless
      valid.call(included_tags, MAX_PUBLICATION_TAG_IDS)
    errors.add(:publication_excluded_tag_ids, "is invalid") unless
      valid.call(excluded_tags, MAX_PUBLICATION_TAG_IDS)
    errors.add(:publication_tag_ids, "overlaps excluded tags") if
      (included_tags & excluded_tags).any?
    configured_tags = (included_tags + excluded_tags).uniq
    errors.add(:publication_tag_ids, "must identify existing tags") unless
      Tag.where(id: configured_tags).count == configured_tags.length
    case publication_tag_mode
    when "all"
      errors.add(:publication_tag_ids, "must be empty in all-tags mode") if included_tags.any?
      errors.add(:publication_excluded_tag_ids, "must be empty in all-tags mode") if excluded_tags.any?
    when "only_selected"
      errors.add(:publication_tag_ids, "must select at least one tag") if included_tags.empty?
      errors.add(:publication_excluded_tag_ids, "must be empty in only-selected mode") if excluded_tags.any?
    when "all_except_selected"
      errors.add(:publication_tag_ids, "must be empty in all-except-selected mode") if
        included_tags.any?
    end
  end

  def publication_path_is_valid
    path = publication_source_path.to_s
    if include_source_in_published_url
      errors.add(:publication_source_path, "is required") if path.blank?
    end
    return if path.blank?

    errors.add(:publication_source_path, "is invalid") unless
      path.bytesize <= 120 && PUBLICATION_SOURCE_PATH_PATTERN.match?(path)
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
#  destination_mapping                   :jsonb            not null
#  destination_mapping_revision          :string(64)
#  destination_mapping_updated_at        :datetime
#  enabled                               :boolean          default(TRUE), not null
#  forum_publication_enabled             :boolean          default(FALSE), not null
#  generate_topic_toc                    :boolean          default(FALSE), not null
#  include_source_in_published_url       :boolean          default(FALSE), not null
#  last_seen_at                          :datetime
#  name                                  :string(120)      not null
#  platform                              :string(32)       not null
#  platform_catalog                      :jsonb            not null
#  platform_catalog_adapter_version      :string(100)
#  platform_catalog_display_revision     :string(64)
#  platform_catalog_observed_at          :datetime
#  platform_catalog_refresh_requested_at :datetime
#  platform_catalog_revision             :string(64)
#  publication_attention_fingerprint     :string(64)
#  publication_attention_notified_at     :datetime
#  publication_category_ids              :jsonb            not null
#  publication_category_mode             :string(32)       default("all_except_selected"), not null
#  publication_excluded_category_ids     :jsonb            not null
#  publication_excluded_tag_ids          :jsonb            not null
#  publication_include_unlisted          :boolean          default(FALSE), not null
#  publication_source_path               :string(120)
#  publication_tag_ids                   :jsonb            not null
#  publication_tag_mode                  :string(32)       default("all"), not null
#  secret_digest                         :string(64)       not null
#  unmapped_author_policy                :string(32)       default("fallback"), not null
#  created_at                            :datetime         not null
#  updated_at                            :datetime         not null
#  adapter_id                            :string(100)
#  author_user_id                        :bigint
#  default_category_id                   :bigint
#  platform_catalog_adapter_id           :string(100)
#  public_id                             :string(64)       not null
#
# Indexes
#
#  idx_db_content_connections_author            (author_user_id)
#  idx_db_content_connections_default_category  (default_category_id)
#  idx_db_content_connections_name              (name) UNIQUE
#  idx_db_content_connections_platform          (platform)
#  idx_db_content_connections_public_id         (public_id) UNIQUE
#
