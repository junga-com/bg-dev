
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
# This section contains functions that implement an interactive debugger.

function atomDebugger_debuggerOn()
{
	local terminalID="${1}"; shift

	# codeEnvironment identifies which atom instances are comapatible with which terminals. When atom has a sandbox folder open
	# it is compatible with terminal in which that sandbox folder is vinstalled
	local codeEnvironment="${bgVinstalledSandbox##*/}"; codeEnvironment="${codeEnvironment:-unk}"

	local potentialPipes
	fsExpandFiles -A potentialPipes /tmp/bgAtomDebugger-$USER/${terminalID:-$codeEnvironment}*toAtom
bgtraceVars potentialPipes

	if [ ${#potentialPipes[@]} -gt 1 ]; then
		# we need a UI to ask the user to choose one.
		assertError -v potentialPipes -v terminalIDFrom_bg_debugCntr:terminalID "there are multiple potential atom instances to connect to. Use 'bg-debugCntr debugger destination atom:<atomInstance>' to choose one"
	fi
	[ ${#potentialPipes[@]} -eq 0 ] && assertError -v codeEnvironment -v potentialPipes -v terminalIDFrom_bg_debugCntr:terminalID "no matching atom instances were found to connect to. Install the bg-bash-debugger atom plugin and open atom on the sandbox folder"

	# lets open the pipe to atom
	declare -g bgPipeToAtom="${potentialPipes[0]}"
	[ ! -p "$bgPipeToAtom" ] && assertError -v bgPipeToAtom "bgPipeToAtom is not a pipe"
	declare -gi bgPipeToAtomFD
	exec {bgPipeToAtomFD}>"$bgPipeToAtom" || assertError -v bgPipeToAtom "could not open pipe for writing"
bgtraceVars -1 bgPipeToAtom bgPipeToAtomFD

	# make the return pipe that we will listen to
	local parentTermPID; getTerminalPID parentTermPID
	declare -g bgPipeToBash="/tmp/bgAtomDebugger-$USER/${codeEnvironment}-$parentTermPID-toBash"
	[ ! -p "$bgPipeToBash" ] && { mkfifo "$bgPipeToBash" || assertError -v bgPipeToBash "could not make pipe at bgPipeToBash. maybe you need to delete something that is already there?"; }
	declare -gi bgPipeToBashFD

	# announce ourselves
	echo "helloFrom ${codeEnvironment}-$parentTermPID" >&$bgPipeToAtomFD || assertError
bgtrace "sent helloFrom"
	exec {bgPipeToBashFD}<"$bgPipeToBash" || assertError -v bgPipeToBash "could not open pipe for reading"
bgtraceVars -1 bgPipeToBash bgPipeToBashFD
	local msg; read -u "$bgPipeToBashFD" msg || assertError
	[ "$msg" != "letsDoThisThing" ] && assertError -v msg "we were rejected by the atom instance. expected msg to be 'letsDoThisThing' "
bgtraceVars -1 bgPipeToBash bgPipeToBashFD

	bgtraceVars -l"succesfully connected to atom instance" bgPipeToAtom bgPipeToBash
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

	if [ "$bgPipeToAtomFD" ]; then
		echo "goodbye" >&$bgPipeToAtomFD || assertError
		exec {bgPipeToAtomFD}<&-         || assertError
		bgPipeToAtomFD=""
	fi
}

# usage: returnFromDebugger <actionCmd> [<p1>..<pN>]
# The code inside the debugger uses this to to return to the script process. The debugger is running in a subshell so exitting
# this process will resume the bg_debugger.sh stub code. Some commands will perform a function that needs to be done in the script
# PID and then reenters this debugger. Other commands will return execution to the script and optionally use the DEBUG trap to
# return to the debugger if a condidtion is met.
function returnFromDebugger()
{
bgtraceParams
	echo "$*" >&$bgdActionFD
	exit
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
#
# See Also:
#    bgtraceBreak : the user level function to enter the debugger that can be called from code or trap handlers other than DEBUG
function _debugDriverEnterDebugger()
{
	# restore the argv from the User function we are stopped in so that they can be examined
	set -- "${bgBASH_debugArgv[@]:1}"

	echo "enter ${bgBASH_SOURCE:---} ${bgBASH_debugTrapLINENO:---}" >&$bgPipeToAtomFD


	local lineFromAtom traceStep=()
	local dbgScriptState="running"
	while read lineFromAtom; do
		if [ "$dbgScriptState" != "ended" ] && pidIsDone $$; then
			dbgScriptState="ended"
		fi

		# parse the dbgCmd
bgtraceVars lineFromAtom
		local dbgCmd="${lineFromAtom%%[; ]*}"
		local dbgArgs=(${lineFromAtom#$dbgCmd})
bgtraceVars -1 dbgCmd dbgArgs

		# any case that returns, will cause the script to continue. If it calls _debugSetTrap first,
		# then the debugger will continue to montitor the script and if the break condition is met,
		# we will get back to this loop at a different place in the script. If the _debugSetTrap is not
		# called before the return, the script will run to conclusion.

		case $dbgScriptState:${dbgCmd:-emptyLine} in
			# stepOverPlumbing state needs to be persistent between steps so we send it back to the script PID to process
			*:stepOverPlumbing) echo "will now step over plumbing code like object _bgclassCall";  returnFromDebugger stepOverPlumbing   ;;
			*:stepIntoPlumbing) echo "will now step into plumbing code like object _bgclassCall";  returnFromDebugger stepIntoPlumbing   ;;

			# these, (unlike stepOverPlumbing) are not persistent between steps so we can just set them locally
			*:traceNextStep)    traceStep+=("--traceStep") ;;
			*:traceNextHit)     traceStep+=("--traceHit") ;;

			*:step*|*:skip*|*:resume|*:rerun|*:endScript)
				returnFromDebugger _debugSetTrap "${traceStep[@]}" "$dbgCmd" "${dbgArgs[@]}"
			;;

			*:quit*|*:exit)
				returnFromDebugger _debugSetTrap "${traceStep[@]}" endScript
			;;

			*:reload)
				returnFromDebugger reload
			;;

			*:breakAtFunction)
				debugBreakAtFunction "$dbgCmd" "${dbgArgs[@]}"
			;;

			*)	[ "$bgDevModeUnsecureAllowed" ] || return 35
				local evalOutput="$(eval "$dbgCmd" "${dbgArgs[@]}")" ;;
		esac
	done <&"$bgPipeToBashFD"
	return true
}

# usage: _debugDriverScriptEnding
# The debugger stub in the script process calls this when it exits so that the debugger UI
function _debugDriverScriptEnding()
{
	echo "scriptEnded" >&$bgPipeToAtomFD
}
# usage: _debugDriverIsActive
# returns false after the user closes the debugger terminal
function _debugDriverIsActive()
{
return 0
	local msg
	echo "ping" >&$bgPipeToAtomFD && \
	read -u $bgPipeToBashFD msg || return 1
	[ "$msg" == "pong" ]
}
