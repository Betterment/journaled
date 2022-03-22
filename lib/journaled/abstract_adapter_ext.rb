module Journaled
  module AbstractAdapterExt
    delegate :_journaled_pending_events, to: :_journaled_transaction_handler

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
        raise TransactionSafetyError, "Journaled events must be enqueued within a database transaction" unless connection.transaction_open?

        connection.add_transaction_record(self)
        @active = true
      end

      def active?
        @active
      end

      def _journaled_pending_events
        @_journaled_pending_events ||= []
      end

      def before_committed!(*)
        Writer.enqueue!(_journaled_pending_events)
      end

      def committed!(*)
        _journaled_pending_events.clear
        @active = false
      end

      def rolledback!(*)
        _journaled_pending_events.clear
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
