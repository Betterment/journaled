# frozen_string_literal: true

module Journaled
  class Engine < ::Rails::Engine
    engine_name 'journaled'

    config.after_initialize do
      ActiveSupport.on_load(:active_job) do
        Journaled.delivery_adapter.validate_configuration! unless Journaled.development_or_test?
      end

      ActiveSupport.on_load(:active_record) do
        require 'journaled/transaction_ext'
        ActiveRecord::ConnectionAdapters::Transaction.prepend Journaled::TransactionExt
      end
    end
  end
end
