import std/uri except Url
import std/tables
import std/os
import std/strutils
import std/asyncdispatch
import std/options
import std/strformat
import std/sequtils

import bump

import nimph/spec
import nimph/nimble
import nimph/project
import nimph/doctor
import nimph/thehub
import nimph/config
import nimph/package
import nimph/dependency
import nimph/locker
import nimph/group
import nimph/version

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
      fatal &"👌{project.name} version {project.version} lookin' good"
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
    nimble = project.runSomething("nimble", args)
  if not nimble.ok:
    crash &"nimble didn't like that"

proc pather*(names: seq[string]; log_level = logLevel; dry_run = false): int =
  ## cli entry to echo the path(s) of any dependencies

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  if names.len == 0:
    crash &"give me an import name to retrieve its filesystem path"

  # setup our dependency group
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

proc runner*(args: seq[string]; log_level = logLevel; dry_run = false): int =
  ## this is another pather, basically, that invokes the arguments in the path
  let
    exe = args[0]
    args = args[1..^1]

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  # setup our dependency group
  var group = project.newDependencyGroup(flags = {Flag.Quiet})
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # make sure we visit every project that fits the requirements
  for req, dependency in group.pairs:
    for child in dependency.projects.values:
      withinDirectory(child.repo):
        info &"running {exe} in {child.repo}"
        let
          got = project.runSomething(exe, args)
        if not got.ok:
          error &"{exe} didn't like that in {child.repo}"
          result = 1

proc upgradeChild(child: var Project; requirement: Requirement;
                  dry_run = false): bool =
  result = true
  block:
    if child.dist != Git:
      break
    if child.name in ["Nim", "nim", "compiler"]:
      debug &"ignoring the compiler"
      break
    if not child.upgradeAvailable:
      debug &"no upgrade available for {child.name}"
      break
    let latest = child.tags.latestRelease
    if not child.upgrade(requirement, dry_run = dry_run):
      if not dry_run:
        warn &"unable to upgrade {child.name}"
      result = false
    elif child.version < latest:
      notice &"the latest {child.name} release of {latest} is masked"

proc upgrader*(names: seq[string]; log_level = logLevel; dry_run = false): int =
  ## perform upgrades of dependencies within project requirement specifications

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  # setup our dependency group
  var group = project.newDependencyGroup(flags = {Flag.Quiet})
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  if names.len == 0:
    for requirement, dependency in group.pairs:
      for child in dependency.projects.mvalues:
        if not child.upgradeChild(requirement, dry_run = dry_run):
          result = 1
  else:
    for name in names.items:
      let found = group.projectForName(name)
      if found.isSome:
        var child = found.get
        let required = group.reqForProject(found.get)
        if required.isSome:
          if not child.upgradeChild(required.get, dry_run = dry_run):
            result = 1
        else:
          raise newException(Defect, &"found `{name}` but not its requirement")
      else:
        error &"couldn't find `{name}` among our installed dependencies"

  if result == 0:
    fatal &"👌{project.name} is up-to-date"
  else:
    notice &"{project.name} is not fully up-to-date"


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

proc tagger*(log_level = logLevel; dry_run = false): int =
  ## cli entry to add missing tags

  # user's choice, our default
  setLogFilter(log_level)

  var
    project: Project
  setupLocalProject(project)

  if project.fixTags(dry_run = dry_run):
    if dry_run:
      warn "run without --dry-run to fix these"
    else:
      crash &"the doctor wasn't able to fix everything"
  else:
    fatal &"👌{project.name} tags are lookin' good"

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

  # if only one argument was supplied, see if we can parse it as a url
  if args.len == 1:
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

  # if the input wasn't parsed to a url,
  if not url.isValid:
    # search github using the input as a query
    let
      query {.used.} = args.join(" ")
      hubs = waitfor searchHub(args)
    if hubs.isNone:
      crash &"unable to retrieve search results from github"

    # and pluck the first result, presumed to be the best
    block found:
      for repo in hubs.get.values:
        url = repo.git
        name = repo.name
        break found
      crash &"unable to find a package matching `{query}`"

  # if we STILL don't have a url, we're done
  if not url.isValid:
    crash &"unable to determine a valid url to clone"

  # perform the clone
  var
    cloned: Project
  if not project.clone(url, name, cloned):
    crash &"problem cloning {url}"

  # reset our paths to, hopefully, grab the new project
  project.cfg = loadAllCfgs(project.repo)

  # setup our dependency group
  var group = project.newDependencyGroup(flags = {Flag.Quiet})
  if not project.resolve(group):
    notice &"unable to resolve all dependencies for {project}"

  # see if we can find this project in the dependencies
  let needed = group.projectForPath(cloned.repo)

  # if it's in there, let's get its requirement and roll to meet it
  block relocated:
    if needed.isSome:
      let requirement = group.reqForProject(cloned)
      if requirement.isNone:
        warn &"unable to retrieve requirement for {cloned.name}"
      else:
        # rollTowards will relocate us, too
        if cloned.rollTowards(requirement.get):
          notice &"rolled {cloned.name} to {cloned.version}"
          # so skip the tail of this block (and a 2nd relocate)
          break relocated
        notice &"unable to meet {requirement} with {cloned}"
    # rename the directory to match head release
    project.relocateDependency(cloned)

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
      scHelp = "--help"
      scDoctor = "doctor"
      scSearch = "search"
      scClone = "clone"
      scNimble = "nimble"
      scPath = "path"
      scFork = "fork"
      scLock = "lock"
      scUnlock = "unlock"
      scTag = "tag"
      scRun = "run"
      scUpgrade = "upgrade"
      scVersion = "--version"

    AliasTable = Table[string, seq[string]]

  let
    logger = newCuteConsoleLogger()
  addHandler(logger)

  const
    release = projectVersion()
  if release.isSome:
    clCfg.version = $release.get
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
  dispatchGen(tagger, cmdName = $scTag, dispatchName = "run" & $scTag,
              doc="tag versions")
  dispatchGen(upgrader, cmdName = $scUpgrade, dispatchName = "run" & $scUpgrade,
              doc="upgrade project dependencies")
  dispatchGen(nimbler, cmdName = $scNimble, dispatchName = "run" & $scNimble,
              doc="Nimble handles other subcommands (with a proper nimbleDir)")
  dispatchGen(runner, cmdName = $scRun, dispatchName = "run" & $scRun,
              stopWords = @["--"],
              doc="execute the program & arguments in every dependency directory")

  proc makeAliases(passthrough: openArray[string]): AliasTable {.compileTime.} =
    # command aliases can go here
    result = {
      # the nurse is aka `nimph` without arguments...
      "nurse":    @[$scDoctor, "--dry-run"],
      "fix":      @[$scDoctor],
      "fetch":    @[$scRun, "--", "git", "fetch"],
      "pull":     @[$scRun, "--", "git", "pull"],
      "outdated": @[$scUpgrade, "--dry-run"],
    }.toTable

    # add in the default subcommands
    for sub in SubCommand.low .. SubCommand.high:
      result[$sub] = @[$sub]

    # associate known nimble subcommands
    for sub in passthrough.items:
      result[sub] = @[$scNimble, sub]

  const
    # these are our subcommands that we want to include in help
    dispatchees = [rundoctor, runsearch, runclone, runpath, runfork,
                   runlock, rununlock, runtag, runupgrade, runrun]

    # these are nimble subcommands that we don't need to warn about
    passthrough = ["install", "uninstall", "build", "test", "doc", "dump",
                   "refresh", "list", "tasks"]

    # associate commands to dispatchers created by cligen
    dispatchers = {
      scSearch: runsearch,
      scDoctor: rundoctor,
      scClone: runclone,
      scPath: runpath,
      scFork: runfork,
      scLock: runlock,
      scUnlock: rununlock,
      scTag: runtag,
      scRun: runrun,
      scUpgrade: runupgrade,
    }.toTable

    # setup the mapping between subcommand and expanded parameters
    aliases = makeAliases(passthrough)

  var
    # get the command line
    params = commandLineParams()

  # get the subcommand one way or another
  if params.len == 0:
    params = @["nurse"]
  let first = params[0].strip.toLowerAscii

  # try to parse the subcommand
  var sub: SubCommand
  if first in aliases:
    # expand the alias
    params = aliases[first].concat params[1..^1]
    # and then parse the subcommand
    sub = parseEnum[SubCommand](params[0])
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
      # we'll enhance logging for these subcommands
      if first in ["outdated", "nurse"]:
        let newLog = max(0, logLevel.ord - 1).Level
        params = params.concat @["--log-level=" & $newLog]
      # invoke the appropriate dispatcher
      quit dispatchers[sub](cmdline = params[1..^1])
  except HelpOnly:
    discard
  quit 0
