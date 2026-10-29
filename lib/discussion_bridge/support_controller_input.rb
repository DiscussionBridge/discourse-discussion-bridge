# frozen_string_literal: true

module DiscussionBridge
  module SupportControllerInput
    def self.included(base)
      base.rescue_from SupportWorkflow::Error do |error|
        response.headers["Cache-Control"] = "no-store"
        render json: { errors: [error.message] }, status: error.status
      end
      base.rescue_from CmsProtocol::Error do |error|
        definition = CmsProtocol::ERRORS.fetch(error.code)
        response.headers["Cache-Control"] = "no-store"
        render json: { errors: ["The current native action was rejected (#{error.code}). Refresh before retrying."] }, status: definition.fetch("http")
      end
      base.rescue_from ArgumentError do
        render json: { errors: ["A valid native account, connection or topic identity is required."] }, status: :unprocessable_content
      end
    end

    private

    def support_input
      raise SupportWorkflow::Error, "Query fields are not accepted for support actions." unless request.query_string.empty?
      encoding = request.headers["Content-Encoding"]
      unless encoding.nil? || encoding == "identity"
        raise SupportWorkflow::Error, "An uncompressed JSON request is required."
      end
      raw = request.body.read(65_537).to_s
      request.body.rewind
      return {} if request.delete? && raw.empty?
      unless request.headers["Content-Type"].to_s.match?(%r{\Aapplication/json(?:\s*;\s*charset\s*=\s*(?:UTF-8|"UTF-8"))?\z}i)
        raise SupportWorkflow::Error, "A JSON request is required."
      end
      CmsProtocol.parse_json(raw)
    end

    def support_envelope(name, fields)
      input = support_input
      unless input.keys == [name] && input[name].is_a?(Hash) && input[name].keys.sort == fields.sort
        raise SupportWorkflow::Error, "Only the displayed support action fields are accepted."
      end
      input.fetch(name)
    end

    def support_json(body, status: 200)
      response.headers["Cache-Control"] = "no-store"
      render json: body, status: status
    end
  end
end
