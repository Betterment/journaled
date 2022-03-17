module Journaled
  class TransactionRecord
    %i(before_commit after_commit after_rollback).each do |name|
      define_method(name) do |&block|
        callbacks[name] << block
      end
    end

    def before_committed!(*)
      callbacks[:before_commit].each(&:call)
    end

    def committed!(*)
      callbacks[:after_commit].each(&:call)
    end

    def rolledback!(*)
      callbacks[:after_rollback].each(&:call)
    end

    def trigger_transactional_callbacks?
      true
    end

    def has_transactional_callbacks?
      true
    end

    private

    def callbacks
      @callbacks ||= { before_commit: [], after_commit: [], after_rollback: [] }
    end
  end
end
