# frozen_string_literal: true

class SnapshotPublicationWorkDeploymentMode < ActiveRecord::Migration[7.0]
  STATIC_PROFILES = %w[astro hugo statamic_flat statamic_ssg].freeze

  def up
    add_column :discussion_bridge_publication_works, :static_deployment, :boolean
    execute <<~SQL
      UPDATE discussion_bridge_publication_works AS work
      SET static_deployment = policy.value->>'profile' IN (
        #{STATIC_PROFILES.map { |profile| connection.quote(profile) }.join(", ")}
      )
      FROM discussion_bridge_content_connections AS content_connection,
           jsonb_array_elements(content_connection.destination_policies) AS policy(value)
      WHERE content_connection.id = work.content_connection_id
        AND content_connection.policy_revision = work.policy_revision
        AND policy.value->>'destination_policy_id' = work.destination_policy_id
    SQL
    unresolved = select_value(<<~SQL).to_i
      SELECT COUNT(*)
      FROM discussion_bridge_publication_works
      WHERE static_deployment IS NULL
    SQL
    raise ActiveRecord::MigrationError, "publication work deployment mode cannot be proven" if unresolved.positive?

    change_column_default :discussion_bridge_publication_works, :static_deployment, from: nil, to: false
    change_column_null :discussion_bridge_publication_works, :static_deployment, false
  end

  def down
    remove_column :discussion_bridge_publication_works, :static_deployment
  end
end
