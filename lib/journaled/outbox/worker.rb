# frozen_string_literal: true

module Journaled
  module Outbox
    # Worker daemon for processing Outbox-style events
    #
    # This worker polls the database for pending events and sends them to Kinesis in batches.
    # Multiple workers can run concurrently and will coordinate using row-level locking.
    #
    # The Worker handles the daemon lifecycle (start/stop, signal handling, run loop) and
    # delegates actual batch processing to BatchProcessor.
    #
    # Usage:
    #   worker = Journaled::Outbox::Worker.new
    #   worker.start  # Blocks until shutdown signal received
    class Worker
      def initialize
        @worker_id = "#{Socket.gethostname}-#{Process.pid}"
        self.running = false
        @processor = BatchProcessor.new
        @metric_emitter = MetricEmitter.new(worker_id: @worker_id)
        self.shutdown_requested = false
        @last_metrics_emission = Time.current
      end

      # Start the worker (blocks until shutdown)
      def start
        check_prerequisites!

        self.running = true
        Rails.logger.info("Journaled worker starting (id: #{worker_id})")

        setup_signal_handlers

        run_loop
      ensure
        self.running = false
        Rails.logger.info("Journaled worker stopped (id: #{worker_id})")
      end

      # Request graceful shutdown
      def shutdown
        self.shutdown_requested = true
      end

      # Check if worker is still running
      def running?
        running
      end

      private

      attr_reader :worker_id, :processor, :metric_emitter
      attr_accessor :shutdown_requested, :running, :last_metrics_emission

      def run_loop
        loop do
          if shutdown_requested
            Rails.logger.info("Shutdown requested for worker #{worker_id}")
            break
          end

          begin
            process_batch
            emit_metrics_if_needed
          rescue StandardError => e
            Rails.logger.error("Worker error: #{e.class} - #{e.message}")
            Rails.logger.error(e.backtrace.join("\n"))
          end

          break if shutdown_requested

          sleep(Journaled.worker_poll_interval)
        end
      end

      def process_batch
        stats = processor.process_batch

        instrument_batch_results(stats)
      end

      def instrument_batch_results(stats)
        metric_emitter.emit_batch_metrics(stats)
      end

      def check_prerequisites!
        unless Event.table_exists?
          raise <<~ERROR
            The 'journaled_outbox_events' table does not exist.

            To create the required table, run:

              rails generate journaled:database_events
              rails db:migrate
          ERROR
        end

        Rails.logger.info("Prerequisites check passed")
      end

      def setup_signal_handlers
        %w(INT TERM).each do |signal|
          Signal.trap(signal) do
            shutdown
          end
        end
      end

      # Emit metrics if the interval has elapsed
      def emit_metrics_if_needed
        return unless Time.current - last_metrics_emission >= 60

        # Collect and emit metrics in a background thread to avoid blocking the main loop
        Thread.new do
          collect_and_emit_metrics
        rescue StandardError => e
          Rails.logger.error("Error collecting metrics: #{e.class} - #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
        end

        self.last_metrics_emission = Time.current
      end

      # Collect and emit queue metrics
      def collect_and_emit_metrics
        metric_emitter.emit_queue_metrics
      end
    end
  end
end
