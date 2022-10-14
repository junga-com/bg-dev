import bg_cui.sh ;$L1;$L2
import bg_ipc.sh ;$L1;$L2

#bglogOn atomDbg

# Library bg_debugger_atom.sh
# This library is a front end debugger driver that connects to the bg-bash-debugger Plugin running in an Atom instance.
#
# When an Atom editor instance is started in a folder that is a sandbox that is also vinstalled, the bg-bash-debugger Plugin
# will create a fifo pipe at /tmp/bgAtomDebugger-$USER/<sandboxFolder>-toAtom. This driver, when loaded in a script, will connect
# to that pipe to initiate a debugger session.
#
# Scripts that are ran in any terminal where that same sandbox folder is vinstalled can use that Atom instance as the debugger
# front end.
#
# bgDebuggerDestination:
# For this driver the bgDebuggerDestination environment variable is of the form 'atom:'. bgDebuggerDestination is typicall set by
# the command "bg-debugCntr debugger destination atom:"
#
# Code Flow:
# When the debugger stub calls _dbgDrv_debuggerOn, this driver will create a new 'DebuggedProcess session' with the atom plugin
# establishing a new pair of pipes for the session. That session will last until either  _dbgDrv_debuggerOff  or _dbgDrv_scriptEnding
# is called.
#
# When the debugger stub calls _dbgDrv_enter, this driver establishes a new 'breakSession' with the atom plugin with a new pair
# of pipes. This session lasts until the stub calls _dbgDrv_leave or _dbgDrv_scriptEnding. Note that multiple breakSessions can
# exist concurrently, for example, when running a pipelined command with more that one compoent implemented as a bash function.
#
# While a breakSession exists, the code in its subshell is paused, blocked on the _dbgDrv_getMessage API which this driver implements
# by reading msgs from the breakSession incomming pipe.
#

##################################################################################################################
### Debugger Driver API
#   The functions in this section are required by the bg_debugger.sh stub
#   They all begin with _dbgDrv_*

# usage: _dbgDrv_debuggerOn <terminalID>
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# Openning this driver will attempt to find a suitable Atom instance to use as a debugger front end by looking for pipes in the
# /tmp/bgAtomDebugger-$USER/ folder that are named with the value found in the $bgVinstalledSandbox env variable. The idea is that
# Atom editors announce (by creating a named pipe file) which sandbox (i.e. folders with scripts) for which it can access the source.
# Scripts in that sandbox folder tree can then find the pipe and connect to it.
#
# The <terminalID> passed to this function (which comes from the bgDebuggerDestination  <drvName>:<driverParameter>) is typically
# not used because the bgVinstalledSandbox environment is good source to know what project(s) the Atom editor needs to have open
# in order for it to access the sources for the script being executed.
#
# For the duration between _dbgDrv_debuggerOn and either _dbgDrv_debuggerOff or the script's termination, a new DebuggedProcess
# session with atom will be established with a pair of pipes for bidirectional comminication.
#
function _dbgDrv_debuggerOn()
{
	local terminalID="${1}"; shift

	# codeEnvironment identifies which atom instances are comapatible with which terminals. When atom has a sandbox folder open
	# it is compatible with terminal in which that sandbox folder is vinstalled
	declare -g codeEnvironment="${bgVinstalledSandbox##*/}"; codeEnvironment="${codeEnvironment:-unk}"

	local potentialPipes
	fsExpandFiles -A potentialPipes /tmp/bgAtomDebugger-$USER/${terminalID:-$codeEnvironment}-toAtom

	if [ ${#potentialPipes[@]} -gt 1 ]; then
		# we need a UI to ask the user to choose one.
		assertError -v potentialPipes -v terminalIDFrom_bg_debugCntr:terminalID "there are multiple potential atom instances to connect to. Use 'bg-debugCntr debugger destination atom:<atomInstance>' to choose one"
	fi
	[ ${#potentialPipes[@]} -eq 0 ] && assertError -v codeEnvironment -v potentialPipes -v terminalIDFrom_bg_debugCntr:terminalID "no matching atom instances were found to connect to. Install the bg-bash-debugger atom plugin and open atom on the sandbox folder"

	# lets open the pipe to atom
	declare -g bgPipeToAtom="${potentialPipes[0]}"
	[ ! -p "$bgPipeToAtom" ] && assertError -v bgPipeToAtom "bgPipeToAtom is not a pipe"

	# create a debugger session with the atom plugin

	# make pipes for the debugger to communicate with the paused script
	declare -g _dbgDrv_DbgSessionName; varGenVarname -t "/tmp/bgdbDbgSession-XXXXXXXXX" _dbgDrv_DbgSessionName
	mkfifo -m 600 "${_dbgDrv_DbgSessionName}-toScript"
	mkfifo -m 600 "${_dbgDrv_DbgSessionName}-fromScript"

	# the 'helloFrom' msg will cause atom to open the _dbgDrv_DbgSessionName toScript and fromScript

	printf "%s %s %s %s\n\n" \
		"helloFrom" \
		"$_dbgDrv_DbgSessionName" \
		"$$" \
		"${0##*/}" > "$bgPipeToAtom"

	# this will block until Atom open its end for both pipes (it does not matter if we or atom opens each pipe first)
	# since we are 'the script', we open 'toScript' for reading and 'fromScript' for writing
	declare -gi _dbgDrv_DbgSessionOutFD _dbgDrv_DbgSessionInFD
	exec \
		{_dbgDrv_DbgSessionInFD}<"${_dbgDrv_DbgSessionName}-toScript" \
		{_dbgDrv_DbgSessionOutFD}>"${_dbgDrv_DbgSessionName}-fromScript"

	# now that both ends of the pipes are complete, we can remove the pipes from the file system
	rm \
		"${_dbgDrv_DbgSessionName}-fromScript" \
		"${_dbgDrv_DbgSessionName}-toScript"

	# config the debugger stub to allow breaks in subshells to proceed concurrently
	_bgdb_config[asyncBreaks]="yes"

	# cread an asyn child to monitor the script
	(
		builtin trap - SIGUSR1
		while read -a cmdTokens; do
			case ${cmdTokens[0]} in
				exit)
					bglog atomDbg "exitting script on behalf of debugger"
					bgExit --complete
				;;
				break)
					kill -SIGUSR1 -$$
				;;
			esac
		done
	) <&$_dbgDrv_DbgSessionInFD >&$_dbgDrv_DbgSessionOutFD &
	_dbgDrv_monitorPID=$!

	bgtrace "succesfully connected to atom instance at '$bgPipeToAtom'"
}


# usage: _dbgDrv_debuggerOff
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# End the DebuggedProcess session with the atom instance
function _dbgDrv_debuggerOff()
{
	if [ "$bgPipeToAtom" ]; then
		kill "${_dbgDrv_monitorPID}" 2>/dev/null
		atomWriteMsg "goodbyeFrom" "$$"
		exec \
			{_dbgDrv_DbgSessionInFD}<&- \
			{_dbgDrv_DbgSessionOutFD}>&-
	fi
}

# usage: _dbgDrv_enter
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# _dbgDrv_enter establishes a new breakSession with atom which _dbgDrv_leave will end. The breakSession has its own pair of pipes
# for bidirectional communication.
#
# Inbetween calls to _dbgDrv_enter and _dbgDrv_leave, the bg_debugger.sh stub code loops blocking on calls to _dbgDrv_getMessage
function _dbgDrv_enter()
{
	# make pipes for the debugger to communicate with the paused script
	declare -g _dbgDrv_brkSessionName; varGenVarname -t "/tmp/bgdbBrkSession-XXXXXXXXX" _dbgDrv_brkSessionName
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-toScript"
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-fromScript"

	local absSource="${bgBASH_SOURCE}"
	[[ "$absSource" != /* ]] && absSource="${PWD}/${absSource}"

	# the enter msg will cause atom to open the 'toScript' for writing and the 'fromScript' for reading
	atomWriteMsg "enter" \
		"$_dbgDrv_brkSessionName" \
		"$$" \
		"$bgPID" \
		"${absSource:---}" \
		"${bgBASH_debugTrapLINENO:---}" \
		"$bgBASH_COMMAND"

	# this will block until Atom open its end for both pipes (it does not matter if we or atom opens each pipe first)
	# since we are 'the script', we open 'toScript' for reading and 'fromScript' for writing
	exec \
		{_dbgDrv_brkSesPipeToScriptFD}<"${_dbgDrv_brkSessionName}-toScript" \
		{_dbgDrv_brkSesPipeFromScriptFD}>"${_dbgDrv_brkSessionName}-fromScript"

	# now that both ends of the pipes are complete, we can remove the pipes from the file system
	rm \
		"${_dbgDrv_brkSessionName}-fromScript" \
		"${_dbgDrv_brkSessionName}-toScript"

	local pstreeTxt #="$(pstree -p $$)"
	bgGetPSTree "$$" "pstreeTxt"
	pstreeTxt="${pstreeTxt/bash($_dbgDrv_monitorPID)/dbgmonitor($_dbgDrv_monitorPID)}"
	atomWriteMsgSession "pstree $pstreeTxt"

	atomWriteMsgSession "stack $(bgStackToJSON)"

	local vars; varContextToJSON "$((${#FUNCNAME[@]}-3))" "vars"
	atomWriteMsgSession "vars ${vars}"

	bglog atomDbg "breakSession enter ($_dbgDrv_brkSessionName)"
}

# usage: _dbgDrv_leave
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# _dbgDrv_leave ends the breakSession and cleans up
function _dbgDrv_leave()
{
	if [ "$_dbgDrv_brkSessionName" ]; then
		atomWriteMsgSession "leave"

		exec \
			{_dbgDrv_brkSesPipeFromScriptFD}>&- \
			{_dbgDrv_brkSesPipeToScriptFD}<&-
	fi
	bglog atomDbg "breakSession leave ($_dbgDrv_brkSessionName)"
}

# usage: _dbgDrv_getMessage <cmdStrVar>
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# This function call will block until the user issues a command on the front end. The return code is true if a msg is being returned
# and false if there are no more messages because the brak session has ended.
#
# The 'integrated' driver uses a pipe to send msgs from the async debugger break session child process to the script so this
# implementation just does a blocking read on that pipe
# Params:
#    <cmdStrVar> : the name of a string variable in the caller's scope that will be filled in with a cmd issued by the front end
function _dbgDrv_getMessage()
{
	local scrap
	read -r -u "$_dbgDrv_brkSesPipeToScriptFD" "${1:-scrap}"
	local result=$?
	bglog atomDbg "breakSession ($_dbgDrv_brkSessionName) read($result) msg ${!1}"
	[ "$scrap" ] && echo "$scrap"
	[ $result -ne 0 ] && bgtrace "SCR: _dbgDrv_getMessage: pipe closed"
	return "$result"
}

# usage: _dbgDrv_scriptEnding
# The debugger stub in the script process calls this when it exits so that the debugger UI
function _dbgDrv_scriptEnding()
{
	atomWriteMsg "scriptEnded" "$$"
}

function _dbgDrv_sendMessage()
{
	atomWriteMsgSession "$@"
}


##################################################################################################################################
### Internal Driver Implementation


function atomWriteMsg()
{
	local msg="$*"
	local logMsg="${msg:0:40}..."
	bglog atomDbg "atomWriteMsg '${logMsg//$'\n'/\\n}...'"
	printf "%s\n\n" "$msg" >&$_dbgDrv_DbgSessionOutFD
} 2>/dev/null

# note that even though a script could have multiple breakSession active concurrently, each breakSession must be in a separate
# async subshell so this code never sees any of the others that might exist. That is why it is unambiguous for this code to refer
# to 'the' breakSession without considering if there are any others.
function atomWriteMsgSession()
{
	local msg="$*"
	local logMsg="${msg:0:40}..."
	bglog atomDbg "atomWriteMsgSession '${logMsg//$'\n'/\\n}...'"
	printf "%s\n\n" "$msg" >&$_dbgDrv_brkSesPipeFromScriptFD
} 2>/dev/null
