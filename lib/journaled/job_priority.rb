module Journaled::JobPriority
  INTERACTIVE = 0 # These jobs will actively hinder end-user interactions until complete, e.g. assembling a report a user is polling for.
  USER_VISIBLE = 10 # These jobs have end-user-visible side effects that will not obviously impact customers, e.g. welcome emails
  EVENTUAL = 20 # These jobs affect business process that are tolerant to some degree of queue backlog, e.g. desk record synchronization
end
