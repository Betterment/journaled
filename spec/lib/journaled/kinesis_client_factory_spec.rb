# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Journaled::KinesisClientFactory do
  describe "#build" do
    it "returns a Kinesis client" do
      kinesis_client = Aws::Kinesis::Client.new(stub_responses: true)
      allow(Aws::Kinesis::Client).to receive(:new).and_return(kinesis_client)

      client = described_class.build
      expect(client).to be_a(Aws::Kinesis::Client)
    end
  end

  describe "configuration" do
    subject { described_class.new }

    it "is in us-east-1 by default" do
      with_env(AWS_DEFAULT_REGION: nil) do
        expect(subject.send(:config)).to include(region: 'us-east-1')
      end
    end

    it "respects AWS_DEFAULT_REGION env var" do
      with_env(AWS_DEFAULT_REGION: 'us-west-2') do
        expect(subject.send(:config)).to include(region: 'us-west-2')
      end
    end

    it "doesn't limit retry" do
      expect(subject.send(:config)).to include(retry_limit: 0)
    end

    it "provides no AWS credentials by default" do
      with_env(RUBY_AWS_ACCESS_KEY_ID: nil, RUBY_AWS_SECRET_ACCESS_KEY: nil, JOURNALED_IAM_ROLE_ARN: nil) do
        expect(subject.send(:config)).not_to have_key(:access_key_id)
        expect(subject.send(:config)).not_to have_key(:secret_access_key)
      end
    end

    it "will use legacy credentials if specified" do
      with_env(RUBY_AWS_ACCESS_KEY_ID: 'key_id', RUBY_AWS_SECRET_ACCESS_KEY: 'secret', JOURNALED_IAM_ROLE_ARN: nil) do
        expect(subject.send(:config)).to include(access_key_id: 'key_id', secret_access_key: 'secret')
      end
    end

    it "will set http_idle_timeout by default" do
      expect(subject.send(:config)).to include(http_idle_timeout: 5)
    end

    it "will set http_open_timeout by default" do
      expect(subject.send(:config)).to include(http_open_timeout: 2)
    end

    it "will set http_read_timeout by default" do
      expect(subject.send(:config)).to include(http_read_timeout: 60)
    end

    context "when Journaled.http_idle_timeout is specified" do
      it "will set http_idle_timeout by specified value" do
        allow(Journaled).to receive(:http_idle_timeout).and_return(2)
        expect(subject.send(:config)).to include(http_idle_timeout: 2)
      end
    end

    context "when Journaled.http_open_timeout is specified" do
      it "will set http_open_timeout by specified value" do
        allow(Journaled).to receive(:http_open_timeout).and_return(1)
        expect(subject.send(:config)).to include(http_open_timeout: 1)
      end
    end

    context "when Journaled.http_read_timeout is specified" do
      it "will set http_read_timeout by specified value" do
        allow(Journaled).to receive(:http_read_timeout).and_return(2)
        expect(subject.send(:config)).to include(http_read_timeout: 2)
      end
    end
  end
end
