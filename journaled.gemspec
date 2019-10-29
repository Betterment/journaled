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

  s.files = Dir["{app,config,lib,journaled_schemas}/**/*", "LICENSE", "Rakefile", "README.md"]
  s.test_files = Dir["spec/**/*"]

  s.add_dependency "aws-sdk-resources", "< 4"
  s.add_dependency "delayed_job"
  s.add_dependency "json-schema"
  s.add_dependency "rails", ">= 5.1", "< 7.0"
  s.add_dependency "request_store"

  s.add_development_dependency "appraisal", "~> 2.2.0"
  s.add_development_dependency "delayed_job_active_record"
  s.add_development_dependency "pg"
  s.add_development_dependency "pry-rails"
  s.add_development_dependency "rspec-rails"
  s.add_development_dependency "rspec_junit_formatter"
  s.add_development_dependency "rubocop-betterment", "~> 1.3"
  s.add_development_dependency "spring"
  s.add_development_dependency "spring-commands-rspec"
  s.add_development_dependency 'sprockets', '< 4.0'
  s.add_development_dependency "timecop"
  s.add_development_dependency "webmock"
end
