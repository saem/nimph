import std/uri except Url
import std/tables
import std/os
import std/strutils
import std/asyncdispatch
import std/options
import std/strformat

import bump

import nimph/spec
import nimph/git
import nimph/nimble
import nimph/project
import nimph/doctor
import nimph/thehub
import nimph/config
import nimph/package
import nimph/dependency
import nimph/locker
import nimph/group

template crash(why: string) =
  ## a good way to exit nimph
  error why
  return 1

method pretty(ex: ref Exception): string {.base.} =
  let
    prefix = $typeof(ex)
  result = prefix.split(" ")[^1] & ": " & ex.msg

template warnException() =
  warn getCurrentException().pretty

const
  logLevel =
    when defined(debug):
      lvlDebug
    elif defined(release):
      lvlNotice
    elif defined(danger):
      lvlNotice
    else:
      lvlInfo

template prepareForTheWorst(body: untyped) =
  when defined(release) or defined(danger):
    try:
      body
    except:
      warnException
      crash("crashing because something bad happened")
  else:
    body

template setupLocalProject(project: var Project) =
  if not findProject(project, getCurrentDir()):
    crash &"unable to find a project; try `nimble init`?"
  try:
    project.cfg = loadAllCfgs(project.repo)
  except Exception as e:
    crash "unable to parse nim configuration: " & e.msg

proc searcher*(args: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to search github for nim packages

  # user's choice, our default
  setLogFilter(log_level)

  if args.len == 0:
    crash &"a search was requested but no query parameters were provided"
  let
    group = waitfor searchHub(args)
  if group.isNone:
    crash &"unable to retrieve search results from github"
  for repo in group.get.reversed:
    fatal "\n" & repo.renderShortly
  if group.get.len == 0:
    fatal &"😢no results"

proc fixer*(log_level = logLevel; dry_run = false): int =
  ## cli entry to evaluate and/or repair the environment

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  prepareForTheWorst:
    if project.doctor(dry = dry_run):
      fatal &"👌{project.nimble.package} version {project.version} lookin' good"
    elif not dry_run:
      crash &"the doctor wasn't able to fix everything"
    else:
      warn "run `nimph doctor` to fix this stuff"

proc nimbler*(args: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to pass-through nimble commands with a sane nimbleDir

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  let
    nimble = project.runNimble(args)
  if not nimble.ok:
    crash &"nimble didn't like that"

proc pather*(names: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to echo the path(s) of any dependencies

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  var group = project.newDependencyGroup(flags = {Flag.Quiet})
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # for convenience, add the project itself if possible
  if not group.hasKey(project.name):
    let dependency = newDependency(project)
    group.add dependency.requirement, dependency

  for name in names.items:
    let found = group.pathForName(name)
    if found.isSome:
      echo found.get
    else:
      error &"couldn't find `{name}` among our installed dependencies"
      echo ""      # a failed find produces empty output
      result = 1   # and sets the return code to nonzero

proc dumpLockList(project: Project) =
  for room in project.allLockerRooms:
    once:
      fatal &"here's a list of available locks:"
    fatal &"\t{room.name}"

proc lockfiler*(names: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to write a lockfile

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  let name = names.join(" ")
  if name == "":
    project.dumpLockList
    fatal &"give me some arguments so i can name the lock"
    result = 1
  else:
    if project.lock(name):
      fatal &"👌locked {project} as `{name}`"
    else:
      result = 1

proc unlockfiler*(names: seq[string]; log_level = logLevel;
                  dry_run = false): int =
  ## cli entry to read a lockfile

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  let name = names.join(" ")
  if name == "":
    project.dumpLockList
    fatal &"give me some arguments so i can fetch the lock by name"
    result = 1
  else:
    if project.unlock(name):
      fatal &"👌unlocked {project} via `{name}`"
    else:
      result = 1

proc forker*(names: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to remotely fork installed packages

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  var group = project.newDependencyGroup(flags = {Flag.Quiet})
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  for name in names.items:
    let found = group.projectForName(name)
    if found.isNone:
      error &"couldn't find `{name}` among our installed dependencies"
      result = 1
      continue
    let
      child = found.get
      fork = child.forkTarget
    if not fork.ok:
      error fork.why
      result = 1
      continue
    info &"🍴forking {child}"
    let forked = waitfor forkHub(fork.owner, fork.repo)
    if forked.isNone:
      result = 1
      continue
    fatal &"🔱{forked.get.web}"
    if child.dist == Git:
      let name = defaultRemote
      if not child.promoteRemoteLike(forked.get.git, name = name):
        notice &"unable to promote new fork to {name}"
    else:
      {.warning: "optionally upgrade a gitless install to clone".}

proc cloner*(args: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to clone a package into the environment

  # user's choice, our default
  setLogFilter(log_level)

  var
    url: Uri
    name: string

  if args.len == 0:
    crash &"provide a single url, or a github search query"
  elif args.len == 1:
    try:
      let
        uri = parseUri(args[0])
      if uri.isValid:
        url = uri
        name = packageName(url.path.lastPathPart)
    except:
      discard

  var project: Project
  setupLocalProject(project)

  if not url.isValid:
    let
      query {.used.} = args.join(" ")
      group = waitfor searchHub(args)
    if group.isNone:
      crash &"unable to retrieve search results from github"

    var
      repository: HubResult
    block found:
      for repos in group.get.values:
        repository = repos
        url = repository.git
        name = repository.name
        break found
      crash &"unable to find a package matching `{query}`"

  if not url.isValid:
    crash &"unable to determine a valid url to clone"

  var
    cloned: Project
  if not project.clone(url, name, cloned):
    crash &"unable to clone {url}"

  # rename the directory to match head release
  cloned.relocateDependency

  # try to point it at github if it looks like it's our repo
  if not cloned.promote:
    debug &"did not promote remote to ssh"

template dumpHelp(fun: typed; use: string) =
  try:
    discard fun(cmdline = @["--help"], prefix = "    ", usage = use)
  except HelpOnly:
    discard

when isMainModule:
  import cligen
  type
    SubCommand = enum
      scDoctor = "doctor"
      scSearch = "search"
      scClone = "clone"
      scNimble = "nimble"
      scPath = "path"
      scFork = "fork"
      scLock = "lock"
      scUnlock = "unlock"
      scVersion = "--version"
      scHelp = "--help"

  let
    logger = newCuteConsoleLogger()
  addHandler(logger)

  const
    version = projectVersion()
  if version.isSome:
    clCfg.version = $version.get
  else:
    clCfg.version = "(unknown version)"

  # setup some dispatchers for various subcommands
  dispatchGen(searcher, cmdName = $scSearch, dispatchName = "run" & $scSearch,
              doc="search github for packages")
  dispatchGen(fixer, cmdName = $scDoctor, dispatchName = "run" & $scDoctor,
              doc="repair (or report) env issues")
  dispatchGen(cloner, cmdName = $scClone, dispatchName = "run" & $scClone,
              doc="add a package to the env")
  dispatchGen(pather, cmdName = $scPath, dispatchName = "run" & $scPath,
              doc="fetch package path(s) by import name(s)")
  dispatchGen(forker, cmdName = $scFork, dispatchName = "run" & $scFork,
              doc="fork a package to your GitHub profile")
  dispatchGen(lockfiler, cmdName = $scLock, dispatchName = "run" & $scLock,
              doc="lock dependencies")
  dispatchGen(unlockfiler, cmdName = $scUnlock, dispatchName = "run" & $scUnlock,
              doc="unlock dependencies")
  dispatchGen(nimbler, cmdName = $scNimble, dispatchName = "run" & $scNimble,
              doc="Nimble handles other subcommands (with a proper nimbleDir)")

  const
    # these are our subcommands that we want to include in help
    dispatchees = [rundoctor, runsearch, runclone, runpath, runfork,
                   runlock, rununlock]

    # these are nimble subcommands that we don't need to warn about
    passthrough = ["install", "uninstall", "build", "test", "doc", "dump",
                   "refresh", "list", "tasks"]

  var
    # get the command line
    params = commandLineParams()

    # command aliases can go here
    aliases = {
      "fix": scDoctor,
    }.toTable

    # associate commands to dispatchers created by cligen
    dispatchers = {
      scSearch: runsearch,
      scDoctor: rundoctor,
      scClone: runclone,
      scPath: runpath,
      scFork: runfork,
      scLock: runlock,
      scUnlock: rununlock,
      #scNimble: runnimble,
    }.toTable

  # obviate the need to run parseEnum
  for sub in SubCommand.low .. SubCommand.high:
    aliases[$sub] = sub

  # don't warn if it's an expected Nimble subcommand
  for sub in passthrough.items:
    aliases[sub] = scNimble

  # maybe just run the nurse
  if params.len == 0:
    let newLog = max(0, logLevel.ord - 1).Level
    quit dispatchers[scDoctor](cmdline = @["--dry-run", "--log-level=" & $newLog])

  # try to parse the subcommand
  var sub: SubCommand
  let first = params[0].strip.toLowerAscii
  if first in aliases:
    sub = aliases[first]
  else:
    # if we couldn't parse it, try passing it to nimble
    warn &"unrecognized subcommand `{first}`; passing it to Nimble..."
    sub = scNimble

  # take action according to the subcommand
  try:
    case sub:
    of scNimble:
      # invoke nimble with the original parameters
      quit runnimble(cmdline = params)
    of scVersion:
      # report the version
      echo clCfg.version
    of scHelp:
      # yield some help
      echo "run `nimph` for a non-destructive report, or use a subcommand;"
      for fun in dispatchees.items:
        once:
          fun.dumpHelp("all subcommands accept (at least) the following options:\n$options")
        fun.dumpHelp("\n$command $args\n$doc")
      echo ""
      echo "    " & passthrough.join(", ")
      let nimbleUse = "    $args\n$doc"
      # produce help for nimble subcommands
      discard runnimble(cmdline = @["--help"], prefix = "    ",
                         usage = nimbleUse)
    else:
      # invoke the appropriate dispatcher
      quit dispatchers[sub](cmdline = params[1..^1])
  except HelpOnly:
    discard
  quit 0
