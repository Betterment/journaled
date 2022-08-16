require "aws-sdk-kinesis"
require "active_job"
require "json-schema"

require "journaled/engine"
require "journaled/current"
require "journaled/errors"
require 'journaled/connection'

module Journaled
  SUPPORTED_QUEUE_ADAPTERS = %w(delayed delayed_job good_job que).freeze

  mattr_accessor :default_stream_name
  mattr_accessor(:job_priority) { 20 }
  mattr_accessor(:http_idle_timeout) { 5 }
  mattr_accessor(:http_open_timeout) { 2 }
  mattr_accessor(:http_read_timeout) { 60 }
  mattr_accessor(:job_base_class_name) { 'ActiveJob::Base' }
  mattr_accessor(:transactional_batching_enabled) { true }

  def self.development_or_test?
    %w(development test).include?(Rails.env)
  end

  def self.enabled?
    ['0', 'false', false, 'f', ''].exclude?(ENV.fetch('JOURNALED_ENABLED', !development_or_test?))
  end

  def self.schema_providers
    @schema_providers ||= [Journaled::Engine, Rails]
  end

  def self.commit_hash
    ENV.fetch('GIT_COMMIT')
  end

  def self.actor_uri
    Journaled::ActorUriProvider.instance.actor_uri
  end

  def self.queue_adapter
    job_base_class_name.constantize.queue_adapter_name
  end

  def self.detect_queue_adapter!
    unless SUPPORTED_QUEUE_ADAPTERS.include?(queue_adapter)
      raise <<~MSG
        Journaled has detected an unsupported ActiveJob queue adapter: `:#{queue_adapter}`

        Journaled jobs must be enqueued transactionally to your primary database.

        Please install the appropriate gems and set `queue_adapter` to one of the following:
        #{SUPPORTED_QUEUE_ADAPTERS.map { |a| "- `:#{a}`" }.join("\n")}

        Read more at https://github.com/Betterment/journaled
      MSG
    end
  end

  def self.tagged(**tags)
    existing_tags = Current.tags
    tag!(**tags)
    yield
  ensure
    Current.tags = existing_tags
  end

  def self.tag!(**tags)
    Current.tags = Current.tags.merge(tags)
  end
end
