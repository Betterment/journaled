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
        # Mock successful put_records response
        response = mock_put_records_response([
          { error_code: nil, error_message: nil },
          { error_code: nil, error_message: nil },
        ])
        allow(kinesis_client).to receive(:put_records).and_return(response)
      end

      it 'sends records to Kinesis with DB-generated ID merged into event_data' do
        sender.send_batch(events)

        expect(kinesis_client).to have_received(:put_records).with(
          stream_name: 'stream1',
          records: [
            {
              data: event_1.event_data.merge(id: event_1.id).to_json,
              partition_key: event_1.partition_key,
            },
            {
              data: event_2.event_data.merge(id: event_2.id).to_json,
              partition_key: event_2.partition_key,
            },
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
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event_1) { create_database_event(stream_name: 'stream1') }
      let(:event_2) { create_database_event(stream_name: 'stream1') }
      let(:events) { [event_1, event_2] }

      before do
        # First event succeeds, second event fails with transient error
        response = mock_put_records_response([
          { error_code: nil, error_message: nil },
          { error_code: 'ProvisionedThroughputExceededException', error_message: 'Rate exceeded' },
        ])
        allow(kinesis_client).to receive(:put_records).and_return(response)
      end

      it 'returns successful event and transient failure' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to eq([event_1])
        expect(result[:failed].length).to eq(1)

        failure = result[:failed].first
        expect(failure.event).to eq(event_2)
        expect(failure.error_code).to eq('ProvisionedThroughputExceededException')
        expect(failure.error_message).to eq('Rate exceeded')
        expect(failure.transient?).to be true
        expect(failure.permanent?).to be false
      end

      it 'collects all batch results including transient failures' do
        # Test with 3 events: success, transient failure, success
        # All were sent in the batch, so all results should be collected
        event_3 = create_database_event(stream_name: 'stream1')
        events_with_middle_failure = [event_1, event_2, event_3]

        response = mock_put_records_response([
          { error_code: nil, error_message: nil },
          { error_code: 'ProvisionedThroughputExceededException', error_message: 'Rate exceeded' },
          { error_code: nil, error_message: nil },
        ])
        allow(kinesis_client).to receive(:put_records).and_return(response)

        result = sender.send_batch(events_with_middle_failure)

        # Both successful events should be collected
        expect(result[:succeeded]).to eq([event_1, event_3])
        # Transient failure should be in failed array
        expect(result[:failed].length).to eq(1)
        expect(result[:failed].first.event).to eq(event_2)
        expect(result[:failed].first.transient?).to be true
      end
    end

    context 'with transient error on entire batch' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event) { create_database_event }
      let(:events) { [event] }

      before do
        allow(kinesis_client).to receive(:put_records)
          .and_raise(Aws::Kinesis::Errors::ServiceUnavailable.new(nil, 'Service unavailable'))
      end

      it 'returns all events as transient failures' do
        result = sender.send_batch(events)
        expect(result[:succeeded]).to be_empty
        expect(result[:failed].length).to eq(1)

        failure = result[:failed].first
        expect(failure.event).to eq(event)
        expect(failure.error_code).to eq('Aws::Kinesis::Errors::ServiceUnavailable')
        expect(failure.error_message).to eq('Service unavailable')
        expect(failure.transient?).to be true
        expect(failure.permanent?).to be false
      end
    end

    context 'with permanent error' do
      before do
        skip "Database event tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      end

      let(:event) { create_database_event }
      let(:events) { [event] }

      context 'when entire batch fails with validation exception' do
        before do
          allow(kinesis_client).to receive(:put_records)
            .and_raise(Aws::Kinesis::Errors::ValidationException.new(nil, 'Invalid stream name'))
        end

        it 'raises the exception (configuration error, not event data error)' do
          expect { sender.send_batch(events) }.to raise_error(
            Aws::Kinesis::Errors::ValidationException,
            'Invalid stream name',
          )
        end
      end

      context 'when individual record has permanent error code' do
        let(:event_1) { create_database_event(stream_name: 'stream1') }
        let(:event_2) { create_database_event(stream_name: 'stream1') }
        let(:events) { [event_1, event_2] }

        before do
          # First event succeeds, second has permanent error
          response = mock_put_records_response([
            { error_code: nil, error_message: nil },
            { error_code: 'ValidationException', error_message: 'Invalid record' },
          ])
          allow(kinesis_client).to receive(:put_records).and_return(response)
        end

        it 'returns succeeded and failed events, continues processing' do
          result = sender.send_batch(events)
          expect(result[:succeeded]).to eq([event_1])
          expect(result[:failed].length).to eq(1)
          failure = result[:failed].first
          expect(failure.event).to eq(event_2)
          expect(failure.error_code).to eq('ValidationException')
          expect(failure.error_message).to eq('Invalid record')
          expect(failure.transient?).to be false
          expect(failure.permanent?).to be true
        end
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
        # Mock successful responses for each stream
        response_two_records = mock_put_records_response([
          { error_code: nil, error_message: nil },
          { error_code: nil, error_message: nil },
        ])
        response_one_record = mock_put_records_response([
          { error_code: nil, error_message: nil },
        ])
        allow(kinesis_client).to receive(:put_records) do |args|
          if args[:stream_name] == 'stream1'
            response_two_records
          else
            response_one_record
          end
        end
      end

      it 'groups events by stream and sends batches to each stream' do
        sender.send_batch(events)

        # Should send one batch to stream1 with events 1 and 3
        expect(kinesis_client).to have_received(:put_records).with(
          stream_name: 'stream1',
          records: [
            {
              data: event_1.event_data.merge(id: event_1.id).to_json,
              partition_key: event_1.partition_key,
            },
            {
              data: event_3.event_data.merge(id: event_3.id).to_json,
              partition_key: event_3.partition_key,
            },
          ],
        ).once

        # Should send one batch to stream2 with event 2
        expect(kinesis_client).to have_received(:put_records).with(
          stream_name: 'stream2',
          records: [
            {
              data: event_2.event_data.merge(id: event_2.id).to_json,
              partition_key: event_2.partition_key,
            },
          ],
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

  def mock_put_records_response(record_results)
    record_result_struct = Struct.new(:error_code, :error_message, keyword_init: true)
    response_struct = Struct.new(:records)

    records = record_results.map { |attrs| record_result_struct.new(**attrs) }
    response_struct.new(records)
  end
end
