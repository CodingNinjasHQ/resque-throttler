require 'resque'
require 'securerandom'

module Resque
  module Plugins
    # The Throttler module provides rate-limiting and concurrent-job limiting for Resque queues.
    #
    # Active jobs are tracked as entries in a Redis Sorted Set keyed by a unique per-job token,
    # with the job's start time as the score. On every count read, entries older than
    # :max_runtime age out via ZREMRANGEBYSCORE, so counter leaks from SIGKILL'd workers
    # (e.g. PruneDeadWorkerDirtyExit) self-heal without manual intervention.
    module Throttler
      extend self

      # Prefix used for Redis keys related to throttling.
      LOCK_KEYS_PREFIX = 'throttler'.freeze

      # Default upper bound on how long a single job can legitimately run before
      # its active-job entry is considered stale and evicted. One hour covers typical
      # long-running jobs; override per-queue via the :max_runtime option.
      DEFAULT_MAX_RUNTIME = 3600

      # Initializes rate limits when the module is extended.
      def self.extended(other)
        other.instance_variable_set(:@rate_limits, {})
      end

      # Sets rate limits for a specific queue.
      #
      # @param [Symbol, String] queue The name of the queue to rate limit.
      # @param [Hash] options The rate limit options.
      # @option options [Integer] :at The maximum number of jobs allowed in the time window.
      # @option options [Integer] :per The time window in seconds.
      # @option options [Integer] :concurrent Max concurrent jobs running for this queue (optional).
      # @option options [Integer] :max_runtime Seconds after which a stale active-job entry is
      #   auto-evicted (defaults to DEFAULT_MAX_RUNTIME). Only meaningful with :concurrent.
      #
      # @example
      #   Resque.rate_limit(:my_queue, at: 5, per: 60)
      #   Resque.rate_limit(:my_queue, at: 5, per: 60, concurrent: 10)
      #   Resque.rate_limit(:my_queue, at: 5, per: 60, concurrent: 10, max_runtime: 300)
      #
      # @raise [ArgumentError] If required options are missing or unknown options are supplied.
      def rate_limit(queue, options = {})
        required_keys = [:at, :per]
        unless (required_keys - options.keys).empty?
          raise ArgumentError.new("Missing either :at or :per in options")
        end

        allowed_keys = [:at, :per, :concurrent, :max_runtime]
        invalid_keys = options.keys - allowed_keys
        unless invalid_keys.empty?
          raise ArgumentError.new("Invalid options: #{invalid_keys.join(', ')}")
        end

        @rate_limits[queue.to_s] = options
      end

      def rate_limit_for(queue)
        @rate_limits[queue.to_s]
      end

      def rate_limited_queues
        @rate_limits.keys
      end

      def queue_rate_limited?(queue)
        !!@rate_limits[queue.to_s]
      end

      def rate_limiting_queue_lock_key(queue)
        "#{LOCK_KEYS_PREFIX}:lock:#{queue}"
      end

      def rate_limit_key_for(queue)
        "#{LOCK_KEYS_PREFIX}:rate_limit:#{queue}"
      end

      # Redis key for the Sorted Set tracking active jobs for a queue.
      # Members are per-job tokens; scores are job-start Unix timestamps.
      def active_jobs_set_key_for(queue)
        "#{LOCK_KEYS_PREFIX}:active_jobs_set:#{queue}"
      end

      # Legacy counter key retained only for cleanup in reset_throttling so deployments
      # that had an old leaked counter can DEL it on first reset.
      def active_jobs_key_for(queue)
        "#{LOCK_KEYS_PREFIX}:active_jobs:#{queue}"
      end

      # Returns the configured max job runtime (in seconds) for the queue, or the default.
      def max_runtime_for(queue)
        rate_limit = rate_limit_for(queue)
        (rate_limit && rate_limit[:max_runtime]) || DEFAULT_MAX_RUNTIME
      end

      # Returns the current active-job count for a queue, first evicting stale entries
      # older than :max_runtime. This is what makes the tracking self-healing: a job whose
      # worker was SIGKILL'd (and therefore never ran its ensure-block unregister) is
      # dropped here the next time anyone asks for the count.
      def active_job_count(queue)
        key = active_jobs_set_key_for(queue)
        cutoff = Time.now.to_f - max_runtime_for(queue)
        Resque.redis.zremrangebyscore(key, '-inf', cutoff)
        Resque.redis.zcard(key)
      end

      def queue_has_concurrent_limit?(queue)
        rate_limit = rate_limit_for(queue)
        rate_limit && rate_limit[:concurrent]
      end

      def queue_at_or_over_concurrent_limit?(queue)
        if queue_has_concurrent_limit?(queue)
          active_job_count(queue) >= rate_limit_for(queue)[:concurrent]
        else
          false
        end
      end

      # Registers a new active job and returns a token that must be passed to
      # unregister_active_job when the job finishes. The score is the job-start
      # timestamp, which is what allows stale entries to be auto-evicted later.
      def register_active_job(queue)
        token = SecureRandom.uuid
        Resque.redis.zadd(active_jobs_set_key_for(queue), Time.now.to_f, token)
        token
      end

      # Removes a previously-registered active job. Safe to call with a nil token
      # (no-op) so the ensure-block path stays simple.
      def unregister_active_job(queue, token)
        return if token.nil?
        Resque.redis.zrem(active_jobs_set_key_for(queue), token)
      end

      # @deprecated Use {#register_active_job} and capture the returned token.
      # Retained for backward compatibility; the returned token is a string rather
      # than an integer count, so callers relying on the old numeric return value
      # should migrate to the token API.
      def increment_active_jobs(queue)
        register_active_job(queue)
      end

      # @deprecated Use {#unregister_active_job} with the token from {#register_active_job}.
      # Without a token there is no way to know which entry to remove, so this falls back
      # to removing the oldest entry (ZPOPMIN). Paired increment/decrement calls without
      # intervening SIGKILL still behave correctly under this fallback.
      def decrement_active_jobs(queue)
        key = active_jobs_set_key_for(queue)
        Resque.redis.zpopmin(key, 1)
        active_job_count(queue)
      end

      def processed_job_count_in_rate_limit_window(queue)
        Resque.redis.get(rate_limit_key_for(queue)).to_i
      end

      def queue_at_or_over_rate_limit?(queue)
        if queue_rate_limited?(queue)
          processed_job_count_in_rate_limit_window(queue) >= rate_limit_for(queue)[:at]
        else
          false
        end
      end

      # Resets throttling data for one or all rate-limited queues.
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
        Resque.redis.del(rate_limiting_queue_lock_key(queue))
        Resque.redis.del(rate_limit_key_for(queue))
        Resque.redis.del(active_jobs_set_key_for(queue))
        # Also clean up the legacy counter key from pre-sorted-set versions.
        Resque.redis.del(active_jobs_key_for(queue))
      end
    end
  end
end

Resque.extend(Resque::Plugins::Throttler)

module Resque
  class Worker
    alias_method :original_perform, :perform

    # Overrides Worker#perform to register the job in the active-set before running
    # and unregister it after. The token is captured in a local variable and used
    # in the ensure block — if the process is SIGKILL'd, the ensure block does not
    # run but the entry still ages out via max_runtime.
    def perform(job)
      queue = job.queue

      if Resque.queue_rate_limited?(queue)
        token = Resque.register_active_job(queue)
        log_with_severity :debug, "Registered active job token=#{token} for #{queue} (count=#{Resque.active_job_count(queue)})"
        begin
          original_perform(job)
        ensure
          Resque.unregister_active_job(queue, token)
          log_with_severity :debug, "Unregistered active job token=#{token} for #{queue} (count=#{Resque.active_job_count(queue)})"
        end
      else
        original_perform(job)
      end
    end

    def reserve
      queues.each do |queue|
        log_with_severity :debug, "Checking #{queue}"

        if Resque.queue_rate_limited?(queue)
          log_with_severity :debug, "Rate limit applies to #{queue}, attempting to acquire lock"

          lock_acquired = acquire_lock(queue)
          unless lock_acquired
            log_with_severity :debug, "Could not acquire lock for #{queue}, skipping"
            next
          end

          log_with_severity :debug, "lock acquired"

          if Resque.queue_at_or_over_rate_limit?(queue)
            log_with_severity :debug, "#{queue} is over its rate limit, releasing lock and skipping"
            release_lock(queue)
            next
          end

          if Resque.queue_at_or_over_concurrent_limit?(queue)
            log_with_severity :debug, "#{queue} is at concurrent job limit (#{Resque.active_job_count(queue)} active jobs), releasing lock and skipping"
            release_lock(queue)
            next
          end

          if job = Resque.reserve(queue)
            log_with_severity :debug, "Found job on #{queue}"
            increment_job_counter(queue)
            release_lock(queue)
            return job
          else
            log_with_severity :debug, "No job on #{queue}"
            release_lock(queue)
          end
        else
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

    def acquire_lock(queue)
      Resque.redis.set(
        Resque.rate_limiting_queue_lock_key(queue),
        "locked",
        ex: 30,
        nx: true
      )
    end

    def release_lock(queue)
      Resque.redis.del(Resque.rate_limiting_queue_lock_key(queue))
    end

    def increment_job_counter(queue)
      Resque.redis.incr(Resque.rate_limit_key_for(queue))
      limit = Resque.rate_limit_for(queue)
      Resque.redis.expire(Resque.rate_limit_key_for(queue), limit[:per])
    end
  end
end
