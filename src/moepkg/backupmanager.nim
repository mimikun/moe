#[###################### GNU General Public License 3.0 ######################]#
#                                                                              #
#  Copyright (C) 2017─2023 Shuhei Nogawa                                       #
#                                                                              #
#  This program is free software: you can redistribute it and/or modify        #
#  it under the terms of the GNU General Public License as published by        #
#  the Free Software Foundation, either version 3 of the License, or           #
#  (at your option) any later version.                                         #
#                                                                              #
#  This program is distributed in the hope that it will be useful,             #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of              #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the               #
#  GNU General Public License for more details.                                #
#                                                                              #
#  You should have received a copy of the GNU General Public License           #
#  along with this program.  If not, see <https://www.gnu.org/licenses/>.      #
#                                                                              #
#[############################################################################]#

# Manager for automatic backup.

import std/os
import pkg/results
import editorstatus, bufferstatus, unicodeext, ui, movement, gapbuffer,
       highlight, settings, messages, backup, fileutils, editorview,
       windownode, commandlineutils, backupmanagerutils

template baseBackupDir*(status: EditorStatus): Runes =
  status.settings.autoBackup.backupDir

proc openDiffViewer(status: var EditorStatus, sourceFilePath: string) =
  ## Create an new window and open the diff viewer.
  ## `sourceFilePath` and `backupFilePath` is need to absolute path.
  ## Use diff command.

  if currentLineBuffer.len == 0:
    return

  let
    backupDir = backupDir($status.baseBackupDir, sourceFilePath)
    backupFilePath = backupDir / $currentLineBuffer

  if not validateBackupFileName(backupFilePath.splitPath.tail):
    return

  # Create a new window and move to it.
  status.verticalSplitWindow
  status.resize
  status.moveNextWindow

  discard status.addNewBufferInCurrentWin(Mode.diff)
  status.changeCurrentBuffer(status.bufStatus.high)

  currentBufStatus.path = backupFilePath.toRunes

  status.resize

proc restoreBackupFile(
  status: var EditorStatus,
  sourceFilePath: Runes,
  isForceRestore: bool) =
    ## Restore the current buffer from backupFile.
    ## the filename is the current line.

    if not fileExists($sourceFilePath): return

    let
      backupFilename = currentBufStatus.buffer[currentMainWindowNode.currentLine]
      baseBackupDir = status.settings.autoBackup.backupDir
      backupDir = getBackupDir(baseBackupDir, sourceFilePath)
      restoreFilePath = $backupDir / $backupFilename

    if not fileExists(restoreFilePath): return

    if not isForceRestore:
      let isRestore = status.commandLine.askBackupRestorePrompt(
        backupFilename)
      if not isRestore: return

    # Backup the current buffer before restore
    for bufStatus in status.bufStatus:
      if bufStatus.absolutePath == sourceFilePath and
         bufStatus.mode == Mode.normal:
           bufStatus.backupBuffer(
             status.settings.autoBackup,
             status.settings.notification,
             status.commandLine)

    try:
      copyFile(restoreFilePath, $sourceFilePath)
    except OSError:
      status.commandLine.writeBackupRestoreError
      return

    # Update restored buffer
    for i in 0 ..< status.bufStatus.len:
      if status.bufStatus[i].absolutePath == sourceFilePath:
        let beforeBufStatus = status.bufStatus[i]

        let b = initBufferStatus($sourceFilePath)
        if b.isOk:
          status.bufStatus[i] = b.get
        else:
          status.commandLine.writeBackupRestoreError
          return

        let textAndEncoding = openFile(sourceFilePath)
        if textAndEncoding.isErr:
          status.bufStatus[i] = beforeBufStatus
          status.commandLine.writeBackupRestoreError
          return

        status.bufStatus[i].buffer = textAndEncoding.get.text.toGapBuffer
        status.bufStatus[i].characterEncoding = textAndEncoding.get.encoding

        status.bufStatus[i].language = detectLanguage($sourceFilePath)

        currentMainWindowNode.view =
          status.bufStatus[i].buffer.initEditorView(1, 1)

        status.resize

        let settings = status.settings.notification
        status.commandLine.writeRestoreFileSuccessMessage(
          backupFilename,
          settings)

        return

    status.commandLine.writeBackupRestoreError

template restoreBackupFile(
  status: var EditorStatus,
  sourceFilePath: Runes) =

    const IS_FORCE_RESTORE = false
    status.restoreBackupFile(sourceFilePath, IS_FORCE_RESTORE)

proc removeBackupFile(
  status: var EditorStatus,
  sourceFilePath: Runes,
  isForceRemove: bool) =
    ## Remove the backup file.
    ## the filename is the current line.

    let
      backupFilename = currentBufStatus.buffer[currentMainWindowNode.currentLine]
      baseBackupDir = status.settings.autoBackup.backupDir
      backupDir = backupDir($baseBackupDir, $sourceFilePath)
      backupFilePath = backupDir / $backupFilename

    if not fileExists(backupFilePath): return

    if not isForceRemove:
      let isRemove = status.commandLine.askDeleteBackupPrompt(
        backupFilename)
      if not isRemove: return

    try:
      removeFile(backupFilePath)
    except OSError:
      status.commandLine.writeDeleteBackupError
      return

    let settings = status.settings.notification
    status.commandLine.writeMessageDeletedFile(
      $backupFilename,
      settings)

template removeBackupFile(status: var EditorStatus, sourceFilePath: Runes) =
  const IS_FORCE_REMOVE = false
  status.removeBackupFile(sourceFilePath, IS_FORCE_REMOVE)

proc isBackupManagerCommand*(command: Runes): InputState =
  result = InputState.Invalid

  if command.len == 1:
    let key = command[0]
    if isCtrlK(key) or
       isCtrlJ(key) or
       key == ord(':') or
       key == ord('k') or isUpKey(key) or
       key == ord('j') or isDownKey(key) or
       isEnterKey(key) or
       key == ord('R') or
       key == ord('D') or
       key == ord('r') or
       key == ord('G'):
         return InputState.Valid
    elif key == ord('g'):
      return InputState.Continue
  elif command.len == 2:
    if command[0] == ord('g'):
      if command[1] == ord('g'):
        return InputState.Valid

proc execBackupManagerCommand*(status: var EditorStatus, command: Runes) =
  let sourceFilePath = status.bufStatus[status.prevBufferIndex].absolutePath

  if command.len == 1:
    let key = command[0]
    if isCtrlK(key):
      status.moveNextWindow
    elif isCtrlJ(key):
      status.movePrevWindow
    elif key == ord(':'):
      status.changeMode(Mode.ex)
    elif key == ord('k') or isUpKey(key):
      currentBufStatus.keyUp(currentMainWindowNode)
    elif key == ord('j') or isDownKey(key):
      currentBufStatus.keyDown(currentMainWindowNode)
    elif isEnterKey(key):
      status.openDiffViewer($sourceFilePath)
    elif key == ord('R'):
      status.restoreBackupFile(sourceFilePath)
    elif key == ord('D'):
      status.removeBackupFile(sourceFilePath)
      currentBufStatus.buffer = initBackupManagerBuffer(
        status.baseBackupDir,
        sourceFilePath).toGapBuffer
    elif key == ord('r'):
      # Reload backup files
      currentBufStatus.buffer = initBackupManagerBuffer(
        status.baseBackupDir,
        sourceFilePath).toGapBuffer
    elif key == ord('G'):
      currentBufStatus.moveToLastLine(currentMainWindowNode)
  elif command.len == 2:
    if command[0] == ord('g'):
      if command[1] == ord('g'):
        currentBufStatus.moveToFirstLine(currentMainWindowNode)
