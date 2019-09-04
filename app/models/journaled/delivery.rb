class Journaled::Delivery
  DEFAULT_REGION = 'us-east-1'.freeze

  def initialize(serialized_event:, partition_key:, app_name:)
    @serialized_event = serialized_event
    @partition_key = partition_key
    @app_name = app_name
  end

  def perform
    kinesis_client.put_record record if Journaled.enabled?
  rescue Aws::Kinesis::Errors::InternalFailure, Aws::Kinesis::Errors::ServiceUnavailable, Aws::Kinesis::Errors::Http503Error => e
    Rails.logger.error "Kinesis Error - Server Error occurred - #{e.class}"
    raise KinesisTemporaryFailure
  rescue Seahorse::Client::NetworkingError => e
    Rails.logger.error "Kinesis Error - Networking Error occurred - #{e.class}"
    raise KinesisTemporaryFailure
  end

  def stream_name
    env_var_name = [app_name&.upcase, 'JOURNALED_STREAM_NAME'].compact.join('_')
    ENV.fetch(env_var_name)
  end

  def kinesis_client_config
    {
      region: ENV.fetch('AWS_DEFAULT_REGION', DEFAULT_REGION),
      retry_limit: 0
    }.merge(credentials)
  end

  private

  attr_reader :serialized_event, :partition_key, :app_name

  def record
    {
      stream_name: stream_name,
      data: serialized_event,
      partition_key: partition_key
    }
  end

  def kinesis_client
    Aws::Kinesis::Client.new(kinesis_client_config)
  end

  def credentials
    if ENV.key?('JOURNALED_IAM_ROLE_ARN')
      {
        credentials: iam_assume_role_credentials
      }
    else
      legacy_credentials_hash_if_present
    end
  end

  def legacy_credentials_hash_if_present
    if ENV.key?('RUBY_AWS_ACCESS_KEY_ID')
      {
        access_key_id: ENV.fetch('RUBY_AWS_ACCESS_KEY_ID'),
        secret_access_key: ENV.fetch('RUBY_AWS_SECRET_ACCESS_KEY')
      }
    else
      {}
    end
  end

  def sts_client
    Aws::STS::Client.new({
      region: ENV.fetch('AWS_DEFAULT_REGION', DEFAULT_REGION)
    }.merge(legacy_credentials_hash_if_present))
  end

  def iam_assume_role_credentials
    @iam_assume_role_credentials ||= Aws::AssumeRoleCredentials.new(
      client: sts_client,
      role_arn: ENV.fetch('JOURNALED_IAM_ROLE_ARN'),
      role_session_name: "JournaledAssumeRoleAccess"
    )
  end

  class KinesisTemporaryFailure < NotTrulyExceptionalError
  end
end
