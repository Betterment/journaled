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

RSpec::Matchers.define_negated_matcher :not_journal_changes_to, :journal_changes_to

RSpec::Matchers.define :journal_events do |*events|
  attr_accessor :expected, :actual, :matches, :nonmatches

  chain :with_schema_name, :expected_schema_name
  chain :with_partition_key, :expected_partition_key
  chain :with_stream_name, :expected_stream_name
  chain :with_enqueue_opts, :expected_enqueue_opts
  chain :with_priority, :expected_priority

  def supports_block_expectations?
    true
  end

  def hash_including_recursive(hash)
    hash_including(
      hash.transform_values { |v| v.is_a?(Hash) ? hash_including_recursive(v) : v },
    )
  end

  match do |block|
    events = [events.first || {}].flatten(1) unless events.length > 1
    self.expected = events.map { |e| { journaled_attributes: e } }
    expected.each { |e| e.merge!(journaled_schema_name: expected_schema_name) } if expected_schema_name
    expected.each { |e| e.merge!(journaled_partition_key: expected_partition_key) } if expected_partition_key
    expected.each { |e| e.merge!(journaled_stream_name: expected_stream_name) } if expected_stream_name
    expected.each { |e| e.merge!(journaled_enqueue_opts: expected_enqueue_opts) } if expected_enqueue_opts
    expected.each { |e| e.merge!(priority: expected_priority) } if expected_priority
    self.actual = []

    callback = ->(_name, _started, _finished, _unique_id, payload) do
      event = payload[:event]
      a = { journaled_attributes: event.journaled_attributes }
      a[:journaled_schema_name] = event.journaled_schema_name if expected_schema_name
      a[:journaled_partition_key] = event.journaled_partition_key if expected_partition_key
      a[:journaled_stream_name] = event.journaled_stream_name if expected_stream_name
      a[:journaled_enqueue_opts] = event.journaled_enqueue_opts if expected_enqueue_opts
      a[:priority] = payload[:priority] if expected_priority
      actual << a
    end

    ActiveSupport::Notifications.subscribed(callback, 'journaled.event.enqueue', &block)

    self.matches = actual.select do |a|
      expected.any? { |e| values_match?(hash_including_recursive(e), a) }
    end

    self.nonmatches = actual - matches

    matches.count == expected.count && expected.all? do |e|
      matches.find { |a| values_match?(hash_including_recursive(e), a) }
    end
  end

  failure_message do
    <<~MSG
      Expected the code block to journal exactly one matching event per expected event.

      Expected Events (#{expected.count}):
      ===============================================================================
        #{expected.map(&:to_json).join("\n ")}
      ===============================================================================

      Matching Events (#{matches.count}):
      ===============================================================================
        #{matches.map(&:to_json).join("\n ")}
      ===============================================================================

      Non-Matching Events (#{nonmatches.count}):
      ===============================================================================
        #{nonmatches.map(&:to_json).join("\n  ")}
      ===============================================================================
    MSG
  end
end
RSpec::Matchers.alias_matcher :journal_event, :journal_events
RSpec::Matchers.define_negated_matcher :not_journal_events, :journal_events
RSpec::Matchers.define_negated_matcher :not_journal_event, :journal_event
