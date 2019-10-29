module Journaled::Event
  extend ActiveSupport::Concern

  def journal!
    Journaled::Writer.new(journaled_event: self).journal!
  end

  # Base attributes

  def id
    @id ||= SecureRandom.uuid
  end

  def event_type
    @event_type ||= self.class.event_type
  end

  def created_at
    @created_at ||= Time.zone.now
  end

  # Event metadata and configuration (not serialized)

  def journaled_schema_name
    self.class.to_s.underscore
  end

  def journaled_attributes
    self.class.public_send(:journaled_attributes).each_with_object({}) do |attribute, memo|
      memo[attribute] = public_send(attribute)
    end
  end

  def journaled_partition_key
    event_type
  end

  def journaled_app_name
    Journaled.default_app_name
  end

  private

  class_methods do
    def journal_attributes(*args, **opts)
      journaled_attributes.concat(args)
      journaled_enqueue_opts.merge!(opts.fetch(:enqueue_with, {}))
    end

    def journaled_attributes
      @journaled_attributes ||= []
    end

    def event_type
      name.underscore.parameterize(separator: '_')
    end
  end

  included do
    cattr_accessor(:journaled_enqueue_opts, instance_writer: false) { {} }

    journal_attributes :id, :event_type, :created_at
  end
end
