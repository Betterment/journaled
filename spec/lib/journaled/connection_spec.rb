require 'rails_helper'

RSpec.describe Journaled::Connection do
  describe '.available?, .stage!' do
    let(:event_class) { Class.new { include Journaled::Event } }
    let(:event) do
      instance_double(
        event_class,
        journaled_schema_name: nil,
        journaled_attributes: {},
        journaled_partition_key: '',
        journaled_stream_name: nil,
        journaled_enqueue_opts: {},
      )
    end

    it 'returns false, and raises an error when events are staged' do
      expect(described_class.available?).to be false
      expect { described_class.stage!(event) }.to raise_error(Journaled::TransactionSafetyError)
    end

    context 'when inside of a transaction' do
      it 'returns true, and allows for staging events' do
        ActiveRecord::Base.transaction do
          expect(described_class.available?).to be true
          expect { described_class.stage!(event) }.not_to raise_error
        end
      end

      context 'when transactional batching is disabled' do
        around do |example|
          Journaled.transactional_batching_enabled = false
          example.run
        ensure
          Journaled.transactional_batching_enabled = true
        end

        it 'returns false, and raises an error when events are staged' do
          expect(described_class.available?).to be false
          expect { described_class.stage!(event) }.to raise_error(Journaled::TransactionSafetyError)
        end
      end
    end
  end
end
