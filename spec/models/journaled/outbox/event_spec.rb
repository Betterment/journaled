# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Outbox::Event do
  before do
    skip "Outbox tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
  end
  describe '.connection' do
    it 'uses the configured base class connection' do
      expect(described_class.connection).to eq(ActiveRecord::Base.connection)
    end

    context 'with custom outbox_base_class_name' do
      let(:custom_base_class) { Class.new(ActiveRecord::Base) { self.abstract_class = true } }

      before do
        stub_const('CustomEventsBase', custom_base_class)
      end

      around do |example|
        old_config = Journaled.outbox_base_class_name
        Journaled.outbox_base_class_name = 'CustomEventsBase'
        example.run
        Journaled.outbox_base_class_name = old_config
      end

      it 'uses the custom base class connection' do
        expect(described_class.connection).to eq(CustomEventsBase.connection)
      end
    end
  end

  describe '.timestamp_from_uuid' do
    it 'extracts timestamp from UUID v7' do
      # UUID v7 with known timestamp: 2024-01-01 00:00:00 UTC (1704067200000 milliseconds)
      # In hex: 0x18CC251F400 = 018cc251f400
      uuid_with_known_timestamp = '018cc251-f400-7000-8000-000000000000'

      timestamp = described_class.timestamp_from_uuid(uuid_with_known_timestamp)

      expect(timestamp).to be_within(1.second).of(Time.zone.parse('2024-01-01 00:00:00 UTC'))
    end

    it 'handles UUID without dashes' do
      uuid_without_dashes = '018cc251f40070008000000000000000'

      timestamp = described_class.timestamp_from_uuid(uuid_without_dashes)

      expect(timestamp).to be_within(1.second).of(Time.zone.parse('2024-01-01 00:00:00 UTC'))
    end
  end

  describe '.oldest_non_failed_timestamp' do
    it 'returns nil when no events exist' do
      expect(described_class.oldest_non_failed_timestamp).to be_nil
    end

    it 'returns timestamp of oldest non-failed event' do
      # Create events with different timestamps embedded in their UUIDs
      older_event = described_class.create!(
        id: '018cc251-f400-7000-8000-000000000000', # 2024-01-01
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key1',
        stream_name: 'test_stream',
      )

      described_class.create!(
        id: '018cc252-0000-7000-8000-000000000000', # slightly newer
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key2',
        stream_name: 'test_stream',
      )

      timestamp = described_class.oldest_non_failed_timestamp
      expected_timestamp = described_class.timestamp_from_uuid(older_event.id)

      expect(timestamp).to be_within(1.second).of(expected_timestamp)
    end

    it 'ignores failed events' do
      # Create a failed event with older timestamp
      described_class.create!(
        id: '018cc251-f400-7000-8000-000000000000', # 2024-01-01
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key1',
        stream_name: 'test_stream',
        failed_at: Time.current,
      )

      # Create a non-failed event with newer timestamp
      newer_event = described_class.create!(
        id: '018cc252-0000-7000-8000-000000000000', # slightly newer
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key2',
        stream_name: 'test_stream',
      )

      timestamp = described_class.oldest_non_failed_timestamp
      expected_timestamp = described_class.timestamp_from_uuid(newer_event.id)

      expect(timestamp).to be_within(1.second).of(expected_timestamp)
    end
  end
end
