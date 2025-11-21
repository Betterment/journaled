# frozen_string_literal: true

module Journaled
  module Outbox
    # Handles metric emission for the Worker
    #
    # This class is responsible for collecting and emitting metrics about the outbox queue.
    class MetricEmitter
      def initialize(worker_id:)
        @worker_id = worker_id
      end

      # Emit batch processing metrics
      #
      # @param stats [Hash] Processing statistics with :succeeded, :failed_permanently, :failed_transiently
      def emit_batch_metrics(stats)
        total_events = stats[:succeeded] + stats[:failed_permanently] + stats[:failed_transiently]

        emit_metric('journaled.worker.batch_process', value: total_events)
        emit_metric('journaled.worker.batch_sent', value: stats[:succeeded])
        emit_metric('journaled.worker.batch_failed_permanently', value: stats[:failed_permanently])
        emit_metric('journaled.worker.batch_failed_transiently', value: stats[:failed_transiently])
      end

      # Collect and emit queue metrics
      #
      # This calculates various queue statistics and emits individual metrics for each.
      def emit_queue_metrics
        metrics = calculate_queue_metrics

        emit_metric('journaled.worker.queue_total_count', value: metrics[:total_count])
        emit_metric('journaled.worker.queue_workable_count', value: metrics[:workable_count])
        emit_metric('journaled.worker.queue_erroring_count', value: metrics[:erroring_count])
        emit_metric('journaled.worker.queue_oldest_age_seconds', value: metrics[:oldest_age_seconds])

        Rails.logger.info(
          "Queue metrics: total=#{metrics[:total_count]}, " \
          "workable=#{metrics[:workable_count]}, " \
          "erroring=#{metrics[:erroring_count]}, " \
          "oldest_age=#{metrics[:oldest_age_seconds].round(2)}s",
        )
      end

      private

      attr_reader :worker_id

      # Emit a single metric notification
      #
      # @param event_name [String] The name of the metric event
      # @param payload [Hash] Additional payload data (event_count, value, etc.)
      def emit_metric(event_name, payload)
        ActiveSupport::Notifications.instrument(
          event_name,
          payload.merge(worker_id:),
        )
      end

      # Calculate queue metrics
      #
      # @return [Hash] Metrics including counts and oldest event timestamp
      def calculate_queue_metrics
        # Use a single query with COUNT(*) FILTER to calculate all counts in one table scan
        result = Event.connection.select_one(
          Event.select(
            'COUNT(*) AS total_count',
            'COUNT(*) FILTER (WHERE failed_at IS NULL) AS workable_count',
            'COUNT(*) FILTER (WHERE failure_reason IS NOT NULL AND failed_at IS NULL) AS erroring_count',
            'MIN(created_at) FILTER (WHERE failed_at IS NULL) AS oldest_non_failed_timestamp',
          ).to_sql,
        )

        oldest_timestamp = result['oldest_non_failed_timestamp']
        oldest_age_seconds = oldest_timestamp ? Time.current - oldest_timestamp : 0

        {
          total_count: result['total_count'],
          workable_count: result['workable_count'],
          erroring_count: result['erroring_count'],
          oldest_age_seconds:,
        }
      end
    end
  end
end
