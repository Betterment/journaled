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

1. If you haven't already,
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

#### `Journaled.default_stream_name `

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

#### ActiveJob `set` options

Both model-level directives accept additional options to be passed into ActiveJob's `set` method:

```ruby
# For change journaling:
journal_changes_to :email, as: :identity_change, enqueue_with: { priority: 10 }

# Or for custom journaling:
journal_attributes :email, enqueue_with: { priority: 20, queue: 'journaled' }
```

### Change Journaling

Out of the box, `Journaled` provides an event type and ActiveRecord
mix-in for durably journaling changes to your model, implemented via
ActiveRecord hooks. Use it like so:

```ruby
class User < ApplicationRecord
  include Journaled::Changes

  journal_changes_to :email, :first_name, :last_name, as: :identity_change
end
```

Add the following to your controller base class for attribution:

```ruby
class ApplicationController < ActionController::Base
  include Journaled::Actor

  self.journaled_actor = :current_user # Or your authenticated entity
end
```

Your authenticated entity must respond to `#to_global_id`, which ActiveRecords do by default.
This feature relies on `ActiveSupport::CurrentAttributes` under the hood.

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
as described in [Change Journaling](#change-journaling) above.

### Testing

If you use RSpec, you can test for journaling behaviors with the
`journal_event(s)` and `journal_changes_to` matchers. First, make sure to
require `journaled/rspec` in your spec setup (e.g. `spec/rails_helper.rb`):

```ruby
require 'journaled/rspec'
```

#### Checking for specific events

The `journal_event` and `journal_events` matchers allow you to check for one or
more matching event being journaled:

```ruby
expect { my_code }.to journal_event(name: 'foo')
expect { my_code }.to journal_events({ name: 'foo', value: 1 }, { name: 'foo', value: 2 })
```

This will only perform exact matches on the specified fields (and will not match
one way or the other against unspecified fields).

The matchers also support negative assertions (in two forms):

```ruby
expect { my_code }.not_to journal_event
expect { my_code }.to not_journal_event # supports chaining with `.and`
```

Several chainable modifiers are also available:

```ruby
expect { my_code }.to journal_event(name: 'foo')
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
  .to journal_events({ name: 'event1', value: 300 }, { name: 'event2', value: 200 })
    .with_priority(10)
  .and journal_event(name: 'event3', value: 100)
    .with_priority(20)
  .and not_journal_event(name: 'other_event')
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


## Upgrades

Since this gem relies on background jobs (which can remain in the queue across
code releases), this gem generally aims to support jobs enqueued by the prior
gem version.

As such, **we always recommend upgrading only one major version at a time.**

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
