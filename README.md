# podcaster

Fast and stable Bandcamp/Youtube to Telegram audio uploader

## Dependencies

`yt-dlp` and `ffmpeg`

Temporary files will be located in default system temporary files directory, mount tmpfs or analogous filesystem to reduce your HDD/SSD wear and tear

## Installation

```bash
shards build --production --release
```

## Usage

```bash
./bin/podcaster
```
