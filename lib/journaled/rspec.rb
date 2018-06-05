require 'rspec/expectations'

RSpec::Matchers.define :journal_changes_to do |*attribute_names, as:|
  match do |model_class|
    model_class._journaled_change_definitions.any? do |change_definition|
      change_definition.logical_operation == as &&
        attribute_names.map(&:to_s).sort == change_definition.attribute_names.sort
    end
  end

  failure_message do |model_class|
    "expected #{model_class} to journal changes to #{attribute_names.map(&:inspect).join(', ')} as #{as.inspect}"
  end

  failure_message_when_negated do |model_class|
    "expected #{model_class} not to journal changes to #{attribute_names.map(&:inspect).join(', ')} as #{as.inspect}"
  end
end
