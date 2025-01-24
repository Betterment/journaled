# frozen_string_literal: true

$LOAD_PATH.push File.expand_path('lib', __dir__)

# Maintain your gem's version:
require "journaled/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "journaled"
  s.version     = Journaled::VERSION
  s.authors     = ["Jake Lipson", "Corey Alexander", "Cyrus Eslami", "John Mileham"]
  s.email       = ["jacob.lipson@betterment.com", "corey@betterment.com", "cyrus@betterment.com", "john@betterment.com"]
  s.homepage    = "http://github.com/Betterment/journaled"
  s.summary     = "Journaling for Betterment apps."
  s.description = "A Rails engine to durably deliver schematized events to Amazon Kinesis via DelayedJob."
  s.license     = "MIT"
  s.metadata['rubygems_mfa_required'] = 'true'

  s.files = Dir["{app,config,lib,journaled_schemas}/**/*", "LICENSE", "Rakefile", "README.md"]

  s.required_ruby_version = ">= 3.2"

  s.post_install_message = File.read("UPGRADING") if File.exist?('UPGRADING')

  s.add_dependency "activejob"
  s.add_dependency "activerecord"
  s.add_dependency "activesupport"
  s.add_dependency "aws-sdk-kinesis", "< 2"
  s.add_dependency "json-schema"
  s.add_dependency "railties", ">= 7.0", "< 8.1"

  s.add_development_dependency "appraisal"
  s.add_development_dependency "betterlint"
  s.add_development_dependency "rspec_junit_formatter"
  s.add_development_dependency "rspec-rails"
  s.add_development_dependency "spring"
  s.add_development_dependency "spring-commands-rspec"
  s.add_development_dependency "timecop"
  s.add_development_dependency "uncruft"
  s.add_development_dependency "webmock"
end
