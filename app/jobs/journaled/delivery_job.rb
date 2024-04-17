# frozen_string_literal: true

module Journaled
  class DeliveryJob < ApplicationJob
    DEFAULT_REGION = 'us-east-1'

    rescue_from(Aws::Kinesis::Errors::InternalFailure, Aws::Kinesis::Errors::ServiceUnavailable, Aws::Kinesis::Errors::Http503Error) do |e|
      Rails.logger.error "Kinesis Error - Server Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    rescue_from(Seahorse::Client::NetworkingError) do |e|
      Rails.logger.error "Kinesis Error - Networking Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    def perform(*events, **legacy_kwargs)
      events << legacy_kwargs if legacy_kwargs.present?
      @kinesis_records = events.map { |e| KinesisRecord.new(**e.delete_if { |_k, v| v.nil? }) }

      journal! if Journaled.enabled?
    end

    def kinesis_client_config
      {
        region: ENV.fetch('AWS_DEFAULT_REGION', DEFAULT_REGION),
        retry_limit: 0,
        http_idle_timeout: Journaled.http_idle_timeout,
        http_open_timeout: Journaled.http_open_timeout,
        http_read_timeout: Journaled.http_read_timeout,
      }.merge(credentials)
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
      Aws::Kinesis::Client.new(kinesis_client_config)
    end

    def credentials
      if ENV.key?('JOURNALED_IAM_ROLE_ARN')
        {
          credentials: iam_assume_role_credentials,
        }
      else
        legacy_credentials_hash_if_present
      end
    end

    def legacy_credentials_hash_if_present
      if ENV.key?('RUBY_AWS_ACCESS_KEY_ID')
        {
          access_key_id: ENV.fetch('RUBY_AWS_ACCESS_KEY_ID'),
          secret_access_key: ENV.fetch('RUBY_AWS_SECRET_ACCESS_KEY'),
        }
      else
        {}
      end
    end

    def sts_client
      Aws::STS::Client.new({
        region: ENV.fetch('AWS_DEFAULT_REGION', DEFAULT_REGION),
      }.merge(legacy_credentials_hash_if_present))
    end

    def iam_assume_role_credentials
      @iam_assume_role_credentials ||= Aws::AssumeRoleCredentials.new(
        client: sts_client,
        role_arn: ENV.fetch('JOURNALED_IAM_ROLE_ARN'),
        role_session_name: "JournaledAssumeRoleAccess",
      )
    end

    class KinesisTemporaryFailure < NotTrulyExceptionalError
    end
  end
end
