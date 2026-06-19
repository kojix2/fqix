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
      None
      Version
      Index
      Get
      Show
      Check
    end

    enum GetOrder
      Query
      Input
    end

    class Options
      property command = Command::None
      property output : String?
      property index_path : String?
      property checkpoint_span = Index::DEFAULT_CHECKPOINT_SPAN
      property index_mode = Index::DEFAULT_MODE
      property name_interval = Index::DEFAULT_NAME_INTERVAL
      property? name_interval_set = false
      property name_order : OrderMode? = nil # nil = auto-detect
      property? name_order_set = false
      property scan_bytes = Reader::DEFAULT_SCAN_BYTES
      property list_path : String?
      property get_order = GetOrder::Input
      property? raw = false
      property? first = false
      property? count = false
      property? all = true
      property? unique = false
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
      in .none?
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
        parser.summary_width = 14
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
      parser.summary_width = 28
      parser.banner = command_banner(
        "Build a read-name index for a FASTQ.gz file",
        "fqix index [OPTIONS] <fastq.gz>",
        [
          {"fastq.gz", "Input FASTQ.gz file"},
        ]
      )
      parser.on("-o", "--output FILE", "FQIX index path [fastq.gz.fqix]") { |v| opt.output = v }
      parser.on("-c", "--checkpoint-span BYTES", "Uncompressed bytes between zran checkpoints [4194304]") { |v| opt.checkpoint_span = parse_u64(v, "checkpoint span") }
      parser.on("-m", "--mode MODE", "Index mode: sparse or exact [sparse]") { |v| opt.index_mode = parse_index_mode(v) }
      parser.on("-n", "--name-interval N", "Sparse anchor interval [1024]") { |v| opt.name_interval = parse_u32(v, "name interval"); opt.name_interval_set = true }
      parser.on("--name-order ORDER", "Sparse read-name order: auto, lex, or natural [auto]") { |v| opt.name_order = parse_name_order(v); opt.name_order_set = true }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_get_command(parser : CommandParser, opt : Options)
      opt.command = Command::Get
      parser.reset_for_subcommand
      parser.summary_width = 23
      parser.banner = command_banner(
        "Fetch FASTQ records by read name",
        "fqix get [OPTIONS] <fastq.gz> <readname>...",
        [
          {"fastq.gz", "Input FASTQ.gz file"},
          {"readname", "Read name to fetch"},
        ]
      )
      parser.on("-i", "--index FILE", "FQIX index path [fastq.gz.fqix]") { |v| opt.index_path = v }
      parser.on("-s", "--scan-limit BYTES", "Sparse mode forward-scan byte limit [16777216]") { |v| opt.scan_bytes = parse_u64(v, "scan limit") }
      parser.on("--first", "Return only the first matching record for each name") { opt.first = true; opt.all = false }
      parser.on("--count", "Print match counts instead of FASTQ records") { opt.count = true }
      parser.on("--all", "Return all matching records [default]") { opt.all = true; opt.first = false }
      parser.on("--unique", "Fail when a requested name has multiple matches") { opt.unique = true }
      parser.on("--list FILE", "Read query names from FILE") { |v| opt.list_path = v }
      parser.on("--order ORDER", "Output order: input or query [input]") { |v| opt.get_order = parse_get_order(v) }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_show_command(parser : CommandParser, opt : Options)
      opt.command = Command::Show
      parser.reset_for_subcommand
      parser.summary_width = 14
      parser.banner = command_banner(
        "Show index metadata",
        "fqix show [OPTIONS] <index.fqix>",
        [
          {"index.fqix", "Input FQIX index file"},
        ]
      )
      parser.on("--entries", "Print raw mode-specific lookup entries") { opt.raw = true }
      parser.on("--anchors", "Alias for --entries") { opt.raw = true }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def configure_check_command(parser : CommandParser, opt : Options)
      opt.command = Command::Check
      parser.reset_for_subcommand
      parser.summary_width = 17
      parser.banner = command_banner(
        "Check whether an index is stale",
        "fqix check [OPTIONS] <fastq.gz>",
        [
          {"fastq.gz", "Input FASTQ.gz file"},
        ]
      )
      parser.on("-i", "--index FILE", "FQIX index path [fastq.gz.fqix]") { |v| opt.index_path = v }
      parser.on("-h", "--help", "Print help") { opt.help = true }
      opt.help_message = parser.to_s
    end

    private def run_index(args : Array(String), opt : Options) : Int32
      gz = args.shift? || return print_required_args_error(opt)
      raise Error.new("too many arguments") unless args.empty?

      @err.puts "fqix: warning: --name-interval is ignored with --mode exact" if opt.index_mode.exact? && opt.name_interval_set?
      @err.puts "fqix: warning: --name-order is ignored with --mode exact" if opt.index_mode.exact? && opt.name_order_set?
      index = Index.build(gz, checkpoint_span: opt.checkpoint_span, mode: opt.index_mode, name_interval: opt.name_interval, order_mode: opt.name_order)
      out_path = opt.output || Index.default_path(gz)
      index.write(out_path)
      @err.puts "wrote #{out_path}"
      0
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def run_get(args : Array(String), opt : Options) : Int32
      gz = args.shift? || return print_required_args_error(opt)
      names = args
      if list_path = opt.list_path
        names = names + File.read_lines(list_path).map(&.strip).reject(&.empty?)
      end
      return print_required_args_error(opt) if names.empty?

      idx_path = opt.index_path || Index.default_path(gz)
      idx = Index.read(idx_path)
      raise Error.new("index is stale for #{gz}") if idx.stale_for?(gz)

      reader = Reader.new(gz, idx)
      found_names = 0
      matches = [] of Tuple(UInt64, String)
      names.each do |name|
        result = reader.fetch_matches_with_status(name, opt.scan_bytes)
        records = result.matches
        if result.status.scan_limit_reached?
          @err.puts "fqix: scan limit reached before lookup completed: #{name}"
          next
        end
        if records.empty?
          @err.puts "fqix: not found: #{name}"
        else
          if opt.unique? && records.size > 1
            @err.puts "fqix: not unique: #{name}"
            next
          end
          found_names += 1
          if opt.count?
            @out.puts "#{name}\t#{records.size}"
          elsif opt.first?
            matches << records.first
          else
            matches.concat(records)
          end
        end
      end
      unless opt.count?
        ordered =
          case opt.get_order
          in .query?
            matches
          in .input?
            matches.sort_by(&.[0])
          end
        ordered.each do |_, record|
          @out << record
        end
      end
      found_names == names.size ? 0 : 2
    end

    private def run_show(args : Array(String), opt : Options) : Int32
      path = args.shift? || return print_required_args_error(opt)
      raise Error.new("too many arguments") unless args.empty?

      idx = Index.read(path)
      opt.raw? ? show_raw_entries(idx) : show_metadata(idx)
      0
    end

    private def show_raw_entries(idx : Index) : Nil
      case idx.mode
      in .sparse?
        idx.names.each do |entry|
          @out.puts [
            entry.name,
            entry.uncompressed_offset,
            entry.checkpoint_id,
            entry.delta,
          ].join('\t')
        end
      in .exact?
        idx.entries.each do |entry|
          @out.puts [
            idx.entry_name(entry),
            entry.name_hash,
            entry.record_number,
            entry.record_offset,
            entry.record_size,
          ].join('\t')
        end
      end
    end

    private def show_metadata(idx : Index) : Nil
      @out.puts "version\t#{idx.format_version}"
      @out.puts "mode\t#{idx.mode}"
      @out.puts "source_size\t#{idx.source_size}"
      @out.puts "source_mtime\t#{idx.source_mtime}"
      @out.puts "checkpoint_span\t#{idx.checkpoint_span}"
      @out.puts "name_interval\t#{idx.name_interval}" if idx.sparse?
      @out.puts "order_mode\t#{idx.order_mode_label}" if idx.sparse?
      @out.puts "hash_algorithm\t#{idx.hash_algorithm}" if idx.exact?
      @out.puts "hash_seed\t#{idx.hash_seed}" if idx.exact?
      @out.puts "name_mode\t#{idx.name_mode}"
      @out.puts "record_count\t#{idx.record_count}" if idx.record_count > 0
      @out.puts "input_names_sorted\t#{idx.input_names_sorted?}"
      @out.puts "checkpoints\t#{idx.checkpoint_metas.size}"
      @out.puts "anchors\t#{idx.names.size}" if idx.sparse?
      @out.puts "entries\t#{idx.entries.size}" if idx.exact?
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
        io << "  <" << name << ">  "
        io << " " * (width - name.size)
        io.puts summary
      end
    end

    private def parse_u64(s : String, label : String) : UInt64
      s.to_u64? || raise Error.new("invalid #{label}: #{s}")
    end

    private def parse_u32(s : String, label : String) : UInt32
      value = s.to_u32? || raise Error.new("invalid #{label}: #{s}")
      value
    end

    private def parse_index_mode(s : String) : IndexMode
      case s
      when "sparse"
        IndexMode::Sparse
      when "exact"
        IndexMode::Exact
      else
        raise Error.new("invalid index mode: #{s}")
      end
    end

    private def parse_get_order(s : String) : GetOrder
      case s
      when "query"
        GetOrder::Query
      when "input"
        GetOrder::Input
      else
        raise Error.new("invalid output order: #{s}")
      end
    end

    private def parse_name_order(s : String) : OrderMode?
      case s
      when "auto"
        nil
      when "lex"
        OrderMode::Lexicographic
      when "natural"
        OrderMode::Natural
      else
        raise Error.new("invalid name order: #{s}")
      end
    end
  end
end
