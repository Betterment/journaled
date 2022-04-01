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

RSpec::Matchers.define :journal_events do |events = {}|
  attr_accessor :expected, :actual

  chain :with_partition_key, :expected_partition_key

  def supports_block_expectations?
    true
  end

  def hash_including_recursive(hash)
    hash_including(
      hash.transform_values { |v| v.is_a?(Hash) ? hash_including_recursive(v) : v },
    )
  end

  match do |block|
    @expected = [events].flatten(1).map { |e| { journaled_attributes: e } }
    @expected.each { |e| e.merge!(journaled_partition_key: expected_partition_key) } if expected_partition_key
    @actual = []

    callback = ->(_name, _started, _finished, _unique_id, payload) do
      a = { journaled_attributes: payload.journaled_attributes }
      a[:journaled_partition_key] = payload.journaled_partition_key if expected_partition_key
      actual << a
    end

    ActiveSupport::Notifications.subscribed(callback, 'journaled.event.enqueue', &block)

    expected.all? { |e| actual.any? { |a| values_match?(hash_including_recursive(e), a) } }
  end

  failure_message do
    <<~MSG
      Expected the code block to emit events consisting of (at least) the following:
      ==============================================================================
        #{expected.map(&:to_json).join("\n ")}
      ==============================================================================

      But instead, the following were emitted:
      ==============================================================================
        #{actual.map(&:to_json).join("\n  ")}
      ==============================================================================
    MSG
  end
end
RSpec::Matchers.alias_matcher :journal_event, :journal_events
RSpec::Matchers.define_negated_matcher :not_journal_events, :journal_events
RSpec::Matchers.define_negated_matcher :not_journal_event, :journal_event
