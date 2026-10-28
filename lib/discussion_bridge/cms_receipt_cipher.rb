# frozen_string_literal: true

module DiscussionBridge
  # Receipts must replay the original lease response, while lease tokens remain
  # protected at rest. Neither request nor response lease secrets are plain JSON
  # in the database, native metadata, or a public artifact.
  module CmsReceiptCipher
    def self.encrypt(value)
      { "ciphertext" => encryptor.encrypt_and_sign(value) }
    end

    def self.decrypt(value)
      encryptor.decrypt_and_verify(value.fetch("ciphertext"))
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      # Lost or changed protected key material cannot authorize an unsafe
      # replacement mutation or a fabricated replay.
      CmsProtocol.reject!("native_ownership_conflict")
    end

    def self.encryptor
      @encryptor ||= begin
        key = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base).generate_key(
          "discussionbridge-cms-mutation-receipts-1", 32,
        )
        ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm", serializer: JSON)
      end
    end
    private_class_method :encryptor
  end
end
