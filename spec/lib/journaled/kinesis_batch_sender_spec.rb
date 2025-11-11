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
      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2] }

      let(:kinesis_response) do
        instance_double(
          Aws::Kinesis::Types::PutRecordsOutput,
          records: [
            instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '123', shard_id: 'shard-1'),
            instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '124', shard_id: 'shard-1'),
          ],
        )
      end

      before do
        allow(kinesis_client).to receive(:put_records).and_return(kinesis_response)
      end

      it 'sends records to Kinesis' do
        sender.send_batch(events)

        expect(kinesis_client).to have_received(:put_records).with(
          stream_name: 'stream1',
          records: [
            { data: event_1.event_data.to_json, partition_key: event_1.partition_key },
            { data: event_2.event_data.to_json, partition_key: event_2.partition_key },
          ],
        )
      end

      it 'returns succeeded events' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to eq([event_1, event_2])
        expect(result[:failed]).to be_empty
      end
    end

    context 'with partial failure' do
      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2] }

      let(:kinesis_response) do
        instance_double(
          Aws::Kinesis::Types::PutRecordsOutput,
          records: [
            instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '123', shard_id: 'shard-1'),
            instance_double(
              Aws::Kinesis::Types::PutRecordsResultEntry,
              error_code: 'ProvisionedThroughputExceededException',
              error_message: 'Rate exceeded',
            ),
          ],
        )
      end

      before do
        allow(kinesis_client).to receive(:put_records).and_return(kinesis_response)
      end

      it 'returns successful event' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to eq([event_1])
      end

      it 'returns failed event with error details' do
        result = sender.send_batch(events)
        expect(result[:failed].length).to eq(1)
        failure = result[:failed].first
        expect(failure.event).to eq(event_2)
        expect(failure.error_code).to eq('ProvisionedThroughputExceededException')
        expect(failure.error_message).to eq('Rate exceeded')
        expect(failure.transient).to be true
        expect(failure.transient?).to be true
        expect(failure.permanent?).to be false
      end
    end

    context 'with transient error on entire batch' do
      let(:event) { create_database_event }
      let(:events) { [event] }

      before do
        allow(kinesis_client).to receive(:put_records)
          .and_raise(Aws::Kinesis::Errors::ServiceUnavailable.new(nil, 'Service unavailable'))
      end

      it 'returns all events as failed with transient flag' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to be_empty
        expect(result[:failed].length).to eq(1)
        failure = result[:failed].first
        expect(failure.event).to eq(event)
        expect(failure.error_code).to eq('Aws::Kinesis::Errors::ServiceUnavailable')
        expect(failure.error_message).to eq('Service unavailable')
        expect(failure.transient?).to be true
      end
    end

    context 'with permanent error' do
      let(:event) { create_database_event }
      let(:events) { [event] }

      let(:kinesis_response) do
        instance_double(
          Aws::Kinesis::Types::PutRecordsOutput,
          records: [
            instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: 'InvalidArgumentException',
              error_message: 'Invalid data'),
          ],
        )
      end

      before do
        allow(kinesis_client).to receive(:put_records).and_return(kinesis_response)
      end

      it 'returns failed event with non-transient flag' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to be_empty
        expect(result[:failed].length).to eq(1)
        failure = result[:failed].first
        expect(failure.event).to eq(event)
        expect(failure.error_code).to eq('InvalidArgumentException')
        expect(failure.error_message).to eq('Invalid data')
        expect(failure.transient?).to be false
        expect(failure.permanent?).to be true
      end
    end

    context 'with multiple streams' do
      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream2') }
      let(:event_3) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2, event_3] }

      before do
        # Return appropriate number of records for each stream
        allow(kinesis_client).to receive(:put_records) do |args|
          if args[:stream_name] == 'stream1'
            # stream1 has 2 events
            instance_double(Aws::Kinesis::Types::PutRecordsOutput, records: [
              instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '123', shard_id: 'shard-1'),
              instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '124', shard_id: 'shard-1'),
            ])
          else
            # stream2 has 1 event
            instance_double(Aws::Kinesis::Types::PutRecordsOutput, records: [
              instance_double(Aws::Kinesis::Types::PutRecordsResultEntry, error_code: nil, sequence_number: '125', shard_id: 'shard-1'),
            ])
          end
        end
      end

      it 'groups events by stream and makes separate API calls' do
        sender.send_batch(events)

        expect(kinesis_client).to have_received(:put_records).with(
          hash_including(stream_name: 'stream1'),
        )
        expect(kinesis_client).to have_received(:put_records).with(
          hash_including(stream_name: 'stream2'),
        )
      end
    end
  end

  private

  def create_database_event(attrs = {})
    Journaled::Outbox::Event.create!(
      {
        event_type: 'test_event',
        event_data: { id: SecureRandom.uuid, event_type: 'test' },
        partition_key: 'test_key',
        stream_name: 'test_stream',
        attempts: 1,
        locked_by: 'worker-1',
        locked_at: Time.current,
      }.merge(attrs),
    )
  end
end
