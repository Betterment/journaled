# frozen_string_literal: true

module Journaled::Actor
  extend ActiveSupport::Concern

  included do
    class_attribute :_journaled_actor_method_name, instance_writer: false
    before_action :_set_journaled_actor_proc, if: :_journaled_actor_method_name?
  end

  private

  def _set_journaled_actor_proc
    Journaled::Current.journaled_actor_proc = -> { send(self.class._journaled_actor_method_name) }
  end

  class_methods do
    def journaled_actor=(method_name)
      raise "Must provide a symbol method name" unless method_name.is_a?(Symbol)

      self._journaled_actor_method_name = method_name
    end
  end
end
