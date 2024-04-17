# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled do
  it "is enabled in production" do
    allow(Rails).to receive(:env).and_return("production")
    expect(described_class).to be_enabled
  end

  it "is disabled in development" do
    allow(Rails).to receive(:env).and_return("development")
    expect(described_class).not_to be_enabled
  end

  it "is disabled in test" do
    allow(Rails).to receive(:env).and_return("test")
    expect(described_class).not_to be_enabled
  end

  it "is enabled in whatevs" do
    allow(Rails).to receive(:env).and_return("whatevs")
    expect(described_class).to be_enabled
  end

  it "is enabled when explicitly enabled in development" do
    with_env(JOURNALED_ENABLED: true) do
      allow(Rails).to receive(:env).and_return("development")
      expect(described_class).to be_enabled
    end
  end

  it "is disabled when explicitly disabled in production" do
    with_env(JOURNALED_ENABLED: false) do
      allow(Rails).to receive(:env).and_return("production")
      expect(described_class).not_to be_enabled
    end
  end

  it "is disabled when explicitly disabled with empty string" do
    with_env(JOURNALED_ENABLED: '') do
      allow(Rails).to receive(:env).and_return("production")
      expect(described_class).not_to be_enabled
    end
  end

  describe "#actor_uri" do
    it "delegates to ActorUriProvider" do
      allow(Journaled::ActorUriProvider).to receive(:instance)
        .and_return(instance_double(Journaled::ActorUriProvider, actor_uri: "my actor uri"))
      expect(described_class.actor_uri).to eq "my actor uri"
    end
  end

  describe '.detect_queue_adapter!' do
    it 'raises an error unless the queue adapter is DB-backed' do
      expect { described_class.detect_queue_adapter! }.to raise_error <<~MSG
        Journaled has detected an unsupported ActiveJob queue adapter: `:test`

        Journaled jobs must be enqueued transactionally to your primary database.

        Please install the appropriate gems and set `queue_adapter` to one of the following:
        - `:delayed`
        - `:delayed_job`
        - `:good_job`
        - `:que`

        Read more at https://github.com/Betterment/journaled
      MSG
    end

    context 'when the queue adapter is supported' do
      before do
        stub_const("ActiveJob::QueueAdapters::DelayedAdapter", Class.new)
        ActiveJob::Base.disable_test_adapter
        ActiveJob::Base.queue_adapter = :delayed
      end

      around do |example|
        example.run
      ensure
        ActiveJob::Base.queue_adapter = :test
        ActiveJob::Base.enable_test_adapter(ActiveJob::QueueAdapters::TestAdapter.new)
      end

      it 'does not raise an error' do
        expect { described_class.detect_queue_adapter! }.not_to raise_error
      end
    end
  end
end
