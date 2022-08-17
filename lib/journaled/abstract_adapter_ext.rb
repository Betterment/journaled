module Journaled
  module AbstractAdapterExt
    delegate :_journaled_pending_events, to: :_journaled_transaction_handler

    def self.included(klass)
      klass.set_callback(:checkout, :before) do
        @_journaled_transaction_handler = nil
      end
    end

    def _journaled_transaction_joinable?
      transaction_open? && _journaled_transaction_handler.joinable?
    end

    private

    def _journaled_transaction_handler
      if @_journaled_transaction_handler&.active?
        @_journaled_transaction_handler
      else
        @_journaled_transaction_handler = TransactionHandler.new(connection: self)
      end
    end

    class TransactionHandler
      def initialize(connection:)
        raise TransactionSafetyError, <<~MSG unless connection.transaction_open?
          Transaction not open! By default, journaled event batching requires an open database transaction.
        MSG

        connection.add_transaction_record(self)
        @active = true
        @joinable = true
      end

      def active?
        @active
      end

      def joinable?
        @joinable
      end

      def _journaled_pending_events
        @_journaled_pending_events ||= []
      end

      # The following methods adhere to the API contract defined by:
      # https://github.com/rails/rails/blob/v6.0.4.7/activerecord/lib/active_record/transactions.rb
      #
      # This allows our TransactionHandler to act as a "transaction record" and
      # run callbacks before/after commit (or after rollback).
      def before_committed!
        Writer.enqueue!(*_journaled_pending_events)
        @joinable = false
      end

      def committed!(*)
        @active = false
      end

      def rolledback!(*)
        @joinable = false
        @active = false
      end

      def trigger_transactional_callbacks?
        true
      end

      def has_transactional_callbacks?
        true
      end
    end
  end
end
