# frozen_string_literal: true

module Journaled
  module DeliveryAdapters
    # Default delivery adapter that uses ActiveJob
    #
    # This adapter enqueues events to Journaled::DeliveryJob which
    # sends them to Kinesis. This is the default behavior and maintains
    # backward compatibility with previous versions of the gem.
    class ActiveJobAdapter < Journaled::DeliveryAdapter
      # Delivers events by enqueueing them to Journaled::DeliveryJob
      #
      # @param events [Array] Array of journaled events to deliver
      # @param enqueue_opts [Hash] Options for ActiveJob (priority, queue, wait, wait_until, etc.)
      # @return [void]
      def self.deliver(events:, enqueue_opts:)
        Journaled::DeliveryJob.set(enqueue_opts).perform_later(*delivery_perform_args(events))
      end

      # Serializes events into the format expected by DeliveryJob
      #
      # @param events [Array] Array of journaled events
      # @return [Array<Hash>] Array of serialized event hashes
      def self.delivery_perform_args(events)
        events.map do |event|
          {
            serialized_event: event.journaled_attributes.to_json,
            partition_key: event.journaled_partition_key,
            stream_name: event.journaled_stream_name,
          }
        end
      end

      # Returns the database connection to use for transactional batching
      #
      # This is determined by the configured queue adapter, since ActiveJob
      # enqueues jobs to the same database that should be used for transactions.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter] The connection to use
      def self.transaction_connection
        queue_adapter = Journaled.queue_adapter

        if queue_adapter.in? %w(delayed delayed_job)
          Delayed::Job.connection
        elsif queue_adapter == 'good_job'
          GoodJob::BaseRecord.connection
        elsif queue_adapter == 'que'
          Que::ActiveRecord::Model.connection
        elsif queue_adapter == 'test' && Rails.env.test?
          ActiveRecord::Base.connection
        else
          raise "Unsupported queue adapter: #{queue_adapter}"
        end
      end

      # Validates that a supported queue adapter is configured
      #
      # @return [void]
      def self.validate_configuration!
        unless Journaled::SUPPORTED_QUEUE_ADAPTERS.include?(Journaled.queue_adapter)
          raise <<~MSG
            Journaled has detected an unsupported ActiveJob queue adapter: `:#{Journaled.queue_adapter}`

            Journaled jobs must be enqueued transactionally to your primary database.

            Please install the appropriate gems and set `queue_adapter` to one of the following:
            #{Journaled::SUPPORTED_QUEUE_ADAPTERS.map { |a| "- `:#{a}`" }.join("\n")}

            Read more at https://github.com/Betterment/journaled
          MSG
        end
      end
    end
  end
end
