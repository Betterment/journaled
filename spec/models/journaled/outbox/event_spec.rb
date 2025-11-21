# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Outbox::Event do
  before do
    skip "Outbox tests require PostgreSQL" unless ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
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
