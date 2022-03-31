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
end
