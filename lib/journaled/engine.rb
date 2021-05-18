module Journaled
  class Engine < ::Rails::Engine
    config.after_initialize do
      ActiveSupport.on_load(:active_job) do
        Journaled.detect_queue_adapter! unless Journaled.development_or_test?
      end
    end
  end
end
