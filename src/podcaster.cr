require "yaml"
require "log"
require "uri"
require "uri/yaml"

require "./command.cr"
require "./common.cr"
require "./downloader.cr"
require "./uploader.cr"
require "./parsers.cr"

module Podcaster
  class Config
    class_property dir : Path
    {% if flag?(:windows) %}
      @@dir = Path.new("~", "AppData", "podcaster", "config").expand(home: true)
    {% else %}
      @@dir = Path.new("~", ".config", "podcaster").expand(home: true)
    {% end %}

    include YAML::Serializable

    getter parser : Parser
    getter downloader : Downloader
    getter uploader : Uploader
    getter tasks : Array(Task)
    getter log : String = "info"

    def after_initialize
      Log.setup Log::Severity.parse @log
    end

    def self.by_name(name : String)
      Dir.mkdir_p @@dir
      Config.from_yaml File.new @@dir / (name + ".yml")
    end
  end
end

if ARGV.size == 0 || (ARGV.size == 1 && (ARGV.first == "-h" || ARGV.first == "--help"))
  puts "Provide configs names, will look for configs in #{Podcaster::Config.dir}"
  example_path = Podcaster::Config.dir / "example.yml"
  if !File.exists? example_path
    File.write example_path, "---
parser:
  source: # youtube or bandcamp
  proxy: # address, e.g. http://127.0.0.1:1234, skip it for direct connection
  only_cache: # do now download, just cache, true or false, false if skipped
downloader:
  audio:
    bitrate: # preferred bitrate, e.g. 192, for each track the nearest available will be selected
    proxy: # address, e.g. http://127.0.0.1:1234, skip it for direct connection
    conversion: # remove this object to skip conversion (however, it is often needed for youtube)
      bitrate: # number, Kb/s, e.g. 128
      samplerate: # number, Hz, e.g. 44100
      stereo: # true or false
  thumbnail:
    side_size: # number, pixels, e.g. 200
    proxy: # address, e.g. http://127.0.0.1:1234, skip it for direct conversion
uploader:
  token: # your telegram bot token
tasks:
- artist: # artist id, e.g. abc, will compose url as http://abc.bandcamp.com or http://www.youtube.com/abc, depending on parser source
  chat: # telegram chat id, e.g. \"-1234567890123\""
    puts "Also, see config template at #{example_path}"
  end
else
  ARGV.each do |name|
    config = Podcaster::Config.by_name(name)

    config.tasks.each do |task|
      config.parser.items task do |item|
        begin
          downloaded = config.downloader.download item
          config.uploader.upload downloaded, task.chat
          true
        rescue ex : Podcaster::Command::FatalError
          false
        end
      end
    end
  end
end
