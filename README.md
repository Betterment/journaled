# Journaled

A Rails engine to durably deliver schematized events to Amazon Kinesis via DelayedJob.

More specifically, `journaled` is composed of three opinionated pieces:
schema definition/validation via JSON Schema, transactional enqueueing
via Delayed::Job (specifically `delayed_job_active_record`), and event
transmission via Amazon Kinesis. Our current use-cases include
transmitting audit events for durable storage in S3 and/or analytical
querying in Amazon Redshift.

Journaled provides an at-least-once event delivery guarantee assuming
Delayed::Job is configured not to delete jobs on failure.

Note: Do not use the journaled gem to build an event sourcing solution
as it does not guarantee total ordering of events. It's possible we'll
add scoped ordering capability at a future date (and would gladly
entertain pull requests), but it is presently only designed to provide a
durable, eventually consistent record that discrete events happened.

## Installation

1. [Install `delayed_job_active_record`](https://github.com/collectiveidea/delayed_job_active_record#installation)
if you haven't already.


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

3. You will also need to define the following environment variables to allow Journaled to publish events to your AWS Kinesis event stream:

    * `JOURNALED_STREAM_NAME`

    Special case: if your `Journaled::Event` objects override the
    `#journaled_app_name` method to a non-nil value e.g. `my_app`, you will
    instead need to provide a corresponding
    `[upcased_app_name]_JOURNALED_STREAM_NAME` variable for each distinct
    value, e.g. `MY_APP_JOURNALED_STREAM_NAME`. You can provide a default value
    for all `Journaled::Event`s in an initializer like this:

    ```ruby
    Journaled.default_app_name = 'my_app'
    ```

    You may optionally define the following ENV vars to specify AWS
    credentials outside of the locations that the AWS SDK normally looks:

      * `RUBY_AWS_ACCESS_KEY_ID`
      * `RUBY_AWS_SECRET_ACCESS_KEY`

    You may also specify the region to target your AWS stream by setting
    `AWS_DEFAULT_REGION`. If you don't specify, Journaled will default to
    `us-east-1`.

## Usage

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

Your authenticated entity must respond to `#to_global_id`, which
ActiveRecords do by default.

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
 
#### Testing

If you use RSpec (and have required `journaled/rspec` in your
`spec/rails_helper.rb`), you can regression-protect important journaling
config with the `journal_changes_to` matcher:

```ruby
it "journals exactly these things or there will be heck to pay" do
  expect(User).to journal_changes_to(:email, :first_name, :last_name, as: :identity_change)
end
```

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

## Future improvements & issue tracking
Suggestions for enhancements to this engine are currently being tracked via Github Issues. Please feel free to open an
issue for a desired feature, as well as for any observed bugs.
