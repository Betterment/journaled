module Journaled
  module AbstractAdapterExt
    delegate :_journaled_pending_events, to: :_journaled_transaction_handler

    def self.included(klass)
      klass.alias_method :_journaled_transaction_open?, :transaction_open?
      klass.prepend TestBehaviors if Rails.env.test?
    end

    module TestBehaviors
      def _journaled_transaction_open?
        open_transactions > 1 || current_transaction.joinable?
      end
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
        raise TransactionSafetyError, <<~MSG unless connection._journaled_transaction_open?
          By default, journaled events must be enqueued within a database transaction.
        MSG

        connection.add_transaction_record(self)
        @active = true
      end

      def active?
        @active
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
        @active = false
      end

      def committed!(*); end

      def rolledback!(*)
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