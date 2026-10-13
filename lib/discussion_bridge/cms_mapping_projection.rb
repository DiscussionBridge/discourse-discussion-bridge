# frozen_string_literal: true

module DiscussionBridge
  module CmsMappingProjection
    # Reservation rows are not move ancestry: reuse of one URL cannot erase
    # prior events. Callers own authentication/scoping and the read transaction.
    def self.call(mapping, configuration: nil)
      configuration ||=
        CmsConfiguration.current!(mapping.content_connection.reload)
      binding = mapping.content_binding
      body = {
        "mapping_id" => mapping.mapping_id,
        "resource_id" => binding.bridge_record.resource_id,
        "connection_id" => mapping.content_connection.public_id,
        "source_id" => mapping.source_id,
        "external_id" => binding.external_id,
        "mapping_revision" => mapping.mapping_revision,
        "destination_native_id" => mapping.destination_native_id,
        "canonical_url" => binding.canonical_url,
        "retired_url_count" =>
          DiscussionBridgeCmsUrlHistoryEntry.where(
            cms_mapping_id: mapping.id
          ).count,
        "mapping_state" => mapping.mapping_state,
        "presentation_mode" =>
          configuration.fetch("policy").fetch("presentation_mode"),
        "desired_source_revision" => mapping.desired_source_revision,
        "synchronized_source_revision" => mapping.synchronized_source_revision,
        "publicly_verified_source_revision" =>
          mapping.publicly_verified_source_revision,
        "destination_native_revision" => mapping.destination_native_revision,
        "source_created_at" => CmsProtocol.instant(mapping.source_created_at),
        "source_updated_at" => CmsProtocol.instant(mapping.source_updated_at),
        "synchronized_at" => CmsProtocol.instant(mapping.synchronized_at),
        "publicly_verified_at" =>
          CmsProtocol.instant(mapping.publicly_verified_at)
      }
      CmsProtocol.validate!("Mapping", body)
      if JSON.generate(body).bytesize > 262_144
        CmsProtocol.reject!("metadata_unavailable")
      end
      body
    end
  end
end
