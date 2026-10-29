# frozen_string_literal: true

require "digest"
require "securerandom"

module DiscussionBridge
  # Accepted catalogs are descriptive native metadata. This store neither
  # changes policy nor starts source, publication or native mutation work.
  class CmsCatalogStore
    Result = Data.define(:status, :body, :change)
    SelectionAvailability =
      Data.define(:available, :missing_ids, :unavailable_ids, :catalog_revisions, :catalog_errors)
    CatalogChange =
      Data.define(
        :connection_id,
        :publication_lane,
        :kind,
        :previous_catalog_revision,
        :catalog_revision,
        :native_revision,
        :total_items,
        :received_at,
        :selected_availability,
      )
    PAGE_ITEMS = 100
    RESPONSE_BYTES = 262_144
    LIFETIME_SECONDS = 86_400

    def initialize(connection, clock: -> { Time.current }, authenticated_secret_digest: nil)
      @connection = connection
      @clock = clock
      @authenticated_secret_digest = authenticated_secret_digest
    end

    def begin_upload(input)
      validate_input!("CatalogBegin", input)
      mutation("catalog_begin", "", input) do |configuration|
        upload =
          DiscussionBridgeCmsCatalogUpload.create!(
            upload_id: SecureRandom.uuid,
            content_connection: @connection,
            kind: input.fetch("kind"),
            native_revision: input.fetch("native_revision"),
            total_items: input.fetch("total_items"),
            profile: configuration.fetch("profile"),
            publication_lane: configuration.fetch("publication_lane"),
            destination_origin: configuration.fetch("destination_origin"),
            scope_signature: scope_signature(configuration),
            expires_at: now + LIFETIME_SECONDS,
          )
        response("CatalogUpload", upload_payload(upload), status: 201)
      end
    end

    def append_page(upload_id, input)
      CmsProtocol.validate!("UUID", upload_id)
      validate_input!("CatalogPageInput", input)
      mutation("catalog_page", upload_id, input) do |configuration|
        upload = current_upload!(upload_id, configuration)
        number = input.fetch("page")
        items = input.fetch("items")
        if accepted = upload.pages.find_by(page: number)
          CmsProtocol.reject!("catalog_page_conflict") unless accepted.entries == items
          next response("CatalogUpload", accepted.acknowledgement)
        end
        CmsProtocol.reject!("invalid_transition") unless upload.state == "open"
        unless number == upload.next_page && upload.total_items.positive?
          CmsProtocol.reject!("catalog_page_conflict")
        end
        if items.empty? && upload.received_items < upload.total_items
          CmsProtocol.reject!("catalog_page_conflict")
        end
        if upload.next_page >= CmsProtocol::MAX_COUNTER ||
             upload.received_items > CmsProtocol::MAX_COUNTER - items.size
          CmsProtocol.reject!("storage_exhausted")
        end
        if upload.received_items + items.size > upload.total_items
          CmsProtocol.reject!("catalog_page_conflict")
        end
        ids = items.map { |item| item.fetch("id") }
        digests = ids.map { |id| Digest::SHA256.hexdigest(id) }
        unless ids.uniq.size == ids.size && digests.uniq.size == digests.size
          CmsProtocol.reject!("catalog_page_conflict")
        end
        if upload.entries.where(entry_id_sha256: digests).exists?
          CmsProtocol.reject!("catalog_page_conflict")
        end
        if items.any?
          upload.entries.insert_all!(
            items.each_with_index.map do |item, index|
              {
                catalog_upload_id: upload.id,
                ordinal: upload.received_items + index,
                entry_id: item.fetch("id"),
                entry_id_sha256: digests.fetch(index),
                payload: item.deep_dup,
                created_at: now,
              }
            end,
          )
        end
        upload.update!(
          received_items: upload.received_items + items.size,
          next_page: upload.next_page + 1,
        )
        result = response("CatalogUpload", upload_payload(upload))
        upload.pages.create!(
          page: number,
          entries: items.deep_dup,
          acknowledgement: result.body.deep_dup,
          created_at: now,
        )
        result
      end
    end

    def finalize(upload_id, input)
      CmsProtocol.validate!("UUID", upload_id)
      validate_input!("CatalogFinalize", input)
      CmsProtocol.reject!("identity_conflict") unless input.fetch("upload_id") == upload_id
      mutation("catalog_finalize", upload_id, input) do |configuration|
        upload = current_upload!(upload_id, configuration)
        unless input.fetch("expected_total_items") == upload.total_items
          CmsProtocol.reject!("catalog_page_conflict")
        end
        next response("CatalogResponse", upload.finalized_response) if upload.state == "finalized"
        ready_for_finalize!(upload)
        previous = active_snapshot(configuration, upload.kind)
        DiscussionBridgeCmsCatalogSnapshot.where(
          content_connection_id: @connection.id,
          kind: upload.kind,
          publication_lane: upload.publication_lane,
          active: true,
        ).update_all(active: false)
        snapshot =
          DiscussionBridgeCmsCatalogSnapshot.create!(
            catalog_upload: upload,
            content_connection: @connection,
            kind: upload.kind,
            profile: upload.profile,
            publication_lane: upload.publication_lane,
            destination_origin: upload.destination_origin,
            catalog_revision: SecureRandom.uuid,
            native_revision: upload.native_revision,
            total_items: upload.total_items,
            active: true,
            created_at: now,
          )
        cursor = new_cursor!(snapshot, configuration, 0, now + LIFETIME_SECONDS).first
        body = render_page!(cursor).body
        upload.update!(state: "finalized", finalized_response: body.deep_dup)
        change =
          CatalogChange.new(
            connection_id: @connection.public_id,
            publication_lane: configuration.fetch("publication_lane"),
            kind: upload.kind,
            previous_catalog_revision: previous&.catalog_revision,
            catalog_revision: snapshot.catalog_revision,
            native_revision: snapshot.native_revision,
            total_items: snapshot.total_items,
            received_at: CmsProtocol.instant(now),
            selected_availability:
              self.class.selected_availability(@connection, configuration: configuration),
          )
        Result.new(status: 200, body: body, change: change)
      end
    end

    def read(query)
      CmsProtocol.validate!("CatalogReadQuery", query)
      transaction do |configuration|
        if query["cursor"]
          cursor = continuation!(query.fetch("cursor"), query.fetch("kind"), configuration)
        else
          snapshot = active_snapshot(configuration, query.fetch("kind"))
          CmsProtocol.reject!("resource_not_found") unless snapshot
          scoped_snapshot!(snapshot, configuration)
          reject_readonly!
          cursor = new_cursor!(snapshot, configuration, 0, now + LIFETIME_SECONDS).first
        end
        render_page!(cursor)
      end
    end

    # Root calls this with already validated, connection-locked configuration.
    # Deliberately does not call current!: its publication gate may call this API.
    # Empty selections do not require any catalog. No state is written here.
    def self.selected_availability(connection, configuration:)
      missing = { "authors" => [], "taxonomy" => [] }
      unavailable = { "authors" => [], "taxonomy" => [] }
      revisions = { "authors" => nil, "taxonomy" => nil }
      errors = {}
      { "authors" => "author_ids", "taxonomy" => "taxonomy_ids" }.each do |kind, field|
        ids = configuration.fetch("policy").fetch(field)
        CmsProtocol.validate!("IdList", ids)
        next if ids.empty?
        snapshot =
          DiscussionBridgeCmsCatalogSnapshot.find_by(
            content_connection_id: connection.id,
            kind: kind,
            publication_lane: configuration.fetch("publication_lane"),
            active: true,
          )
        unless snapshot && snapshot.profile == configuration.fetch("profile") &&
                 snapshot.destination_origin == configuration.fetch("destination_origin")
          missing[kind] = ids.deep_dup
          next
        end
        revisions[kind] = snapshot.catalog_revision
        begin
          unless snapshot_binding_valid?(snapshot) && snapshot.entries.count == snapshot.total_items
            CmsProtocol.reject!("metadata_unavailable")
          end
          wanted = ids.index_by { |id| Digest::SHA256.hexdigest(id) }
          found = {}
          snapshot
            .entries
            .where(entry_id_sha256: wanted.keys)
            .find_each(batch_size: PAGE_ITEMS) do |entry|
              payload = entry_payload!(entry)
              unless wanted.fetch(entry.entry_id_sha256) == payload.fetch("id")
                CmsProtocol.reject!("metadata_unavailable")
              end
              found[payload.fetch("id")] = payload.fetch("available")
            end
          ids.each do |id|
            if !found.key?(id)
              missing[kind] << id
            elsif !found.fetch(id)
              unavailable[kind] << id
            end
          end
        rescue CmsProtocol::Error => error
          # A damaged accepted catalog stops publication but must not prevent
          # repairing another kind. Never describe corrupted data as native ID
          # absence or silently replace it with a different catalog/default.
          missing[kind] = []
          unavailable[kind] = []
          errors[kind] = error.code
        end
      end
      SelectionAvailability.new(
        available: errors.empty? && (missing.values + unavailable.values).all?(&:empty?),
        missing_ids: missing,
        unavailable_ids: unavailable,
        catalog_revisions: revisions,
        catalog_errors: errors,
      )
    end

    def self.snapshot_binding_valid?(snapshot)
      upload = snapshot.catalog_upload
      upload && upload.content_connection_id == snapshot.content_connection_id &&
        %w[
          kind
          profile
          publication_lane
          destination_origin
          native_revision
          total_items
        ].all? { |field| upload.public_send(field) == snapshot.public_send(field) }
    end

    # Root must join this to its synchronous connection scope mutation so ABA
    # disable/re-enable/origin/lane changes cannot resurrect cursor/upload state.
    # Accepted metadata and all success receipts are retained for reconciliation.
    def self.invalidate_scope!(connection, clock: -> { Time.current })
      DiscussionBridgeContentConnection.transaction do
        connection.lock!
        at = clock.call
        DiscussionBridgeCmsCatalogUpload.where(content_connection_id: connection.id).update_all(
          expires_at: at,
          invalidated_at: at,
          updated_at: at,
        )
        DiscussionBridgeCmsCatalogCursor
          .joins(:catalog_snapshot)
          .where(discussion_bridge_cms_catalog_snapshots: { content_connection_id: connection.id })
          .update_all(expires_at: at, invalidated_at: at)
      end
    end

    def self.entry_payload!(entry)
      payload = entry.payload
      CmsProtocol.validate!("CatalogEntry", payload)
      unless payload.fetch("id") == entry.entry_id &&
               Digest::SHA256.hexdigest(entry.entry_id) == entry.entry_id_sha256
        CmsProtocol.reject!("metadata_unavailable")
      end
      payload
    rescue CmsProtocol::Error
      CmsProtocol.reject!("metadata_unavailable")
    end

    private

    def now
      Time.at((@clock.call.to_r * 1000).floor / 1000r).utc
    end

    def validate_input!(type, input)
      CmsProtocol.validate!(type, input)
      # The inherited HTTP transport bounds the actual raw UTF-8 request.
      # Reserializing a valid typed tree is not that raw-body measurement.
    end

    def transaction
      DiscussionBridgeContentConnection.transaction do
        @connection.lock!
        if @authenticated_secret_digest &&
             !ActiveSupport::SecurityUtils.secure_compare(
               @connection.secret_digest,
               @authenticated_secret_digest,
             )
          CmsProtocol.reject!("authentication_failed")
        end
        configuration = CmsConfiguration.current!(@connection, required_direction: nil)
        CmsProtocol.validate!("Directions", @connection.allowed_directions)
        yield configuration
      end
    end

    def mutation(route, path, input)
      transaction do |configuration|
        upload = owned_upload!(path) unless path.empty?
        scoped_upload!(upload, configuration) if upload
        keys = {
          content_connection_id: @connection.id,
          route: route,
          path_resource: path,
          mutation_id: input.fetch("mutation_id"),
        }
        if receipt = DiscussionBridgeCmsMutationReceipt.find_by(keys)
          unless CmsReceiptCipher.decrypt(receipt.request_tree) == input
            CmsProtocol.reject!("mutation_conflict")
          end
          body = CmsReceiptCipher.decrypt(receipt.response_body)
          scoped_upload!(owned_upload!(body.fetch("upload_id")), configuration) if path.empty?
          next Result.new(status: receipt.response_status, body: body, change: nil)
        end
        reject_readonly!
        result = yield configuration
        DiscussionBridgeCmsMutationReceipt.create!(
          **keys,
          request_tree: CmsReceiptCipher.encrypt(input),
          response_status: result.status,
          response_body: CmsReceiptCipher.encrypt(result.body),
        )
        result
      end
    rescue ActiveRecord::RecordNotUnique
      CmsProtocol.reject!("catalog_page_conflict")
    end

    def reject_readonly!
      CmsProtocol.reject!("native_service_unavailable") if Discourse.readonly_mode?
    end

    def scope_signature(configuration)
      # Policy/catalog refresh/source eligibility are not catalog authority.
      # Root separately invalidates tokens synchronously on scope revocation.
      Digest::SHA256.hexdigest(
        CmsProtocol.semantic_identity(
          [
            @connection.public_id,
            @connection.platform,
            @connection.allowed_origins,
            @connection.allowed_directions,
            @connection.allowed_lanes,
            configuration.fetch("profile"),
            configuration.fetch("destination_origin"),
            configuration.fetch("publication_lane"),
          ],
        ),
      )
    end

    def owned_upload!(upload_id)
      upload =
        DiscussionBridgeCmsCatalogUpload.find_by(
          content_connection_id: @connection.id,
          upload_id: upload_id,
        )
      CmsProtocol.reject!("resource_not_found") unless upload
      upload
    end

    def scoped_upload!(upload, configuration)
      unless upload.profile == configuration.fetch("profile") &&
               upload.publication_lane == configuration.fetch("publication_lane") &&
               upload.destination_origin == configuration.fetch("destination_origin")
        CmsProtocol.reject!("scope_denied")
      end
    end

    def current_upload!(upload_id, configuration)
      upload = owned_upload!(upload_id)
      upload.lock!
      scoped_upload!(upload, configuration)
      unless upload.scope_signature == scope_signature(configuration)
        CmsProtocol.reject!("scope_denied")
      end
      if upload.invalidated_at || upload.expires_at <= now
        CmsProtocol.reject!("catalog_upload_expired")
      end
      upload
    end

    def upload_payload(upload)
      {
        "upload_id" => upload.upload_id,
        "kind" => upload.kind,
        "native_revision" => upload.native_revision,
        "total_items" => upload.total_items,
        "received_items" => upload.received_items,
        "next_page" => upload.next_page,
        "expires_at" => CmsProtocol.instant(upload.expires_at),
      }
    end

    def ready_for_finalize!(upload)
      count = upload.entries.count
      valid =
        upload.state == "open" && upload.received_items == upload.total_items &&
          count == upload.total_items && upload.pages.count == upload.next_page
      if count.positive?
        valid &&=
          upload.entries.minimum(:ordinal) == 0 && upload.entries.maximum(:ordinal) == count - 1
      end
      if upload.next_page.positive?
        valid &&=
          upload.pages.minimum(:page) == 0 && upload.pages.maximum(:page) == upload.next_page - 1
      end
      valid &&= upload.pages.sum(Arel.sql("jsonb_array_length(entries)")) == upload.total_items
      CmsProtocol.reject!("catalog_page_conflict") unless valid
    end

    def active_snapshot(configuration, kind)
      DiscussionBridgeCmsCatalogSnapshot.find_by(
        content_connection_id: @connection.id,
        kind: kind,
        publication_lane: configuration.fetch("publication_lane"),
        active: true,
      )
    end

    def scoped_snapshot!(snapshot, configuration)
      unless snapshot.content_connection_id == @connection.id &&
               snapshot.profile == configuration.fetch("profile") &&
               snapshot.publication_lane == configuration.fetch("publication_lane") &&
               snapshot.destination_origin == configuration.fetch("destination_origin")
        CmsProtocol.reject!("scope_denied")
      end
      unless self.class.snapshot_binding_valid?(snapshot)
        CmsProtocol.reject!("metadata_unavailable")
      end
    end

    def continuation!(token, kind, configuration)
      cursor =
        DiscussionBridgeCmsCatalogCursor.find_by(token_digest: Digest::SHA256.hexdigest(token))
      CmsProtocol.reject!("cursor_invalid") unless cursor
      snapshot = cursor.catalog_snapshot
      CmsProtocol.reject!("cursor_expired") unless snapshot
      unless snapshot.content_connection_id == @connection.id && snapshot.kind == kind &&
               snapshot.profile == configuration.fetch("profile") &&
               snapshot.publication_lane == configuration.fetch("publication_lane") &&
               snapshot.destination_origin == configuration.fetch("destination_origin") &&
               cursor.scope_signature == scope_signature(configuration)
        CmsProtocol.reject!("cursor_scope_changed")
      end
      CmsProtocol.reject!("cursor_expired") if cursor.invalidated_at || cursor.expires_at <= now
      unless self.class.snapshot_binding_valid?(snapshot)
        CmsProtocol.reject!("metadata_unavailable")
      end
      cursor
    end

    def new_cursor!(snapshot, configuration, position, expires_at)
      token = SecureRandom.urlsafe_base64(32, false)
      cursor =
        DiscussionBridgeCmsCatalogCursor.create!(
          catalog_snapshot: snapshot,
          scope_signature: scope_signature(configuration),
          token_digest: Digest::SHA256.hexdigest(token),
          position: position,
          expires_at: expires_at,
          created_at: now,
        )
      [cursor, token]
    end

    def render_page!(cursor)
      snapshot = cursor.catalog_snapshot
      return response("CatalogResponse", cursor.page_body) if cursor.page_body
      reject_readonly!
      CmsProtocol.reject!("cursor_expired") unless cursor.position.between?(0, snapshot.total_items)
      rows =
        snapshot
          .entries
          .where("ordinal >= ?", cursor.position)
          .order(:ordinal)
          .limit(PAGE_ITEMS)
          .to_a
      expected = [PAGE_ITEMS, snapshot.total_items - cursor.position].min
      unless rows.size == expected &&
               rows.each_with_index.all? { |row, index| row.ordinal == cursor.position + index }
        CmsProtocol.reject!("cursor_expired")
      end
      items = []
      rows.each do |row|
        candidate = items + [self.class.entry_payload!(row)]
        if JSON.generate(catalog_payload(snapshot, candidate, "a" * 43)).bytesize > RESPONSE_BYTES
          CmsProtocol.reject!("metadata_unavailable") if items.empty?
          break
        end
        items = candidate
      end
      position = cursor.position + items.size
      configuration = @connection.cms_configuration
      token =
        (
          if position < snapshot.total_items
            new_cursor!(snapshot, configuration, position, cursor.expires_at).last
          else
            nil
          end
        )
      result = response("CatalogResponse", catalog_payload(snapshot, items, token))
      cursor.update!(page_body: result.body.deep_dup)
      result
    end

    def catalog_payload(snapshot, items, token)
      {
        "kind" => snapshot.kind,
        "catalog_revision" => snapshot.catalog_revision,
        "native_revision" => snapshot.native_revision,
        "total_items" => snapshot.total_items,
        "items" => items,
        "next_cursor" => token,
      }
    end

    def response(type, body, status: 200)
      CmsProtocol.validate!(type, body)
      CmsProtocol.reject!("metadata_unavailable") if JSON.generate(body).bytesize > RESPONSE_BYTES
      Result.new(status: status, body: body.deep_dup, change: nil)
    rescue CmsProtocol::Error
      CmsProtocol.reject!("metadata_unavailable")
    end
  end
end
