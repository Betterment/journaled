# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::DeliveryAdapters::ActiveJobAdapter do
  describe '.deliver' do
    let(:event_class) { Class.new { include Journaled::Event } }
    let(:event) do
      instance_double(
        event_class,
        journaled_attributes: { id: 'test_id', event_type: 'test_event', created_at: Time.zone.now },
        journaled_partition_key: 'test_partition_key',
        journaled_stream_name: 'test_stream',
      )
    end
    let(:events) { [event] }
    let(:enqueue_opts) { { priority: 15, queue: 'test_queue' } }

    it 'enqueues a Journaled::DeliveryJob with the provided options' do
      expect {
        described_class.deliver(events:, enqueue_opts:)
      }.to change { enqueued_jobs.count }.by(1)

      enqueued_job = enqueued_jobs.last
      expect(enqueued_job['job_class']).to eq('Journaled::DeliveryJob')
      expect(enqueued_job['priority']).to eq(15)
      expect(enqueued_job['queue_name']).to eq('test_queue')
    end

    it 'serializes events correctly' do
      described_class.deliver(events:, enqueue_opts:)

      enqueued_job = enqueued_jobs.last
      job_args = enqueued_job['arguments'].first

      expect(job_args).to include(
        'serialized_event' => event.journaled_attributes.to_json,
        'partition_key' => 'test_partition_key',
        'stream_name' => 'test_stream',
      )
    end

    context 'with multiple events' do
      let(:event_2) do
        instance_double(
          event_class,
          journaled_attributes: { id: 'test_id2', event_type: 'test_event2', created_at: Time.zone.now },
          journaled_partition_key: 'test_partition_key2',
          journaled_stream_name: 'test_stream2',
        )
      end
      let(:events) { [event, event_2] }

      it 'batches all events into a single job' do
        expect {
          described_class.deliver(events:, enqueue_opts:)
        }.to change { enqueued_jobs.count }.by(1)

        enqueued_job = enqueued_jobs.last
        expect(enqueued_job['arguments'].length).to eq(2)
      end
    end
  end

  describe '.delivery_perform_args' do
    let(:event_class) { Class.new { include Journaled::Event } }
    let(:event) do
      instance_double(
        event_class,
        journaled_attributes: { id: 'test_id', event_type: 'test_event' },
        journaled_partition_key: 'test_partition_key',
        journaled_stream_name: 'test_stream',
      )
    end

    it 'returns serialized event data' do
      result = described_class.delivery_perform_args([event])

      expect(result).to eq([
        {
          serialized_event: event.journaled_attributes.to_json,
          partition_key: 'test_partition_key',
          stream_name: 'test_stream',
        },
      ])
    end
  end

  describe '.transaction_connection' do
    it 'returns the connection for the configured queue adapter' do
      # In test mode, we use ActiveRecord::Base.connection
      expect(described_class.transaction_connection).to eq(ActiveRecord::Base.connection)
    end
  end

  describe '.validate_configuration!' do
    it 'raises an error unless the queue adapter is DB-backed' do
      expect { described_class.validate_configuration! }.to raise_error <<~MSG
        Journaled has detected an unsupported ActiveJob queue adapter: `:test`

        Journaled jobs must be enqueued transactionally to your primary database.

        Please install the appropriate gems and set `queue_adapter` to one of the following:
        - `:delayed`
        - `:delayed_job`
        - `:good_job`
        - `:que`

        Read more at https://github.com/Betterment/journaled
      MSG
    end

    context 'when the queue adapter is supported' do
      before do
        stub_const("ActiveJob::QueueAdapters::DelayedAdapter", Class.new)
        ActiveJob::Base.disable_test_adapter
        ActiveJob::Base.queue_adapter = :delayed
      end

      around do |example|
        example.run
      ensure
        ActiveJob::Base.queue_adapter = :test
        ActiveJob::Base.enable_test_adapter(ActiveJob::QueueAdapters::TestAdapter.new)
      end

      it 'does not raise an error' do
        expect { described_class.validate_configuration! }.not_to raise_error
      end
    end
  end
end
