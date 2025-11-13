# frozen_string_literal: true

namespace :journaled_worker do
  desc "Start a Journaled worker to process Outbox-style events"
  task work: :environment do
    Journaled::Outbox::Worker.new.start
  end
end
