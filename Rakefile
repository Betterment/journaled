begin
  require 'bundler/setup'
rescue LoadError
  puts 'You must `gem install bundler` and `bundle install` to run rake tasks'
end

require 'rdoc/task'

RDoc::Task.new(:rdoc) do |rdoc|
  rdoc.rdoc_dir = 'rdoc'
  rdoc.title    = 'Journaled'
  rdoc.options << '--line-numbers'
  rdoc.rdoc_files.include('README.rdoc')
  rdoc.rdoc_files.include('lib/**/*.rb')
end

APP_RAKEFILE = File.expand_path('spec/dummy/Rakefile', __dir__)
load 'rails/tasks/engine.rake'

Bundler::GemHelper.install_tasks

if %w(development test).include? Rails.env
  require 'rspec/core'
  require 'rspec/core/rake_task'
  RSpec::Core::RakeTask.new

  require 'rubocop/rake_task'
  RuboCop::RakeTask.new

  task(:default).clear
  task default: %i(rubocop spec)

  task 'db:test:prepare' => 'db:setup'
end
