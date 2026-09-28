# frozen_string_literal: true

module DiscussionBridge
  module NetworkSecret
    PURPOSE = "discussion-bridge-network-peer-secret-v1"
    MINIMUM_BYTES = 32
    MAXIMUM_BYTES = 256

    def self.encrypt(value)
      validate!(value)
      encryptor.encrypt_and_sign(value, purpose: PURPOSE)
    end

    def self.decrypt(value)
      secret = encryptor.decrypt_and_verify(value, purpose: PURPOSE)
      validate!(secret)
      secret
    rescue ActiveSupport::MessageEncryptor::InvalidMessage
      raise AdapterRequestBoundary::Error, "authentication_failed"
    end

    def self.encryptor
      key = Rails.application.key_generator.generate_key(PURPOSE, 32)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
    private_class_method :encryptor

    def self.validate!(value)
      valid = value.is_a?(String) && value.valid_encoding? &&
        value.bytesize.between?(MINIMUM_BYTES, MAXIMUM_BYTES)
      raise ArgumentError, "invalid network peer secret" unless valid
    end
    private_class_method :validate!
  end
end
