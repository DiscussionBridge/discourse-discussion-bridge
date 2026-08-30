# frozen_string_literal: true

require "erb"

module DiscussionBridge
  module SourceAuthorship
    Result = Data.define(:allowed?, :reason, :author, :source_authors, :primary_source_author_id)

    def self.resolve(connection:, request:)
      authors = Array(request[:source_authors])
      primary_id = request[:primary_source_author_id]
      return allowed(connection.effective_author, authors, primary_id) if authors.empty? || connection.authorship_mode == "fixed"

      primary = authors.find { |author| author.fetch("id") == primary_id }
      return denied("primary_source_author_missing", authors, primary_id) unless primary

      source_author = connection.source_authors.find_by(source_author_id: primary_id)
      mapped_user = usable_user(source_author&.discourse_user)
      return allowed(mapped_user, authors, primary_id) if mapped_user
      return denied("source_author_unmapped", authors, primary_id) if connection.unmapped_author_policy == "hold"

      allowed(connection.effective_author, authors, primary_id)
    end

    def self.observe!(connection:, source_authors:)
      Array(source_authors).each do |attributes|
        profile_url = attributes["profile_url"]
        if profile_url.present? && !connection.allows_origin?(profile_url)
          raise ArgumentError, "source author profile origin is outside the Content Connection"
        end

        source_author = connection.source_authors.lock.find_or_initialize_by(
          source_author_id: attributes.fetch("id"),
        )
        source_author.display_name = attributes.fetch("name")
        source_author.profile_url = profile_url
        source_author.last_seen_at = Time.zone.now
        source_author.save!
      end
    end

    def self.credit_html(source_authors)
      authors = Array(source_authors)
      return nil if authors.empty?

      label = authors.one? ? "Source author" : "Source authors"
      credits = authors.map do |author|
        name = ERB::Util.html_escape(author.fetch("name"))
        url = author["profile_url"]
        if url.present?
          %(<a href="#{ERB::Util.html_escape(url)}" rel="noopener noreferrer">#{name}</a>)
        else
          name
        end
      end.join(", ")
      %(<div class="discussion-bridge-source-authors"><strong>#{label}:</strong> #{credits}</div>)
    end

    def self.allowed(author, authors, primary_id)
      return denied("invalid_author", authors, primary_id) unless usable_user(author)

      Result.new(
        allowed?: true,
        reason: "author_resolved",
        author: author,
        source_authors: authors,
        primary_source_author_id: primary_id,
      )
    end
    private_class_method :allowed

    def self.denied(reason, authors, primary_id)
      Result.new(
        allowed?: false,
        reason: reason,
        author: nil,
        source_authors: authors,
        primary_source_author_id: primary_id,
      )
    end
    private_class_method :denied

    def self.usable_user(user)
      return unless user&.active? && !user.staged? && !user.suspended? && !user.silenced?
      return if user.id == Discourse::SYSTEM_USER_ID

      user
    end
    private_class_method :usable_user
  end
end
