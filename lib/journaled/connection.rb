module Journaled
  module Connection
    module TestBehaviors
      def transaction_joinable?
        # Transactional fixtures wrap all tests in an outer, non-joinable transaction:
        super && (connection.open_transactions > 1 || connection.current_transaction.joinable?)
      end
    end

    class << self
      prepend TestBehaviors if Rails.env.test?

      def available?
        Journaled.transactional_batching_enabled && transaction_joinable?
      end

      def stage!(event)
        raise TransactionSafetyError, <<~MSG unless transaction_joinable?
          Transaction not available! By default, journaled event batching requires an open database transaction.
        MSG

        connection._journaled_pending_events << event
      end

      private

      def transaction_joinable?
        connection._journaled_transaction_joinable?
      end

      def connection
        if Journaled.queue_adapter.in? %w(delayed delayed_job)
          Delayed::Job.connection
        elsif Journaled.queue_adapter == 'good_job'
          GoodJob::BaseRecord.connection
        elsif Journaled.queue_adapter == 'que'
          Que::ActiveRecord::Model.connection
        elsif Journaled.queue_adapter == 'test' && Rails.env.test?
          ActiveRecord::Base.connection
        else
          raise "Unsupported adapter: #{Journaled.queue_adapter}"
        end
      end
    end
  end
end
