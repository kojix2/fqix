require "option_parser"
require "./version"
require "./error"
require "./index"
require "./reader"

module Fqix
  class CLI
    private class CommandParser < OptionParser
      def reset_for_subcommand : Nil
        @handlers.clear
        @flags.clear
      end
    end

    enum Command
      Help
      Version
      Index
      Get
      Show
      Check
    end

    class Options
      property command = Command::Help
      property output : String?
      property index_path : String?
      property checkpoint_span = Index::DEFAULT_CHECKPOINT_SPAN
      property name_interval = Index::DEFAULT_NAME_INTERVAL
      property scan_bytes = Reader::DEFAULT_SCAN_BYTES
      property? raw = false
      property? help = false
      property help_message : String?
    end

    def initialize(@argv : Array(String), @out : IO, @err : IO)
    end

    def run : Int32
      opt = Options.new
      parser = build_parser(opt)
      parser.parse(@argv)
      return print_help(opt, parser) if opt.help?

      case opt.command
      in .help?
        if arg = @argv.first?
          raise Error.new("unknown command: #{arg}")
        end
        print_help(opt, parser)
      in .version?
        @out.puts "fqix #{VERSION}"
        0
      in .index?
        run_index(@argv, opt)
      in .get?
        run_get(@argv, opt)
      in .show?
        run_show(@argv, opt)
      in .check?
        run_check(@argv, opt)
      end
    rescue ex : Error
      @err.puts "fqix: #{ex.message}"
      @err.puts "Try 'fqix --help'." if ex.message.try(&.starts_with?("unknown command:"))
      1
    rescue ex : OptionParser::Exception
      @err.puts "fqix: #{ex.message}"
      1
    rescue ex : File::Error | IO::Error
      @err.puts "fqix: #{ex.message}"
      1
    end

    private def build_parser(opt : Options) : CommandParser
      CommandParser.new do |parser|
        parser.banner = main_banner
        parser.summary_width = 32
        parser.summary_indent = "  "

        parser.on("index", "Build an index") do
          configure_index_command(parser, opt)
        end

        parser.on("get", "Fetch reads by name") do
          configure_get_command(parser, opt)
        end

        parser.on("show", "Show index metadata") do
          configure_show_command(parser, opt)
        end

        parser.on("check", "Check whether an index is stale") do
          configure_check_command(parser, opt)
        end

        parser.on("help", "Show this help") do
          opt.command = Command::Help
          opt.help = true
        end

        parser.separator
        parser.separator "Options:"

        parser.on("-v", "--version", "Show version") do
          opt.command = Command::Version
        end

        parser.on("-h", "--help", "Show this help") do
          opt.help = true
        end
      end
    end

    private def configure_index_command(parser : CommandParser, opt : Options)
      opt.command = Command::Index
      parser.reset_for_subcommand
      parser.banner = command_banner(
        "Build a read-name index for a FASTQ.gz file",
        "fqix index [OPTIONS] reads.fastq.gz",
        [
          {"reads.fastq.gz", "Input FASTQ.gz file"},
        ]
      )
      parser.on("-o", "--output FILE", "FQIX index path [reads.fastq.gz.fqix]") { |v| opt.output = v }
      parser.on("-c", "--checkpoint-span BYTES", "Uncompressed bytes between zran checkpoints [4194304]") { |v| opt.checkpoint_span = parse_u64(v, "checkpoint span") }
      parser.on("-n", "--name-interval N", "Store one read-name anchor every N records [1024]") { |v| opt.name_interval = parse_u32(v, "name interval") }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_get_command(parser : CommandParser, opt : Options)
      opt.command = Command::Get
      parser.reset_for_subcommand
      parser.banner = command_banner(
        "Fetch FASTQ records by read name",
        "fqix get [OPTIONS] reads.fastq.gz read-name...",
        [
          {"reads.fastq.gz", "Input FASTQ.gz file"},
          {"read-name...", "Read name to fetch"},
        ]
      )
      parser.on("-i", "--index FILE", "FQIX index path [reads.fastq.gz.fqix]") { |v| opt.index_path = v }
      parser.on("-s", "--scan-limit BYTES", "Maximum bytes to inflate after sparse anchor [16777216]") { |v| opt.scan_bytes = parse_u64(v, "scan limit") }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_show_command(parser : CommandParser, opt : Options)
      opt.command = Command::Show
      parser.reset_for_subcommand
      parser.banner = command_banner(
        "Show index metadata",
        "fqix show [OPTIONS] index.fqix",
        [
          {"index.fqix", "Input FQIX index file"},
        ]
      )
      parser.on("--anchors", "Print sparse name entries") { opt.raw = true }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_check_command(parser : CommandParser, opt : Options)
      opt.command = Command::Check
      parser.reset_for_subcommand
      parser.banner = command_banner(
        "Check whether an index is stale",
        "fqix check [OPTIONS] reads.fastq.gz",
        [
          {"reads.fastq.gz", "Input FASTQ.gz file"},
        ]
      )
      parser.on("-i", "--index FILE", "FQIX index path [reads.fastq.gz.fqix]") { |v| opt.index_path = v }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def run_index(args : Array(String), opt : Options) : Int32
      gz = args.shift? || return print_required_args_error(opt)
      raise Error.new("too many arguments") unless args.empty?

      index = Index.build(gz, opt.checkpoint_span, opt.name_interval)
      out_path = opt.output || Index.default_path(gz)
      index.write(out_path)
      @err.puts "wrote #{out_path}"
      0
    end

    private def run_get(args : Array(String), opt : Options) : Int32
      gz = args.shift? || return print_required_args_error(opt)
      names = args
      return print_required_args_error(opt) if names.empty?

      idx_path = opt.index_path || Index.default_path(gz)
      idx = Index.read(idx_path)
      raise Error.new("index is stale for #{gz}") if idx.stale_for?(gz)

      reader = Reader.new(gz, idx)
      found = 0
      results = reader.fetch_many(names, opt.scan_bytes)
      names.zip(results).each do |name, result|
        case result.status
        in .found?
          @out << result.record
          found += 1
        in .not_found?
          @err.puts "fqix: not found: #{name}"
        in .scan_limit_reached?
          @err.puts "fqix: scan limit reached before finding #{name}; try increasing --scan-limit"
        end
      end
      found == names.size ? 0 : 2
    end

    private def run_show(args : Array(String), opt : Options) : Int32
      path = args.shift? || return print_required_args_error(opt)
      raise Error.new("too many arguments") unless args.empty?

      idx = Index.read(path)
      if opt.raw?
        idx.names.each do |entry|
          @out.puts [entry.name, entry.uncompressed_offset, entry.checkpoint_id, entry.delta].join('\t')
        end
      else
        @out.puts "version\t#{idx.format_version}"
        @out.puts "source_size\t#{idx.source_size}"
        @out.puts "source_mtime\t#{idx.source_mtime}"
        @out.puts "checkpoint_span\t#{idx.checkpoint_span}"
        @out.puts "name_interval\t#{idx.name_interval}"
        @out.puts "checkpoints\t#{idx.checkpoint_metas.size}"
        @out.puts "name_entries\t#{idx.names.size}"
      end
      0
    end

    private def run_check(args : Array(String), opt : Options) : Int32
      gz = args.shift? || return print_required_args_error(opt)
      raise Error.new("too many arguments") unless args.empty?

      idx_path = opt.index_path || Index.default_path(gz)
      idx = Index.read(idx_path)
      if idx.stale_for?(gz)
        @out.puts "stale\t#{idx_path}"
        1
      else
        @out.puts "ok\t#{idx_path}"
        0
      end
    end

    private def print_help(opt : Options, parser : OptionParser) : Int32
      @out.puts opt.help_message || parser.to_s
      0
    end

    private def print_required_args_error(opt : Options) : Int32
      @err.puts opt.help_message
      @err.puts
      @err.puts "[fqix] one or more required arguments were not provided"
      1
    end

    private def main_banner : String
      <<-BANNER

        Program: fqix
        Version: #{VERSION}
        Source:  #{REPOURL}

        Usage:   fqix <COMMAND> [OPTIONS]

        Commands:
        BANNER
    end

    private def command_banner(description : String,
                               usage : String,
                               arguments : Array(Tuple(String, String))) : String
      String.build do |io|
        io.puts
        io.puts description
        io.puts
        io.puts "Usage: #{usage}"
        io.puts
        io.puts "Arguments:"
        write_help_rows(io, arguments)
        io.puts
        io << "Options:"
      end
    end

    private def write_help_rows(io : IO, rows : Array(Tuple(String, String))) : Nil
      width = rows.max_of { |name, _summary| name.size }
      rows.each do |name, summary|
        io << "  " << name << "  "
        io << " " * (width - name.size)
        io.puts summary
      end
    end

    private def parse_u64(s : String, label : String) : UInt64
      s.to_u64? || raise Error.new("invalid #{label}: #{s}")
    end

    private def parse_u32(s : String, label : String) : UInt32
      v = s.to_u32? || raise Error.new("invalid #{label}: #{s}")
      raise Error.new("#{label} must be greater than zero") if v == 0
      v
    end
  end
end
