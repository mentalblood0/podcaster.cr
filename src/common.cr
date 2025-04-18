require "yaml"
require "uri/yaml"

module Podcaster
  struct Item
    getter url : URI
    getter performer : String?
    getter title : String
    getter duration : Time::Span
    getter thumbnail : URI

    def initialize(@url, performer : String, @title, @duration, @thumbnail)
      performer = performer.sub(/Various Artists? *(?:-|—)? */, "").strip
      @title = @title.sub(/Various Artists? *(?:-|—)? */, "").strip

      if performer == "" || performer == "NA"
        splitted = @title.split(/-|—/, 1).map &.strip
        return if splitted.size == 1
        @performer, @title = splitted
      else
        @performer = performer
      end

      @title = @title.sub(/#{Regex.escape @performer.not_nil!} ?-|—/, "").strip
    end

    def to_s(io : IO)
      io.print "#{performer} - #{title} (#{url})"
    end
  end

  class Downloaded
    getter item : Item
    getter audio : Path
    getter thumbnail : Path

    def initialize(@item, @audio, @thumbnail)
    end

    def to_s(io : IO)
      io.print "#{item.performer} - #{item.title} (#{audio}, #{thumbnail})"
    end
  end

  struct Task
    include YAML::Serializable

    getter artist : String
    getter chat : String

    def initialize(@artist, @chat)
    end
  end
end
