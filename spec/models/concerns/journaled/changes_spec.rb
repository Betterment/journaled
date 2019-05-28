require 'rails_helper'

RSpec.describe Journaled::Changes do
  let(:klass) do
    Class.new do
      cattr_accessor :after_create_hooks
      self.after_create_hooks = []
      cattr_accessor :after_save_hooks
      self.after_save_hooks = []
      cattr_accessor :after_destroy_hooks
      self.after_destroy_hooks = []

      def self.after_create(&hook)
        after_create_hooks << hook
      end

      def self.after_save(opts, &hook)
        # This is a back-door assertion to prevent regressions in the module's hook definition behavior
        raise "expected `unless: :saved_change_to_id?`" unless opts[:unless] == :saved_change_to_id?

        after_save_hooks << hook
      end

      def self.after_destroy(&hook)
        after_destroy_hooks << hook
      end

      include Journaled::Changes
      journal_changes_to :my_heart, as: :change_of_heart

      def trigger_after_create_hooks
        after_create_hooks.each { |proc| instance_eval(&proc) }
      end

      def trigger_after_save_hooks
        after_save_hooks.each { |proc| instance_eval(&proc) }
      end

      def trigger_after_destroy_hooks
        after_destroy_hooks.each { |proc| instance_eval(&proc) }
      end
    end
  end

  subject { klass.new }

  let(:change_writer) { double(Journaled::ChangeWriter, create: true, update: true, delete: true) }

  before do
    allow(Journaled::ChangeWriter).to receive(:new) do |opts|
      expect(opts[:model]).to eq(subject)
      expect(opts[:change_definition].logical_operation).to eq(:change_of_heart)
      change_writer
    end
  end

  it "can be asserted on with our matcher" do
    expect(klass).to journal_changes_to(:my_heart, as: :change_of_heart)

    expect(klass).not_to journal_changes_to(:foobaloo, as: :an_event_to_remember)

    expect {
      expect(klass).to journal_changes_to(:foobaloo, as: :an_event_to_remember)
    }.to raise_error(/> to journal changes to :foobaloo as :an_event_to_remember/)

    expect {
      expect(klass).not_to journal_changes_to(:my_heart, as: :change_of_heart)
    }.to raise_error(/> not to journal changes to :my_heart as :change_of_heart/)
  end

  it "has a single change definition" do
    expect(klass._journaled_change_definitions.length).to eq 1
  end

  it "journals create events on create" do
    subject.trigger_after_create_hooks

    expect(change_writer).to have_received(:create)
    expect(Journaled::ChangeWriter).to have_received(:new)
  end

  it "journals update events on save" do
    subject.trigger_after_save_hooks

    expect(change_writer).to have_received(:update)
    expect(Journaled::ChangeWriter).to have_received(:new)
  end

  it "journals delete events on destroy" do
    subject.trigger_after_destroy_hooks

    expect(change_writer).to have_received(:delete)
    expect(Journaled::ChangeWriter).to have_received(:new)
  end
end
