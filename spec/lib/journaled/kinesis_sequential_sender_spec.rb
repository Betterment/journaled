# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::KinesisSequentialSender do
  subject { described_class.new }

  let(:kinesis_client) { instance_double(Aws::Kinesis::Client) }

  before do
    allow(Rails.logger).to receive(:error)
    allow(Journaled::KinesisClientFactory).to receive(:build).and_return(kinesis_client)
  end

  describe '#send_batch' do
    context 'with empty events array' do
      it 'returns empty arrays' do
        result = subject.send_batch([])
        expect(result).to eq(succeeded: [], failed: [])
      end
    end

    context 'with successful delivery' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream2') }
      let(:events) { [event_1, event_2] }

      before do
        # Mock successful put_record response
        allow(kinesis_client).to receive(:put_record).and_return(
          instance_double(Aws::Kinesis::Types::PutRecordOutput),
        )
      end

      it 'sends records to Kinesis one at a time with DB-generated ID merged into event_data' do
        subject.send_batch(events)

        expect(kinesis_client).to have_received(:put_record).with(
          stream_name: 'stream1',
          data: event_1.event_data.merge(id: event_1.id).to_json,
          partition_key: event_1.partition_key,
        )

        expect(kinesis_client).to have_received(:put_record).with(
          stream_name: 'stream2',
          data: event_2.event_data.merge(id: event_2.id).to_json,
          partition_key: event_2.partition_key,
        )
      end

      it 'returns succeeded events' do
        result = subject.send_batch(events)
        expect(result[:succeeded]).to eq([event_1, event_2])
        expect(result[:failed]).to be_empty
      end
    end

    context 'with transient error' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:event_3) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2, event_3] }

      before do
        # First event succeeds, second event fails with transient error
        allow(kinesis_client).to receive(:put_record) do |args|
          if args[:stream_name] == 'stream1' && args[:data].include?(event_2.id)
            raise Aws::Kinesis::Errors::ProvisionedThroughputExceededException.new(nil, 'Rate exceeded')
          end

          instance_double(Aws::Kinesis::Types::PutRecordOutput)
        end
      end

      it 'returns first successful event and stops processing' do
        result = subject.send_batch(events)
        expect(result[:succeeded]).to eq([event_1])
        expect(result[:failed]).to be_empty
      end

      it 'does not send remaining events after transient failure' do
        subject.send_batch(events)

        # Should have sent event_1, attempted event_2, but NOT attempted event_3
        expect(kinesis_client).to have_received(:put_record).twice
      end

      it 'emits a transient failure metric' do
        allow(ActiveSupport::Notifications).to receive(:instrument).and_call_original
        expect(ActiveSupport::Notifications).to receive(:instrument).with(
          'journaled.kinesis_sequential_sender.transient_failure',
        ).and_call_original

        subject.send_batch(events)
      end
    end

    context 'with permanent error' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:event_3) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2, event_3] }

      before do
        # First event succeeds, second event fails with permanent error, third succeeds
        allow(kinesis_client).to receive(:put_record) do |args|
          if args[:stream_name] == 'stream1' && args[:data].include?(event_2.id)
            raise Aws::Kinesis::Errors::ValidationException.new(nil, 'Invalid record')
          end

          instance_double(Aws::Kinesis::Types::PutRecordOutput)
        end
      end

      it 'returns succeeded and failed events, continues processing after permanent failure' do
        result = subject.send_batch(events)
        expect(result[:succeeded]).to eq([event_1, event_3])
        expect(result[:failed].length).to eq(1)

        failure = result[:failed].first
        expect(failure.event).to eq(event_2)
        expect(failure.error_code).to eq('Aws::Kinesis::Errors::ValidationException')
        expect(failure.error_message).to eq('Invalid record')
        expect(failure.transient?).to be false
        expect(failure.permanent?).to be true
      end

      it 'continues sending remaining events after permanent failure' do
        subject.send_batch(events)

        # Should have sent all three events
        expect(kinesis_client).to have_received(:put_record).exactly(3).times
      end
    end

    context 'with mixed errors' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event }
      let(:event_2) { create_database_event }
      let(:event_3) { create_database_event }
      let(:event_4) { create_database_event }
      let(:events) { [event_1, event_2, event_3, event_4] }

      before do
        # Event 1: success
        # Event 2: permanent failure (continues)
        # Event 3: transient failure (stops)
        # Event 4: not sent
        allow(kinesis_client).to receive(:put_record) do |args|
          if args[:data].include?(event_2.id)
            raise Aws::Kinesis::Errors::ValidationException.new(nil, 'Invalid record')
          elsif args[:data].include?(event_3.id)
            raise Aws::Kinesis::Errors::ServiceUnavailable.new(nil, 'Service unavailable')
          end

          instance_double(Aws::Kinesis::Types::PutRecordOutput)
        end
      end

      it 'processes permanent failures but stops on transient failure' do
        result = subject.send_batch(events)

        expect(result[:succeeded]).to eq([event_1])
        expect(result[:failed].length).to eq(1)
        expect(result[:failed].first.event).to eq(event_2)
        expect(result[:failed].first.permanent?).to be true
      end

      it 'does not send events after transient failure' do
        subject.send_batch(events)

        # Should have sent events 1, 2, 3 but NOT 4
        expect(kinesis_client).to have_received(:put_record).exactly(3).times
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
