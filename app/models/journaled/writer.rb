class Journaled::Writer
  EVENT_METHOD_NAMES = %i(
    journaled_schema_name
    journaled_partition_key
    journaled_attributes
    journaled_stream_name
    journaled_enqueue_opts
  ).freeze

  def initialize(journaled_event:)
    raise "An enqueued event must respond to: #{EVENT_METHOD_NAMES.to_sentence}" unless respond_to_all?(journaled_event, EVENT_METHOD_NAMES)

    unless journaled_event.journaled_schema_name.present? &&
        journaled_event.journaled_partition_key.present? &&
        journaled_event.journaled_attributes.present?
      raise <<~ERROR
        An enqueued event must have a non-nil response to:
          #json_schema_name,
          #partition_key, and
          #journaled_attributes
      ERROR
    end

    @journaled_event = journaled_event
  end

  def journal!
    validate!
    enqueue_before_commit!
  end

  def self.enqueue!(*events)
    events.group_by(&:journaled_enqueue_opts).each do |enqueue_opts, delivery_events|
      Journaled::DeliveryJob
        .set(enqueue_opts.reverse_merge(priority: Journaled.job_priority))
        .perform_later(*delivery_perform_args(delivery_events))
    end
  end

  def self.delivery_perform_args(events)
    events.map do |event|
      {
        serialized_event: event.journaled_attributes.to_json,
        partition_key: event.journaled_partition_key,
        stream_name: event.journaled_stream_name,
      }
    end
  end

  private

  attr_reader :journaled_event

  delegate(*EVENT_METHOD_NAMES, to: :journaled_event)

  def validate!
    serialized_event = journaled_event.journaled_attributes.to_json

    schema_validator('base_event').validate! serialized_event
    schema_validator('tagged_event').validate! serialized_event if journaled_event.tagged?
    schema_validator(journaled_schema_name).validate! serialized_event
  end

  def enqueue_before_commit!
    if connection_provider.connection._journaled_transaction_open?
      stage!
    else
      self.class.enqueue!(journaled_event)
    end
  end

  def stage!
    connection_provider.connection._journaled_pending_events << journaled_event
  end

  def connection_provider
    ActiveRecord::Base # TODO: Use underlying ActiveRecord Job class
  end

  def schema_validator(schema_name)
    Journaled::JsonSchemaModel::Validator.new(schema_name)
  end

  def respond_to_all?(object, method_names)
    method_names.all? do |method_name|
      object.respond_to?(method_name)
    end
  end
end
