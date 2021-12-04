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

    def perform( # rubocop:disable Metrics/PerceivedComplexity
      partition_key:,
      serialized_events: UNSPECIFIED,
      serialized_event: UNSPECIFIED,
      stream_name: UNSPECIFIED,
      app_name: UNSPECIFIED
    )
      if serialized_event != UNSPECIFIED
        @serialized_events = [serialized_event]
      elsif serialized_events != UNSPECIFIED
        @serialized_events = serialized_events
      else
        raise(ArgumentError, 'missing keyword: serialized_events')
      end
      @partition_key = partition_key
      if app_name != UNSPECIFIED
        @stream_name = self.class.legacy_computed_stream_name(app_name: app_name)
      elsif stream_name != UNSPECIFIED && !stream_name.nil?
        @stream_name = stream_name
      else
        raise(ArgumentError, 'missing keyword: stream_name')
      end

      journal!
    end

    def self.legacy_computed_stream_name(app_name:)
      env_var_name = [app_name&.upcase, 'JOURNALED_STREAM_NAME'].compact.join('_')
      ENV.fetch(env_var_name)
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

    attr_reader :serialized_events, :partition_key, :stream_name

    def journal!
      serialized_events.map do |event|
        kinesis_client.put_record record(event) if Journaled.enabled?
      end
    end

    def record(serialized_event)
      {
        stream_name: stream_name,
        data: serialized_event,
        partition_key: partition_key,
      }
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
