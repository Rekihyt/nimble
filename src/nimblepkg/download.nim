# Copyright (C) Dominik Picheta. All rights reserved.
# BSD License. Look at license.txt for more info.

import parseutils, os, osproc, strutils, tables, pegs

import packageinfo, version, tools, nimbletypes

type  
  TDownloadMethod* {.pure.} = enum
    Git = "git", Hg = "hg"

proc getSpecificDir(meth: TDownloadMethod): string =
  case meth
  of TDownloadMethod.Git:
    ".git"
  of TDownloadMethod.Hg:
    ".hg"

proc doCheckout(meth: TDownloadMethod, downloadDir, branch: string) =
  case meth
  of TDownloadMethod.Git:
    cd downloadDir:
      # Force is used here because local changes may appear straight after a
      # clone has happened. Like in the case of git on Windows where it
      # messes up the damn line endings.
      doCmd("git checkout --force " & branch)
  of TDownloadMethod.Hg:
    cd downloadDir:
      doCmd("hg checkout " & branch)

proc doPull(meth: TDownloadMethod, downloadDir: string) =
  case meth
  of TDownloadMethod.Git:
    doCheckout(meth, downloadDir, "master")
    cd downloadDir:
      doCmd("git pull")
      if existsFile(".gitmodules"):
        doCmd("git submodule update")
  of TDownloadMethod.Hg:
    doCheckout(meth, downloadDir, "default")
    cd downloadDir:
      doCmd("hg pull")

proc doClone(meth: TDownloadMethod, url, downloadDir: string, branch = "", tip = true) =
  case meth
  of TDownloadMethod.Git:
    let
      depthArg = if tip: "--depth 1 " else: ""
      branchArg = if branch == "": "-b origin/master" else: "-b " & branch & " "
      branch = if branch == "": "master" else: branch
    # Some git versions (e.g. 1.7.9.5) don't check out the correct branch/tag
    # directly during clone, so we enter the download directory and manually
    # initi the git repo issuing several commands in sequence. Recipe taken
    # from http://stackoverflow.com/a/3489576/172690.
    downloadDir.createDir
    downloadDir.cd:
      doCmd("git init")
      doCmd("git remote add origin " & url)
      doCmd("git fetch origin " & depthArg & branch)
      doCmd("git reset --hard FETCH_HEAD")
      doCmd("git checkout --force " & branchArg)
      doCmd("git submodule update --init --recursive")
  of TDownloadMethod.Hg:
    let
      tipArg = if tip: "-r tip " else: ""
      branchArg = if branch == "": "" else: "-b " & branch & " "
    doCmd("hg clone " & tipArg & branchArg & url & " " & downloadDir)

proc getTagsList(dir: string, meth: TDownloadMethod): seq[string] =
  cd dir:
    var output = execProcess("git tag")
    case meth
    of TDownloadMethod.Git:
      output = execProcess("git tag")
    of TDownloadMethod.Hg:
      output = execProcess("hg tags")
  if output.len > 0:
    case meth
    of TDownloadMethod.Git:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        result.add(i)
    of TDownloadMethod.Hg:
      result = @[]
      for i in output.splitLines():
        if i == "": continue
        var tag = ""
        discard parseUntil(i, tag, ' ')
        if tag != "tip":
          result.add(tag)
  else:
    result = @[]

proc getTagsListRemote*(url: string, meth: TDownloadMethod): seq[string] =
  result = @[]
  case meth
  of TDownloadMethod.Git:
    var (output, exitCode) = doCmdEx("git ls-remote --tags " & url)
    if exitCode != QuitSuccess:
      raise newException(OSError, "Unable to query remote tags for " & url &
          ". Git returned: " & output)
    for i in output.splitLines():
      if i == "": continue
      let start = i.find("refs/tags/")+"refs/tags/".len
      let tag = i[start .. -1]
      if not tag.endswith("^{}"): result.add(tag)
    
  of TDownloadMethod.Hg:
    # http://stackoverflow.com/questions/2039150/show-tags-for-remote-hg-repository
    raise newException(ValueError, "Hg doesn't support remote tag querying.")
  
proc getVersionList*(tags: seq[string]): Table[TVersion, string] =
  # Returns: TTable of version -> git tag name
  result = initTable[TVersion, string]()
  for tag in tags:
    if tag != "":
      let i = skipUntil(tag, Digits) # skip any chars before the version
      # TODO: Better checking, tags can have any names. Add warnings and such.
      result[newVersion(tag[i .. -1])] = tag

proc getDownloadMethod*(meth: string): TDownloadMethod =
  case meth
  of "git": return TDownloadMethod.Git
  of "hg", "mercurial": return TDownloadMethod.Hg
  else:
    raise newException(ENimble, "Invalid download method: " & meth)

proc getHeadName*(meth: TDownloadMethod): string =
  ## Returns the name of the download method specific head. i.e. for git
  ## it's ``head`` for hg it's ``tip``.
  case meth
  of TDownloadMethod.Git: "head"
  of TDownloadMethod.Hg: "tip"

proc checkUrlType*(url: string): TDownloadMethod =
  ## Determines the download method based on the URL.
  if doCmdEx("git ls-remote " & url).exitCode == QuitSuccess:
    return TDownloadMethod.Git
  elif doCmdEx("hg identify " & url).exitCode == QuitSuccess:
    return TDownloadMethod.Hg
  else:
    raise newException(ENimble, "Unable to identify url.")

proc isURL*(name: string): bool =
  name.startsWith(peg" @'://' ")

proc doDownload*(url: string, downloadDir: string, verRange: PVersionRange,
                 downMethod: TDownloadMethod) =
  template getLatestByTag(meth: stmt): stmt {.dirty, immediate.} =
    echo("Found tags...")
    # Find latest version that fits our ``verRange``.
    var latest = findLatest(verRange, versions)
    ## Note: HEAD is not used when verRange.kind is verAny. This is
    ## intended behaviour, the latest tagged version will be used in this case.
    
    # If no tagged versions satisfy our range latest.tag will be "".
    # We still clone in that scenario because we want to try HEAD in that case.
    # https://github.com/nimrod-code/nimble/issues/22
    meth

  proc verifyClone() =
    ## Makes sure that the downloaded package's version satisfies the requested
    ## version range.
    let pkginfo = getPkgInfo(downloadDir)
    if pkginfo.version.newVersion notin verRange:
      raise newException(ENimble,
        "Downloaded package's version does not satisfy requested version " &
        "range: wanted $1 got $2." %
        [$verRange, $pkginfo.version])
  
  removeDir(downloadDir)
  if verRange.kind == verSpecial:
    # We want a specific commit/branch/tag here.
    if verRange.spe == newSpecial(getHeadName(downMethod)):
      doClone(downMethod, url, downloadDir) # Grab HEAD.
    else:
      # Mercurial requies a clone and checkout. The git clone operation is
      # already fragmented into multiple steps so we just call doClone().
      if downMethod == TDownloadMethod.Git:
        doClone(downMethod, url, downloadDir, $verRange.spe)
      else:
        doClone(downMethod, url, downloadDir, tip = false)
        doCheckout(downMethod, downloadDir, $verRange.spe)
  else:
    case downMethod
    of TDownloadMethod.Git:
      # For Git we have to query the repo remotely for its tags. This is
      # necessary as cloning with a --depth of 1 removes all tag info.
      let versions = getTagsListRemote(url, downMethod).getVersionList()
      if versions.len > 0:
        getLatestByTag:
          echo("Cloning latest tagged version: ", latest.tag)
          doClone(downMethod, url, downloadDir, latest.tag)
      else:
        # If no commits have been tagged on the repo we just clone HEAD.
        doClone(downMethod, url, downloadDir) # Grab HEAD.
      
      verifyClone()
    of TDownloadMethod.Hg:
      doClone(downMethod, url, downloadDir)
      let versions = getTagsList(downloadDir, downMethod).getVersionList()
    
      if versions.len > 0:
        getLatestByTag:
          echo("Switching to latest tagged version: ", latest.tag)
          doCheckout(downMethod, downloadDir, latest.tag)
      
      verifyClone()

proc echoPackageVersions*(pkg: TPackage) =
  let downMethod = pkg.downloadMethod.getDownloadMethod()
  case downMethod
  of TDownloadMethod.Git:
    try:
      let versions = getTagsListRemote(pkg.url, downMethod).getVersionList()
      if versions.len > 0:
        var vstr = ""
        var i = 0
        for v in values(versions):
          if i != 0:
            vstr.add(", ")
          vstr.add(v)
          i.inc
        echo("  versions:    " & vstr)
      else:
        echo("  versions:    (No versions tagged in the remote repository)")
    except OSError:
      echo(getCurrentExceptionMsg())
  of TDownloadMethod.Hg:
    echo("  versions:    (Remote tag retrieval not supported by " & pkg.downloadMethod & ")")
