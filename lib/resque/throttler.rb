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
      def rate_limit(queue, options={})
        if options.keys.sort != [:at, :per]
          raise ArgumentError.new("Missing either :at or :per in options")
        end

        @rate_limits[queue.to_s] = options
      end

      # Get rate limit configuration for a queue
      def rate_limit_for(queue)
        @rate_limits[queue.to_s]
      end

      # Check if a queue has a rate limit configured
      def queue_rate_limited?(queue)
        !!@rate_limits[queue.to_s]
      end

      # Check if a queue has exceeded its rate limit
      def queue_at_or_over_rate_limit?(queue)
        if queue_rate_limited?(queue)
          Resque.redis.get("rate_limit:#{queue}").to_i >= rate_limit_for(queue)[:at]
        else
          false
        end
      end

      # Garbage collection for expired rate-limit data
      def gc_rate_limit_data_for_queue(queue)
        return unless queue_rate_limited?(queue)

        limit = rate_limit_for(queue)
        queue_key = "#{LOCK_KEYS_PREFIX}:#{queue}_uuids"
        uuids = Resque.redis.smembers(queue_key)

        uuids.each do |uuid|
          job_ended_at = Resque.redis.hmget("#{LOCK_KEYS_PREFIX}:jobs:#{uuid}", "ended_at")[0]
          if job_ended_at && Time.at(job_ended_at.to_i) < Time.now - limit[:per]
            Resque.redis.srem(queue_key, uuid)
            Resque.redis.del("#{LOCK_KEYS_PREFIX}:jobs:#{uuid}")
          end
        end
      end

      private
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
          lock_key = "#{Resque::Plugins::Throttler::LOCK_KEYS_PREFIX}:lock:#{queue}"
          lock_acquired = acquire_lock(lock_key)

          unless lock_acquired
            log_with_severity :debug, "Could not acquire lock for #{queue}, skipping"
            next
          end
          log_with_severity :debug, "lock acquired"

          # Step 3: Check if rate limit is exceeded for this queue.
          rate_limit_key = "rate_limit:#{queue}"
          if Resque.queue_at_or_over_rate_limit?(queue)
            log_with_severity :debug, "#{queue} is over its rate limit, releasing lock and skipping"
            release_lock(lock_key)
            log_with_severity :error, "lock released"
            next
          end
          log_with_severity :debug, "#{queue} is not over its rate limit, proceeding"

          # Step 4: Reserve a job from the queue.
          if job = Resque.reserve(queue)
            log_with_severity :debug, "Found job on #{queue}"
            increment_job_counter(rate_limit_key, queue)

            release_lock(lock_key)
            log_with_severity :error, "lock released"
            return job
          else
            release_lock(lock_key)
            log_with_severity :error, "lock released"
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
    def acquire_lock(lock_key)
      Resque.redis.set(lock_key, "locked", ex: 30, nx: true)  # NX means "set if not exists"
    end

    # Helper method to release the Redis lock
    def release_lock(lock_key)
      Resque.redis.del(lock_key)
    end

    # Helper method to increment the job counter for rate-limiting
    def increment_job_counter(rate_limit_key, queue)
      Resque.redis.incr(rate_limit_key)
      limit = Resque.rate_limit_for(queue)
      Resque.redis.expire(rate_limit_key, limit[:per])
    end
  end
end
