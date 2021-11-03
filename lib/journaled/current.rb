require 'request_store'

module Journaled
  module Current
    def self.tags
      RequestStore.store[:journaled_tags] ||= {}.freeze
    end

    def self.tags=(value)
      RequestStore.store[:journaled_tags] = value.freeze
    end

    def self.actor
      RequestStore.store[:journaled_actor_proc]&.call
    end
  end
end
