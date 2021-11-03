module Journaled
  class Current < ActiveSupport::CurrentAttributes
    attribute :tags
    attribute :journaled_actor_proc

    def tags=(value)
      super(value.freeze)
    end

    def tags
      attributes[:tags] ||= {}.freeze
    end

    def actor
      journaled_actor_proc&.call
    end
  end
end
