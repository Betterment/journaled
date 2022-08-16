module Journaled
  module Connection
    class << self
      def available?
        Journaled.transactional_batching_enabled && transaction_open?
      end

      def stage!(event)
        connection._journaled_pending_events << event
      end

      private

      def transaction_open?
        connection._journaled_transaction_open?
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
