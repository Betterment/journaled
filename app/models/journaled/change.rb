class Journaled::Change
  include Journaled::Event

  attr_reader :table_name,
    :record_id,
    :database_operation,
    :logical_operation,
    :changes,
    :journaled_app_name,
    :actor

  journal_attributes :table_name,
    :record_id,
    :database_operation,
    :logical_operation,
    :changes,
    :actor

  def initialize(table_name:,
                 record_id:,
                 database_operation:,
                 logical_operation:,
                 changes:,
                 journaled_app_name:,
                 actor:)
    @table_name = table_name
    @record_id = record_id
    @database_operation = database_operation
    @logical_operation = logical_operation
    @changes = changes
    @journaled_app_name = journaled_app_name
    @actor = actor
  end
end
