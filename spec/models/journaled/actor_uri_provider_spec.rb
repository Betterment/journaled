require 'rails_helper'

RSpec.describe Journaled::ActorUriProvider do
  describe "#actor_uri" do
    let(:request_store) { class_double(RequestStore, :[] => nil) }
    let(:actor) { instance_double(ActiveRecord::Base, to_global_id: actor_gid) }
    let(:actor_gid) { instance_double(GlobalID, to_s: "my_fancy_gid") }
    let(:program_name) { "/usr/local/bin/puma_or_something" }

    subject { described_class.instance }

    around do |example|
      orig_program_name = $PROGRAM_NAME
      $PROGRAM_NAME = program_name
      example.run
      $PROGRAM_NAME = orig_program_name
    end

    before do
      allow(RequestStore).to receive(:store).and_return(request_store)
    end

    it "returns the global ID of the entity returned by RequestStore.store[:journaled_actor_proc].call if set" do
      allow(request_store).to receive(:[]).and_return(-> { actor })
      expect(subject.actor_uri).to eq("my_fancy_gid")
      expect(request_store).to have_received(:[]).with(:journaled_actor_proc)
    end

    context "when running in rake" do
      let(:program_name) { "rake" }
      it "slurps up command line username if available" do
        allow(Etc).to receive(:getlogin).and_return("my_unix_username")
        expect(subject.actor_uri).to eq("gid://local/my_unix_username")
      end
    end

    it "falls back to printing out a GID of bare app name" do
      expect(subject.actor_uri).to eq("gid://dummy")
    end
  end
end
