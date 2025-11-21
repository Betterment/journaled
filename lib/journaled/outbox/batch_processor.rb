# frozen_string_literal: true

module Journaled
  module Outbox
    # Processes batches of outbox events
    #
    # This class handles the core business logic of:
    # - Fetching events from the database (with FOR UPDATE)
    # - Sending them to Kinesis (batch API or sequential)
    # - Handling successful deliveries (deleting events)
    # - Handling permanent failures (marking with failed_at)
    # - Handling transient failures (leaving unlocked for retry)
    #
    # Supports two modes based on Journaled.outbox_processing_mode:
    # - :batch - Uses put_records API for high throughput with parallel workers
    # - :guaranteed_order - Uses put_record API for sequential processing
    #
    # All operations happen within a single database transaction for consistency.
    # The Worker class delegates to this for actual event processing.
    class BatchProcessor
      def initialize
        @batch_sender = if Journaled.outbox_processing_mode == :guaranteed_order
          KinesisSequentialSender.new
        else
          KinesisBatchSender.new
        end
      end

      # Process a single batch of events
      #
      # Wraps the entire batch processing in a single transaction:
      # 1. SELECT FOR UPDATE (claim events)
      # 2. Send to Kinesis (batch API or sequential, based on mode)
      # 3. Delete successful events
      # 4. Mark permanently failed events
      # 5. Leave transient failures untouched (will be retried)
      #
      # @return [Hash] Statistics with :succeeded, :failed_permanently, :failed_transiently counts
      def process_batch
        ActiveRecord::Base.transaction do
          events = Event.fetch_batch_for_update
          Rails.logger.info("[journaled] Processing batch of #{events.count} events")

          result = batch_sender.send_batch(events)

          # Delete successful events
          Event.where(id: result[:succeeded].map(&:id)).delete_all if result[:succeeded].any?

          # Separate permanent and transient failures
          permanent_failures = result[:failed].select(&:permanent?)
          transient_failures = result[:failed].select(&:transient?)

          # Mark only permanently failed events
          mark_events_as_failed(permanent_failures) if permanent_failures.any?

          # Transient failures are left untouched - they'll be retried in the next batch

          Rails.logger.info(
            "[journaled] Batch complete: #{result[:succeeded].count} succeeded, " \
            "#{permanent_failures.count} permanently failed, " \
            "#{transient_failures.count} transiently failed (will retry) " \
            "(batch size: #{events.count})",
          )

          {
            succeeded: result[:succeeded].count,
            failed_permanently: permanent_failures.count,
            failed_transiently: transient_failures.count,
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
