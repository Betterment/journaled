# frozen_string_literal: true

module Journaled
  module Outbox
    # Handles metric emission for the Worker and Kinesis senders
    #
    # This class provides utility methods for collecting and emitting metrics.
    class MetricEmitter
      class << self
        # Emit batch processing metrics
        #
        # @param stats [Hash] Processing statistics with :succeeded, :failed_permanently, :failed_transiently
        # @param worker_id [String] ID of the worker processing the batch
        def emit_batch_metrics(stats, worker_id:)
          total_events = stats[:succeeded] + stats[:failed_permanently] + stats[:failed_transiently]

          emit_metric('journaled.worker.batch_process', value: total_events, worker_id:)
          emit_metric('journaled.worker.batch_sent', value: stats[:succeeded], worker_id:)
          emit_metric('journaled.worker.batch_failed_permanently', value: stats[:failed_permanently], worker_id:)
          emit_metric('journaled.worker.batch_failed_transiently', value: stats[:failed_transiently], worker_id:)
        end

        # Collect and emit queue metrics
        #
        # This calculates various queue statistics and emits individual metrics for each.
        # @param worker_id [String] ID of the worker collecting metrics
        def emit_queue_metrics(worker_id:)
          metrics = calculate_queue_metrics

          emit_metric('journaled.worker.queue_total_count', value: metrics[:total_count], worker_id:)
          emit_metric('journaled.worker.queue_workable_count', value: metrics[:workable_count], worker_id:)
          emit_metric('journaled.worker.queue_erroring_count', value: metrics[:erroring_count], worker_id:)
          emit_metric('journaled.worker.queue_oldest_age_seconds', value: metrics[:oldest_age_seconds], worker_id:)

          Rails.logger.info(
            "Queue metrics: total=#{metrics[:total_count]}, " \
            "workable=#{metrics[:workable_count]}, " \
            "erroring=#{metrics[:erroring_count]}, " \
            "oldest_age=#{metrics[:oldest_age_seconds].round(2)}s",
          )
        end

        # Emit a metric notification for a Kinesis send failure
        #
        # @param event [Journaled::Outbox::Event] The failed event
        # @param error_code [String] The error code (e.g., 'ProvisionedThroughputExceededException')
        def emit_kinesis_failure(event:, error_code:)
          emit_metric(
            'journaled.kinesis.send_failure',
            partition_key: event.partition_key,
            error_code:,
            stream_name: event.stream_name,
            event_type: event.event_type,
          )
        end

        private

        # Emit a single metric notification
        #
        # @param event_name [String] The name of the metric event
        # @param payload [Hash] Additional payload data (event_count, value, etc.)
        def emit_metric(event_name, payload)
          ActiveSupport::Notifications.instrument(event_name, payload)
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
end
