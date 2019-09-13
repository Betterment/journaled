class Journaled::ChangeWriter
  attr_reader :model, :change_definition
  delegate :attribute_names, :logical_operation, to: :change_definition

  def initialize(model:, change_definition:)
    @model = model
    @change_definition = change_definition
    change_definition.validate!(model) unless change_definition.validated?
  end

  def create
    journaled_change_for("create", relevant_attributes).journal!
  end

  def update
    journaled_change_for("update", relevant_changed_attributes).journal! if relevant_changed_attributes.present?
  end

  def delete
    journaled_change_for("delete", relevant_unperturbed_attributes).journal!
  end

  def journaled_change_for(database_operation, changes)
    Journaled::Change.new(
      table_name: model.class.table_name,
      record_id: model.id.to_s,
      database_operation: database_operation,
      logical_operation: logical_operation,
      changes: JSON.dump(changes),
      journaled_app_name: journaled_app_name,
      actor: actor_uri,
    )
  end

  def relevant_attributes
    model.attributes.slice(*attribute_names)
  end

  def relevant_unperturbed_attributes
    model.attributes.merge(pluck_changed_values(model.changes, index: 0)).slice(*attribute_names)
  end

  def relevant_changed_attributes
    pluck_changed_values(model.saved_changes.slice(*attribute_names), index: 1)
  end

  def actor_uri
    @actor_uri ||= Journaled.actor_uri
  end

  private

  def pluck_changed_values(change_hash, index:)
    change_hash.each_with_object({}) do |(k, v), result|
      result[k] = v[index]
    end
  end

  def journaled_app_name
    if model.class.respond_to?(:journaled_app_name)
      model.class.journaled_app_name
    else
      Journaled.default_app_name
    end
  end
end
