# frozen_string_literal: true

module Journaled
  module Outbox
    # Outbox-style delivery adapter for custom event processing
    #
    # This adapter stores events in a database table instead of enqueuing to ActiveJob.
    # Events are processed by separate worker daemons that poll the database.
    #
    # Setup:
    # 1. Generate migrations: rails generate journaled:database_events
    # 2. Run migrations: rails db:migrate
    # 3. Configure: Journaled.delivery_adapter = Journaled::Outbox::Adapter
    # 4. Start workers: bundle exec rake journaled_worker:work
    class Adapter < Journaled::DeliveryAdapter
      class TableNotFoundError < StandardError; end

      # Delivers events by inserting them into the database
      #
      # @param events [Array] Array of journaled events to deliver
      # @param ** [Hash] Additional options (ignored, for interface compatibility)
      # @return [void]
      def self.deliver(events:, **)
        return unless Journaled.enabled?

        check_table_exists!

        records = events.map do |event|
          # Exclude the application-level id - the database will generate its own using uuid_generate_v7()
          event_data = event.journaled_attributes.except(:id)

          {
            event_type: event.journaled_attributes[:event_type],
            event_data:,
            partition_key: event.journaled_partition_key,
            stream_name: event.journaled_stream_name,
          }
        end

        # rubocop:disable Rails/SkipsModelValidations
        Event.insert_all(records) if records.any?
        # rubocop:enable Rails/SkipsModelValidations
      end

      # Check if the required database table exists
      #
      # @raise [TableNotFoundError] if the table doesn't exist
      def self.check_table_exists!
        return if @table_exists

        unless Event.table_exists?
          raise TableNotFoundError, <<~ERROR
            Journaled::Outbox::Adapter requires the 'journaled_outbox_events' table.

            To create the required tables, run:

              rake journaled:install:migrations
              rails db:migrate

            For more information, see the README:
            https://github.com/Betterment/journaled#outbox-style-event-processing-optional
          ERROR
        end

        @table_exists = true
      end

      # Returns the database connection to use for transactional batching
      #
      # The Outbox adapter uses the same database as the Outbox events table,
      # since events are staged in memory and then written to journaled_events
      # within the same transaction.
      #
      # @return [ActiveRecord::ConnectionAdapters::AbstractAdapter] The connection to use
      def self.transaction_connection
        Event.connection
      end

      # Validates that PostgreSQL is being used
      #
      # The Outbox adapter requires PostgreSQL for UUID v7 support and row-level locking
      #
      # @raise [StandardError] if the database adapter is not PostgreSQL
      def self.validate_configuration!
        return if Event.connection.adapter_name == 'PostgreSQL'

        raise <<~ERROR
          Journaled::Outbox::Adapter requires PostgreSQL database adapter.

          Current adapter: #{Event.connection.adapter_name}

          The Outbox pattern uses PostgreSQL-specific features like UUID v7 generation
          and row-level locking for distributed worker coordination. Other databases are not supported.
        ERROR
      end
    end
  end
end
