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

  def write_gzip_fastq(path : String, records : Array(String)) : Nil
    File.open(path, "wb") do |file|
      Compress::Gzip::Writer.open(file) do |gzip|
        records.each { |record| gzip << record }
      end
    end
  end
end

describe Fqix::CLI do
  context "help and argument handling" do
    it "prints the top-level help" do
      status, stdout, stderr = SpecCliSupport.run_cli(["--help"])

      status.should eq(0)
      stdout.should contain("Program: fqix")
      stdout.should contain("Version: #{Fqix::VERSION}")
      stdout.should contain("index")
      stdout.should contain("Options:")
      stderr.should be_empty
    end

    it "prints subcommand help to stdout with help last" do
      status, stdout, stderr = SpecCliSupport.run_cli(["index", "--help"])

      status.should eq(0)
      stdout.should contain("Build a read-name index for a FASTQ.gz file")
      stdout.should contain("Usage: fqix index")
      stdout.should contain("Arguments:")
      stdout.should contain("<fastq.gz>  Input FASTQ.gz file")
      stdout.should contain("-c, --checkpoint-span BYTES")
      stdout.should contain("-m, --mode MODE")
      stdout.should contain("-n, --name-interval N")
      stdout.should contain("-h, --help")
      stdout.should_not contain("--version")
      stdout.index!("-c, --checkpoint-span BYTES").should be < stdout.index!("-h, --help")
      stderr.should be_empty
    end

    it "prints subcommand help to stderr and fails when required arguments are missing" do
      status, stdout, stderr = SpecCliSupport.run_cli(["index"])

      status.should eq(1)
      stdout.should be_empty
      stderr.should contain("Usage: fqix index")
      stderr.should contain("-h, --help")
      stderr.should contain("[fqix] one or more required arguments were not provided")
    end

    it "does not accept version as a subcommand option" do
      status, stdout, stderr = SpecCliSupport.run_cli(["index", "--version"])

      status.should eq(1)
      stdout.should be_empty
      stderr.should contain("Invalid option: --version")
    end

    it "reports an unknown command" do
      status, stdout, stderr = SpecCliSupport.run_cli(["wat"])

      status.should eq(1)
      stdout.should be_empty
      stderr.should contain("unknown command: wat")
    end
  end

  context "basic workflows" do
    it "indexes a small FASTQ.gz and gets one read through the CLI" do
      File.tempfile("fqix-cli-small", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@read001\nACGT\n+\nIIII\n",
          "@read002 comment\nTGCA\n+\nJJJJ\n",
          "@read003\nGATTACA\n+\nHHHHHHH\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        status, stdout, stderr = SpecCliSupport.run_cli(["index", gz_path])
        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("wrote #{index_path}")
        File.exists?(index_path).should be_true

        status, stdout, stderr = SpecCliSupport.run_cli(["get", gz_path, "read002"])
        status.should eq(0)
        stdout.should eq(records[1])
        stderr.should be_empty
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end
  end

  context "duplicate queries and sparse lookup behavior" do
    it "gets duplicate read names through the CLI in input order" do
      File.tempfile("fqix-cli-duplicates", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@dup\nAAAA\n+\nIIII\n",
          "@other\nCCCC\n+\nIIII\n",
          "@dup comment\nGGGG\n+\nIIII\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        status, stdout, stderr = SpecCliSupport.run_cli(["index", "--mode", "exact", gz_path])
        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("wrote #{index_path}")

        status, stdout, stderr = SpecCliSupport.run_cli(["get", gz_path, "dup"])
        status.should eq(0)
        stdout.should eq(records[0] + records[2])
        stderr.should be_empty
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end

    it "supports duplicate query modes and query lists" do
      File.tempfile("fqix-cli-query-modes", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        list_path = File.tempname("fqix-cli-query-list", ".txt")
        records = [
          "@dup\nAAAA\n+\nIIII\n",
          "@other\nCCCC\n+\nIIII\n",
          "@dup comment\nGGGG\n+\nIIII\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)
        File.write(list_path, "dup\nother\n")

        SpecCliSupport.run_cli(["index", "--mode", "exact", gz_path]).first.should eq(0)

        status, stdout, stderr = SpecCliSupport.run_cli(["get", "--count", "--list", list_path, gz_path])
        status.should eq(0)
        stdout.should eq("dup\t2\nother\t1\n")
        stderr.should be_empty

        status, stdout, stderr = SpecCliSupport.run_cli(["get", "--first", "--order", "query", gz_path, "dup", "other"])
        status.should eq(0)
        stdout.should eq(records[0] + records[1])
        stderr.should be_empty

        status, stdout, stderr = SpecCliSupport.run_cli(["get", "--unique", gz_path, "dup"])
        status.should eq(2)
        stdout.should be_empty
        stderr.should contain("not unique: dup")
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
        File.delete(list_path) if list_path && File.exists?(list_path)
      end
    end

    it "supports sparse duplicate names for count unique all and input order" do
      File.tempfile("fqix-cli-sparse-duplicates", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@dup\nAAAA\n+\nIIII\n",
          "@dup comment\nGGGG\n+\nIIII\n",
          "@other\nCCCC\n+\nIIII\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        SpecCliSupport.run_cli(["index", gz_path]).first.should eq(0)

        status, stdout, stderr = SpecCliSupport.run_cli(["get", "--count", gz_path, "dup"])
        status.should eq(0)
        stdout.should eq("dup\t2\n")
        stderr.should be_empty

        status, stdout, stderr = SpecCliSupport.run_cli(["get", "--unique", gz_path, "dup"])
        status.should eq(2)
        stdout.should be_empty
        stderr.should contain("not unique: dup")

        status, stdout, stderr = SpecCliSupport.run_cli(["get", gz_path, "other", "dup"])
        status.should eq(0)
        stdout.should eq(records[0] + records[1] + records[2])
        stderr.should be_empty
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end

    it "reports sparse scan limit without emitting partial records" do
      File.tempfile("fqix-cli-sparse-scan-limit", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@read00\nAAAA\n+\nIIII\n",
        ]
        limits = [
          4_u64,  # header
          10_u64, # sequence
          14_u64, # plus
          17_u64, # quality
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        SpecCliSupport.run_cli(["index", gz_path]).first.should eq(0)

        limits.each do |limit|
          status, stdout, stderr = SpecCliSupport.run_cli(["get", "--scan-limit", limit.to_s, gz_path, "read00"])
          status.should eq(2)
          stdout.should be_empty
          stderr.should contain("scan limit reached")
          stderr.should_not contain("not found")
        end
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end
  end

  context "sparse-only index options" do
    it "warns when sparse-only name interval is passed to exact indexing" do
      File.tempfile("fqix-cli-exact-name-interval", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, ["@read00\nAAAA\n+\nIIII\n"])

        status, stdout, stderr = SpecCliSupport.run_cli(["index", "--mode", "exact", "--name-interval", "2", gz_path])
        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("--name-interval is ignored with --mode exact")
        stderr.should contain("wrote #{index_path}")
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end

    it "indexes naturally sorted sparse FASTQ with --name-order natural" do
      File.tempfile("fqix-cli-natural-order", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@DRR000001.265 3060N:7:1:502:2032 length=36\nGTTTTTCCCCATTATTTATACCTCTGATAAAAGTAA\n+\nIIIIIIIIII<II@IGIHI3B3IA?1322+)--/:%\n",
          "@DRR000001.572 3060N:7:1:620:2034 length=36\nGGTGACAGCAGGATTACGGAAGACANNNNTNNGNNT\n+\nIIIIIIIIIIIIHAC=869-3852*!!!!+!!#!!0\n",
          "@DRR000001.904 3060N:7:1:873:2032 length=36\nGGCGGTTGTCAAAATAGGGATTCGATTTGCCGTTAA\n+\nIIIII*I>I6+9AI+F.:I138(.(,1<&&(%)*(&\n",
          "@DRR000001.1077 3060N:7:1:596:2031 length=36\nGTAGCGAAATTCCTTGTCGGGTAAGTTCCGACCCGC\n+\nIIIIIIIGIIIICDBI1II9<55:7949./++3.19\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        # Explicit lex is rejected, and the message points at the order that works.
        status, stdout, stderr = SpecCliSupport.run_cli(["index", "--name-order", "lex", gz_path])
        status.should eq(1)
        stdout.should be_empty
        stderr.should contain("not sorted under --name-order lex")
        stderr.should contain("try --name-order natural")

        # The default (auto) detects natural and succeeds with no flag.
        status, stdout, stderr = SpecCliSupport.run_cli(["index", gz_path])
        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("wrote #{index_path}")

        status, stdout, stderr = SpecCliSupport.run_cli(["show", index_path])
        status.should eq(0)
        stdout.should contain("version\t1.2")
        stdout.should contain("order_mode\tnatural")
        stderr.should be_empty

        status, stdout, stderr = SpecCliSupport.run_cli(["get", gz_path, "DRR000001.1077"])
        status.should eq(0)
        stdout.should eq(records[3])
        stderr.should be_empty
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end

    it "warns when sparse-only name order is passed to exact indexing" do
      File.tempfile("fqix-cli-exact-name-order", ".fastq.gz") do |gzip_file|
        gz_path = gzip_file.path
        index_path = "#{gz_path}.fqix"
        records = [
          "@read2\nAAAA\n+\nIIII\n",
          "@read10\nCCCC\n+\nIIII\n",
        ]
        gzip_file.close
        SpecCliSupport.write_gzip_fastq(gz_path, records)

        status, stdout, stderr = SpecCliSupport.run_cli(["index", "--mode", "exact", "--name-order", "natural", gz_path])
        status.should eq(0)
        stdout.should be_empty
        stderr.should contain("--name-order is ignored with --mode exact")

        status, stdout, stderr = SpecCliSupport.run_cli(["show", index_path])
        status.should eq(0)
        stdout.should contain("input_names_sorted\tfalse")
        stdout.should_not contain("order_mode")
        stderr.should be_empty
      ensure
        File.delete(index_path) if index_path && File.exists?(index_path)
      end
    end
  end

  context "filesystem and corrupt input errors" do
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
end
