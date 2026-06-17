require "./fqix/cli"

exit Fqix::CLI.new(ARGV, STDOUT, STDERR).run
