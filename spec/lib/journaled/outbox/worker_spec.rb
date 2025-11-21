# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Outbox::Worker do
  before do
    skip "Outbox tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
  end

  subject(:worker) { described_class.new }

  let(:processor) { instance_double(Journaled::Outbox::BatchProcessor) }

  before do
    allow(Journaled::Outbox::BatchProcessor).to receive(:new).with(no_args).and_return(processor)
    # Ensure table exists for prerequisite checks
    allow(Journaled::Outbox::Event).to receive(:table_exists?).and_return(true)
    # Speed up tests by reducing poll interval
    allow(Journaled).to receive(:worker_poll_interval).and_return(0.001)
  end

  describe '#start' do
    before do
      # Prevent actual signal trap setup
      allow(Signal).to receive(:trap)
    end

    context 'with immediate shutdown' do
      before do
        # Have processor trigger shutdown on first call
        allow(processor).to receive(:process_batch) do
          worker.shutdown
          { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
        end
      end

      it 'checks prerequisites before starting' do
        allow(Journaled::Outbox::Event).to receive(:table_exists?).and_call_original
        worker.start
        expect(Journaled::Outbox::Event).to have_received(:table_exists?)
      end

      it 'sets running to false after completion' do
        worker.start
        expect(worker.running?).to be false
      end

      it 'sets up signal handlers' do
        worker.start
        expect(Signal).to have_received(:trap).with('INT')
        expect(Signal).to have_received(:trap).with('TERM')
      end
    end

    context 'when error occurs during batch processing' do
      before do
        call_count = 0
        allow(processor).to receive(:process_batch) do
          call_count += 1
          if call_count == 1
            raise StandardError, 'Batch error'
          else
            worker.shutdown
            { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
          end
        end
      end

      it 'ensures running is set to false' do
        worker.start
        expect(worker.running?).to be false
      end
    end

    context 'when error occurs before run loop' do
      before do
        allow(Journaled::Outbox::Event).to receive(:table_exists?).and_raise(StandardError, 'DB error')
      end

      it 'ensures running is set to false' do
        expect { worker.start }.to raise_error(StandardError, 'DB error')
        expect(worker.running?).to be false
      end
    end
  end

  describe '#shutdown' do
    it 'stops the run loop' do
      allow(Signal).to receive(:trap)
      call_count = 0
      allow(processor).to receive(:process_batch) do
        call_count += 1
        worker.shutdown if call_count >= 2
        { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
      end

      worker.start
      expect(call_count).to eq(2)
    end
  end

  describe '#running?' do
    it 'returns false initially' do
      expect(worker.running?).to be false
    end
  end

  describe 'prerequisite checks' do
    before do
      allow(Signal).to receive(:trap)
      allow(processor).to receive(:process_batch) do
        worker.shutdown
        { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
      end
    end

    context 'when events table does not exist' do
      before do
        allow(Journaled::Outbox::Event).to receive(:table_exists?).and_return(false)
      end

      it 'raises an error with helpful message' do
        expect { worker.start }.to raise_error(
          RuntimeError,
          /journaled_outbox_events.*table does not exist/m,
        )
      end
    end

    context 'when table exists' do
      it 'does not raise an error' do
        expect { worker.start }.not_to raise_error
      end
    end
  end

  describe 'batch processing loop' do
    before do
      allow(Signal).to receive(:trap)
    end

    it 'processes multiple batches until shutdown' do
      call_count = 0
      allow(processor).to receive(:process_batch) do
        call_count += 1
        worker.shutdown if call_count >= 3
        { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
      end

      worker.start
      expect(processor).to have_received(:process_batch).exactly(3).times
    end

    it 'stops processing when shutdown is requested before start' do
      allow(processor).to receive(:process_batch).and_return(
        succeeded: 0,
        failed_transiently: 0,
        failed_permanently: 0,
      )
      worker.shutdown
      worker.start
      expect(processor).not_to have_received(:process_batch)
    end

    context 'when error occurs during batch processing' do
      before do
        call_count = 0
        allow(processor).to receive(:process_batch) do
          call_count += 1
          if call_count == 1
            raise StandardError, 'First batch error'
          else
            worker.shutdown
            { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
          end
        end
      end

      it 'continues processing after error' do
        worker.start
        expect(processor).to have_received(:process_batch).at_least(:twice)
      end
    end
  end

  describe 'batch processing instrumentation' do
    before do
      allow(Signal).to receive(:trap)
      allow(processor).to receive(:process_batch) do
        worker.shutdown
        stats
      end
    end

    context 'when no events are processed' do
      let(:stats) { { succeeded: 0, failed_permanently: 0, failed_transiently: 0 } }

      it 'emits notifications with zero counts' do
        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        ActiveSupport::Notifications.subscribed(callback, /^journaled\.worker\./) do
          worker.start
        end

        expect(emitted['journaled.worker.batch_process']).to include(value: 0, worker_id: be_present)
        expect(emitted['journaled.worker.batch_sent']).to include(value: 0, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_permanently']).to include(value: 0, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_transiently']).to include(value: 0, worker_id: be_present)
      end
    end

    context 'when events succeed' do
      let(:stats) { { succeeded: 2, failed_permanently: 0, failed_transiently: 0 } }

      it 'emits batch_process and batch_sent notifications with worker_id' do
        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        ActiveSupport::Notifications.subscribed(callback, /^journaled\.worker\./) do
          worker.start
        end

        expect(emitted['journaled.worker.batch_process']).to include(value: 2, worker_id: be_present)
        expect(emitted['journaled.worker.batch_sent']).to include(value: 2, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_permanently']).to include(value: 0, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_transiently']).to include(value: 0, worker_id: be_present)
      end
    end

    context 'when events fail permanently' do
      let(:stats) { { succeeded: 1, failed_permanently: 2, failed_transiently: 0 } }

      it 'emits batch_process, batch_sent, and batch_failed_permanently notifications' do
        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        ActiveSupport::Notifications.subscribed(callback, /^journaled\.worker\./) do
          worker.start
        end

        expect(emitted['journaled.worker.batch_process']).to include(value: 3, worker_id: be_present)
        expect(emitted['journaled.worker.batch_sent']).to include(value: 1, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_permanently']).to include(value: 2, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_transiently']).to include(value: 0, worker_id: be_present)
      end
    end

    context 'when events fail transiently' do
      let(:stats) { { succeeded: 1, failed_permanently: 0, failed_transiently: 3 } }

      it 'emits batch_process, batch_sent, and batch_failed_transiently notifications' do
        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        ActiveSupport::Notifications.subscribed(callback, /^journaled\.worker\./) do
          worker.start
        end

        expect(emitted['journaled.worker.batch_process']).to include(value: 4, worker_id: be_present)
        expect(emitted['journaled.worker.batch_sent']).to include(value: 1, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_permanently']).to include(value: 0, worker_id: be_present)
        expect(emitted['journaled.worker.batch_failed_transiently']).to include(value: 3, worker_id: be_present)
      end
    end
  end

  describe 'signal handlers' do
    let(:captured_handlers) { {} }

    before do
      allow(Signal).to receive(:trap) do |signal, &block|
        captured_handlers[signal] = block
      end
      allow(processor).to receive(:process_batch) do
        worker.shutdown
        { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
      end
    end

    it 'sets up INT signal handler' do
      worker.start
      expect(captured_handlers).to have_key('INT')
    end

    it 'sets up TERM signal handler' do
      worker.start
      expect(captured_handlers).to have_key('TERM')
    end

    it 'INT signal handler calls shutdown' do
      worker.start
      captured_handlers['INT'].call
      expect(worker.running?).to be false
    end

    it 'TERM signal handler calls shutdown' do
      worker.start
      captured_handlers['TERM'].call
      expect(worker.running?).to be false
    end
  end

  describe 'metrics emission' do
    before do
      allow(Signal).to receive(:trap)
      allow(Journaled).to receive(:worker_poll_interval).and_return(0.001)
    end

    context 'when metrics interval has not elapsed' do
      it 'does not emit metrics on first batch' do
        allow(processor).to receive(:process_batch) do
          worker.shutdown
          { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
        end

        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        ActiveSupport::Notifications.subscribed(callback, 'journaled.worker.queue_metrics') do
          worker.start
        end

        expect(emitted).not_to have_key('journaled.worker.queue_metrics')
      end
    end

    context 'when metrics interval has elapsed' do
      it 'emits queue metrics with all required fields' do
        # Create some test events
        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key1',
          stream_name: 'test_stream',
        )

        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key2',
          stream_name: 'test_stream',
          failure_reason: 'Some error',
        )

        # Start worker, then travel forward in time
        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        batch_count = 0
        allow(processor).to receive(:process_batch) do
          batch_count += 1
          # Travel forward after first batch to trigger metrics on second batch
          Timecop.travel(61.seconds) if batch_count == 1
          worker.shutdown if batch_count >= 2
          { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
        end

        # Subscribe to all individual metric notifications
        ActiveSupport::Notifications.subscribed(callback, /journaled\.worker\.queue_/) do
          worker.start

          # Wait for background thread to complete
          timeout = 2.seconds.from_now
          sleep 0.1 until emitted.key?('journaled.worker.queue_total_count') || Time.current > timeout
        end

        # Verify each individual metric was emitted
        expect(emitted).to have_key('journaled.worker.queue_total_count')
        expect(emitted).to have_key('journaled.worker.queue_workable_count')
        expect(emitted).to have_key('journaled.worker.queue_erroring_count')
        expect(emitted).to have_key('journaled.worker.queue_oldest_age_seconds')

        # Verify each metric has worker_id and a value
        expect(emitted['journaled.worker.queue_total_count']).to include(
          worker_id: be_present,
          value: be >= 0,
        )
        expect(emitted['journaled.worker.queue_workable_count']).to include(
          worker_id: be_present,
          value: be >= 0,
        )
        expect(emitted['journaled.worker.queue_erroring_count']).to include(
          worker_id: be_present,
          value: be >= 0,
        )
        expect(emitted['journaled.worker.queue_oldest_age_seconds']).to include(
          worker_id: be_present,
          value: be >= 0,
        )
      end
    end

    context 'when calculating metrics' do
      it 'counts total events correctly' do
        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key1',
          stream_name: 'test_stream',
        )

        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key2',
          stream_name: 'test_stream',
          failed_at: Time.current,
        )

        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        batch_count = 0
        allow(processor).to receive(:process_batch) do
          batch_count += 1
          # Travel forward after first batch to trigger metrics on second batch
          Timecop.travel(61.seconds) if batch_count == 1
          worker.shutdown if batch_count >= 2
          { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
        end

        # Subscribe to individual metric notifications
        ActiveSupport::Notifications.subscribed(callback, /journaled\.worker\.queue_/) do
          worker.start

          # Wait for background thread to complete
          timeout = 2.seconds.from_now
          sleep 0.1 until emitted.key?('journaled.worker.queue_total_count') || Time.current > timeout
        end

        expect(emitted['journaled.worker.queue_total_count'][:value]).to eq(2)
        expect(emitted['journaled.worker.queue_workable_count'][:value]).to eq(1) # Only non-failed events
      end

      it 'counts erroring events correctly' do
        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key1',
          stream_name: 'test_stream',
          failure_reason: 'Error but not failed',
        )

        Journaled::Outbox::Event.create!(
          event_type: 'test_event',
          event_data: { test: 'data' },
          partition_key: 'key2',
          stream_name: 'test_stream',
          failure_reason: 'Error and failed',
          failed_at: Time.current,
        )

        emitted = {}
        callback = ->(name, _started, _finished, _unique_id, payload) { emitted[name] = payload }

        batch_count = 0
        allow(processor).to receive(:process_batch) do
          batch_count += 1
          # Travel forward after first batch to trigger metrics on second batch
          Timecop.travel(61.seconds) if batch_count == 1
          worker.shutdown if batch_count >= 2
          { succeeded: 0, failed_transiently: 0, failed_permanently: 0 }
        end

        # Subscribe to individual metric notifications
        ActiveSupport::Notifications.subscribed(callback, /journaled\.worker\.queue_/) do
          worker.start

          # Wait for background thread to complete
          timeout = 2.seconds.from_now
          sleep 0.1 until emitted.key?('journaled.worker.queue_erroring_count') || Time.current > timeout
        end

        expect(emitted['journaled.worker.queue_erroring_count'][:value]).to eq(1) # Only events with error but not failed
      end
    end
  end
end
