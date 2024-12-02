require 'resque'
require 'securerandom'

module Resque
  module Plugins
    module Throttler
      extend self

      LOCK_KEYS_PREFIX = 'throttler'.freeze

      # Initialize rate limits
      def self.extended(other)
        other.instance_variable_set(:@rate_limits, {})
      end

      # Method to set rate limits on a specific queue
      def rate_limit(queue, options = {})
        if options.keys.sort != [:at, :per]
          raise ArgumentError.new("Missing either :at or :per in options")
        end

        @rate_limits[queue.to_s] = options
      end

      # Get rate limit configuration for a queue
      def rate_limit_for(queue)
        @rate_limits[queue.to_s]
      end

      def rate_limited_queues
        @rate_limits.keys
      end

      # Check if a queue has a rate limit configured
      def queue_rate_limited?(queue)
        !!@rate_limits[queue.to_s]
      end

      def rate_limiting_queue_lock_key(queue)
        "#{LOCK_KEYS_PREFIX}:lock:#{queue}"
      end

      def rate_limit_key_for(queue)
        "#{LOCK_KEYS_PREFIX}:rate_limit:#{queue}"
      end

      def processed_job_count_in_rate_limit_window(queue)
        Resque.redis.get(rate_limit_key_for(queue)).to_i
      end

      # Check if a queue has exceeded its rate limit
      def queue_at_or_over_rate_limit?(queue)
        if queue_rate_limited?(queue)
          processed_job_count_in_rate_limit_window(queue) >= rate_limit_for(queue)[:at]
        else
          false
        end
      end

      def reset_throttling(queue = nil)
        if queue
          reset_queue_throttling(queue)
        else
          rate_limited_queues.each do |queue_name|
            reset_queue_throttling(queue_name)
          end
        end
      end

      private

      def reset_queue_throttling(queue)
        lock_key = rate_limiting_queue_lock_key(queue)
        rate_limit_key = rate_limit_key_for(queue)
        Resque.redis.del(lock_key)
        Resque.redis.del(rate_limit_key)
      end
    end
  end
end

# Extend Resque with Throttler functionality
Resque.extend(Resque::Plugins::Throttler)

# Extend Resque::Worker to manage rate-limited queue jobs
module Resque
  class Worker
    # Override the `reserve` method to implement rate-limiting logic
    def reserve
      queues.each do |queue|
        log_with_severity :debug, "Checking #{queue}"

        # Step 1: Check if rate limits apply to this queue.
        if Resque.queue_rate_limited?(queue)
          log_with_severity :debug, "Rate limit applies to #{queue}, attempting to acquire lock"

          # Step 2: Try to acquire a Redis lock for this queue.
          lock_acquired = acquire_lock(queue)

          unless lock_acquired
            log_with_severity :debug, "Could not acquire lock for #{queue}, skipping"
            next
          end

          log_with_severity :debug, "lock acquired"

          # Step 3: Check if rate limit is exceeded for this queue.
          if Resque.queue_at_or_over_rate_limit?(queue)
            log_with_severity :debug, "#{queue} is over its rate limit, releasing lock and skipping"
            release_lock(queue)
            log_with_severity :debug, "lock released"
            next
          end
          log_with_severity :debug, "#{queue} is not over its rate limit, proceeding"

          # Step 4: Reserve a job from the queue.
          if job = Resque.reserve(queue)
            log_with_severity :debug, "Found job on #{queue}"
            increment_job_counter(queue)

            release_lock(queue)
            log_with_severity :debug, "lock released"
            return job
          else
            log_with_severity :debug, "No job on #{queue}"
            release_lock(queue)
            log_with_severity :debug, "lock released, continuing checking other queues"
          end
        else
          log_with_severity :debug, "Checking #{queue}"
          if job = Resque.reserve(queue)
            log_with_severity :debug, "Found job on #{queue}"
            return job
          end
        end
      end

      nil
    rescue Exception => e
      log_with_severity :error, "Error reserving job: #{e.inspect}"
      log_with_severity :error, e.backtrace.join("\n")
      raise e
    end

    private

    # Helper method to acquire a Redis lock
    def acquire_lock(queue)
      Resque.redis.set(Resque.rate_limiting_queue_lock_key(queue), "locked", ex: 30, nx: true) # NX means "set if not exists"
    end

    # Helper method to release the Redis lock
    def release_lock(queue)
      Resque.redis.del(Resque.rate_limiting_queue_lock_key(queue))
    end

    # Helper method to increment the job counter for rate-limiting
    def increment_job_counter(queue)
      Resque.redis.incr(Resque.rate_limit_key_for(queue))
      limit = Resque.rate_limit_for(queue)
      Resque.redis.expire(Resque.rate_limit_key_for(queue), limit[:per])
    end
  end
end
