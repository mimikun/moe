#[###################### GNU General Public License 3.0 ######################]#
#                                                                              #
#  Copyright (C) 2017─2024 Shuhei Nogawa                                       #
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

import std/[options, json, logging, tables]

import pkg/results

import lsp/client

# Workaround for Nim 1.6.2
import lsp/completion as lspcompletion

import lsp/signaturehelp

import ui, editorstatus, windownode, movement, editor, bufferstatus, settings,
       unicodeext, independentutils, gapbuffer, completion, messages

proc exitInsertMode(status: var EditorStatus) =
  if currentBufStatus.isInsertMultiMode:
    currentBufStatus.selectedArea = none(SelectedArea)

  if currentMainWindowNode.currentColumn > 0:
    currentMainWindowNode.currentColumn.dec
    currentMainWindowNode.expandedColumn = currentMainWindowNode.currentColumn

  changeCursorType(status.settings.standard.normalModeCursor)

  status.changeMode(currentBufStatus.prevMode)

proc deleteBeforeCursorAndMoveToLeft(status: var EditorStatus) {.inline.} =
  if currentBufStatus.isInsertMultiMode:
    const NumOfDelete = 1
    currentBufStatus.deleteMultiplePositions(
      currentBufStatus.bufferPositionsForMultipleEdit(
        currentMainWindowNode.currentColumn),
      NumOfDelete)
    currentMainWindowNode.keyLeft
  else:
    currentBufStatus.keyBackspace(
      currentMainWindowNode,
      status.settings.standard.autoDeleteParen,
      status.settings.standard.tabStop)

proc deleteCurrentCursor(status: var EditorStatus) {.inline.} =
  template currentLineHigh: int =
    currentBufStatus.buffer[currentMainWindowNode.currentLine].high

  if currentBufStatus.isInsertMultiMode:
    const NumOfDelete = 1
    if currentMainWindowNode.currentColumn > currentLineHigh:
      # Delete before cursor and move to left.
      currentBufStatus.deleteMultiplePositions(
        currentBufStatus.bufferPositionsForMultipleEdit(
          currentMainWindowNode.currentColumn),
        NumOfDelete)
      currentMainWindowNode.keyLeft
    else:
      currentBufStatus.deleteCurrentMultiplePositions(
        currentBufStatus.bufferPositionsForMultipleEdit(
          currentMainWindowNode.currentColumn),
        NumOfDelete)
  else:
    currentBufStatus.deleteCharacter(
      currentMainWindowNode.currentLine,
      currentMainWindowNode.currentColumn,
      status.settings.standard.autoDeleteParen)

proc sendDidChangeNotify(status: var EditorStatus): Result[(), string] =
  currentBufStatus.version.inc

  let range = BufferRange(
    first: currentMainWindowNode.bufferPosition,
    last: currentMainWindowNode.bufferPosition)

  let err = lspClient.textDocumentDidChange(
    currentBufStatus.version,
    $currentBufStatus.path.absolutePath,
    currentBufStatus.buffer.toString,
    some(range))
  if err.isErr:
    return Result[(), string].err err.error

  return Result[(), string].ok ()

proc sendCompletionRequest(
  status: var EditorStatus,
  r: Rune): Result[(), string] =
    ## Send didChange and completion requests to the LSP server.

    block:
      let err = status.sendDidChangeNotify
      if err.isErr:
        return Result[(), string].err err.error

    block:
      let isIncompleteTrigger = status.completionWindow.isSome

      let err = lspClient.textDocumentCompletion(
        currentBufStatus.id,
        $currentBufStatus.path.absolutePath,
        currentMainWindowNode.bufferPosition,
        isIncompleteTrigger,
        $r)
      if err.isErr:
        return Result[(), string].err err.error

    return Result[(), string].ok ()

proc sendSignatureHelpRequest(
  status: var EditorStatus,
  r: Option[Rune] = none(Rune)): Result[(), string] =
    ## Send didChange and signatureHelp requests to the LSP server.

    block:
      let err = status.sendDidChangeNotify
      if err.isErr:
        return Result[(), string].err err.error

    block:
      let
        triggerChar =
          if r.isSome: some($r)
          else: none(string)
        triggerKind =
          if r.isSome: SignatureHelpTriggerKind.TriggerCharacter
          else: SignatureHelpTriggerKind.Invoked

      let err = lspClient.textDocumentSignatureHelp(
        currentBufStatus.id,
        $currentBufStatus.path.absolutePath,
        currentMainWindowNode.bufferPosition,
        triggerKind,
        triggerChar)
      if err.isErr:
        return Result[(), string].err err.error

    return Result[(), string ].ok ()

template isCompletionTrigger(c: LspClient, r: Rune): bool =
  if c.capabilities.isSome and c.capabilities.get.completion.isSome:
    isTriggerCharacter(c.capabilities.get.completion.get, $r) or
    isCompletionCharacter(r)
  else:
    isCompletionCharacter(r)

proc insertToBuffer(status: var EditorStatus, r: Rune) {.inline.} =
  if currentBufStatus.isInsertMultiMode:
    currentBufStatus.insertMultiplePositions(
      currentBufStatus.bufferPositionsForMultipleEdit(
        currentMainWindowNode.currentColumn),
        r)
    currentBufStatus.keyRight(currentMainWindowNode)
  else:
    insertCharacter(
      currentBufStatus,
      currentMainWindowNode,
      status.settings.standard.autoCloseParen,
      r)

  if status.lspClients.contains(currentBufStatus.langId):
    if lspClient.isCompletionTrigger(r):
      let err = status.sendCompletionRequest(r)
      if err.isErr: error err.error

proc showSignatureHelp(status: var EditorStatus) =
  if status.lspClients.contains(currentBufStatus.langId) and
     lspClient.capabilities.isSome and
     lspClient.capabilities.get.signatureHelp.isSome:
       let err = status.sendSignatureHelpRequest
       if err.isErr: status.commandLine.writeLspSignatureHelpError(err.error)

proc execInsertModeCommand*(status: var EditorStatus, command: Runes) =
  if command.len == 0:
    return

  let
    beforeBufferLen = currentBufStatus.buffer.len
    key = command[0]

  if isCtrlC(key) or isEscKey(key):
    status.exitInsertMode
  elif isCtrlU(key):
    currentBufStatus.deleteBeforeCursorToFirstNonBlank(
      currentMainWindowNode)
  elif isLeftKey(key):
    currentMainWindowNode.keyLeft
  elif isRightKey(key):
    currentBufStatus.keyRight(currentMainWindowNode)
  elif isUpKey(key):
    currentBufStatus.keyUp(currentMainWindowNode)
  elif isDownKey(key):
    currentBufStatus.keyDown(currentMainWindowNode)
  elif isPageUpKey(key):
    pageUp(status)
  elif isPageDownKey(key):
    pageDown(status)
  elif isHomeKey(key):
    currentMainWindowNode.moveToFirstOfLine
  elif isEndKey(key):
    currentBufStatus.moveToLastOfLine(currentMainWindowNode)
  elif isDeleteKey(key):
    status.deleteCurrentCursor
  elif isBackspaceKey(key) or isCtrlH(key):
    status.deleteBeforeCursorAndMoveToLeft
  elif isEnterKey(key):
    keyEnter(
      currentBufStatus,
      currentMainWindowNode,
      status.settings.standard.autoIndent,
      status.settings.standard.tabStop)
  elif isTabKey(key) or isCtrlI(key):
    insertTab(
      currentBufStatus,
      currentMainWindowNode,
      status.settings.standard.tabStop,
      status.settings.standard.autoCloseParen)
  elif isCtrlE(key):
    currentBufStatus.insertCharacterBelowCursor(
      currentMainWindowNode)
  elif isCtrlY(key):
    currentBufStatus.insertCharacterAboveCursor(
      currentMainWindowNode)
  elif isCtrlW(key):
    const loop = 1
    currentBufStatus.deleteWordBeforeCursor(
      currentMainWindowNode,
      status.registers,
      loop,
      status.settings)
  elif isCtrlU(key):
    currentBufStatus.deleteCharactersBeforeCursorInCurrentLine(
      currentMainWindowNode)
  elif isCtrlT(key):
    currentBufStatus.indentInCurrentLine(
      currentMainWindowNode,
      status.settings.view.tabStop)
  elif isCtrlD(key):
    currentBufStatus.unindentInCurrentLine(
      currentMainWindowNode,
      status.settings.view.tabStop)
  elif isCtrlR(key):
    status.showSignatureHelp
  else:
    status.insertToBuffer(key)

  if currentBufStatus.buffer.len != beforeBufferLen:
    status.shiftFoldingRanges(
      currentMainWindowNode.currentLine,
      currentBufStatus.buffer.len - beforeBufferLen)
