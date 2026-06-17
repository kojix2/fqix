require "./spec_helper"
require "../src/fqix/cli"

module SpecCliSupport
  extend self

  def run_cli(args : Array(String)) : Tuple(Int32, String, String)
    stdout = IO::Memory.new
    stderr = IO::Memory.new

    status = Fqix::CLI.new(args, stdout, stderr).run
    {status, stdout.to_s, stderr.to_s}
  end
end

describe Fqix::CLI do
  it "prints the top-level help" do
    status, stdout, stderr = SpecCliSupport.run_cli(["--help"])

    status.should eq(0)
    stdout.should contain("fqix #{Fqix::VERSION}")
    stdout.should contain("index")
    stdout.should contain("Options:")
    stderr.should be_empty
  end

  it "prints subcommand help from OptionParser" do
    status, stdout, stderr = SpecCliSupport.run_cli(["index", "--help"])

    status.should eq(0)
    stdout.should contain("Usage: fqix index")
    stdout.should contain("--checkpoint-span=BYTES")
    stdout.should contain("--name-interval=N")
    stderr.should be_empty
  end

  it "reports an unknown command" do
    status, stdout, stderr = SpecCliSupport.run_cli(["wat"])

    status.should eq(1)
    stdout.should be_empty
    stderr.should contain("unknown command: wat")
  end

  it "reports missing FASTQ input for index without a stack trace" do
    status, stdout, stderr = SpecCliSupport.run_cli(["index", "nope.fastq.gz"])

    status.should eq(1)
    stdout.should be_empty
    stderr.should start_with("fqix: ")
    stderr.should contain("nope.fastq.gz")
    stderr.should_not contain("Unhandled exception")
  end

  it "reports a missing default index for get without a stack trace" do
    status, stdout, stderr = SpecCliSupport.run_cli(["get", "reads.fastq.gz", "read1"])

    status.should eq(1)
    stdout.should be_empty
    stderr.should start_with("fqix: ")
    stderr.should contain("reads.fastq.gz.fqix")
    stderr.should_not contain("Unhandled exception")
  end

  it "reports a missing default index for check without a stack trace" do
    status, stdout, stderr = SpecCliSupport.run_cli(["check", "reads.fastq.gz"])

    status.should eq(1)
    stdout.should be_empty
    stderr.should start_with("fqix: ")
    stderr.should contain("reads.fastq.gz.fqix")
    stderr.should_not contain("Unhandled exception")
  end

  it "reports a missing index for show without a stack trace" do
    status, stdout, stderr = SpecCliSupport.run_cli(["show", "missing.fqix"])

    status.should eq(1)
    stdout.should be_empty
    stderr.should start_with("fqix: ")
    stderr.should contain("missing.fqix")
    stderr.should_not contain("Unhandled exception")
  end

  it "reports a truncated index without a stack trace" do
    path = File.tempname("fqix-cli-truncated", ".fqix")
    File.write(path, "FQIX")

    begin
      status, stdout, stderr = SpecCliSupport.run_cli(["show", path])

      status.should eq(1)
      stdout.should be_empty
      stderr.should start_with("fqix: ")
      stderr.should_not contain("Unhandled exception")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
