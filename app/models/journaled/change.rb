# frozen_string_literal: true

class Journaled::Change
  include Journaled::Event

  attr_reader :table_name,
              :record_id,
              :database_operation,
              :logical_operation,
              :changes,
              :journaled_stream_name,
              :journaled_enqueue_opts,
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
                 journaled_stream_name:,
                 journaled_enqueue_opts:,
                 actor:)
    @table_name = table_name
    @record_id = record_id
    @database_operation = database_operation
    @logical_operation = logical_operation
    @changes = changes
    @journaled_stream_name = journaled_stream_name
    @journaled_enqueue_opts = journaled_enqueue_opts
    @actor = actor
  end
end
