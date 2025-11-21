# Journaled

A Rails engine to durably deliver schematized events to Amazon Kinesis via ActiveJob.

More specifically, `journaled` is composed of three opinionated pieces:
schema definition/validation via JSON Schema, transactional enqueueing
via ActiveJob (specifically, via a DB-backed queue adapter), and event
transmission via Amazon Kinesis. Our current use-cases include
transmitting audit events for durable storage in S3 and/or analytical
querying in Amazon Redshift.

Journaled provides an at-least-once event delivery guarantee assuming
ActiveJob's queue adapter is not configured to delete jobs on failure.

Note: Do not use the journaled gem to build an event sourcing solution
as it does not guarantee total ordering of events. It's possible we'll
add scoped ordering capability at a future date (and would gladly
entertain pull requests), but it is presently only designed to provide a
durable, eventually consistent record that discrete events happened.

**See [upgrades](#upgrades) below if you're upgrading from an older `journaled` version!**

## Installation

1. **Configure a queue adapter** (only required if using the default ActiveJob delivery adapter):

    If you haven't already,
    [configure ActiveJob](https://guides.rubyonrails.org/active_job_basics.html)
    to use one of the following queue adapters:

    - `:delayed_job` (via `delayed_job_active_record`)
    - `:que`
    - `:good_job`
    - `:delayed`

    Ensure that your queue adapter is not configured to delete jobs on failure.

    **If you launch your application in production mode and the gem detects that
    `ActiveJob::Base.queue_adapter` is not in the above list, it will raise an exception
    and prevent your application from performing unsafe journaling.**

    The following configurations are __not supported__ by Journaled:

    ```ruby
    config.active_job.enqueue_after_transaction_commit = :always
    config.active_job.enqueue_after_transaction_commit = true
    ```

    If you're using Rails 7.2 with the `:test` adapter, please use the following configuration:

    ```ruby
    config.active_job.enqueue_after_transaction_commit = :never
    ```

    This configuration isn't necessary for applications running Rails 8+.

    **Note:** If you plan to use the [Outbox-style Event Processing](#outbox-style-event-processing-optional) (Outbox adapter), you can skip this step entirely, as the Outbox adapter does not use ActiveJob.

2. To integrate Journaled into your application, simply include the gem in your
app's Gemfile.

    ```ruby
    gem 'journaled'
    ```

    If you use rspec, add the following to your rails helper:

    ```ruby
    # spec/rails_helper.rb

    # ... your other requires
    require 'journaled/rspec'
    ```

3. You will need to set the following config in an initializer to allow Journaled to publish events to your AWS Kinesis event stream:

    ```ruby
    Journaled.default_stream_name = "my_app_#{Rails.env}_events"
    ```

    You may also define a `#journaled_stream_name` method on `Journaled::Event` instances:

    ```ruby
    def journaled_stream_name
      "my_app_#{Rails.env}_alternate_events"
    end
    ````

3. You may also need to define environment variables to allow Journaled to publish events to your AWS Kinesis event stream:

    You may optionally define the following ENV vars to specify AWS
    credentials outside of the locations that the AWS SDK normally looks:

      * `RUBY_AWS_ACCESS_KEY_ID`
      * `RUBY_AWS_SECRET_ACCESS_KEY`

    You may also specify the region to target your AWS stream by setting
    `AWS_DEFAULT_REGION`. If you don't specify, Journaled will default to
    `us-east-1`.

    You may also specify a role that the Kinesis AWS client can assume:

      * `JOURNALED_IAM_ROLE_ARN`

    The AWS principal whose credentials are in the environment will need to be allowed to assume this role.

## Usage

### Configuration

Journaling provides a number of different configuation options that can be set in Ruby using an initializer. Those values are:

#### `Journaled.default_stream_name`

  This is described in the "Installation" section above, and is used to specify which stream name to use.

#### `Journaled.job_priority` (default: 20)

  This can be used to configure what `priority` the ActiveJobs are enqueued with. This will be applied to all the `Journaled::DeliveryJob`s that are created by this application.
  Ex: `Journaled.job_priority = 14`

  _Note that job priority is only supported on Rails 6.0+. Prior Rails versions will ignore this parameter and enqueue jobs with the underlying ActiveJob adapter's default priority._

#### `Journaled.http_idle_timeout` (default: 1 second)

  The number of seconds a persistent connection is allowed to sit idle before it should no longer be used.

#### `Journaled.http_open_timeout` (default: 2 seconds)

  The number of seconds before the :http_handler should timeout while trying to open a new HTTP session.

#### `Journaled.http_read_timeout` (default: 60 seconds)

  The number of seconds before the :http_handler should timeout while waiting for a HTTP response.

#### `Journaled.delivery_adapter` (default: `Journaled::DeliveryAdapters::ActiveJobAdapter`)

  Determines how events are delivered to Kinesis. Two options are available:

  - **`Journaled::DeliveryAdapters::ActiveJobAdapter`** (default) - Enqueues events to ActiveJob. Requires a DB-backed queue adapter (see Installation).

  - **`Journaled::Outbox::Adapter`** - Stores events in a database table and processes them via separate worker daemons. See [Outbox-style Event Processing](#outbox-style-event-processing-optional) for setup instructions.

  Example:
  ```ruby
  # Use the Outbox-style adapter
  Journaled.delivery_adapter = Journaled::Outbox::Adapter
  ```

#### `Journaled.outbox_base_class_name` (default: `'ActiveRecord::Base'`)

  **Only relevant when using `Journaled::Outbox::Adapter`.**

  Specifies which ActiveRecord base class the Outbox event storage model (`Journaled::Outbox::Event`) should use for its database connection. This is useful for multi-database setups where you want to store events in a separate database.

  Example:
  ```ruby
  # Store outbox events in a separate database
  class EventsRecord < ActiveRecord::Base
    self.abstract_class = true
    connects_to database: { writing: :events, reading: :events }
  end

  Journaled.outbox_base_class_name = 'EventsRecord'
  ```

#### `Journaled.outbox_processing_mode` (default: `:batch`)

  **Only relevant when using `Journaled::Outbox::Adapter`.**

  Controls how events are sent to Kinesis. Two modes are available:

  - **`:batch`** (default) - Uses the Kinesis `put_records` batch API for high throughput. Events are sent in parallel batches, allowing multiple workers to run concurrently. Best for most use cases where strict ordering is not required.

  - **`:guaranteed_order`** - Uses the Kinesis `put_record` single-event API to send events sequentially. Events are processed one at a time in order, stopping on the first transient failure to preserve ordering. Use this when you need strict ordering guarantees per partition key. Note: The current implementation requires single-threaded processing, but future optimizations may support batching and multi-threading by partition key.

  Example:
  ```ruby
  # For high throughput (default)
  Journaled.outbox_processing_mode = :batch

  # For guaranteed ordering
  Journaled.outbox_processing_mode = :guaranteed_order
  ```

#### ActiveJob `set` options

Both model-level directives accept additional options to be passed into ActiveJob's `set` method:

```ruby
# For change journaling:
journal_changes_to :email, as: :identity_change, enqueue_with: { priority: 10 }

# For audit logging:
has_audit_log enqueue_with: { priority: 30 }

# Or for custom journaling:
journal_attributes :email, enqueue_with: { priority: 20, queue: 'journaled' }
```
##### Outbox-style Event Processing (Optional)

Journaled includes a built-in Outbox-style delivery adapter with horizontally scalable workers.

By default, the Outbox adapter uses the Kinesis `put_records` batch API for high-throughput event processing, allowing multiple workers to process events in parallel. If you require strict ordering guarantees per partition key, you can configure sequential processing mode (see configuration options below).

**Setup:**

This feature requires creating database tables and is completely optional. Existing users are unaffected.

1. **Install migrations:**

```bash
rake journaled:install:migrations
rails db:migrate
```

This creates a table for storing events:
- `journaled_outbox_events` - Queue of events to be processed (includes `failed_at` column for tracking failures)

2. **Configure to use the database adapter:**

```ruby
# config/initializers/journaled.rb

# Use the Outbox-style adapter instead of ActiveJob
Journaled.delivery_adapter = Journaled::Outbox::Adapter

# Optional: Customize worker behavior (these are the defaults)
Journaled.worker_batch_size = 500        # Max events per Kinesis batch (Kinesis API limit)
Journaled.worker_poll_interval = 5       # Seconds between polls

# Optional: Configure processing mode (default: :batch)
# - :batch - Uses Kinesis put_records batch API for high throughput (default)
#            Events are sent in parallel batches. Multiple workers can run concurrently.
# - :guaranteed_order - Uses Kinesis put_record single-event API for sequential processing
#                       Events are sent one at a time in order. Use this if you need
#                       strict ordering guarantees per partition key. The current
#                       implementation processes events single-threaded, though future
#                       optimizations may support batching/multi-threading by partition key.
Journaled.outbox_processing_mode = :batch
```

**Note:** When using the Outbox adapter, you do **not** need to configure an ActiveJob queue adapter (skip step 1 of Installation). The Outbox adapter uses the `journaled_outbox_events` table for event storage and its own worker daemons for processing, making it independent of ActiveJob. Transactional batching still works seamlessly with the Outbox adapter.

3. **Start worker daemon(s):**

```bash
bundle exec rake journaled_worker:work
```

**Note:** In `:batch` mode (the default), you can run multiple worker processes concurrently for horizontal scaling. In `:guaranteed_order` mode, the current implementation requires running a single worker to maintain ordering guarantees.

4. **Monitoring:**

The system emits `ActiveSupport::Notifications` events:

```ruby
# config/initializers/journaled.rb

# Emitted for every batch processed (regardless of outcome)
ActiveSupport::Notifications.subscribe('journaled.worker.batch_process') do |name, start, finish, id, payload|
  Statsd.increment('journaled.worker.batches', tags: ["worker:#{payload[:worker_id]}"])
end

# Emitted for successfully sent events
ActiveSupport::Notifications.subscribe('journaled.worker.batch_sent') do |name, start, finish, id, payload|
  Statsd.increment('journaled.worker.events_sent', payload[:event_count], tags: ["worker:#{payload[:worker_id]}"])
end

# Emitted for permanently failed events (marked as failed in database)
ActiveSupport::Notifications.subscribe('journaled.worker.batch_failed') do |name, start, finish, id, payload|
  Statsd.increment('journaled.worker.events_failed', payload[:event_count], tags: ["worker:#{payload[:worker_id]}"])
end

# Emitted for transiently failed events (will be retried)
ActiveSupport::Notifications.subscribe('journaled.worker.batch_errored') do |name, start, finish, id, payload|
  Statsd.increment('journaled.worker.events_errored', payload[:event_count], tags: ["worker:#{payload[:worker_id]}"])
end

# Emitted once per minute with queue statistics
ActiveSupport::Notifications.subscribe('journaled.worker.queue_metrics') do |name, start, finish, id, payload|
  Statsd.gauge('journaled.worker.queue.total', payload[:total_count], tags: ["worker:#{payload[:worker_id]}"])
  Statsd.gauge('journaled.worker.queue.workable', payload[:workable_count], tags: ["worker:#{payload[:worker_id]}"])
  Statsd.gauge('journaled.worker.queue.erroring', payload[:erroring_count], tags: ["worker:#{payload[:worker_id]}"])
  Statsd.gauge('journaled.worker.queue.oldest_age_seconds', payload[:oldest_age_seconds], tags: ["worker:#{payload[:worker_id]}"]) if payload[:oldest_age_seconds]
end
```

Queue metrics payload includes:
- `total_count` - Total number of events in the queue (including failed)
- `workable_count` - Events ready to be processed (not failed)
- `erroring_count` - Events with errors but not yet marked as permanently failed
- `oldest_non_failed_timestamp` - Timestamp of the oldest non-failed event (extracted from UUID v7)
- `oldest_age_seconds` - Age in seconds of the oldest non-failed event

Note: Metrics are collected in a background thread to avoid blocking the main worker loop.

5. **Failed Events:**

Inspect and requeue failed events:

```ruby
# Find failed events
Journaled::Outbox::Event.failed.where(stream_name: 'my_stream')

# Requeue a failed event (clears failure info and resets attempts)
failed_event = Journaled::Outbox::Event.failed.find(123)
failed_event.requeue!
```

### Attribution

Before using `Journaled::Changes` or `Journaled::AuditLog`, you will want to
set up automatic "actor" attribution (i.e. tracking the current user session).
To enable this feature, add the following to your controller base class for
attribution:

```ruby
class ApplicationController < ActionController::Base
  include Journaled::Actor

  self.journaled_actor = :current_user # Or your authenticated entity
end
```

Your authenticated entity must respond to `#to_global_id`, which ActiveRecords do by default.
This feature relies on `ActiveSupport::CurrentAttributes` under the hood.

### Change Journaling with `Journaled::Changes`

Out of the box, `Journaled` provides an event type and ActiveRecord
mix-in for durably journaling changes to your model, implemented via
ActiveRecord hooks. Use it like so:

```ruby
class User < ApplicationRecord
  include Journaled::Changes

  journal_changes_to :email, :first_name, :last_name, as: :identity_change
end
```

Every time any of the specified attributes is modified, or a `User`
record is created or destroyed, an event will be sent to Kinesis with the following attributes:

  * `id` - a random event-specific UUID
  * `event_type` - the constant value `journaled_change`
  * `created_at`- when the event was created
  * `table_name` - the table name backing the ActiveRecord (e.g. `users`)
  * `record_id` - the primary key of the record, as a string (e.g.
    `"300"`)
  * `database_operation` - one of `create`, `update`, `delete`
  * `logical_operation` - whatever logical operation you specified in
    your `journal_changes_to` declaration (e.g. `identity_change`)
  * `changes` - a serialized JSON object representing the latest values
    of any new or changed attributes from the specified set (e.g.
    `{"email":"mynewemail@example.com"}`). Upon destroy, all
    specified attributes will be serialized as they were last stored.
  * `actor` - a string (usually a rails global_id) representing who
    performed the action.

Callback-bypassing database methods like `update_all`, `delete_all`,
`update_columns` and `delete` are intercepted and will require an
additional `force: true` argument if they would interfere with change
journaling. Note that the less-frequently-used methods `toggle`,
`increment*`, `decrement*`, and `update_counters` are not intercepted at
this time.


### Audit Logging with `Journaled::AuditLog`

Journaled includes a feature for producing audit logs of changes to your model.
Unlike `Journaled::Changes`, which will emit individual sets of changes as
"logical" events, `Journaled::AuditLog` will log all changes in their entirety,
unless otherwise told to ignore changes to specific columns.

This behavior is similar to
[papertrail](https://github.com/paper-trail-gem/paper_trail),
[audited](https://github.com/collectiveidea/audited), and
[logidze](https://github.com/palkan/logidze), except instead of storing
changes/versions locally (in your application's database), it emits them to
Kinesis (as Journaled events).

#### Audit Log Configuration

To enable audit logging for a given record, use the `has_audit_log` directive:

```ruby
class MyModel < ApplicationRecord
  has_audit_log

  # This class will now be audited,
  # but will ignore changes to `created_at` and `updated_at`.
end
```

To ignore changes to additional columns, use the `ignore` option:

```ruby
class MyModel < ApplicationRecord
  has_audit_log ignore: :last_synced_at

  # This class will be audited,
  # and will ignore changes to `created_at`, `updated_at`, and `last_synced_at`.
end
```

By default, changes to `updated_at` and `created_at` will be ignored (since
these generally change on every update), but this behavior can be reconfigured:

```ruby
# change the defaults:
Journaled::AuditLog.default_ignored_columns = %i(createdAt updatedAt)

# or append new defaults:
Journaled::AuditLog.default_ignored_columns += %i(modified_at)

# or disable defaults entirely:
Journaled::AuditLog.default_ignored_columns = []
```

Subclasses will inherit audit log configs:

```ruby
class MyModel < ApplicationRecord
  has_audit_log ignore: :last_synced_at
end

class MySubclass < MyModel
  # this class will be audited,
  # and will ignore `created_at`, `updated_at`, and `last_synced_at`.
end
```

To disable audit logs on subclasses, use `skip_audit_log`:

```ruby
class MySubclass < MyModel
  skip_audit_log
end
```

Subclasses may specify additional columns to ignore (which will be merged into
the inherited list):

```ruby
class MySubclass < MyModel
  has_audit_log ignore: :another_field

  # this class will ignore `another_field`, IN ADDITION TO `created_at`, `updated_at`,
  # and any other fields specified by the parent class.
end
```

To temporarily disable audit logging globally, use the `without_audit_logging` directive:

```ruby
Journaled::AuditLog.without_audit_logging do
  # Any operation in here will skip audit logging
end
```

#### Audit Log Events

Whenever an audited record is created, updated, or destroyed, a
`journaled_audit_log` event is emitted. For example, calling
`user.update!(name: 'Bart')` would result in an event that looks something like
this:

```json
{
  "id": "bc7cb6a6-88cf-4849-a4f0-a31b0b199c47",
  "event_type": "journaled_audit_log",
  "created_at": "2022-01-28T11:06:54.928-05:00",
  "class_name": "User",
  "table_name": "users",
  "record_id": "123",
  "database_operation": "update",
  "changes": { "name": ["Homer", "Bart"] },
  "snapshot": null,
  "actor": "gid://app_name/AdminUser/456",
  "tags": {}
}
```

The field breakdown is as follows:

- `id`: a randomly-generated ID for the event itself
- `event_type`: the type of event (always `journaled_audit_log`)
- `created_at`: the time that the action occurred (should match `updated_at` on
  the ActiveRecord)
- `class_name`: the name of the ActiveRecord class
- `table_name`: the underlying table that the class interfaces with
- `record_id`: the primary key of the ActiveRecord
- `database_operation`: the type of operation (`insert`, `update`, or `delete`)
- `changes`: the changes to the record, in the form of `"field_name":
  ["from_value", "to_value"]`
- `snapshot`: an (optional) snapshot of all of the record's columns and their
  values (see below).
- `actor`: the current `Journaled.actor`
- `tags`: the current `Journaled.tags`

#### Snapshots

When records are created, updated, and deleted, the `changes` field is populated
with only the columns that changed. While this keeps event payload size down, it
may make it harder to reconstruct the state of the record at a given point in
time.

This is where the `snapshot` field comes in! To produce a full snapshot of a
record as part of an update, set use the virtual `_log_snapshot` attribute, like
so:

```ruby
my_user.update!(name: 'Bart', _log_snapshot: true)
```

Or to produce snapshots for all records that change for a given operation,
wrap it a `with_snapshots` block, like so:

```ruby
Journaled::AuditLog.with_snapshots do
  ComplicatedOperation.run!
end
```

Snapshots can also be enabled globally for all _deletion_ operations. Since
`changes` will be empty on deletion, you should consider using this if you care
about the contents of any records being deleted (and/or don't have a full audit
trail from their time of creation):

```ruby
Journaled::AuditLog.snapshot_on_deletion = true
```

Events with snapshots will continue to populate the `changes` field, but will
additionally contain a snapshot with the full state of the user:

```json
{
  "...": "...",
  "changes": { "name": ["Homer", "Bart"] },
  "snapshot": { "name": "Bart", "email": "simpson@example.com", "favorite_food": "pizza" },
  "...": "..."
}
```

#### Handling Sensitive Data

Both `changes` and `snapshot` will filter out sensitive fields, as defined by
your `Rails.application.config.filter_parameters` list:

```json
{
  "...": "...",
  "changes": { "ssn": ["[FILTERED]", "[FILTERED]"] },
  "snapshot": { "ssn": "[FILTERED]" },
  "...": "..."
}
```

They will also filter out any fields whose name ends in `_crypt` or `_hmac`, as
well as fields that rely on Active Record Encryption / `encrypts` ([introduced
in Rails 7](https://edgeguides.rubyonrails.org/active_record_encryption.html)).

This is done to avoid emitting values to locations where it is difficult or
impossible to rotate encryption keys (or otherwise scrub values after the
fact), and currently there is no built-in configuration to bypass this
behavior. If you need to track changes to sensitive/encrypted fields, it is
recommended that you store the values in a local history table (still
encrypted, of course!).

#### Caveats

Because Journaled events are not guaranteed to arrive in order, events emitted
by `Journaled::AuditLog` must be sorted by their `created_at` value, which
should correspond roughly to the time that the SQL statement was issued.
**There is currently no other means of globally ordering audit log events**,
making them susceptible to clock drift and race conditions.

These issues may be mitigated on a per-model basis via
`ActiveRecord::Locking::Optimistic` (and its auto-incrementing `lock_version`
column), and/or by careful use of other locking mechanisms.

### Custom Journaling

For every custom implementation of journaling in your application, define the JSON schema for the attributes in your event.
This schema file should live in your Rails application at the top level and should be named in snake case to match the
class being journaled.
    E.g.: `your_app/journaled_schemas/my_class.json)`

In each class you intend to use Journaled, include the `Journaled::Event` module and define the attributes you want
captured. After completing the above steps, you can call the `journal!` method in the model code and the declared
attributes will be published to the Kinesis stream. Be sure to call
`journal!` within the same transaction as any database side effects of
your business logic operation to ensure that the event will eventually
be delivered if-and-only-if your transaction commits.

Example:

```js
// journaled_schemas/contract_acceptance_event.json

{
  "type": "object",
  "title": "contract_acceptance_event",
  "required": [
    "user_id",
    "signature"
  ],
  "properties": {
    "user_id": {
      "type": "integer"
    },
    "signature": {
      "type": "string"
    }
  }
}
```

```ruby
# app/models/contract_acceptance_event.rb

ContractAcceptanceEvent = Struct.new(:user_id, :signature) do
  include Journaled::Event

  journal_attributes :user_id, :signature
end
```

```ruby
# app/models/contract_acceptance.rb

class ContractAcceptance
  include ActiveModel::Model

  attr_accessor :user_id, :signature

  def user
    @user ||= User.find(user_id)
  end

  def contract_acceptance_event
    @contract_acceptance_event ||= ContractAcceptanceEvent.new(user_id, signature)
  end

  def save!
    User.transaction do
      user.update!(contract_accepted: true)
      contract_acceptance_event.journal!
    end
  end
end
```

An event like the following will be journaled to kinesis:

```js
{
  "id": "bc7cb6a6-88cf-4849-a4f0-a31b0b199c47", // A random event ID for idempotency filtering
  "event_type": "contract_acceptance_event",
  "created_at": "2019-01-28T11:06:54.928-05:00",
  "user_id": 123,
  "signature": "Sarah T. User"
}
```

### Tagged Events

Events may be optionally marked as "tagged." This will add a `tags` field, intended for tracing and
auditing purposes.

```ruby
class MyEvent
  include Journaled::Event

  journal_attributes :attr_1, :attr_2, tagged: true
end
```

You may then use `Journaled.tag!` and `Journaled.tagged` inside of your
`ApplicationController` and `ApplicationJob` classes (or anywhere else!) to tag
all events with request and job metadata:

```ruby
class ApplicationController < ActionController::Base
  before_action do
    Journaled.tag!(request_id: request.request_id, current_user_id: current_user&.id)
  end
end

class ApplicationJob < ActiveJob::Base
  around_perform do |job, perform|
    Journaled.tagged(job_id: job.id) { perform.call }
  end
end
```

This feature relies on `ActiveSupport::CurrentAttributes` under the hood, so these tags are local to
the current thread, and will be cleared at the end of each request request/job.

### Helper methods for custom events

Journaled provides a couple helper methods that may be useful in your
custom events. You can add whichever you need your event types like
this:

```ruby
# my_event.rb
class MyEvent
  include Journaled::Event

  journal_attributes :commit_hash, :actor_uri # ... etc, etc

  def commit_hash
    Journaled.commit_hash
  end

  def actor_uri
    Journaled.actor_uri
  end

  # ... etc, etc
end
```

#### `Journaled.commit_hash`

If you choose to use it, you must provide a `GIT_COMMIT` environment
variable. `Journaled.commit_hash` will fail if it is undefined.

#### `Journaled.actor_uri`

Returns one of the following in order of preference:

* The current controller-defined `journaled_actor`'s GlobalID, if
  set
* A string of the form `gid://[app_name]/[os_username]` if performed on
  the command line
* a string of the form `gid://[app_name]` as a fallback

In order for this to be most useful, you must configure your controller
as described in [Attribution](#attribution) above.

### Testing

If you use RSpec, you can test for journaling behaviors with the
`journal_event(s)_including` and `journal_changes_to` matchers. First, make
sure to require `journaled/rspec` in your spec setup (e.g.
`spec/rails_helper.rb`):

```ruby
require 'journaled/rspec'
```

#### Checking for specific events

The `journal_event_including` and `journal_events_including` matchers allow you
to check for one or more matching event being journaled:

```ruby
expect { my_code }
  .to journal_event_including(name: 'foo')
expect { my_code }
  .to journal_events_including({ name: 'foo', value: 1 }, { name: 'foo', value: 2 })
```

This will only perform matches on the specified fields (and will not match one
way or the other against unspecified fields). These matchers will also ignore
any extraneous events that are not positively matched (as they may be unrelated
to behavior under test).

When writing tests, pairing every positive assertion with a negative assertion
is a good practice, and so negative matching is also supported (via both
`.not_to` and `.to not_`):

```ruby
expect { my_code }
  .not_to journal_events_including({ name: 'foo' }, { name: 'bar' })
expect { my_code }
  .to raise_error(SomeError)
  .and not_journal_event_including(name: 'foo') # the `not_` variant can chain off of `.and`
```

Several chainable modifiers are also available:

```ruby
expect { my_code }.to journal_event_including(name: 'foo')
  .with_schema_name('my_event_schema')
  .with_partition_key(user.id)
  .with_stream_name('my_stream_name')
  .with_enqueue_opts(run_at: future_time)
  .with_priority(999)
```

All of this can be chained together to test for multiple sets of events with
multiple sets of options:

```ruby
expect { subject.journal! }
  .to journal_events_including({ name: 'event1', value: 300 }, { name: 'event2', value: 200 })
    .with_priority(10)
  .and journal_event_including(name: 'event3', value: 100)
    .with_priority(20)
  .and not_journal_event_including(name: 'other_event')
```

#### Checking for `Journaled::Changes` declarations

The `journal_changes_to` matcher checks against the list of attributes specified
on the model. It does not actually test that an event is emitted within a given
codepath, and is instead intended to guard against accidental regressions that
may impact external consumers of these events:

```ruby
it "journals exactly these things or there will be heck to pay" do
  expect(User).to journal_changes_to(:email, :first_name, :last_name, as: :identity_change)
end
```

### Instrumentation

When an event is enqueued, an `ActiveSupport::Notification` titled
`journaled.event.enqueue` is emitted. Its payload will include the `:event` and
its background job `:priority`.

This can be forwarded along to your preferred monitoring solution via a Rails
initializer:

```ruby
ActiveSupport::Notifications.subscribe('journaled.event.enqueue') do |*args|
  payload = ActiveSupport::Notifications::Event.new(*args).payload
  journaled_event = payload[:event]

  tags = { priority: payload[:priority], event_type: journaled_event.journaled_attributes[:event_type] }

  Statsd.increment('journaled.event.enqueue', tags: tags.map { |k,v| "#{k.to_s[0..64]}:#{v.to_s[0..255]}" })
end
```

## Upgrades

Since this gem relies on background jobs (which can remain in the queue across
code releases), this gem generally aims to support jobs enqueued by the prior
gem version.

As such, **we always recommend upgrading only one major version at a time.**

### Upgrading from 4.3.0

Versions of Journaled prior to 5.0 would enqueue events one at a time, but 5.0
introduces a new transaction-aware feature that will bundle up all events
emitted within a transaction and enqueue them all in a single "batch" job
directly before the SQL `COMMIT` statement. This reduces the database impact of
emitting a large volume of events at once.

This feature can be disabled conditionally:

```ruby
Journaled.transactional_batching_enabled = false
```

And can then be enabled via the following block:

```ruby
Journaled.with_transactional_batching do
  # your code
end
```

Backwards compatibility has been included for background jobs enqueued by
version 4.0 and above, but **has been dropped for jobs emitted by versions prior
to 4.0**. (Again, be sure to upgrade only one major version at a time.)

### Upgrading from 3.1.0

Versions of Journaled prior to 4.0 relied directly on environment variables for stream names, but now stream names are configured directly.
When upgrading, you can use the following configuration to maintain the previous behavior:

```ruby
Journaled.default_stream_name = ENV['JOURNALED_STREAM_NAME']
```

If you previously specified a `Journaled.default_app_name`, you would have required a more precise environment variable name (substitute `{{upcase_app_name}}`):

```ruby
Journaled.default_stream_name = ENV["{{upcase_app_name}}_JOURNALED_STREAM_NAME"]
```

And if you had defined any `journaled_app_name` methods on `Journaled::Event` instances, you can replace them with the following:

```ruby
def journaled_stream_name
  ENV['{{upcase_app_name}}_JOURNALED_STREAM_NAME']
end
```

When upgrading from 3.1 or below, `Journaled::DeliveryJob` will handle any jobs that remain in the queue by accepting an `app_name` argument. **This behavior will be removed in version 5.0**, so it is recommended to upgrade one major version at a time.

### Upgrading from 2.5.0

Versions of Journaled prior to 3.0 relied direclty on `delayed_job` and a "performable" class called `Journaled::Delivery`.
In 3.0, this was superceded by an ActiveJob class called `Journaled::DeliveryJob`, but the `Journaled::Delivery` class was not removed until 4.0.

Therefore, when upgrading from 2.5.0 or below, it is recommended to first upgrade to 3.1.0 (to allow any `Journaled::Delivery` jobs to finish working off) before upgrading to 4.0+.

The upgrade to 3.1.0 will require a working ActiveJob config. ActiveJob can be configured globally by setting `ActiveJob::Base.queue_adapter`, or just for Journaled jobs by setting `Journaled::DeliveryJob.queue_adapter`.
The `:delayed_job` queue adapter will allow you to continue relying on `delayed_job`. You may also consider switching your app(s) to [`delayed`](https://github.com/Betterment/delayed) and using the `:delayed` queue adapter.

## Future improvements & issue tracking
Suggestions for enhancements to this engine are currently being tracked via Github Issues. Please feel free to open an
issue for a desired feature, as well as for any observed bugs.
