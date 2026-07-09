require 'test_helper'

class ResqueTest < Minitest::Test

  def setup
    Resque.instance_variable_set(:@rate_limits, {})
    Resque.redis.flushdb
  end

  # ------------------------------------------------------------
  # rate_limit configuration
  # ------------------------------------------------------------

  test "Resque::rate_limit stores basic config" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1)
    assert_equal({:at => 10, :per => 1}, Resque.rate_limit_for(:myqueue))
  end

  test "Resque::rate_limit accepts concurrent and max_runtime options" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3, :max_runtime => 120)
    expected = {:at => 10, :per => 1, :concurrent => 3, :max_runtime => 120}
    assert_equal expected, Resque.rate_limit_for(:myqueue)
  end

  test "Resque::rate_limit raises ArgumentError on unknown options" do
    assert_raises(ArgumentError) do
      Resque.rate_limit(:myqueue, :at => 10, :per => 1, :bogus => true)
    end
  end

  test "Resque::rate_limit raises ArgumentError when :at or :per missing" do
    assert_raises(ArgumentError) { Resque.rate_limit(:myqueue, :at => 10) }
    assert_raises(ArgumentError) { Resque.rate_limit(:myqueue, :per => 1) }
  end

  test "Resque::queue_rate_limited? accepts symbol and string" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1)
    assert Resque.queue_rate_limited?(:myqueue)
    assert Resque.queue_rate_limited?("myqueue")
    assert !Resque.queue_rate_limited?(:other)
  end

  # ------------------------------------------------------------
  # rate-limit window counter
  # ------------------------------------------------------------

  test "Resque::queue_at_or_over_rate_limit? compares window counter to :at" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1)
    key = Resque.rate_limit_key_for(:myqueue)

    Resque.redis.set(key, 5)
    assert !Resque.queue_at_or_over_rate_limit?(:myqueue)

    Resque.redis.set(key, 10)
    assert Resque.queue_at_or_over_rate_limit?(:myqueue)
  end

  # ------------------------------------------------------------
  # active-job tracking (the leak-proof sorted set)
  # ------------------------------------------------------------

  test "register_active_job adds one entry to the sorted set" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)
    assert_equal 0, Resque.active_job_count(:myqueue)

    Resque.register_active_job(:myqueue)
    assert_equal 1, Resque.active_job_count(:myqueue)

    Resque.register_active_job(:myqueue)
    Resque.register_active_job(:myqueue)
    assert_equal 3, Resque.active_job_count(:myqueue)
  end

  test "unregister_active_job removes the matching token" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)

    token_a = Resque.register_active_job(:myqueue)
    token_b = Resque.register_active_job(:myqueue)
    assert_equal 2, Resque.active_job_count(:myqueue)

    Resque.unregister_active_job(:myqueue, token_a)
    assert_equal 1, Resque.active_job_count(:myqueue)

    Resque.unregister_active_job(:myqueue, token_b)
    assert_equal 0, Resque.active_job_count(:myqueue)
  end

  test "unregister_active_job with nil token is a no-op" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)
    Resque.register_active_job(:myqueue)

    Resque.unregister_active_job(:myqueue, nil)

    assert_equal 1, Resque.active_job_count(:myqueue)
  end

  test "queue_at_or_over_concurrent_limit? fires at the configured ceiling" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 2)

    assert !Resque.queue_at_or_over_concurrent_limit?(:myqueue)

    Resque.register_active_job(:myqueue)
    assert !Resque.queue_at_or_over_concurrent_limit?(:myqueue)

    Resque.register_active_job(:myqueue)
    assert Resque.queue_at_or_over_concurrent_limit?(:myqueue)
  end

  test "queue_at_or_over_concurrent_limit? is false when no concurrent option set" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1)

    Resque.register_active_job(:myqueue)
    Resque.register_active_job(:myqueue)
    Resque.register_active_job(:myqueue)

    assert !Resque.queue_at_or_over_concurrent_limit?(:myqueue)
  end

  # ------------------------------------------------------------
  # THE leak-proof behaviour: simulates what SIGKILL does
  # ------------------------------------------------------------

  test "stale entries older than :max_runtime are auto-evicted on count" do
    # 1s max_runtime so we can simulate a SIGKILL'd worker cheaply with travel_to
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3, :max_runtime => 1)

    # Three "worker" processes start jobs. Normally the ensure-block would
    # unregister each on completion. Simulate SIGKILL by NOT calling unregister.
    travel_to Time.at(1_700_000_000) do
      Resque.register_active_job(:myqueue)
      Resque.register_active_job(:myqueue)
      Resque.register_active_job(:myqueue)
      assert_equal 3, Resque.active_job_count(:myqueue)
      assert Resque.queue_at_or_over_concurrent_limit?(:myqueue),
             "counter should be at ceiling while entries are fresh"
    end

    # Jump forward past :max_runtime. The next count call should evict all
    # three stale entries, clearing the way for new jobs.
    travel_to Time.at(1_700_000_000 + 5) do
      assert_equal 0, Resque.active_job_count(:myqueue),
                   "stale leaked entries must auto-evict after :max_runtime"
      assert !Resque.queue_at_or_over_concurrent_limit?(:myqueue),
             "queue must be processable again once stale entries age out"
    end
  end

  test "reset_throttling clears the active-job set and legacy counter" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)

    Resque.register_active_job(:myqueue)
    Resque.register_active_job(:myqueue)
    # Also seed the legacy counter key — previous gem versions used a raw INCR.
    Resque.redis.set(Resque.active_jobs_key_for(:myqueue), 5)

    Resque.reset_throttling(:myqueue)

    assert_equal 0, Resque.active_job_count(:myqueue)
    assert_nil Resque.redis.get(Resque.active_jobs_key_for(:myqueue))
  end

  # ------------------------------------------------------------
  # backward-compat shims
  # ------------------------------------------------------------

  test "increment_active_jobs still bumps the count (returns a token)" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)

    token = Resque.increment_active_jobs(:myqueue)

    assert_equal 1, Resque.active_job_count(:myqueue)
    assert_kind_of String, token
  end

  test "decrement_active_jobs removes the oldest entry when no token given" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)

    Resque.register_active_job(:myqueue)
    Resque.register_active_job(:myqueue)

    Resque.decrement_active_jobs(:myqueue)

    assert_equal 1, Resque.active_job_count(:myqueue)
  end

  test "decrement_active_jobs does not go negative on empty set" do
    Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3)

    Resque.decrement_active_jobs(:myqueue)

    assert_equal 0, Resque.active_job_count(:myqueue)
  end

  # ------------------------------------------------------------
  # shared buckets (bucket: option)
  # ------------------------------------------------------------

  test "rate_limit with bucket: inherits the bucket queue's config" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5, :concurrent => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    assert Resque.queue_rate_limited?(:laneq)
    assert_equal Resque.rate_limit_for(:mainq), Resque.rate_limit_for(:laneq)
    assert_equal 'mainq', Resque.bucket_queue_for(:laneq)
    assert_equal :mainq, Resque.bucket_queue_for(:mainq)
  end

  test "rate_limit with bucket: resolves config changes at read time" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)
    Resque.rate_limit(:mainq, :at => 7, :per => 9)

    assert_equal({:at => 7, :per => 9}, Resque.rate_limit_for(:laneq))
  end

  test "rate_limit rejects bucket: combined with other options" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5)

    assert_raises(ArgumentError) { Resque.rate_limit(:laneq, :bucket => :mainq, :at => 5) }
  end

  test "rate_limit rejects bucket: pointing at an unregistered queue" do
    assert_raises(ArgumentError) { Resque.rate_limit(:laneq, :bucket => :ghost) }
  end

  test "rate_limit rejects self-referential and chained buckets" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    assert_raises(ArgumentError) { Resque.rate_limit(:selfq, :bucket => :selfq) }
    assert_raises(ArgumentError) { Resque.rate_limit(:lane2q, :bucket => :laneq) }
  end

  test "bucketed queue's throttling keys resolve to the bucket queue's keys" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5, :concurrent => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    assert_equal Resque.rate_limit_key_for(:mainq), Resque.rate_limit_key_for(:laneq)
    assert_equal Resque.rate_limiting_queue_lock_key(:mainq), Resque.rate_limiting_queue_lock_key(:laneq)
    assert_equal Resque.active_jobs_set_key_for(:mainq), Resque.active_jobs_set_key_for(:laneq)
    assert_equal Resque.active_jobs_key_for(:mainq), Resque.active_jobs_key_for(:laneq)
    # An unrelated queue keeps its own keys.
    assert_equal "throttler:rate_limit:otherq", Resque.rate_limit_key_for(:otherq)
  end

  test "shared window counter trips the limit for every queue in the bucket" do
    Resque.rate_limit(:mainq, :at => 5, :per => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    Resque.redis.set(Resque.rate_limit_key_for(:mainq), 5)

    assert Resque.queue_at_or_over_rate_limit?(:mainq)
    assert Resque.queue_at_or_over_rate_limit?(:laneq)
  end

  test "active jobs from any queue in the bucket count against one concurrency cap" do
    Resque.rate_limit(:mainq, :at => 10, :per => 1, :concurrent => 2)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    Resque.register_active_job(:laneq)
    Resque.register_active_job(:mainq)

    assert_equal 2, Resque.active_job_count(:laneq)
    assert Resque.queue_at_or_over_concurrent_limit?(:mainq)
    assert Resque.queue_at_or_over_concurrent_limit?(:laneq)
  end

  test "stale entries registered via a bucketed queue self-heal after :max_runtime" do
    # Same SIGKILL simulation as the dedicated test above, but the leaked
    # tokens enter through the bucketed lane — the shared set must still
    # self-heal for BOTH queue names.
    Resque.rate_limit(:mainq, :at => 10, :per => 1, :concurrent => 2, :max_runtime => 1)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    travel_to Time.at(1_700_000_000) do
      Resque.register_active_job(:laneq)
      Resque.register_active_job(:laneq)
      assert Resque.queue_at_or_over_concurrent_limit?(:mainq)
      assert Resque.queue_at_or_over_concurrent_limit?(:laneq)
    end

    travel_to Time.at(1_700_000_000 + 5) do
      assert_equal 0, Resque.active_job_count(:mainq)
      assert !Resque.queue_at_or_over_concurrent_limit?(:laneq)
    end
  end

  test "reset_throttling via either queue name clears the shared bucket keys" do
    Resque.rate_limit(:mainq, :at => 10, :per => 1, :concurrent => 2)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    Resque.register_active_job(:laneq)
    Resque.redis.set(Resque.rate_limit_key_for(:mainq), 3)

    Resque.reset_throttling(:laneq)

    assert_equal 0, Resque.active_job_count(:mainq)
    assert_nil Resque.redis.get(Resque.rate_limit_key_for(:mainq))
  end

  test "worker drains a priority lane first and both queues share one rate budget" do
    Resque.rate_limit(:mainq, :at => 5, :per => 60, :concurrent => 5)
    Resque.rate_limit(:laneq, :bucket => :mainq)

    3.times { Resque::Job.create(:mainq, 'DummyThrottlerJob', 'default') }
    3.times { Resque::Job.create(:laneq, 'DummyThrottlerJob', 'priority') }

    worker = Resque::Worker.new('laneq', 'mainq')
    popped = []
    6.times do
      job = worker.reserve
      break if job.nil?

      popped << job.queue
    end

    assert_equal 5, popped.length, "combined pops must stop at the shared :at limit"
    assert_equal ['laneq'] * 3, popped.first(3), "priority lane must drain first"
    assert_equal ['mainq'] * 2, popped.last(2)
  end

end
