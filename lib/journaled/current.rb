module Journaled
  class Current < ActiveSupport::CurrentAttributes
    attribute :tags
    attribute :journaled_actor_proc
    attribute :pending_events

    def tags=(value)
      super(value.freeze)
    end

    def tags
      attributes[:tags] ||= {}.freeze
    end

    def pending_events
      attributes[:pending_events] ||= []
    end

    def actor
      journaled_actor_proc&.call
    end
  end
end
