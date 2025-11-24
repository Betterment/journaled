# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Outbox::BatchProcessor do
  before do
    skip "Outbox tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
  end
  subject(:processor) { described_class.new }

  let(:batch_sender) { instance_double(Journaled::KinesisBatchSender) }

  before do
    allow(Journaled::KinesisBatchSender).to receive(:new).and_return(batch_sender)
  end

  describe '#process_batch' do
    context 'when no events are available' do
      before do
        allow(Journaled::Outbox::Event).to receive(:fetch_batch_for_update).and_return([])
        allow(batch_sender).to receive(:send_batch).and_return(succeeded: [], failed: [])
      end

      it 'returns zero counts' do
        result = processor.process_batch
        expect(result).to eq(succeeded: 0, failed_permanently: 0, failed_transiently: 0)
      end

      it 'sends empty batch to batch sender' do
        processor.process_batch
        expect(batch_sender).to have_received(:send_batch).with([])
      end
    end

    context 'when events are available' do
      let!(:event_1) { create_database_event }
      let!(:event_2) { create_database_event }
      let(:events) { [event_1, event_2] }

      before do
        allow(Journaled::Outbox::Event).to receive(:fetch_batch_for_update).and_return(events)
      end

      context 'with all successful deliveries' do
        before do
          allow(batch_sender).to receive(:send_batch).with(events).and_return(
            succeeded: events,
            failed: [],
          )
        end

        it 'sends full batch to Kinesis' do
          processor.process_batch
          expect(batch_sender).to have_received(:send_batch).with(events)
        end

        it 'deletes events from database' do
          expect { processor.process_batch }.to change { Journaled::Outbox::Event.count }.by(-2)
          expect(Journaled::Outbox::Event.where(id: [event_1.id, event_2.id])).to be_empty
        end

        it 'returns correct stats' do
          result = processor.process_batch
          expect(result).to eq(succeeded: 2, failed_permanently: 0, failed_transiently: 0)
        end
      end

      context 'with transient failures' do
        let!(:event_1) { create_database_event }
        let!(:event_2) { create_database_event }
        let(:transient_failure) do
          Journaled::KinesisFailedEvent.new(
            event: event_1,
            error_code: 'ProvisionedThroughputExceededException',
            error_message: 'Rate exceeded',
            transient: true,
          )
        end

        before do
          allow(batch_sender).to receive(:send_batch).with(events).and_return(
            succeeded: [event_2],
            failed: [transient_failure],
          )
        end

        it 'leaves the transiently failed event in the queue (not marked as failed)' do
          processor.process_batch
          event_1.reload
          expect(event_1.failed_at).to be_nil
          expect(Journaled::Outbox::Event.exists?(event_1.id)).to be true
        end

        it 'processes successful events' do
          processor.process_batch
          expect(Journaled::Outbox::Event.exists?(event_2.id)).to be false
        end

        it 'returns correct stats' do
          result = processor.process_batch
          expect(result).to eq(succeeded: 1, failed_permanently: 0, failed_transiently: 1)
        end
      end

      context 'with permanent failures' do
        let!(:event_1) { create_database_event }
        let!(:event_2) { create_database_event }
        let(:failure) do
          Journaled::KinesisFailedEvent.new(
            event: event_1,
            error_code: 'InvalidArgumentException',
            error_message: 'Invalid data',
            transient: false,
          )
        end

        before do
          allow(batch_sender).to receive(:send_batch).with(events).and_return(
            succeeded: [event_2],
            failed: [failure],
          )
        end

        it 'marks event as failed immediately and continues processing' do
          processor.process_batch
          event_1.reload
          expect(event_1.failed_at).not_to be_nil
          expect(event_1.failure_reason).to eq('InvalidArgumentException: Invalid data')
        end

        it 'continues processing subsequent events' do
          processor.process_batch
          expect(Journaled::Outbox::Event.exists?(event_2.id)).to be false
        end

        it 'returns correct stats' do
          result = processor.process_batch
          expect(result).to eq(succeeded: 1, failed_permanently: 1, failed_transiently: 0)
        end
      end

      context 'with mixed failure types' do
        let!(:event_1) { create_database_event }
        let!(:event_2) { create_database_event }
        let!(:event_3) { create_database_event }
        let(:events) { [event_1, event_2, event_3] }
        let(:permanent_failure) do
          Journaled::KinesisFailedEvent.new(
            event: event_1,
            error_code: 'InvalidArgumentException',
            error_message: 'Invalid data',
            transient: false,
          )
        end
        let(:transient_failure) do
          Journaled::KinesisFailedEvent.new(
            event: event_2,
            error_code: 'ProvisionedThroughputExceededException',
            error_message: 'Rate exceeded',
            transient: true,
          )
        end

        before do
          allow(batch_sender).to receive(:send_batch).with([event_1, event_2, event_3]).and_return(
            succeeded: [event_3],
            failed: [permanent_failure, transient_failure],
          )
        end

        it 'marks permanent failure as failed' do
          processor.process_batch
          event_1.reload
          expect(event_1.failed_at).not_to be_nil
          expect(event_1.failure_reason).to eq('InvalidArgumentException: Invalid data')
        end

        it 'leaves transient failure in queue' do
          processor.process_batch
          event_2.reload
          expect(event_2.failed_at).to be_nil
        end

        it 'processes successful event' do
          processor.process_batch
          expect(Journaled::Outbox::Event.exists?(event_3.id)).to be false
        end

        it 'returns correct stats' do
          result = processor.process_batch
          expect(result).to eq(succeeded: 1, failed_permanently: 1, failed_transiently: 1)
        end
      end
    end

    context 'mode switching' do
      before do
        allow(Journaled::KinesisBatchSender).to receive(:new).and_call_original
        allow(Journaled::KinesisSequentialSender).to receive(:new).and_call_original
      end

      context 'when in batch mode' do
        before do
          Journaled.outbox_processing_mode = :batch
        end

        it 'initializes with KinesisBatchSender' do
          processor = described_class.new
          expect(processor.send(:batch_sender)).to be_a(Journaled::KinesisBatchSender)
        end
      end

      context 'when in guaranteed_order mode' do
        before do
          Journaled.outbox_processing_mode = :guaranteed_order
        end

        it 'initializes with KinesisSequentialSender' do
          processor = described_class.new
          expect(processor.send(:batch_sender)).to be_a(Journaled::KinesisSequentialSender)
        end
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
