require "yaml"
require "log"
require "uri"
require "uri/yaml"

require "./common.cr"
require "./downloader.cr"
require "./uploader.cr"
require "./parsers.cr"

module Podcaster
  class Config
    class_property dir : Path
    @@dir = (Path.new.posix? ? Path.new("~", ".config", "podcaster_cr") : Path.new("~", "AppData", "podcaster_cr", "config")).expand(home: true)

    include YAML::Serializable

    getter parser : Parser
    getter downloader : Downloader
    getter uploader : Uploader
    getter tasks : Array(Task)

    def self.by_name(name : String)
      Config.from_yaml File.read @@dir / (name + ".yml")
    end
  end
end

if ARGV.size == 0 || (ARGV.size == 1 && (ARGV.first == "-h" || ARGV.first == "--help"))
  puts "Provide configs names, will look for configs in #{Podcaster::Config.dir}

For example, create config
    #{Podcaster::Config.dir / "test.yml"}

with content like
---
parser:
  source: bandcamp
  proxy: http://127.0.0.1:2080
downloader:
  audio:
    bitrate: 128
    proxy:
    conversion:
      # bitrate: 128
      # samplerate: 44100
      # stereo: false
  thumbnail:
    side_size: 200
    proxy: http://127.0.0.1:2080
uploader:
  token: your telegram bot token here
tasks:
- artist: weltlandschaft
  chat: your telegram chat id here

and execute
    podcaster test"
else
  ARGV.each do |name|
    config = Podcaster::Config.by_name(name)

    config.tasks.each do |task|
      config.parser.items task do |item|
        downloaded = config.downloader.download item
        config.uploader.upload downloaded, task.chat
      end
    end
  end
end
