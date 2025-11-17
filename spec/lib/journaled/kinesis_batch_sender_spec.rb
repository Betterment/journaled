# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::KinesisBatchSender do
  let(:sender) { described_class.new }
  let(:kinesis_client) { instance_double(Aws::Kinesis::Client) }

  before do
    allow(Rails.logger).to receive(:error)
    allow(sender).to receive(:kinesis_client).and_return(kinesis_client)
  end

  describe '#send_batch' do
    context 'with empty events array' do
      it 'returns empty arrays' do
        result = sender.send_batch([])
        expect(result).to eq(succeeded: [], failed: [])
      end
    end

    context 'with successful delivery' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2] }

      before do
        allow(kinesis_client).to receive(:put_record)
      end

      it 'sends records to Kinesis with DB-generated ID merged into event_data' do
        sender.send_batch(events)

        expect(kinesis_client).to have_received(:put_record).with(
          stream_name: 'stream1',
          data: event_1.event_data.merge(id: event_1.id).to_json,
          partition_key: event_1.partition_key,
        )
        expect(kinesis_client).to have_received(:put_record).with(
          stream_name: 'stream1',
          data: event_2.event_data.merge(id: event_2.id).to_json,
          partition_key: event_2.partition_key,
        )
      end

      it 'returns succeeded events' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to eq([event_1, event_2])
        expect(result[:failed]).to be_empty
      end
    end

    context 'with partial failure' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2] }

      before do
        # First event succeeds, second event fails
        allow(kinesis_client).to receive(:put_record) do |args|
          if args[:data].include?(event_1.id)
            # Success - put_record returns a response but we don't need to check it
            true
          else
            raise Aws::Kinesis::Errors::ProvisionedThroughputExceededException.new(nil, 'Rate exceeded')
          end
        end
      end

      it 'returns successful event and stops on transient failure' do
        metric_emitted = false
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original
        allow(ActiveSupport::Notifications).to receive(:instrument)
          .with('journaled.kinesis_batch_sender.transient_failure') { metric_emitted = true }

        result = sender.send_batch(events)
        expect(result[:succeeded]).to eq([event_1])
        expect(result[:failed]).to be_empty
        expect(metric_emitted).to be true
      end
    end

    context 'with transient error on entire batch' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event) { create_database_event }
      let(:events) { [event] }

      before do
        allow(kinesis_client).to receive(:put_record)
          .and_raise(Aws::Kinesis::Errors::ServiceUnavailable.new(nil, 'Service unavailable'))
      end

      it 'stops processing and emits metric' do
        metric_emitted = false
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original
        allow(ActiveSupport::Notifications).to receive(:instrument)
          .with('journaled.kinesis_batch_sender.transient_failure') { metric_emitted = true }

        result = sender.send_batch(events)
        expect(result[:succeeded]).to be_empty
        expect(result[:failed]).to be_empty
        expect(metric_emitted).to be true
      end
    end

    context 'with permanent error' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event) { create_database_event }
      let(:events) { [event] }

      before do
        allow(kinesis_client).to receive(:put_record)
          .and_raise(Aws::Kinesis::Errors::ValidationException.new(nil, 'Invalid data'))
      end

      it 'returns failed event with non-transient flag' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to be_empty
        expect(result[:failed].length).to eq(1)
        failure = result[:failed].first
        expect(failure.event).to eq(event)
        expect(failure.error_code).to eq('Aws::Kinesis::Errors::ValidationException')
        expect(failure.error_message).to eq('Invalid data')
        expect(failure.transient?).to be false
        expect(failure.permanent?).to be true
      end
    end

    context 'with multiple streams' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream2') }
      let(:event_3) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2, event_3] }

      before do
        allow(kinesis_client).to receive(:put_record)
      end

      it 'sends each event individually to its respective stream' do
        sender.send_batch(events)

        expect(kinesis_client).to have_received(:put_record).with(
          hash_including(stream_name: 'stream1'),
        ).twice
        expect(kinesis_client).to have_received(:put_record).with(
          hash_including(stream_name: 'stream2'),
        ).once
      end
    end
  end

  private

  def create_database_event(attrs = {})
    Journaled::Outbox::Event.create!(
      {
        event_type: 'test_event',
        event_data: { event_type: 'test' },
        partition_key: 'test_key',
        stream_name: 'test_stream',
      }.merge(attrs),
    )
  end
end
