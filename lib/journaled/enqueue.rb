module Journaled
  class << self
    def enqueue!(performable)
      on_enqueue.call(performable)
    end

    def on_enqueue(&block)
      @on_enqueue = block if block_given?
      @on_enqueue || delayed_job
    end

    private

    def delayed_job
      ->(performable) do
        Delayed::Job.enqueue(performable, priority: Journaled.job_priority)
      end
    end
  end
end
