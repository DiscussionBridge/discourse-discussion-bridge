# frozen_string_literal: true

module DiscussionBridge
  class EmbedRoutesController < ::ApplicationController
    requires_plugin DiscussionBridge::PLUGIN_NAME
    skip_before_action :check_xhr
    skip_before_action :redirect_to_login_if_required

    def show
      attestation = EmbedRouteAttestation.verify(params[:token])
      raise Discourse::NotFound unless attestation
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_enabled
      raise Discourse::NotFound unless SiteSetting.discussion_bridge_comments_only_full_interactive
      raise Discourse::NotFound unless SiteSetting.embed_full_app
      raise Discourse::NotFound unless SiteSetting.embed_full_app_signin_flow

      topic = Topic.find_by(id: attestation[:mapping].topic_id)
      raise Discourse::NotFound unless topic && guardian.can_see?(topic)

      query = {
        embed_mode: true,
        class_name: attestation[:class_name],
        discussion_bridge_embed_token: params[:token],
      }
      response.headers.delete("X-Frame-Options")
      response.headers["Cache-Control"] = "no-store"
      redirect_to "#{topic.url}?#{query.to_query}"
    end
  end
end
