# frozen_string_literal: true

module Journaled
  # Base class for delivery adapters
  #
  # Journaled ships with two delivery adapters:
  #   - Journaled::DeliveryAdapters::ActiveJobAdapter (default) - delivers via ActiveJob
  #   - Journaled::Outbox::Adapter - delivers via Outbox-style workers
  #
  class DeliveryAdapter
    # Delivers a batch of events
    #
    # @param events [Array] Array of journaled events to deliver
    # @param enqueue_opts [Hash] Options for delivery (priority, queue, wait, wait_until, etc.)
    # @return [void]
    def self.deliver(events:, enqueue_opts:) # rubocop:disable Lint/UnusedMethodArgument
      raise NoMethodError, "#{name} must implement .deliver(events:, enqueue_opts:)"
    end

    # Returns the database connection to use for transactional batching
    #
    # This allows delivery adapters to specify which database connection should be used
    # when staging events during a transaction. This is only needed if you want to support
    # transactional batching with your adapter.
    #
    # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter]
    def self.transaction_connection
      raise NoMethodError, "#{name} must implement .transaction_connection"
    end

    # Validates that the adapter is properly configured
    #
    # Called during Rails initialization in production mode. Raise an error if the adapter
    # is not configured correctly (e.g., missing required dependencies, invalid configuration).
    #
    # @return [void]
    def self.validate_configuration!
      # Default: no validation required
    end
  end
end
