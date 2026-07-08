# typed: true

# Journaled mixes AuditLog into every Active Record class at boot via
# `ActiveSupport.on_load(:active_record) { include Journaled::AuditLog }`
# (lib/journaled/audit_log.rb). Runtime reflection tools attribute that mixin
# inconsistently depending on load order — under some hosts it lands in the
# activerecord gem's RBI, under others it is lost entirely — so declare it
# here. Tapioca merges RBI files a gem exports under rbi/ into the RBI it
# generates for the gem, which makes `has_audit_log`, `skip_audit_log`, and
# the blocked-method guards resolve statically in every consuming app.
class ActiveRecord::Base
  include Journaled::AuditLog
end
