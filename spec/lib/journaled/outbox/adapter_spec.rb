# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Outbox::Adapter do
  before do
    skip "Outbox tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
  end
  let(:event_class) { Class.new { include Journaled::Event } }
  let(:event) do
    instance_double(
      event_class,
      id: SecureRandom.uuid,
      journaled_attributes: { id: 'test_id', event_type: 'test_event', created_at: Time.current },
      journaled_partition_key: 'test_partition_key',
      journaled_stream_name: 'test_stream',
    )
  end
  let(:events) { [event] }
  let(:enqueue_opts) { { priority: 15, queue: 'test_queue' } }

  before do
    # Reset table existence cache
    described_class.instance_variable_set(:@table_exists, false)
  end

  describe '.validate_configuration!' do
    context 'when using PostgreSQL' do
      before do
        allow(Journaled::Outbox::Event.connection).to receive(:adapter_name).and_return('PostgreSQL')
      end

      it 'does not raise an error' do
        expect { described_class.validate_configuration! }.not_to raise_error
      end
    end

    context 'when using SQLite' do
      before do
        allow(Journaled::Outbox::Event.connection).to receive(:adapter_name).and_return('SQLite')
      end

      it 'raises an error explaining PostgreSQL is required' do
        expect {
          described_class.validate_configuration!
        }.to raise_error(/PostgreSQL database adapter.*Current adapter: SQLite/m)
      end
    end

    context 'when using MySQL' do
      before do
        allow(Journaled::Outbox::Event.connection).to receive(:adapter_name).and_return('MySQL')
      end

      it 'raises an error explaining PostgreSQL is required' do
        expect {
          described_class.validate_configuration!
        }.to raise_error(/PostgreSQL database adapter.*Current adapter: MySQL/m)
      end
    end
  end

  describe '.transaction_connection' do
    it 'returns the Outbox Event connection' do
      expect(described_class.transaction_connection).to eq(Journaled::Outbox::Event.connection)
    end

    it 'allows Connection module to use it for transactional batching' do
      # This test verifies that the Outbox adapter provides its own connection
      # for transactional batching, so we don't need to configure a queue adapter
      old_adapter = Journaled.delivery_adapter
      begin
        Journaled.delivery_adapter = described_class

        # When using the Outbox adapter, Connection should get its connection from the adapter
        expect(Journaled::Connection.send(:connection)).to eq(Journaled::Outbox::Event.connection)
      ensure
        Journaled.delivery_adapter = old_adapter
      end
    end
  end

  describe '.deliver' do
    context 'when tables exist' do
      it 'creates database event records' do
        expect {
          described_class.deliver(events:, enqueue_opts:)
        }.to change { Journaled::Outbox::Event.count }.by(1)

        db_event = Journaled::Outbox::Event.last
        expect(db_event.event_type).to eq('test_event')
        # event_data is stored as JSON, so keys become strings
        # The application-level id is excluded - DB generates its own
        expected_data = JSON.parse(event.journaled_attributes.except(:id).to_json)
        expect(db_event.event_data).to eq(expected_data)
        expect(db_event.partition_key).to eq('test_partition_key')
        expect(db_event.stream_name).to eq('test_stream')
      end

      context 'with multiple events' do
        let(:event_2) do
          instance_double(
            event_class,
            id: SecureRandom.uuid,
            journaled_attributes: { id: 'test_id2', event_type: 'test_event2', created_at: Time.current },
            journaled_partition_key: 'test_partition_key2',
            journaled_stream_name: 'test_stream2',
          )
        end
        let(:events) { [event, event_2] }

        it 'creates multiple database event records' do
          expect {
            described_class.deliver(events:, enqueue_opts:)
          }.to change { Journaled::Outbox::Event.count }.by(2)
        end
      end
    end

    context 'when tables do not exist' do
      before do
        allow(Journaled::Outbox::Event).to receive(:table_exists?).and_return(false)
      end

      it 'raises a helpful error message' do
        expect {
          described_class.deliver(events:, enqueue_opts:)
        }.to raise_error(
          Journaled::Outbox::Adapter::TableNotFoundError,
          /rake journaled:install:migrations/,
        )
      end
    end
  end
end
