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

ARGV.each do |name|
  config = Podcaster::Config.by_name(name)

  config.tasks.each do |task|
    config.parser.items task do |item|
      downloaded = config.downloader.download item
      config.uploader.upload downloaded, task.chat
    end
  end
end
