# frozen_string_literal: true

if Rails::VERSION::MAJOR > 5 || (Rails::VERSION::MAJOR == 5 && Rails::VERSION::MINOR >= 2)
  require 'journaled/relation_change_protection'
  ActiveRecord::Relation.class_eval { prepend Journaled::RelationChangeProtection }
end
