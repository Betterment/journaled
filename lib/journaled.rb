# frozen_string_literal: true

require "aws-sdk-kinesis"
require "active_job"
require "json-schema"

require "journaled/engine"
require "journaled/current"
require "journaled/errors"
require 'journaled/connection'
require 'journaled/delivery_adapter'
require 'journaled/delivery_adapters/active_job_adapter'
require 'journaled/outbox/adapter'
require 'journaled/kinesis_client_factory'
require 'journaled/kinesis_failed_event'
require 'journaled/kinesis_batch_sender'
require 'journaled/kinesis_sequential_sender'
require 'journaled/outbox/batch_processor'
require 'journaled/outbox/metric_emitter'
require 'journaled/outbox/worker'

module Journaled
  SUPPORTED_QUEUE_ADAPTERS = %w(delayed delayed_job good_job que).freeze

  mattr_accessor :default_stream_name
  mattr_accessor(:job_priority) { 20 }
  mattr_accessor(:http_idle_timeout) { 5 }
  mattr_accessor(:http_open_timeout) { 2 }
  mattr_accessor(:http_read_timeout) { 60 }
  mattr_accessor(:job_base_class_name) { 'ActiveJob::Base' }
  mattr_accessor(:outbox_base_class_name) { 'ActiveRecord::Base' }
  mattr_accessor(:delivery_adapter) { Journaled::DeliveryAdapters::ActiveJobAdapter }
  mattr_writer(:transactional_batching_enabled) { true }

  # Worker configuration (for Outbox-style event processing)
  mattr_accessor(:worker_batch_size) { 500 }
  mattr_accessor(:worker_poll_interval) { 0.5 } # seconds
  mattr_accessor(:outbox_processing_mode) { :batch } # :batch or :guaranteed_order

  def self.transactional_batching_enabled?
    Thread.current[:journaled_transactional_batching_enabled] || @@transactional_batching_enabled
  end

  def self.with_transactional_batching
    value_was = Thread.current[:journaled_transactional_batching_enabled]
    Thread.current[:journaled_transactional_batching_enabled] = true
    yield
  ensure
    Thread.current[:journaled_transactional_batching_enabled] = value_was
  end

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

require 'journaled/audit_log'
