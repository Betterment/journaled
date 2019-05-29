class Journaled::Writer
  EVENT_METHOD_NAMES = %i(
    journaled_schema_name
    journaled_partition_key
    journaled_attributes
    journaled_app_name
  ).freeze

  def initialize(journaled_event:, priority:)
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
    @priority = priority
  end

  def journal!
    base_event_json_schema_validator.validate! serialized_event
    json_schema_validator.validate! serialized_event
    Delayed::Job.enqueue journaled_delivery, priority: priority
  end

  private

  attr_reader :journaled_event, :priority
  delegate :journaled_schema_name, :journaled_attributes, :journaled_partition_key, :journaled_app_name, to: :journaled_event

  def journaled_delivery
    @journaled_delivery ||= Journaled::Delivery.new(
      serialized_event: serialized_event,
      partition_key: journaled_partition_key,
      app_name: journaled_app_name
    )
  end

  def serialized_event
    @serialized_event ||= journaled_attributes.to_json
  end

  def json_schema_validator
    @json_schema_validator ||= Journaled::JsonSchemaModel::Validator.new(journaled_schema_name)
  end

  def base_event_json_schema_validator
    @base_event_json_schema_validator ||= Journaled::JsonSchemaModel::Validator.new('base_event')
  end

  def respond_to_all?(object, method_names)
    method_names.all? do |method_name|
      object.respond_to?(method_name)
    end
  end
end
