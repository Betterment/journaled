require File.expand_path('boot', __dir__)

require "active_record/railtie"
require "active_job/railtie"
require "active_model/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "journaled"

module Dummy
  class Application < Rails::Application
    config.autoloader = Rails::VERSION::MAJOR >= 7 ? :zeitwerk : :classic
    config.active_record.sqlite3.represent_boolean_as_integer = true if Rails::VERSION::MAJOR < 6
    config.active_record.legacy_connection_handling = false if Rails::VERSION::MAJOR >= 7
  end
end
