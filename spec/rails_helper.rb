# frozen_string_literal: true

# This file is copied to spec/ when you run 'rails generate rspec:install'
ENV['RAILS_ENV'] ||= 'test'
require 'spec_helper'
require File.expand_path('../spec/dummy/config/environment', __dir__)
require 'rspec/rails'
require 'timecop'
require 'webmock/rspec'
require 'journaled/rspec'

Dir[Rails.root.join('../support/**/*.rb')].sort.each { |f| require f }

RSpec.configure do |config|
  config.use_transactional_fixtures = true

  config.infer_spec_type_from_file_location!

  config.include ActiveJob::TestHelper
  config.include EnvironmentSpecHelper

  # Auto-restore Journaled configuration after each test
  config.around(:each) do |example|
    default_stream_name_was = Journaled.default_stream_name
    job_priority_was = Journaled.job_priority
    http_idle_timeout_was = Journaled.http_idle_timeout
    http_open_timeout_was = Journaled.http_open_timeout
    http_read_timeout_was = Journaled.http_read_timeout
    job_base_class_name_was = Journaled.job_base_class_name
    outbox_base_class_name_was = Journaled.outbox_base_class_name
    delivery_adapter_was = Journaled.delivery_adapter
    worker_batch_size_was = Journaled.worker_batch_size
    worker_poll_interval_was = Journaled.worker_poll_interval
    outbox_processing_mode_was = Journaled.outbox_processing_mode

    example.run
  ensure
    Journaled.default_stream_name = default_stream_name_was
    Journaled.job_priority = job_priority_was
    Journaled.http_idle_timeout = http_idle_timeout_was
    Journaled.http_open_timeout = http_open_timeout_was
    Journaled.http_read_timeout = http_read_timeout_was
    Journaled.job_base_class_name = job_base_class_name_was
    Journaled.outbox_base_class_name = outbox_base_class_name_was
    Journaled.delivery_adapter = delivery_adapter_was
    Journaled.worker_batch_size = worker_batch_size_was
    Journaled.worker_poll_interval = worker_poll_interval_was
    Journaled.outbox_processing_mode = outbox_processing_mode_was
  end
end
