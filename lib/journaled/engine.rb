module Journaled
  class Engine < ::Rails::Engine
    config.after_initialize do
      ActiveSupport.on_load(:active_job) do
        Journaled.detect_queue_adapter! unless Journaled.development_or_test?
      end

      ActiveSupport.on_load(:active_record) do
        require 'journaled/transaction_ext'
        ActiveRecord::ConnectionAdapters::Transaction.prepend Journaled::TransactionExt
      end
    end
  end
end
