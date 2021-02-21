#!/bin/bash

import bg_strings.sh ;$L1;$L2
import bg_ipc.sh ;$L1;$L2

# Library bg_debugger.sh
# This library provides an interactive debugger for stepping through and examining the state of scripts
# that source /usr/lib/bg_core.sh.
#


##################################################################################################################
### debugger functions
# This section contains functions that implement an interactive debugger.


# usage: debuggerOnImpl <remoteDbgID>
# This is the debuggerOn implementation that is specific to the remote bash debugger stub that uses two FIFO pipes to communicate
# with a remote debugger UI. It is called by the generic debuggerOn function when the dbgID matches remote:<remoteDbgID>
# This function identifies the remote debugger instance that is to be connected and creates it if needed. If successful, the pipes
# to the remote debugger instance will be setup.
# Params:
#    <remoteDbgID> : this identifies the remote debugger instance
function remoteDebugger_debuggerOn()
{
	local remoteDbgID="$1"; shift

	#################################################################################################
	declare -gx  bgdbCntrFile=""

	case ${remoteDbgID:-win} in
		win|cuiWin)
			import bg_debuggerCUIWin.sh ;$L1;$L2
			local cuiWinID="${bgTermID:-$$}.debugNew"
			Try:
				cuiWinCntr --class Debugger --returnChannel $cuiWinID open >/dev/null
				cuiWinCntr -R bgdbCntrFile $cuiWinID getCntrFile
			Catch: && {
				assertError -c "could not connect to debugger instance at cuiWin '$cuiWinID'. Use bg-cuiWin status|clean"
			}
			;;
		*) assertError -v remoteDbgID "remoteDbgID not yet implemented or is unknown"
	esac
}

# usage: debugOff
# there is not much reason to turn off debugging. From _debugEnterDebugger, the operator can resume which does
# mostly the same thing.
function debugOff()
{
	builtin trap - DEBUG
	shopt -u extdebug
	set +o functrace
	#2020-10 i think this was a mistake. debugger does not use ERR trap and it interfers with unit tests # set +o errtrace
	bgdbCntrFile=""
}

# usage: _debugDriverEnterDebugger [<dbgContext>]
# This enters the main loop of an interactive debugger. It must only be called from a DEBUG trap because it assumes that environment.
# The DEBUG trap handler is typically set for the first time by debuggerOn or bgtraceBreak. That will cause this functino to be invoked.
# Each time this function returns, if it is not resuming excecution, it sets the DEBUG trap again so that this function will be called
# again when the condition specified in the DEBUG trap handler is met.
#
# Debugger Control Flow:
# The debugger loop accepts user inputs from a terminal or other place and whenever the user steps, skips, or resumes, it returns so
# that the script continues. The step*, skip*, and resume set of commands call _debugSetTrap to set a new DEBUG trap handler with a
# condition that causes _debugEnterDebugger to be called again at the specified point in the script. The resume command does not set
# the DEBUG trap handler so that the script will continue to completion unless some code has been modified to include a bgtraceBreak
# call.
#
# The return value of this function determines the DEBUG trap handler exit code which tells bash to execute the current BASH_COMMAND(0),
# dont execute the current BASH_COMMAND(1) or simulate a return from the current function without executing the the current BASH_COMMAND(2)
#
# Implementation:
# This implementation uses a MVC pattern to defer most of what it does to the currectly selected DebuggerView and DebuggerController.
# The View determines what information is shown to the user and the Controller determines what commands are valid at that point.
#
# There is no mechanism yet for selecting alternate View and/or Controller but it would be easy to add one to support different debugger
# UIs. For example, a Controller could be implemented that manages a communication channel to an IDE like atom or Visual Studio.
# The debuggerOn function would determine which Controller and/or Views are selected and this function would honor that selection.
#
# DebuggerViews:
# _debugEnterDebugger defers to a DebuggerView function to paint the screen and leave the scroll region and
# cursor position set correctly for the DebuggerController to operate within.
# A DebuggerView function implements an OO pattern so that everything is encapsulated in that function
# so that it can have implementation details that are persistent from one DebuggerView function call
# to the next but also not global so that other tty View functions that might use some of the same
# variable names can coexist (DebuggerWatch window, for example) without walking over each other.
# The active DebuggerView can be determined at runtime and changed at any time by storing the
# DebuggerView function name in a string var and re-constructing it when ever the string changes.
#
# DebuggerControllers:
# _debugEnterDebugger defers to a DebuggerController function to implement a comamnd prompt and a commands.
# The main debugger specific contract to these controllers is that they implement commands that determine
# when the loop ends to return control to the script and the state of the debug trap at that time which
# determines when the _debugEnterDebugger will be called again (i.e. at what script line it will be invoked).
# The controller may optionally interact with the view to change how the view represents the state
# of the script to the user . The controller can also change the DebuggerView function.
#
# See Also:
#    bgtraceBreak : the user level function to enter the debugger that can be called from code or trap handlers other than DEBUG
function _debugDriverEnterDebugger()
{
	# restore the argv from the User function we are stopped in so that they can be examined
	set -- "${bgBASH_debugArgv[@]:1}"

	# push the stack data to the remote
	debuggerMarshalVarsToDbg ${!bgStack*}

	# tell remote we are entering the break
	cuiWinExec --cntrPipe  "$bgdbCntrFile" enterBreak "$0"


	# read and process commands sent from the debugger
	local done="" cmd args result
	while [ ! "$done" ]; do
		read -r  -t 2 cmd args <"$bgdbCntrFile.ret"; result=$?; (( result > 128)) && result=129
		#bgtraceVars -1 -l"dbgStub: " cmd args result
		case $result in
			0) 	;;
			129) # timeout (if we give read the -t <n> option)
				bgtrace "stub: read timed out"
				continue
				;;
			*)	bgtrace "debugger: read from cuiWin return channel failed. $bgdbCntrFile.ret exit code '$result'"
				bgsleep 5
				continue
				;;
		esac

		case $cmd in
			debuggerEnding)
				bgtrace "dbg stub: debugger received the remote debugger ending message. resuming"
				trap -r -n debuggerOn '_debugEnterDebugger scriptEnding' EXIT
				_debugSetTrap resume; dbgResult=$?; done="1"
				;;
			step*|skip*|resume)
				_debugSetTrap $cmd  "${args[@]}"; dbgResult=$?; done="1" > "$bgdbCntrFile.ret" 2>&1
				;;

			breakAtFunction)
				debugBreakAtFunction "${args[@]}" > "$bgdbCntrFile.ret" 2>&1
				;;

			*)
				[ "$bgDevModeUnsecureAllowed" ] || return 35
				eval "$cmd" "${args[@]}" > "$bgdbCntrFile.ret" 2>&1
				;;
		esac

	done

	cuiWinExec --cntrPipe  "$bgdbCntrFile" leaveBreak
}


function _debugDriverScriptEnding()
{
	cuiWinExec --cntrPipe  "$bgdbCntrFile" scriptEnding
}

function debuggerMarshalVarsToDbg()
{
	while [ $# -gt 0 ]; do
		local varName="$1"; shift
		local varMarshalledData; varMarshal "$varName" varMarshalledData
		cuiWinExec --cntrPipe  "$bgdbCntrFile" marshalVar "$varMarshalledData"
	done
}
