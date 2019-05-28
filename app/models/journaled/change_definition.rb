class Journaled::ChangeDefinition
  attr_reader :attribute_names, :logical_operation

  def initialize(attribute_names:, logical_operation:)
    @attribute_names = attribute_names.map(&:to_s)
    @logical_operation = logical_operation
    @validated = false
  end

  def validated?
    @validated
  end

  def validate!(model)
    nonexistent_attribute_names = attribute_names - model.class.attribute_names
    raise <<~ERROR if nonexistent_attribute_names.present?
      Unable to persist #{model} because `journal_changes_to, as: #{logical_operation.inspect}`
      includes nonexistant attributes:

        #{nonexistent_attribute_names.join(', ')}
    ERROR

    @validated = true
  end
end
