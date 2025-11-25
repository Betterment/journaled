# frozen_string_literal: true

module Journaled
  # Sends batches of events to Kinesis using the PutRecords batch API
  #
  # This class handles:
  # - Sending events in batches to improve throughput
  # - Handling failures on a per-event basis
  # - Classifying errors as transient vs permanent
  #
  # Returns structured results for the caller to handle event state management.
  class KinesisBatchSender
    # Per-record error codes that indicate permanent failures (bad event data)
    PERMANENT_ERROR_CODES = [
      'ValidationException',
    ].freeze

    # Send a batch of database events to Kinesis
    #
    # Uses put_records batch API. Groups events by stream and sends each group as a batch.
    #
    # @param events [Array<Journaled::Outbox::Event>] Events to send
    # @return [Hash] Result with:
    #   - succeeded: Array of successfully sent events
    #   - failed: Array of FailedEvent structs (both transient and permanent failures)
    def send_batch(events)
      # Group events by stream since put_records requires all records to go to the same stream
      events.group_by(&:stream_name).each_with_object({ succeeded: [], failed: [] }) do |(stream_name, stream_events), result|
        batch_result = send_stream_batch(stream_name, stream_events)
        result[:succeeded].concat(batch_result[:succeeded])
        result[:failed].concat(batch_result[:failed])
      end
    end

    private

    def send_stream_batch(stream_name, stream_events)
      records = build_records(stream_events)

      begin
        response = kinesis_client.put_records(stream_name:, records:)
        process_response(response, stream_events)
      rescue Aws::Kinesis::Errors::ValidationException
        # Re-raise batch-level validation errors (configuration issues)
        # These indicate invalid stream name, batch too large, etc.
        # Not event data problems - requires manual intervention
        raise
      rescue StandardError => e
        # Handle transient errors (throttling, network issues, service unavailable)
        handle_transient_batch_error(e, stream_events)
      end
    end

    def build_records(stream_events)
      stream_events.map do |event|
        {
          data: event.event_data.merge(id: event.id).to_json,
          partition_key: event.partition_key,
        }
      end
    end

    def process_response(response, stream_events)
      succeeded = []
      failed = []

      response.records.each_with_index do |record_result, index|
        event = stream_events[index]

        if record_result.error_code
          failed << create_failed_event(event, record_result)
        else
          succeeded << event
        end
      end

      { succeeded:, failed: }
    end

    def create_failed_event(event, record_result)
      Outbox::MetricEmitter.emit_kinesis_failure(event:, error_code: record_result.error_code)

      Journaled::KinesisFailedEvent.new(
        event:,
        error_code: record_result.error_code,
        error_message: record_result.error_message,
        transient: PERMANENT_ERROR_CODES.exclude?(record_result.error_code),
      )
    end

    def handle_transient_batch_error(error, stream_events)
      Rails.logger.error("Kinesis batch send failed (transient): #{error.class} - #{error.message}")

      failed = stream_events.map do |event|
        error_code = error.class.to_s
        Outbox::MetricEmitter.emit_kinesis_failure(event:, error_code:)

        Journaled::KinesisFailedEvent.new(
          event:,
          error_code:,
          error_message: error.message,
          transient: true,
        )
      end

      { succeeded: [], failed: }
    end

    def kinesis_client
      @kinesis_client ||= KinesisClientFactory.build
    end
  end
end
