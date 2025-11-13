# frozen_string_literal: true

require 'rails/generators'
require 'rails/generators/active_record'

module Journaled
  module Generators
    class DatabaseEventsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path('templates', __dir__)

      desc "Generates migration for journaled Outbox-style event processing"

      def install_uuid_generate_v7_migration
        migration_template(
          "install_uuid_generate_v7.rb.erb",
          "db/migrate/install_uuid_generate_v7.rb",
          migration_version:,
        )
      end

      def create_journaled_events_migration
        migration_template(
          "create_journaled_events.rb.erb",
          "db/migrate/create_journaled_events.rb",
          migration_version:,
        )
      end

      def show_readme
        readme "README" if behavior == :invoke
      end

      private

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end
