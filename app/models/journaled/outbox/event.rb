# frozen_string_literal: true

module Journaled
  module Outbox
    # ActiveRecord model for Outbox-style event processing
    #
    # This model is only used when the Outbox::Adapter is configured.
    # Events are stored in the database and processed by worker daemons.
    #
    # Successfully delivered events are deleted immediately.
    # Failed events are marked with failed_at and can be queried or requeued.
    class Event < Journaled.outbox_base_class_name.constantize
      self.table_name = 'journaled_outbox_events'

      skip_audit_log

      attribute :event_data, :json

      validates :event_type, :event_data, :partition_key, :stream_name, presence: true

      scope :ready_to_process, -> {
        where(failed_at: nil)
          .order(:id)
      }

      scope :failed, -> { where.not(failed_at: nil) }
      scope :failed_since, ->(time) { where('failed_at >= ?', time) }

      # Fetch a batch of events for processing using SELECT FOR UPDATE
      #
      # @return [Array<Journaled::Outbox::Event>] Events locked for processing
      def self.fetch_batch_for_update
        ready_to_process
          .limit(Journaled.worker_batch_size)
          .lock('FOR UPDATE')
          .to_a
      end

      # Requeue a failed event for processing
      #
      # Clears failure information so the event can be retried.
      #
      # @return [Boolean] Whether the requeue was successful
      def requeue!
        update!(
          failed_at: nil,
          failure_reason: nil,
        )
      end

      # Extract timestamp from UUID v7 id
      #
      # UUID v7 embeds a timestamp in the first 48 bits (milliseconds since Unix epoch)
      #
      # @return [Time] The timestamp embedded in the UUID
      def self.timestamp_from_uuid(uuid)
        # Remove dashes and take first 12 hex characters (48 bits)
        hex_timestamp = uuid.to_s.delete('-')[0, 12]
        # Convert from hex to milliseconds since epoch
        milliseconds = hex_timestamp.to_i(16)
        # Convert to Time object
        Time.zone.at(milliseconds / 1000.0)
      end

      # Get the oldest non-failed event's timestamp
      #
      # @return [Time, nil] The timestamp of the oldest event, or nil if no events exist
      def self.oldest_non_failed_timestamp
        oldest = ready_to_process.order(:id).limit(1).pick(:id)
        return nil unless oldest

        timestamp_from_uuid(oldest)
      end
    end
  end
end
