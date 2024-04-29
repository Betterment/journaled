# frozen_string_literal: true

rails_env = ENV['RAILS_ENV'] ||= 'test'
require 'uncruft'
require 'active_support/testing/time_helpers'

require File.expand_path('dummy/config/environment.rb', __dir__)

Rails.configuration.database_configuration[rails_env].tap do |c|
  ActiveRecord::Tasks::DatabaseTasks.create(c)
  ActiveRecord::Base.establish_connection(c)
  load File.expand_path('dummy/db/schema.rb', __dir__)
end

RSpec::Matchers.define_negated_matcher :not_change, :change
RSpec::Matchers.define_negated_matcher :not_raise_error, :raise_error

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.order = :random
end

RSpec::Matchers.define :emit_notification do |expected_event_name|
  attr_reader :actual, :expected

  def supports_block_expectations?
    true
  end

  chain :with_payload, :expected_payload
  chain :with_value, :expected_value
  diffable

  match do |block|
    @expected = { event_name: expected_event_name, payload: expected_payload, value: expected_value }
    @actuals = []
    callback = ->(name, _started, _finished, _unique_id, payload) do
      @actuals << { event_name: name, payload: payload.except(:value), value: payload[:value] }
    end

    ActiveSupport::Notifications.subscribed(callback, expected_event_name, &block)

    unless expected_payload
      @actuals.each { |a| a.delete(:payload) }
      @expected.delete(:payload)
    end

    @actual = @actuals.select { |a| values_match?(@expected.except(:value), a.except(:value)) }
    @expected = [@expected]
    values_match?(@expected, @actual)
  end

  failure_message do
    <<~MSG
      Expected the code block to emit:
        #{@expected.first.inspect}

      But instead, the following were emitted:
        #{(@actual.presence || @actuals).map(&:inspect).join("\n  ")}
    MSG
  end
end
