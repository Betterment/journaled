require 'active_record/connection_adapters/abstract/transaction'

module Journaled
  module TransactionExt
    def before_commit_records
      super.tap do
        Writer.enqueue!(*_journaled_staged_events) if @run_commit_callbacks
      end
    end

    def commit_records
      connection.current_transaction._journaled_staged_events.push(*_journaled_staged_events) unless @run_commit_callbacks
      super
    end

    def _journaled_staged_events
      @_journaled_staged_events ||= []
    end
  end
end
