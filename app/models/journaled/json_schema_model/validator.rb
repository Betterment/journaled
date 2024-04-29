# frozen_string_literal: true

class Journaled::JsonSchemaModel::Validator
  def initialize(schema_name)
    @schema_name = schema_name
  end

  def validate!(json_to_validate)
    JSON::Validator.validate!(json_schema, json_to_validate)
  end

  private

  attr_reader :schema_name

  def json_schema
    @json_schema ||= JSON.parse(json_schema_file)
  end

  def json_schema_file
    @json_schema_file ||= File.read(json_schema_path)
  end

  def json_schema_path
    @json_schema_path ||= gem_paths.detect { |path| File.exist?(path) } || raise(<<~ERROR)
      journaled_schemas/#{schema_name}.json not found in any of #{Journaled.schema_providers.map { |sp| "#{sp}.root" }.join(', ')}

      You can add schema providers as follows:

      # config/initializers/journaled.rb
      Journaled.schema_providers << MyGem::Engine
    ERROR
  end

  def gem_paths
    Journaled.schema_providers.map do |engine|
      engine.root.join "journaled_schemas/#{schema_name}.json"
    end
  end
end
