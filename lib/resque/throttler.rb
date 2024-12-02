require 'resque'
require 'securerandom'

module Resque
  module Plugins
    # The Throttler module provides rate-limiting capabilities for Resque queues.
    module Throttler
      extend self

      # Prefix used for Redis keys related to throttling.
      LOCK_KEYS_PREFIX = 'throttler'.freeze

      # Initializes rate limits when the module is extended.
      #
      # @param [Object] other The object extending this module.
      def self.extended(other)
        other.instance_variable_set(:@rate_limits, {})
      end

      # Sets rate limits for a specific queue.
      #
      # @param [Symbol, String] queue The name of the queue to rate limit.
      # @param [Hash] options The rate limit options.
      # @option options [Integer] :at The maximum number of jobs allowed in the time window.
      # @option options [Integer] :per The time window in seconds.
      #
      # @example
      #   Resque.rate_limit(:my_queue, at: 5, per: 60)
      #
      # @raise [ArgumentError] If either :at or :per option is missing.
      def rate_limit(queue, options = {})
        unless options.keys.sort == [:at, :per]
          raise ArgumentError.new("Missing either :at or :per in options")
        end

        @rate_limits[queue.to_s] = options
      end

      # Retrieves the rate limit configuration for a queue.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [Hash, nil] The rate limit options for the queue, or nil if not set.
      def rate_limit_for(queue)
        @rate_limits[queue.to_s]
      end

      # Returns all queues that have rate limits configured.
      #
      # @return [Array<String>] List of queue names as strings.
      def rate_limited_queues
        @rate_limits.keys
      end

      # Checks if a queue has a rate limit configured.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [Boolean] True if the queue has a rate limit, false otherwise.
      def queue_rate_limited?(queue)
        !!@rate_limits[queue.to_s]
      end

      # Generates the Redis key for the lock of a specific queue.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [String] The Redis key for the queue lock.
      def rate_limiting_queue_lock_key(queue)
        "#{LOCK_KEYS_PREFIX}:lock:#{queue}"
      end

      # Generates the Redis key for the rate limit counter of a specific queue.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [String] The Redis key for the rate limit counter.
      def rate_limit_key_for(queue)
        "#{LOCK_KEYS_PREFIX}:rate_limit:#{queue}"
      end

      # Retrieves the number of jobs processed in the current rate limit window for a queue.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [Integer] The number of jobs processed.
      def processed_job_count_in_rate_limit_window(queue)
        Resque.redis.get(rate_limit_key_for(queue)).to_i
      end

      # Checks if a queue has reached or exceeded its rate limit.
      #
      # @param [Symbol, String] queue The name of the queue.
      # @return [Boolean] True if the queue is at or over its rate limit, false otherwise.
      def queue_at_or_over_rate_limit?(queue)
        if queue_rate_limited?(queue)
          processed_job_count_in_rate_limit_window(queue) >= rate_limit_for(queue)[:at]
        else
          false
        end
      end

      # Resets throttling data for one or all rate-limited queues.
      #
      # @param [Symbol, String, nil] queue The name of the queue to reset, or nil to reset all.
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

      # Resets throttling data for a specific queue.
      #
      # @param [Symbol, String] queue The name of the queue.
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
    # Overrides the `reserve` method to implement rate-limiting logic.
    #
    # This method attempts to reserve a job from the queues in order,
    # applying rate limits where configured.
    #
    # @return [Resque::Job, nil] The next job to process, or nil if none are available.
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

    # Acquires a Redis lock for the given queue.
    #
    # @param [Symbol, String] queue The name of the queue.
    # @return [Boolean] True if the lock was acquired, false otherwise.
    def acquire_lock(queue)
      Resque.redis.set(
        Resque.rate_limiting_queue_lock_key(queue),
        "locked",
        ex: 30, # Set expiration to 30 seconds.
        nx: true # NX option ensures the key is set only if it does not exist.
      )
    end

    # Releases the Redis lock for the given queue.
    #
    # @param [Symbol, String] queue The name of the queue.
    def release_lock(queue)
      Resque.redis.del(Resque.rate_limiting_queue_lock_key(queue))
    end

    # Increments the job counter for rate limiting on a queue.
    #
    # @param [Symbol, String] queue The name of the queue.
    def increment_job_counter(queue)
      Resque.redis.incr(Resque.rate_limit_key_for(queue))
      limit = Resque.rate_limit_for(queue)
      Resque.redis.expire(Resque.rate_limit_key_for(queue), limit[:per])
    end
  end
end
