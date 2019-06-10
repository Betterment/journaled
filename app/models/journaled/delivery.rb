class Journaled::Delivery
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
    @kinesis_client ||= Journaled::KinesisClient.new.client
  end

  class KinesisTemporaryFailure < NotTrulyExceptionalError
  end
end
