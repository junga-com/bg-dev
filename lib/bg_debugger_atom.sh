
import bg_cui.sh ;$L1;$L2
import bg_ipc.sh ;$L1;$L2

# Library bg_debugger_atom.sh
# This library provides the debugger driver that connects to the bgDebugger Atom Plug.
#
# TODO: heres a list of things to make this an atom debugger...
#       create a new atom plugin called bg-atom-bash-debugger
#       atomPlugin: creates a unique pipe following a well known naming pattern <something>-<sandboxName_or_other_ID>-$$-toAtom
#       atomPlugin: listens to that pipe in a worker thread (or similar)
#       bg-debugCntr: BC for "bg-debugCntr debugger destination atom:<tab><tab>" lists existing pipes by <sandboxName_or_other_ID>
#       driver: when driver starts, check bgDebuggerDestination for pipe to connect to.
#       driver: if not specified, enumerate available pipes -- if more than one -> prompt user to select which
#       authentication/authorization: consider the user auth feature of named pipes
#       driver-atomplugin: create handshake protocol
#            driver IDs itself (unix pipe?) and creates a <something>-<sciptname>-$$-toBash pipe
#       bg-debugCntr: read loop accepts enterBreak msg and updates sourceFile(lineno) -- maintains break/running modes
#       bg-debugCntr: add cmds for
#           running mode:
#             breakRunningScript: when in running mode -- send a USR? signal to the $$ to ask script pid to enterBreak
#           break mode:
#             cmds for all the step* and other debugger cmds




##################################################################################################################
### debugger functions

function atomDebugger_debuggerOn()
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
		{_dbgDrv_DbgSessionOutFD}>"${_dbgDrv_DbgSessionName}-fromScript" \
		{_dbgDrv_DbgSessionInFD}<"${_dbgDrv_DbgSessionName}-toScript"

	# now that both ends of the pipes are complete, we can remove the pipes from the file system
	rm \
		"${_dbgDrv_DbgSessionName}-fromScript" \
		"${_dbgDrv_DbgSessionName}-toScript"

	bgtrace "succesfully connected to atom instance at '$bgPipeToAtom'"
}


# usage: debugOff
# there is not much reason to turn off debugging. From _debugEnterDebugger, the operator can resume which does
# mostly the same thing.
# TODO: debugOff should be in bg_debugger.sh and call a callback like debuggerOn
function debugOff()
{
	# these should be in the driver nuetral debugOff()
	builtin trap - DEBUG
	shopt -u extdebug
	set +o functrace

	if [ "$bgPipeToAtom" ]; then
		atomWriteMsg "goodbyeFrom" "$$"
		exec {bgPipeToAtomFD}<&-         || assertError
		bgPipeToAtomFD=""
	fi
}

# usage: _debugDriverScriptEnding
# The debugger stub in the script process calls this when it exits so that the debugger UI
function _debugDriverScriptEnding()
{
	atomWriteMsg "scriptEnded" "$$"
}


# # usage: returnFromDebugger <actionCmd> [<p1>..<pN>]
# # The code inside the debugger uses this to to return to the script process. The debugger is running in a subshell so exitting
# # this process will resume the bg_debugger.sh stub code. Some commands will perform a function that needs to be done in the script
# # PID and then reenters this debugger. Other commands will return execution to the script and optionally use the DEBUG trap to
# # return to the debugger if a condidtion is met.
# function returnFromDebugger()
# {
# bgtraceParams
# 	echo "$*" >&$bgdActionFD
# 	exit
# }

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
#
# See Also:
#    bgtraceBreak : the user level function to enter the debugger that can be called from code or trap handlers other than DEBUG

# function _debugDriverEnterDebugger()
# {
# bgtraceParams
# 	# restore the argv from the User function we are stopped in so that they can be examined
# 	set -- "${bgBASH_debugArgv[@]:1}"
#
# 	# create the session pipes for this break
# 	# 1) make sure both session pipes exist
# 	declare -g bgDbgSessionPipe="/tmp/bgAtomDebugger-$USER/${codeEnvironment}-${bgPID}"
# 	[ ! -p "${bgDbgSessionPipe}-toBash" ] && { mkfifo "${bgDbgSessionPipe}-toBash" || assertError -v bgDbgSessionPipe "could not make pipe at {bgDbgSessionPipe}-toBash. maybe you need to delete something that is already there?"; }
# 	[ ! -p "${bgDbgSessionPipe}-toAtom" ] && { mkfifo "${bgDbgSessionPipe}-toAtom" || assertError -v bgDbgSessionPipe "could not make pipe at {bgDbgSessionPipe}-toAtom. maybe you need to delete something that is already there?"; }
# 	declare -gi _dbgDrv_brkSesPipeToScriptFD _dbgDrv_brkSesPipeFromScriptFD
#
# 	# announce this break session on the global toAtom pipe
# 	atomWriteMsg "enter" "$bgDbgSessionPipe" "$$" "$bgPID" "${bgBASH_SOURCE:---}" "${bgBASH_debugTrapLINENO:---}" "$bgBASH_COMMAND"
#
# 	# (old comment. now using '<' because we do want the read loop to end if the atom process goes away)
# 	# we open -toBash for read and write (e.g. the '<>') so that there will always be one writer completing the the pipe. We never
# 	# write to it. This has two effects. 1) the exec will not block until a writer opens the pipe. 2) the stream wont receive a EOF
# 	# each time a writer closes the pipe (it only does that when the last writer closes)
# 	#
# 	# 2) open our end -- -toBash for reading and -toAtom for writing
# 	# Note: this line will block until the atom front end 1) opens -toAtom for reading and 2) opens -toBash for writing
# 	bgtrace "dbg: waiting for atom front end to open the session pipes"
# 	exec {_dbgDrv_brkSesPipeToScriptFD}<"${bgDbgSessionPipe}-toBash" {_dbgDrv_brkSesPipeFromScriptFD}>"${bgDbgSessionPipe}-toAtom"
#
# 	# 3) now that we know the both sides have openned the session pipes, we can remove them
# 	rm -f "${bgDbgSessionPipe}-"*
#
# 	# 4) now we can send and receive messages
#
# 	# now we are connected to the break session, send the stack message.
# 	atomWriteMsgSession "stack $(bgStackToJSON)"
#
# 	local lineFromAtom traceStep=()
# 	local dbgScriptState="running"
# 	bgtrace "dbg: entering read loop"
# 	while read lineFromAtom; do
# 		bgtrace "dbg: received line '$lineFromAtom'"
#
# 		# detect if the main script has ended (we might be an orphaned child)
# 		if [ "$dbgScriptState" != "ended" ] && pidIsDone $$; then
# 			dbgScriptState="ended"
# 		fi
#
# 		# parse the dbgCmd
# 		local dbgCmd="${lineFromAtom%%[; ]*}"
# 		local dbgArgs=(${lineFromAtom#$dbgCmd})
#
# 		# any case that returns, will cause the script to continue. If it calls _debugSetTrap first,
# 		# then the debugger will continue to montitor the script and if the break condition is met,
# 		# we will get back to this loop at a different place in the script. If the _debugSetTrap is not
# 		# called before the return, the script will run to conclusion.
#
# 		case $dbgScriptState:${dbgCmd:-emptyLine} in
# 			# stepOverPlumbing state needs to be persistent between steps so we send it back to the script PID to process
# 			*:stepOverPlumbing) echo "will now step over plumbing code like object _bgclassCall";  returnFromDebugger stepOverPlumbing   ;;
# 			*:stepIntoPlumbing) echo "will now step into plumbing code like object _bgclassCall";  returnFromDebugger stepIntoPlumbing   ;;
#
# 			# these, (unlike stepOverPlumbing) are not persistent between steps so we can just set them locally
# 			*:traceNextStep)    traceStep+=("--traceStep") ;;
# 			*:traceNextHit)     traceStep+=("--traceHit") ;;
#
# 			*:step*|*:skip*|*:resume|*:rerun|*:endScript)
# 				returnFromDebugger _debugSetTrap "${traceStep[@]}" "$dbgCmd" "${dbgArgs[@]}"
# 			;;
#
# 			*:quit*|*:exit)
# 				returnFromDebugger _debugSetTrap "${traceStep[@]}" endScript
# 			;;
#
# 			*:reload)
# 				returnFromDebugger reload
# 			;;
#
# 			*:breakAtFunction)
# 				debugBreakAtFunction "$dbgCmd" "${dbgArgs[@]}"
# 			;;
#
# 			*:ping) ;;
#
# 			*)	[ "$bgDevModeUnsecureAllowed" ] || return 35
# 				local evalOutput="$(eval "$dbgCmd" "${dbgArgs[@]}")" ;;
# 		esac
# 	done <&"$_dbgDrv_brkSesPipeToScriptFD"
#
# 	# if we loose contact with the atom instance, resume the script
# 	bgtrace "dbg: resuming script because the atom front end unexpectedly closed the -toBash break session pipe"
# 	returnFromDebugger _debugSetTrap "${traceStep[@]}" "resume"
# 	return 0
# }
#
# function _debugDriverLeaveDebugger()
# {
# bgtraceParams
# bgtraceVars bgDbgSessionPipe
# 	if [ "$bgDbgSessionPipe" ]; then
# 		rm -f "${bgDbgSessionPipe}"* # redundant -- we should have already removed them
# 		unset bgDbgSessionPipe
#
# 		# send the 'leave' msg in the background and set a timer to kill it if its not done in 2 seconds.
# 		(atomWriteMsgSession "leave $bgDbgSessionPipe $bgPID")&
# 		local msgPID = $!
# 		(sleep 2; kill -0 $msgPID && kill -SIGINT $msgPID)&
#
# 		# wait for the send msg to be sent (or it times out)
# 		wait $msgPID
#
# 		# close out ends of the pipes
# 		exec {_dbgDrv_brkSesPipeToScriptFD}<&-; unset _dbgDrv_brkSesPipeToScriptFD
# 		exec {_dbgDrv_brkSesPipeFromScriptFD}>&-; unset _dbgDrv_brkSesPipeFromScriptFD
# 	fi
# }

# usage: _debugDriverIsActive
# returns false after the user closes the debugger terminal
function _debugDriverIsActive()
{
return 0
	local returnPipe="/tmp/bgAtomDebugger-$USER/${codeEnvironment}-$$-toBash.tmp"
	[ ! -p "${returnPipe}" ] && { mkfifo "${returnPipe}" || assertError -v returnPipe "could not make pipe at {returnPipe}. maybe you need to delete something that is already there?"; }
	atomWriteMsg "ping" "$returnPipe" "$$"
	local msg; read -r  msg <"${returnPipe}"  || assertError
	rm -f "${returnPipe}"
	[ "$msg" == "pong" ]
}

function atomWriteMsg()
{
bgtraceParams
	printf "%s\n\n" "$*" >&$_dbgDrv_DbgSessionOutFD || assertError
}

function atomWriteMsgSession()
{
bgtraceParams
	printf "%s\n\n" "$*" >&$_dbgDrv_brkSesPipeFromScriptFD || assertError
}



###################################################################################################################################
### new driver API

function _dbgDrv_enter()
{
bgtraceParams

	# make pipes for the debugger to communicate with the paused script
	declare -g _dbgDrv_brkSessionName; varGenVarname -t "/tmp/bgdbBrkSession-XXXXXXXXX" _dbgDrv_brkSessionName
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-toScript"
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-fromScript"

	# the enter msg will cause atom to open the 'toScript' for writing and the 'fromScript' for reading
	atomWriteMsg "enter" \
		"$_dbgDrv_brkSessionName" \
		"$$" \
		"$bgPID" \
		"${bgBASH_SOURCE:---}" \
		"${bgBASH_debugTrapLINENO:---}" \
		"$bgBASH_COMMAND"

	# this will block until Atom open its end for both pipes (it does not matter if we or atom opens each pipe first)
	# since we are 'the script', we open 'toScript' for reading and 'fromScript' for writing
	exec {_dbgDrv_brkSesPipeFromScriptFD}>"${_dbgDrv_brkSessionName}-fromScript" {_dbgDrv_brkSesPipeToScriptFD}<"${_dbgDrv_brkSessionName}-toScript"

	# now that both ends of the pipes are complete, we can remove the pipes from the file system
	rm \
		"${_dbgDrv_brkSessionName}-fromScript" \
		"${_dbgDrv_brkSessionName}-toScript"
}

function _dbgDrv_leave()
{
bgtraceParams
	if [ "$_dbgDrv_brkSessionName" ]; then
		atomWriteMsgSession "leave"

		exec \
			{_dbgDrv_brkSesPipeFromScriptFD}>&- \
			{_dbgDrv_brkSesPipeToScriptFD}<&-
	fi
}
