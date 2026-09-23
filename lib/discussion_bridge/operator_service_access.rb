# frozen_string_literal: true

module DiscussionBridge
  class OperatorServiceAccess
    def self.service
      DiscussionBridgeOperatorService.instance
    end

    def self.view?(user, now: Time.zone.now)
      user&.staff? || service.view_allowed?(user, now: now)
    end

    def self.mutate?(user, now: Time.zone.now)
      user&.staff? || service.mutation_allowed?(user, now: now)
    end

    def self.admin?(user)
      user&.admin?
    end
  end
end
