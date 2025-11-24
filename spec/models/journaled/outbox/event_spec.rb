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

  describe '.oldest_non_failed_timestamp' do
    it 'returns nil when no events exist' do
      expect(described_class.oldest_non_failed_timestamp).to be_nil
    end

    it 'returns timestamp of oldest non-failed event' do
      # Create events - the database will generate UUIDs, which are ordered chronologically
      older_event = described_class.create!(
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key1',
        stream_name: 'test_stream',
      )

      described_class.create!(
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key2',
        stream_name: 'test_stream',
      )

      timestamp = described_class.oldest_non_failed_timestamp

      expect(timestamp).to be_within(1.second).of(older_event.created_at)
    end

    it 'ignores failed events' do
      # Create a failed event
      described_class.create!(
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key1',
        stream_name: 'test_stream',
        failed_at: Time.current,
      )

      # Create a non-failed event
      newer_event = described_class.create!(
        event_type: 'test_event',
        event_data: { test: 'data' },
        partition_key: 'key2',
        stream_name: 'test_stream',
      )

      timestamp = described_class.oldest_non_failed_timestamp

      expect(timestamp).to be_within(1.second).of(newer_event.created_at)
    end
  end

  describe '.fetch_batch_for_update' do
    context 'when in batch mode' do
      before do
        Journaled.outbox_processing_mode = :batch
      end

      it 'generates correct SQL with SKIP LOCKED' do
        queries = []
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
          queries << payload[:sql] if payload[:sql].include?('FOR UPDATE')
        end

        described_class.fetch_batch_for_update

        expected_sql = <<~SQL.squish
          SELECT "journaled_outbox_events".*
          FROM "journaled_outbox_events"
          WHERE "journaled_outbox_events"."failed_at" IS NULL
          ORDER BY "journaled_outbox_events"."id" ASC
          LIMIT $1
          FOR UPDATE SKIP LOCKED
        SQL

        actual_sql = queries.first.squish
        expect(actual_sql).to eq(expected_sql)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end
    end

    context 'when in guaranteed_order mode' do
      before do
        Journaled.outbox_processing_mode = :guaranteed_order
      end

      it 'generates correct SQL with blocking FOR UPDATE' do
        queries = []
        subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |_name, _start, _finish, _id, payload|
          queries << payload[:sql] if payload[:sql].include?('FOR UPDATE')
        end

        described_class.fetch_batch_for_update

        expected_sql = <<~SQL.squish
          SELECT "journaled_outbox_events".*
          FROM "journaled_outbox_events"
          WHERE "journaled_outbox_events"."failed_at" IS NULL
          ORDER BY "journaled_outbox_events"."id" ASC
          LIMIT $1
          FOR UPDATE
        SQL

        actual_sql = queries.first.squish
        expect(actual_sql).to eq(expected_sql)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end
    end
  end
end
