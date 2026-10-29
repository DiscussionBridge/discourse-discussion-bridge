# frozen_string_literal: true

require "openssl"
require "tmpdir"
require "fileutils"

# Use Core's real Capybara/Puma/Playwright stack, with a disposable loopback TLS
# certificate. This is browser/controller/SQL evidence, not public-origin proof.
# Production transport and certificate validation are not changed by this file.
module DiscussionBridgeAttentionHttpsSystem
  module Driver
    private

    def register_chrome(name, **options)
      super(name, **options.merge(ignoreHTTPSErrors: true))
    end
  end

  def self.start
    host = Capybara.server_host
    loopback = %w[localhost 127.0.0.1 ::1].include?(host)
    raise "Attention system TLS must remain loopback-only" unless loopback

    @directory = Dir.mktmpdir("discussionbridge-attention-tls-")
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = 1
    certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 86_400
    extensions = OpenSSL::X509::ExtensionFactory.new
    extensions.subject_certificate = certificate
    extensions.issuer_certificate = certificate
    certificate.add_extension(extensions.create_extension("basicConstraints", "CA:FALSE", true))
    certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1,IP:::1"))
    certificate.sign(key, OpenSSL::Digest.new("SHA256"))
    key_path = File.join(@directory, "key.pem")
    certificate_path = File.join(@directory, "certificate.pem")
    File.write(key_path, key.to_pem, mode: "w", perm: 0o600)
    File.write(certificate_path, certificate.to_pem)
    bind_host = host == "::1" ? "[::1]" : host
    query = URI.encode_www_form(key: key_path, cert: certificate_path)
    Capybara.server = :puma, { Host: "ssl://#{bind_host}:#{Capybara.server_port}?#{query}", Silent: true }
    Capybara.app_host = "https://#{bind_host}:#{Capybara.server_port}"
    SystemDrivers.singleton_class.prepend(Driver)
  end

  def self.stop
    FileUtils.remove_entry_secure(@directory) if @directory
  end
end

RSpec.configure do |config|
  config.before(:suite) { DiscussionBridgeAttentionHttpsSystem.start }
  config.after(:suite) { DiscussionBridgeAttentionHttpsSystem.stop }
end
