Resque Throttler [![Circle CI](https://circleci.com/gh/malomalo/resque-throttler.svg?style=svg)](https://circleci.com/gh/malomalo/resque-throttler)
================

Resque Throttler is a plugin for the [Resque](https://github.com/resque/resque) queueing system that adds rate limiting and concurrent job limiting to queues. This helps prevent queue overload and allows for better resource management.

## Features

- **Rate Limiting**: Control how many jobs can start within a time window
- **Concurrent Job Limiting**: Limit how many jobs can run simultaneously
- **Queue-based**: Works on entire queues, not individual job classes
- **Non-blocking**: Workers skip over rate-limited queues rather than waiting

## Installation

Add to your Gemfile:

```ruby
gem 'resque-throttler', require: 'resque/throttler'
```

Then run:

```bash
bundle install
```

Or install directly:

```bash
gem install resque-throttler
```

In your code:

```ruby
require 'resque'
require 'resque/throttler'
```

## Configuration

### Basic Rate Limiting

Limit the number of jobs that can start within a time window:

```ruby
# Allow 10 jobs per minute
Resque.rate_limit(:my_queue, at: 10, per: 60)

# Allow 30 jobs per hour
Resque.rate_limit(:hourly_queue, at: 30, per: 3600)

# Allow 1 job per second
Resque.rate_limit(:slow_queue, at: 1, per: 1)
```

### Concurrent Job Limiting

Limit how many jobs can run at the same time:

```ruby
# Allow 5 jobs per 10 seconds, but only 2 running concurrently
Resque.rate_limit(:api_queue, at: 5, per: 10, concurrent: 2)

# Heavy database operations - limit concurrency to prevent lock issues
Resque.rate_limit(:db_intensive_queue, at: 10, per: 60, concurrent: 3)
```

### Real-World Examples

#### 1. External API Integration
Respect third-party API rate limits:

```ruby
# Twitter API: 15 requests per 15 minutes
Resque.rate_limit(:twitter_api_queue, at: 15, per: 900)

# Stripe API: Be conservative to avoid hitting limits
Resque.rate_limit(:payment_processing, at: 20, per: 60, concurrent: 5)
```

#### 2. Database-Intensive Operations
Prevent database lock accumulation:

```ruby
# Bulk imports that lock tables
Resque.rate_limit(:bulk_import_queue, at: 2, per: 10, concurrent: 1)

# Lead processing with complex queries
Resque.rate_limit(:lead_processing, at: 10, per: 30, concurrent: 3)
```

#### 3. Resource-Intensive Tasks
Manage CPU/memory usage:

```ruby
# Image processing
Resque.rate_limit(:image_resize_queue, at: 5, per: 10, concurrent: 2)

# Video transcoding
Resque.rate_limit(:video_transcode_queue, at: 1, per: 60, concurrent: 1)
```

#### 4. Email Sending
Avoid being marked as spam:

```ruby
# Gradual email sending
Resque.rate_limit(:email_queue, at: 100, per: 300, concurrent: 10)

# Newsletter queue - spread over time
Resque.rate_limit(:newsletter_queue, at: 50, per: 60)
```

## Monitoring and Debugging

### Check Current Limits

```ruby
# Get rate limit configuration for a queue
Resque.rate_limit_for(:my_queue)
# => {:at => 5, :per => 10, :concurrent => 3}

# Check if a queue has rate limiting
Resque.queue_rate_limited?(:my_queue)
# => true

# List all rate-limited queues
Resque.rate_limited_queues
# => ["my_queue", "api_queue", "db_queue"]
```

### Monitor Active Jobs

```ruby
# Get current number of running jobs
Resque.active_job_count(:my_queue)
# => 2

# Check if at rate limit
Resque.queue_at_or_over_rate_limit?(:my_queue)
# => false

# Check if at concurrent limit
Resque.queue_at_or_over_concurrent_limit?(:my_queue)
# => false
```

### Reset Throttling

```ruby
# Reset throttling for a specific queue
Resque.reset_throttling(:my_queue)

# Reset throttling for all queues
Resque.reset_throttling
```

### Debug Logging

Workers log throttling decisions at the debug level. Enable debug logging to see:

```
Checking my_queue
Rate limit applies to my_queue, attempting to acquire lock
lock acquired
my_queue is at concurrent job limit (3 active jobs), releasing lock and skipping
```

## How It Works

1. **Rate Limiting**: Uses Redis counters with expiration to track jobs started within time windows
2. **Concurrent Limiting**: Tracks active job count, incrementing on start and decrementing on completion
3. **Distributed Locking**: Uses Redis locks to prevent race conditions in distributed environments
4. **Non-blocking**: Workers check limits and skip queues that are at capacity

## Worker Configuration

Workers automatically respect rate limits. Just ensure your workers are processing the rate-limited queues:

```ruby
# Single queue
QUEUE=my_queue rake resque:work

# Multiple queues
QUEUE=api_queue,db_queue,email_queue rake resque:work

# All queues
QUEUE=* rake resque:work
```

## Advanced Usage

### Conditional Rate Limiting

You can dynamically adjust rate limits based on time of day or system load:

```ruby
# Increase limits during off-peak hours
if Time.now.hour < 8 || Time.now.hour > 20
  Resque.rate_limit(:api_queue, at: 100, per: 60)
else
  Resque.rate_limit(:api_queue, at: 30, per: 60)
end
```

### Queue-Lock Pattern

Ensure only one job runs at a time:

```ruby
# Equivalent to resque-queue-lock behavior
Resque.rate_limit(:exclusive_queue, at: 1, per: 0, concurrent: 1)
```

## Similar Resque Plugins

* [resque-queue-lock](https://github.com/mashion/resque-queue-lock) - Only allows one job at a time per queue. With resque-throttler: `Resque.rate_limit(:my_queue, at: 1, per: 0)`

* [resque-throttle](https://github.com/scotttam/resque-throttle) - Works on job classes rather than queues and throws errors when at limit

* [resque-waiting-room](https://github.com/julienXX/resque-waiting-room) - Moves rate-limited jobs to a waiting queue

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Add tests for your changes
4. Commit your changes (`git commit -am 'Add some feature'`)
5. Push to the branch (`git push origin my-new-feature`)
6. Create new Pull Request

## License

Released under the MIT License. See LICENSE file for details.