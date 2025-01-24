# frozen_string_literal: true

module Journaled::Changes
  extend ActiveSupport::Concern

  included do
    cattr_accessor(:_journaled_change_definitions) { [] }
    cattr_accessor(:journaled_attribute_names) { [] }
    cattr_accessor(:journaled_enqueue_opts, instance_writer: false) { {} }

    after_create do
      self.class._journaled_change_definitions.each do |definition|
        Journaled::ChangeWriter.new(model: self, change_definition: definition).create
      end
    end

    after_save unless: :saved_change_to_id? do
      self.class._journaled_change_definitions.each do |definition|
        Journaled::ChangeWriter.new(model: self, change_definition: definition).update
      end
    end

    after_destroy do
      self.class._journaled_change_definitions.each do |definition|
        Journaled::ChangeWriter.new(model: self, change_definition: definition).delete
      end
    end
  end

  def delete(force: false)
    if force || self.class.journaled_attribute_names.empty?
      super()
    else
      raise(<<~ERROR)
        #delete aborted by Journaled::Changes.

        Call #destroy instead to ensure journaling or invoke #delete(force: true)
        to override and skip journaling.
      ERROR
    end
  end

  def update_columns(attributes, opts = { force: false })
    unless opts[:force] || self.class.journaled_attribute_names.empty?
      conflicting_journaled_attribute_names = self.class.journaled_attribute_names & attributes.keys.map(&:to_sym)
      raise(<<~ERROR) if conflicting_journaled_attribute_names.present?
        #update_columns aborted by Journaled::Changes due to journaled attributes:

          #{conflicting_journaled_attribute_names.join(', ')}

        Call #update instead to ensure journaling or invoke #update_columns
        with additional arg `{ force: true }` to override and skip journaling.
      ERROR
    end
    super(attributes)
  end

  class_methods do
    def journal_changes_to(*attribute_names, as:, enqueue_with: {})
      if attribute_names.empty? || attribute_names.any? { |n| !n.is_a?(Symbol) }
        raise "one or more symbol attribute_name arguments is required"
      end

      raise "as: must be a symbol" unless as.is_a?(Symbol)

      _journaled_change_definitions << Journaled::ChangeDefinition.new(attribute_names: attribute_names, logical_operation: as)
      journaled_attribute_names.concat(attribute_names)
      journaled_enqueue_opts.merge!(enqueue_with)
    end

    def delete(id_or_array, opts = { force: false })
      if opts[:force] || journaled_attribute_names.empty?
        where(primary_key => id_or_array).delete_all(force: true)
      else
        raise(<<~ERROR)
          .delete aborted by Journaled::Changes.

          Call .destroy(id_or_array) instead to ensure journaling or invoke
          .delete(id_or_array, force: true) to override and skip journaling.
        ERROR
      end
    end
  end
end
