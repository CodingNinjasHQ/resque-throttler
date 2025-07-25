require 'resque'
require 'resque/throttler'

# Example: Configuring concurrent job limits for database-intensive workers

# Configure Redis
Resque.redis = Redis.new(host: 'localhost', port: 6379)

# Configure rate limits with concurrent job limits
# This allows 5 jobs to start per 5 seconds, but only 3 can run concurrently
Resque.rate_limit(:lsq_rl_pro, at: 5, per: 5, concurrent: 3)

# Without concurrent limit (original behavior)
Resque.rate_limit(:lsq_rl_freshers, at: 2, per: 5)

# Example worker that simulates long-running database operations
class DatabaseIntensiveWorker
  @queue = :lsq_rl_pro

  def self.perform(lead_id)
    puts "Starting job for lead #{lead_id} - Active jobs: #{Resque.active_job_count(@queue)}"
    
    # Simulate long-running database operation
    sleep(10)
    
    puts "Completed job for lead #{lead_id}"
  end
end

# Queue multiple jobs
10.times do |i|
  Resque.enqueue(DatabaseIntensiveWorker, i)
end

puts "Queued 10 jobs"
puts "Rate limit config: #{Resque.rate_limit_for(:lsq_rl_pro).inspect}"

# In your Rails app config/initializers/resque.rb:
# Resque.rate_limit(:lsq_rl_pro, at: 5, per: 5, concurrent: 3)
#
# This means:
# - At most 5 jobs can start within any 5-second window
# - At most 3 jobs can be actively running at the same time
#
# If 3 jobs are already running and taking longer than 5 seconds,
# new jobs won't start even if the rate limit would allow it.