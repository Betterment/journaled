# frozen_string_literal: true

module Journaled
  class DeliveryJob < ApplicationJob
    rescue_from(Aws::Kinesis::Errors::InternalFailure, Aws::Kinesis::Errors::ServiceUnavailable, Aws::Kinesis::Errors::Http503Error) do |e|
      Rails.logger.error "Kinesis Error - Server Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    rescue_from(Seahorse::Client::NetworkingError) do |e|
      Rails.logger.error "Kinesis Error - Networking Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    def perform(*events)
      @kinesis_records = events.map { |e| KinesisRecord.new(**e.delete_if { |_k, v| v.nil? }) }

      journal! if Journaled.enabled?
    end

    private

    KinesisRecord = Struct.new(:serialized_event, :partition_key, :stream_name, keyword_init: true) do
      def initialize(serialized_event:, partition_key:, stream_name:)
        super(serialized_event: serialized_event, partition_key: partition_key, stream_name: stream_name)
      end

      def to_h
        { stream_name: stream_name, data: serialized_event, partition_key: partition_key }
      end
    end

    attr_reader :kinesis_records

    def journal!
      kinesis_records.map do |record|
        kinesis_client.put_record(**record.to_h)
      end
    end

    def kinesis_client
      @kinesis_client ||= KinesisClientFactory.build
    end

    class KinesisTemporaryFailure < NotTrulyExceptionalError
    end
  end
end
