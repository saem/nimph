version = "1.1.0"
author = "disruptek"
description = "nim package handler from the future"
license = "MIT"

bin = @["nimph"]
srcDir = "src"

# this breaks tests
#installDirs = @["docs", "tests", "src"]

requires "https://github.com/c-blake/cligen >= 0.9.46 & < 1.5.20"
requires "https://github.com/zevv/npeg >= 0.26.0 & < 1.0.0"
requires "https://github.com/disruptek/bump >= 1.8.18 & < 2.0.0"
requires "https://github.com/disruptek/github >= 2.0.3 & < 3.0.0"
requires "https://github.com/disruptek/jsonconvert < 2.0.0"
requires "https://github.com/disruptek/badresults >= 2.1.2 & < 3.0.0"
requires "https://github.com/disruptek/cutelog >= 1.1.0 & < 2.0.0"
requires "https://github.com/disruptek/gittyup >= 3.1.0 & < 4.0.0"
requires "https://github.com/disruptek/ups >= 0.0.5 & < 1.0.0"

when not defined(release):
  requires "https://github.com/disruptek/balls >= 3.0.0 & < 4.0.0"

task test, "run unit tests":
  when defined(windows):
    exec """balls.cmd --define:ssl"""
  else:
    exec """balls --define:ssl"""
