# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe 'app/models' do
  it 'loads all files without a database connection pool configured' do
    env_file = Rails.root.join('config/environment').to_s
    gem_root = Rails.root.join('../..').expand_path.to_s
    model_files = Dir[File.join(gem_root, 'app/models/**/*.rb')]

    file_loads = model_files.map { |f| "load #{f.inspect}" }.join("\n")

    # Boot Rails in development mode (lazy loading), remove all connection pools,
    # then load each model file. This simulates the conditions under which the bug
    # was originally discovered: tapioca loading classes without a DB configured.
    # Rails 7.2+ calls ActiveRecord::Type.adapter_name_from at class load time for
    # symbol-typed attributes, which raises if no connection pool exists.
    script = <<~RUBY
      ENV['RAILS_ENV'] = 'development'
      require #{env_file.inspect}

      handler = ActiveRecord::Base.connection_handler
      handler.connection_pool_names.each { |name| handler.remove_connection_pool(name) }

      #{file_loads}

      puts "#{model_files.size} model files loaded successfully"
    RUBY

    output, status = Open3.capture2e(RbConfig.ruby, '-e', script)
    expect(status.exitstatus).to eq(0), "Model load failed:\n#{output}"
  end
end
