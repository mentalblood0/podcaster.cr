module Podcaster
  class Command
    class RecoverableError < Exception
      class_property substrings
      @@substrings = [
        "SSL: UNEXPECTED_EOF_WHILE_READING", "Unable to connect to proxy",
        "Read timed out.", "Unable to fetch PO Token for mweb client", "IncompleteRead",
        "Remote end closed connection without response", "Cannot connect to proxy.",
        "Temporary failure in name resolution", "timed out. (connect timeout",
        "Connection reset by peer",
      ]
    end

    class FatalError < Exception
      class_property substrings
      @@substrings = [
        "No video formats found!;", "The page doesn't contain any tracks;",
        "Sign in to confirm your age", ": Premieres in ",
        ": Requested format is not available",
        "Postprocessing: Error opening output files: Invalid argument",
        "members-only content like this video",
      ]
    end

    @process : Process

    def initialize(@command : String, @args : Enumerable(String))
      @process = run
    end

    def run
      Process.new @command, @args, output: :pipe, error: :pipe
    end

    def result
      loop do
        output = @process.output.gets_to_end
        error = @process.error.gets_to_end
        ec = @process.wait.exit_code
        raise Exception.new "No exit code for process #{@command} #{@args}" if ec == nil
        if ec != 0
          puts "error executing #{@command} #{@args}: #{error}" if error.size > 1
          raise FatalError.new "#{@command} #{@args}" if FatalError.substrings.any? { |sub| error.includes? sub }
          if RecoverableError.substrings.any? { |sub| error.includes? sub }
            @process = run
            next
          end
        end
        return output
      end
    end
  end
end
