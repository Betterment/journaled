module Journaled::Actor
  extend ActiveSupport::Concern

  included do
    class_attribute :_journaled_actor_method_name, instance_accessor: false, instance_predicate: false
    before_action do
      RequestStore.store[:journaled_actor_proc] = self.class._journaled_actor_method_name &&
        -> { send(self.class._journaled_actor_method_name) }
    end
  end

  class_methods do
    def journaled_actor=(method_name)
      raise "Must provide a symbol method name" unless method_name.is_a?(Symbol)

      self._journaled_actor_method_name = method_name
    end
  end
end
