# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::DeliveryAdapter do
  describe '.deliver' do
    it 'raises NoMethodError when not overridden' do
      expect {
        described_class.deliver(events: [], enqueue_opts: {})
      }.to raise_error(NoMethodError, /must implement \.deliver/)
    end
  end

  describe '.transaction_connection' do
    it 'returns nil by default' do
      expect {
        described_class.transaction_connection
      }.to raise_error(NoMethodError, /must implement \.transaction_connection/)
    end
  end

  describe '.validate_configuration!' do
    it 'does nothing by default' do
      expect { described_class.validate_configuration! }.not_to raise_error
    end
  end
end
