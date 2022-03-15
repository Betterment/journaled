module Journaled
  class DeliveryJob < ApplicationJob
    DEFAULT_REGION = 'us-east-1'.freeze

    rescue_from(Aws::Kinesis::Errors::InternalFailure, Aws::Kinesis::Errors::ServiceUnavailable, Aws::Kinesis::Errors::Http503Error) do |e|
      Rails.logger.error "Kinesis Error - Server Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    rescue_from(Seahorse::Client::NetworkingError) do |e|
      Rails.logger.error "Kinesis Error - Networking Error occurred - #{e.class}"
      raise KinesisTemporaryFailure
    end

    UNSPECIFIED = Object.new
    private_constant :UNSPECIFIED

    def perform(*events,
                serialized_event: UNSPECIFIED,
                partition_key: UNSPECIFIED,
                stream_name: UNSPECIFIED)
      if events != []
        @events = events
      elsif serialized_event != UNSPECIFIED && partition_key != UNSPECIFIED && stream_name != UNSPECIFIED
        @events = [{ serialized_event: serialized_event, partition_key: partition_key, stream_name: stream_name }]
      else
        raise(ArgumentError, 'please provide a list of event hashes with :serialized_event, :partition_key, and :stream_name keys')
      end

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

    attr_reader :events

    def journal!
      events.map do |e|
        kinesis_client.put_record(
          stream_name: e[:stream_name],
          data: e[:serialized_event],
          partition_key: e[:partition_key],
        )
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
