# frozen_string_literal: true

module Journaled
  # Sends batches of events to Kinesis using the PutRecord single-event API
  #
  # This class handles:
  # - Sending events individually in order to support guaranteed ordering
  # - Stopping on first transient failure to preserve ordering
  # - Classifying errors as transient vs permanent
  #
  # Returns structured results for the caller to handle event state management.
  class KinesisSequentialSender
    FailedEvent = Struct.new(:event, :error_code, :error_message, :transient, keyword_init: true) do
      def transient?
        transient
      end

      def permanent?
        !transient
      end
    end

    PERMANENT_ERROR_CLASSES = [
      Aws::Kinesis::Errors::ValidationException,
    ].freeze

    # Send a batch of database events to Kinesis
    #
    # Sends events one at a time to guarantee ordering. Stops on first transient failure.
    #
    # @param events [Array<Journaled::Outbox::Event>] Events to send
    # @return [Hash] Result with:
    #   - succeeded: Array of successfully sent events
    #   - failed: Array of FailedEvent structs (only permanent failures)
    def send_batch(events)
      result = { succeeded: [], failed: [] }

      events.each do |event|
        event_result = send_event(event)
        if event_result.is_a?(FailedEvent)
          if event_result.transient?
            emit_transient_failure_metric
            break
          else
            result[:failed] << event_result
          end
        else
          result[:succeeded] << event_result
        end
      end

      result
    end

    private

    # Send a single event to Kinesis
    #
    # @param event [Journaled::Outbox::Event] Event to send
    # @return [Journaled::Outbox::Event, FailedEvent] The event on success, or FailedEvent on failure
    def send_event(event)
      # Merge the DB-generated ID into the event data before sending to Kinesis
      event_data_with_id = event.event_data.merge(id: event.id)

      kinesis_client.put_record(
        stream_name: event.stream_name,
        data: event_data_with_id.to_json,
        partition_key: event.partition_key,
      )

      event
    rescue *PERMANENT_ERROR_CLASSES => e
      Rails.logger.error("Kinesis event send failed (permanent): #{e.class} - #{e.message}")
      FailedEvent.new(
        event:,
        error_code: e.class.to_s,
        error_message: e.message,
        transient: false,
      )
    rescue StandardError => e
      Rails.logger.error("Kinesis event send failed (transient): #{e.class} - #{e.message}")
      FailedEvent.new(
        event:,
        error_code: e.class.to_s,
        error_message: e.message,
        transient: true,
      )
    end

    def kinesis_client
      @kinesis_client ||= KinesisClientFactory.build
    end

    def emit_transient_failure_metric
      ActiveSupport::Notifications.instrument('journaled.kinesis_sequential_sender.transient_failure')
    end
  end
end
