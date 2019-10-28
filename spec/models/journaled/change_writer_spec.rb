require 'rails_helper'

RSpec.describe Journaled::ChangeWriter do
  let(:model) do
    now = Time.zone.now
    double(
      "Soldier",
      id: 28_473,
      class: model_class,
      attributes: {
        "name" => "bob",
        "rank" => "first lieutenant",
        "serial_number" => "foobar",
        "last_sign_in_at" => now,
      },
      saved_changes: {
        "name" => %w(bill bob),
        "last_sign_in_at" => now,
      },
      journaled_enqueue_opts: {},
    )
  end

  let(:model_class) do
    double(
      "SoldierClass",
      table_name: "soldiers",
      attribute_names: %w(id name rank serial_number last_sign_in_at),
    )
  end

  let(:change_definition) do
    Journaled::ChangeDefinition.new(
      attribute_names: %i(name rank serial_number),
      logical_operation: "identity_change",
    )
  end

  let(:faulty_change_definition) do
    Journaled::ChangeDefinition.new(
      attribute_names: %i(name rank serial_number nonexistent_thingie),
      logical_operation: "identity_change",
    )
  end

  subject { described_class.new(model: model, change_definition: change_definition) }

  it "fails to instantiate with an undefined attribute_name" do
    expect { described_class.new(model: model, change_definition: faulty_change_definition) }.to raise_error(/\bnonexistent_thingie\n/)
  end

  describe "#relevant_attributes" do
    let(:model) do
      double(
        "Soldier",
        id: 28_473,
        class: model_class,
        attributes: {
          "name" => "bill",
          "rank" => "first lieutenant",
          "serial_number" => "foobar",
          "last_sign_in_at" => Time.zone.now,
        },
        saved_changes: {},
        journaled_enqueue_opts: {},
      )
    end

    it "returns all relevant attributes regardless of saved changes" do
      expect(subject.relevant_attributes).to eq(
        "name" => "bill",
        "rank" => "first lieutenant",
        "serial_number" => "foobar",
      )
    end
  end

  describe "#relevant_unperturbed_attributes" do
    let(:model) do
      double(
        "Soldier",
        id: 28_473,
        class: model_class,
        attributes: {
          "name" => "bill",
          "rank" => "first lieutenant",
          "serial_number" => "foobar",
          "last_sign_in_at" => Time.zone.now,
        },
        changes: {
          "name" => %w(bob bill),
        },
        journaled_enqueue_opts: {},
      )
    end

    it "returns the pre-change value of the attributes, regardless of whether they changed" do
      expect(subject.relevant_unperturbed_attributes).to eq(
        "name" => "bob",
        "rank" => "first lieutenant",
        "serial_number" => "foobar",
      )
    end
  end

  describe "#relevant_changed_attributes" do
    it "returns only relevant changes" do
      expect(subject.relevant_changed_attributes).to eq("name" => "bob")
    end
  end

  describe "#actor_uri" do
    it "delegates to ActorUriProvider" do
      allow(Journaled::ActorUriProvider).to receive(:instance).and_return(double(actor_uri: "my actor uri"))
      expect(Journaled.actor_uri).to eq "my actor uri"
    end
  end

  describe "#journaled_change_for" do
    it "stores passed changes serialized to json" do
      expect(subject.journaled_change_for("update", "name" => "bob").changes).to eq('{"name":"bob"}')
    end

    it "stores the model's table_name" do
      expect(subject.journaled_change_for("update", {}).table_name).to eq("soldiers")
    end

    it "converts the model's record_id to a string" do
      expect(subject.journaled_change_for("update", {}).record_id).to eq("28473")
    end

    it "stuffs the database operation directly" do
      expect(subject.journaled_change_for("update", {}).database_operation).to eq("update")
      expect(subject.journaled_change_for("delete", {}).database_operation).to eq("delete")
    end

    it "includes logical_operation" do
      expect(subject.journaled_change_for("update", {}).logical_operation).to eq("identity_change")
    end

    it "doesn't set journaled_app_name if model class doesn't respond to it" do
      expect(subject.journaled_change_for("update", {}).journaled_app_name).to eq(nil)
    end

    context "with journaled default app name set" do
      around do |example|
        orig_app_name = Journaled.default_app_name
        Journaled.default_app_name = "foo"
        example.run
        Journaled.default_app_name = orig_app_name
      end

      it "passes through default" do
        expect(subject.journaled_change_for("update", {}).journaled_app_name).to eq("foo")
      end
    end

    context "when model class defines journaled_app_name" do
      before do
        allow(model_class).to receive(:journaled_app_name).and_return("my_app")
      end

      it "sets journaled_app_name if model_class responds to it" do
        expect(subject.journaled_change_for("update", {}).journaled_app_name).to eq("my_app")
      end
    end
  end

  context "with journaling stubbed" do
    let(:journaled_change) { instance_double(Journaled::Change, journal!: true) }

    before do
      allow(Journaled::Change).to receive(:new).and_return(nil) # must be restubbed to work in context
    end

    describe "#create" do
      let(:model) do
        double(
          "Soldier",
          id: 28_473,
          class: model_class,
          attributes: {
            "name" => "bill",
            "rank" => "first lieutenant",
            "serial_number" => "foobar",
            "last_sign_in_at" => Time.zone.now,
          },
          saved_changes: {},
          journaled_enqueue_opts: {},
        )
      end

      it "always journals all relevant attributes, even if unchanged" do
        allow(Journaled::Change).to receive(:new) do |opts|
          expect(opts[:changes]).to eq '{"name":"bill","rank":"first lieutenant","serial_number":"foobar"}'
          journaled_change
        end

        subject.create

        expect(Journaled::Change).to have_received(:new)
        expect(journaled_change).to have_received(:journal!)
      end
    end

    describe "#update" do
      it "journals only relevant changes" do
        allow(Journaled::Change).to receive(:new) do |opts|
          expect(opts[:changes]).to eq '{"name":"bob"}'
          journaled_change
        end

        subject.update

        expect(Journaled::Change).to have_received(:new)
        expect(journaled_change).to have_received(:journal!)
      end

      context "with no changes" do
        let(:model) do
          double(
            "Soldier",
            id: 28_473,
            class: model_class,
            attributes: {
              "name" => "bill",
              "rank" => "first lieutenant",
              "serial_number" => "foobar",
              "last_sign_in_at" => Time.zone.now,
            },
            saved_changes: {},
          )
        end

        it "doesn't journal" do
          subject.update

          expect(Journaled::Change).not_to have_received(:new)
          expect(journaled_change).not_to have_received(:journal!)
        end
      end
    end

    describe "#delete" do
      let(:model) do
        now = Time.zone.now
        double(
          "Soldier",
          id: 28_473,
          class: model_class,
          attributes: {
            "name" => "bob",
            "rank" => "first lieutenant",
            "serial_number" => "foobar",
            "last_sign_in_at" => now,
          },
          changes: {
            "name" => %w(bill bob),
          },
          journaled_enqueue_opts: {},
        )
      end

      it "journals the unperturbed values of all relevant attributes" do
        allow(Journaled::Change).to receive(:new) do |opts|
          expect(JSON.parse(opts[:changes])).to eq(
            "name" => "bill",
            "rank" => "first lieutenant",
            "serial_number" => "foobar",
          )
          journaled_change
        end

        subject.delete

        expect(Journaled::Change).to have_received(:new)
        expect(journaled_change).to have_received(:journal!)
      end
    end
  end
end
