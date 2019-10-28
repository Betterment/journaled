module Journaled
  class << self
    def enqueue!(*args)
      on_enqueue.call(*args)
    end

    def on_enqueue(&block)
      @on_enqueue = block if block_given?
      @on_enqueue || delayed_job_enqueue
    end

    private

    def delayed_job_enqueue
      ->(*args, **opts) do
        Delayed::Job.enqueue(*args, **opts.reverse_merge(priority: Journaled.job_priority))
      end
    end
  end
end
