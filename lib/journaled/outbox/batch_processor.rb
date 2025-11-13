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
          Rails.logger.info("Processing batch of #{events.count} events")

          result = batch_sender.send_batch(events)

          # Delete successful events
          Event.where(id: result[:succeeded].map(&:id)).delete_all if result[:succeeded].any?

          # Mark failed events
          mark_events_as_failed(result[:failed]) if result[:failed].any?

          Rails.logger.info(
            "Batch complete: #{result[:succeeded].count} succeeded, " \
            "#{result[:failed].count} marked as failed",
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
        ids = failed_events.map { |f| f.event.id }
        case_statement = build_error_case_statement(failed_events)

        # rubocop:disable Rails/SkipsModelValidations
        Event.where(id: ids).update_all(
          "failed_at = '#{Time.current.to_fs(:db)}', failure_reason = #{case_statement}",
        )
        # rubocop:enable Rails/SkipsModelValidations
      end

      # Build a SQL CASE statement to set per-event error messages
      # Returns: "CASE WHEN id = 'uuid1' THEN 'error1' WHEN id = 'uuid2' THEN 'error2' END"
      def build_error_case_statement(failed_events)
        connection = Event.connection
        cases = failed_events.map do |failed_event|
          error_message = "#{failed_event.error_code}: #{failed_event.error_message}"
          sanitized_id = connection.quote(failed_event.event.id)
          sanitized_error = connection.quote(error_message)
          "WHEN id = #{sanitized_id} THEN #{sanitized_error}"
        end

        "CASE #{cases.join(' ')} END"
      end
    end
  end
end
