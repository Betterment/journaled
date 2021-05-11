unless Journaled.development_or_test?
  ActiveSupport.on_load(:active_job) do
    Journaled.detect_queue_adapter!
  end
end
