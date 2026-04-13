source "https://rubygems.org"

# Specify your gem's dependencies in sunstone.gemspec
gemspec

# Pin ActiveSupport to 6.x for compatibility with the test harness on Ruby 2.7.
# AS 7.x requires pieces (active_support/deprecation/deprecators) that don't load
# cleanly when we only pull in a single testing helper.
gem "activesupport", "~> 6.1"
