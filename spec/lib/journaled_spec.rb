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
    let(:uri_provider_double) { instance_double(Journaled::ActorUriProvider, actor_uri: "my actor uri") }

    it "delegates to ActorUriProvider" do
      allow(Journaled::ActorUriProvider).to receive(:instance).and_return(uri_provider_double)
      expect(described_class.actor_uri).to eq "my actor uri"
    end
  end
end
