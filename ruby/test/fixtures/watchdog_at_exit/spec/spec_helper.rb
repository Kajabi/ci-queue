# frozen_string_literal: true
RSpec.configure { |config| config.backtrace_inclusion_patterns << %r{/test/fixtures/} }
at_exit { sleep 30 }
