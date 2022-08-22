require 'active_record/connection_adapters/abstract/transaction'

module Journaled
  module TransactionExt
    def before_commit_records
      @_journaled_committing_records = true
      super
    end

    def _journaled_transaction_handler
      if @_journaled_transaction_handler&.active?
        @_journaled_transaction_handler
      else
        @_journaled_transaction_handler = TransactionHandler.new(txn: self).tap do |txn_handler|
          txn_handler.joinable = !@_journaled_committing_records
        end
      end
    end

    class TransactionHandler
      attr_writer :joinable

      def initialize(txn:)
        raise TransactionSafetyError, <<~MSG unless txn.connection.transaction_open?
          Transaction not open! By default, journaled event batching requires an open database transaction.
        MSG

        txn.add_record(self)
        @txn = txn
        self.joinable = true
        @active = true
      end

      def active?
        @active
      end

      def joinable?
        @joinable
      end

      def staged_events
        @staged_events ||= []
      end

      # The following methods adhere to the API contract defined by:
      # https://github.com/rails/rails/blob/v6.0.4.7/activerecord/lib/active_record/transactions.rb
      #
      # This allows our TransactionHandler to act as a "transaction record" and
      # run callbacks before/after commit (or after rollback).
      def before_committed!
        Writer.enqueue!(*staged_events)
        @joinable = false
      end

      def committed!(*)
        @active = false
      end

      def rolledback!(*)
        @joinable = false
        @active = false
      end

      if Rails::VERSION::MAJOR < 6
        # With Rails 6.0, this method is no longer necessary, as its behavior was inlined here:
        # https://github.com/rails/rails/blob/6-0-stable/activerecord/lib/active_record/connection_adapters/abstract/transaction.rb#L130
        def add_to_transaction
          @txn.connection.add_transaction_record(self)
        end
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
