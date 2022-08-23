module Journaled
  module Connection
    class << self
      def available?
        Journaled.transactional_batching_enabled && transaction_open?
      end

      def stage!(event)
        raise TransactionSafetyError, <<~MSG unless transaction_open?
          Transaction not available! By default, journaled event batching requires an open database transaction.
        MSG

        connection.current_transaction._journaled_staged_events << event
      end

      private

      def transaction_open?
        connection.transaction_open?
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

    module TestOnlyBehaviors
      def transaction_open?
        # Transactional fixtures wrap all tests in an outer, non-joinable transaction:
        super && (connection.open_transactions > 1 || connection.current_transaction.joinable?)
      end
    end

    class << self
      prepend TestOnlyBehaviors if Rails.env.test?
    end
  end
end
