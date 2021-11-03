require 'request_store'

module Journaled
  module Current
    def self.tags
      Thread.current[:journaled_tags] ||= {}.freeze
    end

    def self.tags=(value)
      Thread.current[:journaled_tags] = value.freeze
    end

    def self.actor
      RequestStore.store[:journaled_actor_proc]&.call
    end
  end
end
