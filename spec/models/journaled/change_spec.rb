# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::Change do
  subject(:change) do
    described_class.new(
      table_name: 'widgets',
      record_id: '1',
      database_operation: 'update',
      logical_operation: :widget_change,
      changes: '{}',
      journaled_stream_name: nil,
      journaled_enqueue_opts: {},
      actor: 'gid://app/User/1',
      tagged:,
    )
  end

  context 'when tagged: false (the default)' do
    let(:tagged) { false }

    it 'omits :tags from the journaled payload' do
      expect(change.journaled_attributes.keys).not_to include(:tags)
    end
  end

  context 'when tagged: true' do
    let(:tagged) { true }

    around do |example|
      Journaled.tagged(impersonator: 'gid://app/Advisor/2') { example.run }
    end

    it 'includes the current Journaled tags in the journaled payload' do
      expect(change.journaled_attributes[:tags]).to eq(impersonator: 'gid://app/Advisor/2')
    end
  end

  context 'when a tagged instance and an untagged instance coexist' do
    subject(:untagged_change) do
      described_class.new(
        table_name: 'widgets',
        record_id: '1',
        database_operation: 'update',
        logical_operation: :widget_change,
        changes: '{}',
        journaled_stream_name: nil,
        journaled_enqueue_opts: {},
        actor: 'gid://app/User/1',
        tagged: false,
      )
    end

    let(:tagged_change) do
      described_class.new(
        table_name: 'widgets',
        record_id: '2',
        database_operation: 'update',
        logical_operation: :widget_change,
        changes: '{}',
        journaled_stream_name: nil,
        journaled_enqueue_opts: {},
        actor: 'gid://app/User/2',
        tagged: true,
      )
    end

    it 'includes :tags only in the tagged instance\'s payload' do
      tagged_change

      expect(untagged_change.journaled_attributes.keys).not_to include(:tags)
    end
  end
end
