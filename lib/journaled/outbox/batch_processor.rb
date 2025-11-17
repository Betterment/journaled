# frozen_string_literal: true

module Journaled
  module Outbox
    # Processes batches of outbox events
    #
    # This class handles the core business logic of:
    # - Fetching events from the database (with FOR UPDATE)
    # - Sending them to Kinesis one at a time to guarantee ordering
    # - Handling successful deliveries (deleting events)
    # - Handling permanent failures (marking with failed_at)
    # - Handling ephemeral failures (stopping processing and committing)
    #
    # Events are processed one at a time to guarantee ordering. If an event fails
    # with an ephemeral error, processing stops and the transaction commits
    # (deleting successes and marking permanent failures), then the loop re-enters.
    #
    # All operations happen within a single database transaction for consistency.
    # The Worker class delegates to this for actual event processing.
    class BatchProcessor
      def initialize
        @batch_sender = KinesisBatchSender.new
      end

      # Process a single batch of events
      #
      # Wraps the entire batch processing in a single transaction:
      # 1. SELECT FOR UPDATE (claim events)
      # 2. Send to Kinesis (batch sender handles one-at-a-time and short-circuiting)
      # 3. Delete successful events
      # 4. Mark failed events (batch sender only returns permanent failures)
      #
      # @return [Hash] Statistics with :succeeded, :failed_permanently counts
      def process_batch
        ActiveRecord::Base.transaction do
          events = Event.fetch_batch_for_update
          Rails.logger.info("[journaled] Processing batch of #{events.count} events")

          result = batch_sender.send_batch(events)

          # Delete successful events
          Event.where(id: result[:succeeded].map(&:id)).delete_all if result[:succeeded].any?

          # Mark failed events
          mark_events_as_failed(result[:failed]) if result[:failed].any?

          Rails.logger.info(
            "[journaled] Batch complete: #{result[:succeeded].count} succeeded, " \
            "#{result[:failed].count} marked as failed (batch size: #{events.count})",
          )

          {
            succeeded: result[:succeeded].count,
            failed_permanently: result[:failed].count,
          }
        end
      end

      private

      attr_reader :batch_sender

      # Mark events as permanently failed
      # Sets: failed_at = NOW, failure_reason = per-event message
      def mark_events_as_failed(failed_events)
        now = Time.current

        records = failed_events.map do |failed_event|
          failed_event.event.attributes.except('created_at').merge(
            failed_at: now,
            failure_reason: "#{failed_event.error_code}: #{failed_event.error_message}",
          )
        end

        # rubocop:disable Rails/SkipsModelValidations
        Event.upsert_all(
          records,
          unique_by: :id,
          on_duplicate: :update,
          update_only: %i(failed_at failure_reason),
        )
        # rubocop:enable Rails/SkipsModelValidations
      end
    end
  end
end
