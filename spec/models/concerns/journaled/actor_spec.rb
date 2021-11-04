require 'rails_helper'

# This is a controller mixin, but testing as a model spec!
RSpec.describe Journaled::Actor do
  let(:user) { double("User") }
  let(:klass) do
    Class.new do
      cattr_accessor(:before_actions) { [] }

      def self.before_action(method_name, _opts)
        before_actions << method_name
      end

      include Journaled::Actor

      self.journaled_actor = :current_user

      def current_user
        nil
      end

      def trigger_before_actions
        before_actions.each { |method_name| send(method_name) }
      end
    end
  end

  subject { klass.new }

  it "Stores a thunk returning nil if current_user returns nil" do
    subject.trigger_before_actions

    allow(subject).to receive(:current_user).and_return(nil)

    expect(Journaled::Current.journaled_actor_proc.call).to eq nil
    expect(Journaled::Current.actor).to eq nil
  end

  it "Stores a thunk returning current_user if it is set when called" do
    subject.trigger_before_actions

    allow(subject).to receive(:current_user).and_return(user)

    expect(Journaled::Current.journaled_actor_proc.call).to eq user
    expect(Journaled::Current.actor).to eq user
  end
end
