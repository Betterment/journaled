# frozen_string_literal: true

require 'bundler/setup'
require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'active_job/railtie'

Bundler.require(:default, Rails.env)

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path('..', __dir__)
    config.load_defaults Rails::VERSION::STRING.to_f
    config.eager_load = Rails.env.test?
    config.cache_classes = Rails.env.test?
    config.active_job.queue_adapter = :test
    config.filter_parameters += [:password]
    config.active_support.deprecation = :raise

    if ActiveJob.gem_version < Gem::Version.new('8.0')
      config.active_job.enqueue_after_transaction_commit = :never
    end
  end
end
