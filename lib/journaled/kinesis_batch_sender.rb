# frozen_string_literal: true

module Journaled
  # Sends batches of events to Kinesis using the PutRecords batch API
  #
  # This class handles:
  # - Grouping events by stream (required for batch API)
  # - Sending up to 500 events per stream (Kinesis limit)
  # - Handling partial failures (some records succeed, others fail)
  # - Classifying errors as transient vs permanent
  #
  # Returns structured results for the caller to handle event state management.
  class KinesisBatchSender
    # Represents a failed event delivery attempt
    FailedEvent = Struct.new(:event, :error_code, :error_message, :transient, keyword_init: true) do
      def transient?
        transient
      end

      def permanent?
        !transient
      end
    end
    # Transient errors that should be retried
    TRANSIENT_ERROR_CLASSES = [
      Aws::Kinesis::Errors::InternalFailure,
      Aws::Kinesis::Errors::ServiceUnavailable,
      Aws::Kinesis::Errors::Http503Error,
      Aws::Kinesis::Errors::ProvisionedThroughputExceededException,
      Seahorse::Client::NetworkingError,
    ].freeze

    # Send a batch of database events to Kinesis
    #
    # @param events [Array<Journaled::Outbox::Event>] Events to send
    # @return [Hash] Result with:
    #   - succeeded: Array of successfully sent events
    #   - failed: Array of FailedEvent structs
    def send_batch(events)
      result = { succeeded: [], failed: [] }

      # Group events by stream (required for Kinesis put_records API)
      events.group_by(&:stream_name).each do |stream_name, stream_events|
        stream_result = send_to_stream(stream_name, stream_events)
        result[:succeeded].concat(stream_result[:succeeded])
        result[:failed].concat(stream_result[:failed])
      end

      result
    end

    private

    # Send events for a single stream
    # rubocop:disable Metrics/AbcSize
    def send_to_stream(stream_name, events)
      result = { succeeded: [], failed: [] }

      # Prepare records for Kinesis
      records = events.map do |event|
        {
          data: event.event_data.to_json,
          partition_key: event.partition_key,
        }
      end

      begin
        # Send batch to Kinesis using put_records API
        response = kinesis_client.put_records(
          stream_name:,
          records:,
        )

        # Process results
        events.each_with_index do |event, index|
          record_result = response.records[index]

          if record_result.error_code.nil?
            result[:succeeded] << event
          else
            # Partial failure - this specific record failed
            result[:failed] << FailedEvent.new(
              event:,
              error_code: record_result.error_code,
              error_message: record_result.error_message,
              transient: transient_error_code?(record_result.error_code),
            )
          end
        end
      rescue *TRANSIENT_ERROR_CLASSES => e
        # Entire batch failed with transient error
        Rails.logger.error("Kinesis batch send failed (transient): #{e.class} - #{e.message}")
        events.each do |event|
          result[:failed] << FailedEvent.new(
            event:,
            error_code: e.class.to_s,
            error_message: e.message,
            transient: true,
          )
        end
      rescue StandardError => e
        # Entire batch failed with permanent error
        Rails.logger.error("Kinesis batch send failed (permanent): #{e.class} - #{e.message}")
        events.each do |event|
          result[:failed] << FailedEvent.new(
            event:,
            error_code: e.class.to_s,
            error_message: e.message,
            transient: false,
          )
        end
      end

      result
    end
    # rubocop:enable Metrics/AbcSize

    # Check if an error code indicates a transient failure
    def transient_error_code?(error_code)
      # Common transient error codes returned in PutRecords response
      transient_codes = %w(
        InternalFailure
        ServiceUnavailable
        ProvisionedThroughputExceededException
      )
      transient_codes.include?(error_code)
    end

    # Get or create Kinesis client
    def kinesis_client
      @kinesis_client ||= KinesisClientFactory.build
    end
  end
end
