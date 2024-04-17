# frozen_string_literal: true

require 'active_record/connection_adapters/abstract/transaction'

module Journaled
  module TransactionExt
    def initialize(*, **)
      super.tap do
        raise TransactionSafetyError, <<~MSG unless instance_variable_defined?(:@run_commit_callbacks)
          Journaled::TransactionExt expects @run_commit_callbacks to be defined on Transaction!
          This is an internal API that may have changed in a recent Rails release.
          If you were not expecting to see this error, please file an issue here:
          https://github.com/Betterment/journaled/issues
        MSG
      end
    end

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
