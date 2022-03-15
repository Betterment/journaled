rails_env = ENV['RAILS_ENV'] ||= 'test'
require 'uncruft'
require File.expand_path('dummy/config/environment.rb', __dir__)

Rails.application.config.active_record.sqlite3.represent_boolean_as_integer = true if Rails::VERSION::MAJOR < 6
Rails.application.config.active_record.legacy_connection_handling = false if Rails::VERSION::MAJOR >= 7

Rails.configuration.database_configuration[rails_env].tap do |c|
  ActiveRecord::Tasks::DatabaseTasks.create(c)
  ActiveRecord::Base.establish_connection(c)
  load File.expand_path('dummy/db/schema.rb', __dir__)
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.order = :random
end
