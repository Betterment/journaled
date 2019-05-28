require 'rails_helper'

# This is a controller mixin, but testing as a model spec!
RSpec.describe Journaled::Actor do
  let(:user) { double }
  let(:klass) do
    Class.new do
      cattr_accessor :before_actions
      self.before_actions = []

      def self.before_action(&hook)
        before_actions << hook
      end

      include Journaled::Actor

      self.journaled_actor = :current_user

      def current_user
        nil
      end

      def trigger_before_actions
        before_actions.each { |proc| instance_eval(&proc) }
      end
    end
  end

  subject { klass.new }

  it "Stores a thunk returning nil if current_user returns nil" do
    subject.trigger_before_actions

    allow(subject).to receive(:current_user).and_return(nil) # rubocop:disable RSpec/SubjectStub

    expect(RequestStore.store[:journaled_actor_proc].call).to eq nil
  end

  it "Stores a thunk returning current_user if it is set when called" do
    subject.trigger_before_actions

    allow(subject).to receive(:current_user).and_return(user) # rubocop:disable RSpec/SubjectStub

    expect(RequestStore.store[:journaled_actor_proc].call).to eq user
  end
end
