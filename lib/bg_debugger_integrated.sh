
import bg_cui.sh ;$L1;$L2
import bg_ipc.sh ;$L1;$L2

# bglogOn intDbg
# bglogOn intDbg.reader

# Library bg_debugger_integrated.sh
# This library provides an interactive debugger front end for stepping through and examining the state of scripts that source
# /usr/lib/bg_core.sh.
#
# This debugger front end driver implements a text mode UI from inside the script being debugged (i.e. there is no external front
# end process). During a break, it spawns a child process that maintains the UI and accepts user input. The UI is drawn on a TTY
# and can optionally preserve the existing content in the TTY by switching to the alt page for the duration of the break.
#
# bgDebuggerDestination:
# For this driver the bgDebuggerDestination environment variable is of the form 'integrated:<terminalID>'. bgDebuggerDestination
# is typicall set by the command "bg-debugCntr debugger destination integrated:<terminalID>"
# <terminalID> is one of ...
#    self         : display the UI on the alt page of the tty that the script is running on. This is the default when there is no
#                   DISPLAY env variable which is typicaly when ssh'ing into a remote server.
#    cuiWin       : open a new terminal window to use for the UI. The id of the cuiWin will be <bgTermID>.debug which remains constant
#                   between script runs in the same terminal. <bgTermID> is an env variable provided by bg-debugCntr. The cuiWin
#                   will remain open after the script ends so that it can be reused for any script debugged in that terminal.
#                   See man bg-core and man cuiWinCntr
#    bgtrace      : Only when bgtrace is configured to use a cuiWin itself, this can be used to make the debugger UI display in that
#                   same terminal window. It will display in the alt page so that the bgtrace output can be seen on the other page.
#    <pathToATTY> : you can give it any arbitrary TTY to use for the UI. For example, if you have a favorite tiled setup you can
#                   place a terminal window anywhere you want and use its tty (run tty in the terminal to find it). You need to ocupy
#                   the shell program in that terminal so that it does not fight to read commands. Something like "trap '' SIGINT; sleep 9999999"
#
# Script Process Tree:
# The script being debugged can spawn multiple children -- both explicitly using the & terminater and also implicitly for any pipeline
# command. Each child can be stopped in the debugger independantly. By default the bg_debugger.sh stub serializes the breaks so only
# one will use the debugger UI at a time. The effect is that when you step into a pipelined statement where two of the components
# are shell functions, for example, the first step will go into one of the piplined functions (picked psuedo randomly). When you continue
# to step, at some point (probably the next step) it will 'jump' over to the other function. This can be a little confusing at first.
# The two piplined child subshells are truely independant so you can 'resume' from one of them and then you can step through the remaining
# one without the distraction of switching back and forth.
#
# Each time a break session is entered, this driver will create a new async subshell that runs the breakSession UI. That process
# loops reading incoming commands from a pipe. Other API functions in this driver can send msgs to the breakSession process via that
# pipe. The breakSession process spawns an additional async sub shell that reads lines from the TTY and sends them to the breakSession
# process via the pipe. It does this because there seems to be no equivalent to 'select' that would allow the breakSession process
# to read from either the TTY or a pipe (to receive msgs from the other APIs in the driver).
#
# Alternate Approaches:
# Before refactoring in 2020-09 to better support the 'atom' debugger front end driver, this driver was simpler. The stub function
# _debugEnterDebugger() would loop calling _debugDriverEnterDebugger() in a synchronous subshell. _debugDriverEnterDebugger would
# return a command entered by the user by writing to its stdout which _debugEnterDebugger would capture in a string.
#
# I mistakenly thought that I had to update this driver to use pipes because _debugEnterDebugger was now reading a pipe instead of
# calling a function. Eventually, I added the _dbgDrv_getMessage() API which abstracts away how it gets the msg so that a driver
# could use a pipe but it could just implement the UI code and return the command in the passed in variable. So I could have left
# it the old way after all. If I were doing it over, I would run the breakSession process in a syncronous subshell from the
# _dbgDrv_getMessage() API function and not mess with the pipes.
#
# Because I made the breakSession process respond to msgs like 'leave' and 'scriptEnded' sent from the script bg_debugger.sh stub
# code, it could not simply block reading from the TTY. I think I was in the midset of the 'atom' driver where there are substantial
# messages to pass the scrip state to the front end for examination, but this driver is not really like that. Each break runs in a
# new subshell forked from the script's current state so it comes complete with all that data.
# It now seems that the _dbgDrv_leave and _dbgDrv_scriptEnding API functions dont need to send a real msg but instead could just
# kill the breakSession process.


##################################################################################################################
### Debugger Driver API
#   The functions in this section are required by the bg_debugger.sh stub
#   They all begin with _dbgDrv_*

# usage: _dbgDrv_debuggerOn <terminalID>
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# Openning this driver will identify the terminal device file that will be used for the debugger UI and creates it if needed.
# If successful, the bgdbtty variable will contain the tty device file and bgdbttyFD will be an open file descriptor that can be
# written to and read from.
#
# Note that all the _dbgDrv_* functions are executed in the script's process space so they can share the same global variable space.
#
# Params:
#    <terminalID> : See man(7) bg_debugger_integrated
function _dbgDrv_debuggerOn()
{
	local terminalID="$1"; shift

	declare -gx bgdbtty=""  bgdbttyFD="" bgdbCntrFile="" bgdbPageFlipFlag=""

	case ${terminalID:-win} in
		win|cuiWin)
			type -t cuiWinCntr>/dev/null || import bg_cuiWin.sh ;$L1;$L2
			local cuiWinID="${bgTermID:-$$}.debug"
			cuiWinCntr -R bgdbtty $cuiWinID open
			cuiWinCntr -R bgdbCntrFile $cuiWinID getCntrFile
		;;
		self)
			# 2022-08 bobg: changed this from $(tty) b/c from a unit test with stdio redirected, $(tty) returns "not a tty"
			bgdbtty="/dev/$(ps -ho tty --pid $$)"
		;;

		bgtrace)
			if [ "$_bgtraceFile" != "/dev/null" ] && [ -e "$_bgtraceFile.cntr" ]; then
				type -t cuiWinCntr>/dev/null || import bg_cuiWin.sh ;$L1;$L2
				cuiWinCntr -R bgdbtty "$_bgtraceFile.cntr" gettty
				cuiWinCntr -R bgdbCntrFile $cuiWinID getCntrFile
			else
				assertError -v bgTracingOn -v _bgtraceFile "
					could not enable debugging on bgtrace. Only a bgtrace destination that has a cntr pipe
					can be used for debugging. The cntr pipe is named \$_bgtraceFile.cntr
				"
			fi
		;;

		*)	if [ -e "$terminalID" ]; then
				bgdbtty="$terminalID"
			else
				assertError -v terminalID "terminalID not a known way to specify a tty to user for the UI. See man bg-debugCntr. Try 'self' or 'cuiWin'"
			fi
		;;
	esac

	[ "$bgdbtty" == "$(tty)" ] && bgdbPageFlipFlag="on"

	# if $bgdbPageFlipFlag is on (not empty), init _dbgDrv_showPageFlipMsg to non-empty so that it will be displayed
	declare -g _dbgDrv_showPageFlipMsg="$bgdbPageFlipFlag";


	# open file descriptors to the debug tty
	exec {bgdbttyFD}<>"$bgdbtty"

	[ -t $bgdbttyFD ] || assertError -v terminalID -v bgdbtty -v bgdbttyFD "The specified terminalID for a debugger session is not a terminal device"

	[ ! "$bgdbPageFlipFlag" ] && _initDedicatedTTY <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD
}


# usage: _dbgDrv_debuggerOff
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
function _dbgDrv_debuggerOff()
{
	bgdbtty=""
	[ "$bgdbttyFD" ] && exec {bgdbttyFD}<&-
	bgdbttyFD=""
	bgdbCntrFile="" # should we close the cuiWin if we openned it? No, its better to reuse so that the user can position it once
}

# usage: _dbgDrv_isConnected
# Return Code:
#    0(true)  : this driver is connected to this script (and BASHPID subshell)
#    1(false) : this driver is NOT connected
function _dbgDrv_isConnected()
{
	# is our terminal still there?
	[ ! "$bgdbtty" ] || [ ! -t "$bgdbttyFD" ] && return 1

	return 0;
}





# usage: _dbgDrv_enter
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
function _dbgDrv_enter()
{
	# ${_dbgDrv_brkSessionName}-<name> are the pipes we use to communicate with the _dbgDrv_brkSesPID child
	declare -g _dbgDrv_brkSessionName; varGenVarname -t "/tmp/bgdbBrkSession-XXXXXXXXX" _dbgDrv_brkSessionName
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-toScript"
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-fromScript"
	mkfifo -m 600 "${_dbgDrv_brkSessionName}-readerSync" # make the reader prompt write in sync with paints

	dbgPrompt="[${0##*/}] bgdb> "

	# launch the debugger UI in a separate thread so that we can return to the stub which will loop on reading msgs
	(
		bgSubShellInit --name="integratedDebugger";

		builtin trap - DEBUG # prior to bash 5.1, we need to explicitly reset the DEBUG trap in the background subshell

		local dbgPID="$BASHPID"
		bglog intDbg "($dbgPID) breakSession is starting"

		trap '
			bglog intDbg "($BASHPID) breakSession ending."
			intDrv_asyncCmdReader off
		' EXIT

		# open the pipes. this will block until the script process opens the other end
		exec <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD

		# open the debugger side of the debugger->script pipe
		exec {_dbgDrv_brkSesPipeToScriptFD}>"${_dbgDrv_brkSessionName}-toScript"

		_enterTTYAltPage

		# this should change now that we are in a proper subshell for the life of the break
		local $(debugBreakPaint --declareVars);
		debugBreakPaint --init

		[ "$_dbgDrv_showPageFlipMsg" ] && echo "$(dedent "
			WARNING: you are running the 'self' mode debugger which flips between the debugger and script output using the terminal's
			alt page feature. There is a bug that suspends the debugger into the background sometimes. (i.e. when there is a coproc
			like while read...;done < <(gawk...)
			IF that happens enter 'fg' at the bash prompt to return to the debugger.
			Use alt-z to switch between debugger and script output.
		")"

		DebuggerController "$dbgPrompt"

		_leaveTTYAltPage
	) &
	declare -gi _dbgDrv_brkSesPID=$!

	trap -n intDbg "kill $_dbgDrv_brkSesPID 2>/dev/null" EXIT

	# complete the pipe to the coproc by opnenning them. (this is the script side)
	exec {_dbgDrv_brkSesPipeToScriptFD}<"${_dbgDrv_brkSessionName}-toScript"

	# we only want to display the msg once (at most). The next break wont show it
	_dbgDrv_showPageFlipMsg=""
}

# usage: _dbgDrv_leave
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
function _dbgDrv_leave()
{
	if [ "$_dbgDrv_brkSesPID" ]; then
		trap -n intDbg -r EXIT

		printf "leave\n" >"${_dbgDrv_brkSessionName}-fromScript"
		wait "$_dbgDrv_brkSesPID"

		unset _dbgDrv_brkSesPID
		exec {_dbgDrv_brkSesPipeToScriptFD}<&-
		unset _dbgDrv_brkSesPipeToScriptFD

		rm -f "${_dbgDrv_brkSessionName}-"*
	else
		bglog intDbg "(WARN) NOT sending leave msg"
	fi
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
	[ "$scrap" ] && echo "$scrap"
	[ $result -ne 0 ] && bglog intDbg "_dbgDrv_getMessage: pipe closed"
	return "$result"
}

# usage: _dbgDrv_scriptEnding
# This function is part of the required API that a debugger driver must implement. It is only called by the debugger stub from within
# a script being debugged.
#
# The debugger stub in the script process calls this when it exits so that the debugger UI
function _dbgDrv_scriptEnding()
{
	_enterTTYAltPage
	debugBreakPaint --scriptEnding  <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD
	_leaveTTYAltPage
}


##################################################################################################################################
### Internal Driver Implementation


# this is used by keyboard shortcuts to invoke a debugger command.
# See Also:
#    intDbg_installKeyMap
function simulateCmdlineinput()
{
	printf "ui:%s\n" "$*" >"${_dbgDrv_brkSessionName}-fromScript"
}

# usage: intDrv_asyncCmdReader on|off
# This maintains a child process to read lines from the TTY stdin and then writes them to the ${_dbgDrv_brkSessionName}-fromScript
# pipe. We need this because the breakSession child process can not block on both reading lines from the TTY and also reading commands
# from the stub (e.g. the 'leave' message).
# An additional advantange of this structure is that the simulateCmdlineinput can simply write its commands to that pipe also.
# The child process this creates is a one-shot meaning that it will read and transfer one typed line and then exit. Additionally,
# when the breakSession child process recieves a msg to process, it will call this function 'off' so that even if the msg was sent
# from a different source (so this reader child is still waiting for TTY input) this read child will be killed. This is so that
# there is no pending read while the breakSession processes its msg. This is important for example, when the users flips pages in
# 'self' mode so that readline does not redrawn the prompt on the alternate screen (which is the script output).
function intDrv_asyncCmdReader()
{
	declare -g intDrv_readerPID
	if [ "${1:-on}" == "on" ] && { [ ! "$intDrv_readerPID" ] || pidIsDone "$intDrv_readerPID"; }; then
		(
			bgSubShellInit --name="integratedDbgCmdReader";

			trap 'bglog intDbg.reader "($BASHPID) reader coproc ended"' EXIT
			bglog intDbg.reader "($BASHPID) reader coproc started pipes='${_dbgDrv_brkSessionName}-*'"

			intDbg_installKeyMap
			history -r ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history
			if read -e -p "$dbgPrompt" cmd; then
				[[ "${cmd:- }" != " "* ]] && { history -s "$cmd"; history -a ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history; }
				printf "ui:%s\n" "$cmd" >"${_dbgDrv_brkSessionName}-fromScript"
			fi
		) <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD &
		intDrv_readerPID=$!

	elif [ "$1" == "off" ] && [ "$intDrv_readerPID" ]; then
		kill "$intDrv_readerPID" &>/dev/null;
		intDrv_readerPID=""
	fi
}

# usage: DebuggerController <prompt>
# This is a 'Controller' in the MVC terminology. It loops on reading cmd lines from the debugger tty (bgdbtty),
# processes the command and exits or continues to loop based on the cmd.
# It supports defining key board shorcuts as an alias for a command which are not included in the command
# history.
# It uses a compatible DebuggerView function to paint the tty and leave the cursor in a scroll region that
# it can write cmd output to.
# It is anticipated that other DebuggerController functions will be written that implement alternate modes
# of operation and that all compatible DebuggerController functions will support navigation modes to switch
# between the controllers. -- for example a help screen or a watch focused mode or a code focused mode.
function DebuggerController()
{
	local dbgPrompt="$1"; shift

	# restore the argv from the User function we are stopped in so that they can be examined
	set -- "${bgBASH_debugArgv[@]:1}"

	debugWatchWindow softRefresh ${bgBASH_debugTrapFuncVarList[*]}

	trap 'dbgCmd="leave"; bgtrace "dbg: writing to script debugger stub returned an error"' SIGPIPE

	local dbgResult dbgDone traceStep=()
	while [ ! "$dbgDone" ] && [ ${dbgResult:-0} -eq 0 ]; do
		Try:
			stty echo; cuiShowCursor
			intDrv_asyncCmdReader on

			# commands entered by the user from the reader child proc will be prefixed with 'ui:'.
			# commands sent from the debugged process will not be prefixed
			local dbgCmdlineValue
			read -r dbgCmdlineValue <"${_dbgDrv_brkSessionName}-fromScript"

			stty -echo; cuiHideCursor
			intDrv_asyncCmdReader off

			# parse the dbgCmd
			local dbgCmd=""; stringConsumeNextBashToken dbgCmdlineValue dbgCmd
			local dbgArgs=();stringSplitIntoBashTokens dbgArgs "$dbgCmdlineValue"

			bglog intDbg "received msg(2) cmd='$dbgCmd'  args='${dbgArgs[*]}'"

			# any case that returns, will cause the script to continue. If it calls _debugSetTrap first,
			# then the debugger will continue to montitor the script and if the break condition is met,
			# we will get back to this loop at a different place in the script. If the _debugSetTrap is not
			# called before the return, the script will run to conclusion.

			case ${dbgCmd:-emptyLine} in
				leave)
					debugBreakPaint --leavingDebugger
					dbgDone="leave"
					;;
				scriptEnding)
					debugBreakPaint --scriptEnding
					dbgDone="scriptEnding"
					;;


				ui:close)                cuiWinCntr "$bgdbCntrFile" close; return 0 ;;
				ui:stackViewSelectFrame) debugBreakPaint --stackViewSelectFrame "${dbgArgs[@]}" ;;
				ui:scrollCodeView)       debugBreakPaint --scrollCodeView       "${dbgArgs[@]}" ;;
				ui:watch)                debugWatchWindow "${dbgArgs[@]}"  ;;
				ui:stack)                debugStackWindow "${dbgArgs[@]}"  ;;

				ui:stepOverPlumbing)
					echo "will now step over plumbing code like object _bgclassCall";
					echo "stepOverPlumbing" >&$_dbgDrv_brkSesPipeToScriptFD
				;;
				ui:stepIntoPlumbing)
					echo "will now step into plumbing code like object _bgclassCall";
					echo "stepIntoPlumbing" >&$_dbgDrv_brkSesPipeToScriptFD
				;;

				ui:traceNextStep)    traceStep+=("--traceStep") ;;
				ui:traceNextHit)     traceStep+=("--traceHit") ;;

				ui:step*|ui:skip*|ui:resume|ui:rerun|ui:endScript)
					echo "${traceStep[@]}" "${dbgCmd#ui:}" "${dbgArgs[@]}" >&$_dbgDrv_brkSesPipeToScriptFD
				;;

				ui:quit*|ui:exit)
					echo "${traceStep[@]}" endScript >&$_dbgDrv_brkSesPipeToScriptFD
				;;

				ui:reload)
					echo "reload" >&$_dbgDrv_brkSesPipeToScriptFD
				;;

				ui:toggleAltScreen)      _toggleTTYAltPage ;;

				ui:toggleStackArgs)      debugBreakPaint --toggleStackArgs      "${dbgArgs[@]}" ;;
				ui:toggleStackDebug)     debugBreakPaint --toggleStackDebug     "${dbgArgs[@]}" ;;

				ui:breakAtFunction)
					debugBreakAtFunction "${dbgArgs[@]}"
				;;

				ui:help)
					printf "%s\n" "breakAtFunction toggleStackDebug toggleStackArgs reload exit step skip resume rerun endScript stepOverPlumbing stepIntoPlumbing traceNextStep traceNextHit close stackViewSelectFrame scrollCodeView watch stack"
				;;

				ui:eval)
					echo "eval ${dbgArgs[*]}" >&$_dbgDrv_brkSesPipeToScriptFD
				;;

				ui:|emptyLine)
					debugBreakPaint
				;;

				*)
					bgtrace "dbg: unknown cmd '$dbgCmd'"
					# [ "$bgDevModeUnsecureAllowed" ] || return 35
					# eval "$dbgCmd" "$dbgCmdlineValue" ;;
			esac
		Catch: && {
			PrintException
		}
	done
	bglog intDbg "controller ending dbgDone='$dbgDone'"
}


# usage: debugBreakPaint
# usage: debugBreakPaint --declareVars
# usage: debugBreakPaint --init
# usage: debugBreakPaint --scrollCodeView <scrollOffset>
# usage: debugBreakPaint --stackViewSelectFrame <offset>
# usage: debugBreakPaint --toggleStackArgs|--toggleStackCode
# usage: debugBreakPaint --toggleStackDebug
# Paint a tty window with the context where the script is stopped in the debugger.
# This function implements an OO pattern where the first argument can be the method name --<method>
# The method is statefull. The calling scope should first use --declareVars to define its state and then --init
# The default method is --paint. The 'interface' that it implements is a 'View' that paints a tty screen.
# More specifically, it is a 'DebuggerView' because it implements a contract of what state vars and methods
# it provides so that the debuggerBreak/DebuggerController function can reference/invoke them
# This makes it so that everything specific to this alogorithm is contained in this one function so that
# an alternate DebuggerView can be implemented and the debuggerBreak can dynamically choose and switch
# between them.
# View Layout:
# This DebuggerView splits the tty window into four vertical regions.
#     region 1: Call Stack : the stack frame being shown in the code view is highlighted
#     region 2: Code View : the line of code that is about to be executed is highlighted.
#     region 3: cmd area  : this region acts as a sub terminal. It leaves the tty's scroll region set
#          to this region with the cursor on its last line. The assumption is that the cmd prompt will
#          be performed at that cursor location and will perform line any cmd prompt with the output
#          of cmds (if any) written and scrolled within this region with no further help from this view.
#     region 4: cmd help line. Shows the most common keyboard shortcuts
function debugBreakPaint()
{
	local method; [ "${1:0:2}" == "--" ] && { method="$1"; shift; }

	case $method in
		--declareVars)
			# these are the varnames of our 'member vars' that will be declared at the caller's scope
			# so that they will be persistent each time that scope calls this function
			echo "
				stackViewCurFrame stackViewLastFrame stackShowCallerFlag stackDebugFlag
				bgSTKDBG_codeViewWinStart bgSTKDBG_codeViewCursor
			"
			return
			;;
		--init)
			# construction. init the member vars
			stackViewCurFrame=0
			stackViewLastFrame=-1
			stackShowCallerFlag="--showCaller"
			stackDebugFlag=""
			bgSTKDBG_codeViewWinStart=()
			bgSTKDBG_codeViewCursor=()
			;;

		# --paint does nothing and drops through. Other method cases can drop through or return to skip painting
		--paint) ;;

		--leavingDebugger)
			debuggerStatusWin scriptRunning
			cuiHideCursor
			return
			;;

		--scriptEnding)
			debuggerStatusWin scriptEnding
			cuiHideCursor
			return
			;;

		# scroll the code view section up(-n) or down(+n)
		# note that we don't have to to clip is to start/end bounds of the file because the codeView
		# will clip it and update this value so that each cycle it will start in bounds.
		# default value. view will center the focused line
		--scrollCodeView)
			if [ "$1" ]; then
				((bgSTKDBG_codeViewCursor[${stackViewCurFrame:-empty}]+=${1:- 1}))
			else
				bgSTKDBG_codeViewCursor[${stackViewCurFrame:-empty}]=""
			fi
			shift
			;;

		# change the selected stack frame up(-1) or down(+1)
		--stackViewSelectFrame)
			case ${1:-0} in
				[+-]*) (( stackViewCurFrame+=${1:- 1} )) ;;
				*)     stackViewCurFrame="$1" ;;
			esac; shift
			# clip stackViewCurFrame to range[0,${#bgSTK_cmdName[@]}]
			(( stackViewCurFrame = (stackViewCurFrame >= ${#bgSTK_cmdName[@]}) ? (${#bgSTK_cmdName[@]}-1) : ( (stackViewCurFrame<=0) ? 0 : stackViewCurFrame  ) ))
			;;

		--toggleStackArgs|--toggleStackCode)
			stackShowCallerFlag="$(  varToggle "$stackShowCallerFlag"    "" "--showCaller")"
			;;
		--toggleStackDebug) stackDebugFlag="$(varToggle "$stackDebugFlag"  "" "--debugInfo")" ;;

	esac

	printf "${csiLineWrapOff}"

	# every time we are called, we want to notice if the terminal dimensions have changed because there
	# is not (always) a reliable event for terminal resizing in all supported bash versions (see SIGWINCH
	# and checkwinsize in man bash)
	local maxLines maxCols; cuiGetScreenDimension maxLines maxCols

	### make the layout.
	# <----stkWin-------->
	# <-srcWin |  varWin->
	# <----cmdWin-------->
	# <----statWin------->

	# Define cmdAreaSize first b/c cmdWin and srcWin are both dependent on it
	local cmdAreaSize=$((maxLines/4)); ((cmdAreaSize<2)) && cmdAreaSize=2
	#local cmdAreaSize=$((maxLines*3/4)); ((cmdAreaSize<2)) && cmdAreaSize=2

	local stkX1=1            stkY1=1                         stkX2="$((maxCols))"        stkY2=$(( (maxLines*7/20<(${#bgSTK_cmdName[@]}+2)) ? maxLines*7/20 : (${#bgSTK_cmdName[@]}+2) ))
	local statX1=1           statY1=$((maxLines))            statX2="$((maxCols))"       statY2="$((maxLines))"
	local cmdX1=1            cmdY1=$((statY2-1-cmdAreaSize)) cmdX2="$((maxCols))"        cmdY2="$((statY2-1))"
	local srcX1=1            srcY1=$((stkY2 +1))             srcX2="$(( maxCols *2/3 ))" srcY2="$((cmdY1-1))"
	local varX1=$((srcX2+1)) varY1=$((srcY1))                varX2="$((maxCols))"        varY2="$((srcY2))"

	dbgPgSize=$((srcY2-srcY1-1))

	cuiHideCursor

	### Call Stack Section
	(( stackViewCurFrame = (stackViewCurFrame >= ${#bgSTK_cmdName[@]}) ? (${#bgSTK_cmdName[@]}-1) : ( (stackViewCurFrame<=0) ? 0 : stackViewCurFrame  ) ))
	debuggerPaintStack $stackDebugFlag $stackShowCallerFlag -- "$stackViewCurFrame" "$stkX1" "$stkY1" "$stkX2" "$stkY2"


	### Code View Section
	debuggerPaintCodeView \
		"${bgSTK_cmdFile[$stackViewCurFrame]}" \
		bgSTKDBG_codeViewWinStart[$stackViewCurFrame] \
		bgSTKDBG_codeViewCursor[$stackViewCurFrame] \
		"${bgSTK_cmdLineNo[$stackViewCurFrame]}" \
		"$srcX1" "$srcY1" "$srcX2" "$srcY2" \
		"${bgSTK_caller[$stackViewCurFrame]}" \
		"${bgSTK_cmdLine[$stackViewCurFrame]}"

	### Variable View Section
	declare -gA varsWin
	local focusedFunction="${bgSTK_caller[$stackViewCurFrame]}"
	[ "$focusedFunction" ] && [ "$focusedFunction" != "main" ] && extractVariableRefsFromSrc --func="${focusedFunction%[(]*}" --exists "$(type ${focusedFunction%[(]*} 2>/dev/null)"  bgBASH_debugTrapFuncVarList
	debuggerPaintVarsWin "varsWin" "${bgBASH_debugTrapFuncVarList[*]}" "$varX1" "$varY1" "varX2" "$varY2"

	### Status Area Section
	debuggerStatusWin

	### Cmd Area Section
	declare -gA cmdWin; winCreate cmdWin "$cmdX1" "$cmdY1" "$cmdX2" "$cmdY2"
	cmdWin[xMax]=maxCols
	# set the scroll region to cmdWin and set the cursor to the last line of the scroll region so that the prompt will be performed there
	winScrollOn cmdWin
	cuiMoveTo "${cmdWin[y2]}" 1
	cuiShowCursor
}

function debuggerStatusWin()
{
	local maxLines maxCols; cuiGetScreenDimension maxLines maxCols
	declare -gA statWin; winCreate statWin "1" "$maxLines" "$maxCols" "$maxLines"
	case $1 in
		scriptRunning)
			winWriteAt statWin 1 1 "${csiBlack}${csiBkYellow}  script running ...${csiNorm}"
		;;
		scriptEnding)
			winWriteAt statWin 1 1 "${csiBlack}${csiBkYellow}  script ended. press cntr-c to close this terminal or restart a script to debug in the other terminal${csiNorm}"
		;;
		*)	# write the key binding help line
			winClear statWin
			local keybindingData="${csiBlack}${csiBkCyan}"
			local shftKeyColor="${csiBlack}${csiBkGreen}"
			winWriteAt statWin 1 1 "${csiClrToEOL}${keybindingData}F5-stepIn${csiNorm} ${keybindingData}F6-stepOver${shftKeyColor}+shft=skip${csiNorm} ${keybindingData}F7-stepOut${shftKeyColor}+shft=skip${csiNorm} ${keybindingData}F8-stepToCursor${csiNorm} ${keybindingData}F9-resume${shftKeyColor}+shft=re-run${csiNorm} ${keybindingData}cntr+nav=stack${csiNorm} ${keybindingData}alt+nav=code${csiNorm} ${keybindingData}watch add ...${csiNorm}"
		;;
	esac
	winPaint statWin
}


# usage: debuggerPaintVarsWin <varsWin> <varList> <winX1> <winY1> <winX2> <winY2>
function debuggerPaintVarsWin()
{
	local -n _win="$1"; shift
	local varList=($1); shift
	winCreate _win "$1" "$2" "$3" "$4"
	winClear _win
	winWrite _win "${csiBlack}${csiHiBkCyan}"

[ "$DBSIMERR" ] && assertError DBSIMERR
	local varname; for varname in "${varList[@]}"; do
		if varExists "$varname"; then
			local varvalue; csiStrip -R varvalue -- "${!varname}"
			winWriteLine _win "%s='%s'" "$varname" "$varvalue"
		fi
	done
	winPaint _win
}


# usage: dbgPrintfVars
function dbgPrintfVars()
{
	local _pvRetVar="$1"; shift
	local  _pvTmp
	printf -v "$_pvRetVar" "%s" ""
	while [ $# -gt 0 ]; do
		local _pvTerm="$1"; shift
		local _pvLabel="$_pvTerm"

		# we copy L1 and L2 on entering debugger because the debugger has import statements that use L1 and L2
		[ "$_pvTerm" == "L1" ] && _pvTerm="_L1"
		[ "$_pvTerm" == "L2" ] && _pvTerm="_L2"

		# treat foo[@] and foo[*] same as foo (show size of array)
		_pvTerm="${_pvTerm%\[@\]}"
		_pvTerm="${_pvTerm%\[\*\]}"


		case $_pvTerm in
			+*) continue ;;
			-*) continue ;;
		esac

		local _pvType; varGetAttributes "${_pvTerm}" _pvType

		case ${_pvTerm:-__EMPTY__}:${_pvType:-__EMPTY__} in
			# function/program args $1,$2,...${10}...
			[0-9]:*)        printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvTerm}" "${bgBASH_debugArgv[$_pvTerm]}" ;;
			{[0-9][0-9]}:*) printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvTerm}" "${bgBASH_debugArgv[$_pvTerm]}" ;;

			# undeclared var
			*:__EMPTY__)    printf -v "$_pvRetVar" "%s %s=<ND>" "${!_pvRetVar}" "${_pvLabel}" ;;

			# an array
			*:[aA])         arraySize "${_pvTerm}" _pvTmp
			                printf -v "$_pvRetVar" "%s %s=array(%s)" "${!_pvRetVar}" "${_pvLabel}" "$_pvTmp"
			                ;;

			# default -> dereference
			*)              printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvLabel}" "${!_pvTerm}" ;;
		esac
#		if [[ "$_pvTerm" =~ ^[0-9]$ ]]; then
#			printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvTerm}" "${bgBASH_debugArgv[$_pvTerm]}"
#		elif [ ! "$_pvType" ]; then
#			printf -v "$_pvRetVar" "%s %s=<ND>" "${!_pvRetVar}" "${_pvLabel}"
#		elif [[ "$_pvType" =~ [aA] ]]; then
#			arraySize "${_pvTerm}" _pvTmp
#			printf -v "$_pvRetVar" "%s %s=array(%s)" "${!_pvRetVar}" "${_pvLabel}" "$_pvTmp"
#		else
#			printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvLabel}" "${!_pvTerm}"
#		fi

	done
}


# usage: debuggerPaintStack [<options>] <highlightedFrameNo> <winX1> <winY1> <winX2> <winY2>
# Paint the current logical stack to stdout which is assumed to be a tty used in the context of debugging
# Params:
#     <highlightedFrameNo>  : if specified, the line corresponding to this stack frame number will be highlighted
# Options:
#    --debugInfo : append the raw stack data at the end of each frame
#    --showCaller  : show the caller column in the stack trace
function debuggerPaintStack()
{
	local debugInfoFlag showCallerFlag
	while [ $# -gt 0 ]; do case $1 in
		--debugInfo) debugInfoFlag="--debugInfo" ;;
		--showCaller) showCallerFlag="on" ;;
		--)           shift; break ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local highlightedFrameNo="${1:-0}"; shift
	local winX1="${1:-1}";   shift
	local winY1="${1:-1}";   shift
	local winX2="${1:-100}"; shift
	local winY2="${1:-20}";  shift

	declare -A stkWin
	winCreate stkWin "$winX1" "$winY1" "$winX2" "$winY2"

	winWriteAt stkWin "1" "1" "${csiBkBlue}"

	# --     dbgStackSize(8)
	# 7 frmTop
	# 6
	# 5            ^         | <- framesEnd(5)   <-highlightedFrameNo(5)
	# 4            |         |
	# 3   framesToDisplay(4)-|
	# 2            .         | <- framesStart(2)
	# 1
	# 0 frmBottom

	local dbgStackSize="${#bgSTK_cmdName[@]}"
	(( highlightedFrameNo= (highlightedFrameNo<dbgStackSize) ? (highlightedFrameNo) : (dbgStackSize-1) ))
	local framesToDisplay=$(( (dbgStackSize+2 <= stkWin[height])?dbgStackSize:(stkWin[height]-2) ))
	local framesEnd=$((  (highlightedFrameNo >= framesToDisplay) ? (highlightedFrameNo) : (framesToDisplay-1) ))
	local framesStart=$(( (framesEnd+1)-framesToDisplay ))

	local infiniteEquals; strFill -R infiniteEquals 500 '='
	local infiniteDashes; strFill -R infiniteDashes 500 '-'

	winWrite stkWin "${csiNorm}"
	if (( framesEnd < dbgStackSize-1 )); then
		winWriteLine stkWin "----- ^  $((dbgStackSize-framesEnd-1)) frames above (caller column: ${showCallerFlag:-off}) ${csiBlack}${csiBkCyan}<cntr-left/right>${csiNorm}  ^ $infiniteDashes"
	else
		winWriteLine stkWin "=====  Call Stack (caller column: ${showCallerFlag:-off}) ${csiBlack}${csiBkCyan}<cntr-left/right>${csiNorm}  $infiniteEquals"
	fi

	local w1=0 w2=0 frameNo
	for ((frameNo=framesEnd; frameNo>=framesStart; frameNo--)); do
		((w1= (w1>${#bgSTK_cmdLoc[frameNo]}) ? w1 : ${#bgSTK_cmdLoc[frameNo]} ))
		((w2= (w2>${#bgSTK_caller[frameNo]}) ? w2 : ${#bgSTK_caller[frameNo]} ))
	done
	[ "$showCallerFlag" ] && ((w2+=2)) || w2=0

	local highlightedFrameFont="${_CSI}48;2;62;62;62;38;2;210;210;210m"
	for ((frameNo=framesEnd; frameNo>=framesStart; frameNo--)); do
		local lineColor="${csiNorm}"; ((frameNo==highlightedFrameNo )) && lineColor="${highlightedFrameFont}"
		local callerTerm=""; [ "$showCallerFlag" ] && callerTerm="${bgSTK_caller[$frameNo]} :"
		winWriteLine stkWin "${lineColor}%*s %*s %*s" \
				${w1:-0} "${bgSTK_cmdLoc[$frameNo]}" \
				${w2:-0} "$callerTerm" \
				-0       "${bgSTK_cmdLine[$frameNo]//$'\n'*/...}"
	done

	if (( framesStart > 0 )); then
		winWriteLine stkWin "${csiNorm}-----\    $((framesStart)) frames below    /$infiniteDashes"
	else
		winWriteLine stkWin "${csiNorm}=====  BOTTOM of call stack $infiniteEquals"
	fi
	winPaint stkWin
}

# usage: debuggerPaintCodeView <srcFile> <srcWinStartLineNoVar> <srcCursorLineNoVar> <srcFocusedLineNo> <y1> <y2> <x1> <x2> <functionName> <simpleCommand>
# Paint the specified code page to stdout which is assumed to be a tty in the context of dugging.
# A section of the file will be written to stdout with the <srcFocusedLineNo> emphasized. If there are not
# enough lines in the file to write <viewLineHeight> number of lines, it will clear the remainder of
# clines. It always leaves the cursor <viewLineHeight> below where it was at the start of calling this
# function. It uses ${csiClrToEOL} to ensure that if content was in this area before, it will not
# bleed through. However, if the previous call to this function had a larger <viewLineHeight> the
# lines after the new <viewLineHeight> will not be cleared.
# Params:
#    <srcFile>          : the file that contains the source code to be shown
#    <srcWinStartLineNoVar> : a variable name that contains the line number in <srcFile> of the first line displayed in the window
#                         This is a var reference so that it can be saved in the Controller's state and be consistent across views
#                         we change it only when the srcCursorLineNoVar goes out of view
#    <srcCursorLineNoVar>: a variable name that contains the cursor line number in <srcFile> of the page that
#                         will be shown. Its a variable name so that this function can reset it to its bounds
#                         if the caller tries to increment or decrement past the start or end of the <srcFile>
#    <srcFocusedLineNo> : the line in the file to emphasize if it appears in the page
# TODO: add winX1...
#  rm  <viewLineHeight>   : the height in lines of this view that will be painted. If not enough srcFile
#                         lines exist to fill the area, the remaining lines will be cleared of previous
#                         content.
#  rm  <viewColWidth>     : the max width in columns of the code section that will be shown. lines longer
#                         will be truncated
function debuggerPaintCodeView()
{
	local srcFile="$1"
	local srcWinStartLineNoVar="$2"
	local srcCursorLineNoVar="$3"
	local srcFocusedLineNo="$4"
	local winX1="$5"
	local winY1="$6"
	local winX2="$7"
	local winY2="$8"
	local functionName="$9"
	local simpleCommand="${10}"

	local viewLineHeight=$((winY2-winY1+1))
	(( ${viewLineHeight:-0}<1 )) && return 1

	local codeSectionFont="${csiNorm}${csiBlack}${csiHiBkWhite}"
	local highlightedCodeFont="${csiNorm}${csiBlue}${csiHiBkWhite}"
	local highlightedCodeFont2="${csiBold}${csiBlue}${csiBkWhite}"

	# Init the viewport and cursor. The debugger inits srcCursorLineNoVar to "" at each new location.
	if [ "${!srcCursorLineNoVar}" == "" ]; then
		varOutput -R "$srcCursorLineNoVar"    "$((srcFocusedLineNo))"
		varOutput -R "$srcWinStartLineNoVar"  "$(( (srcFocusedLineNo-viewLineHeight*9/20 >0)?(srcFocusedLineNo-viewLineHeight*9/20):1))"
	fi

	# user cursor can not be moved less than 1
	(( ${!srcCursorLineNoVar} <  1 )) && varOutput -R "$srcCursorLineNoVar" 	"1"

	# scroll the viewport up or down if needed based on where the cursor is
	(( ${!srcCursorLineNoVar} < ${!srcWinStartLineNoVar} )) && varOutput -R "$srcWinStartLineNoVar" "${!srcCursorLineNoVar}"
	(( ${!srcCursorLineNoVar} > (${!srcWinStartLineNoVar} + viewLineHeight -1) )) && varOutput -R "$srcWinStartLineNoVar" "$((${!srcCursorLineNoVar} - viewLineHeight+1))"

	# typically we are displaying a real src file but if its a TRAP, we get the text of the handler and display it
	local contentStr contentFile
	# example: pts-<n>  or (older) <bash>(<n>)
	if [[ "$srcFile" =~ (^\<bash:([0-9]*)\>)|^pts ]]; then
		contentStr="$USER@$HOSTNAME:$PWD\\\$ ${simpleCommand}"$'\n\n'
		contentStr+=$(ps --forest $$ | sed 's/[?][?][?]/\n\t/g')
		contentFile="-"

	# example: EXIT-12345<handler>
	elif [[ "$srcFile" =~ ^(.*)-(.*)\<handler\> ]]; then
		signal="${BASH_REMATCH[1]}"
		setPID="${BASH_REMATCH[2]}"
		if [[ "$signal" =~ USR2$ ]] && [ "$bgBASH_tryStackPID" ]; then
			bgTrapStack peek "USR2" contentStr
			contentFile="-"

		elif signalNorm -q "$signal" signal; then
			bgTrapUtils --pid="$setPID" get $signal contentStr

			if [ ! "$contentStr" ] && [ "$signal" == "ERR" ]; then
				contentStr="$bgtrap_lastErrHandler"
			fi
			if [ ! "$contentStr" ] && [ "$signal" == "ERR" ] && [ "$_utRun_errHandlerHack" ]; then
				contentStr="$_utRun_errHandlerHack"
			fi
			contentStr="${contentStr:-"
				This stack frame is executing the handler string set for trap '$signal'
				but trap -p '$signal' did not return any code for the signal handler.
				Not sure why this happens sometimes. "
			}"
			contentFile="-"

		else
			contentStr="
				This stack frame is executing the handler string set for a trap
				but which trap can not be determined at this time. Signal='$signal'
				This is typically caused by the fact that BASH does not preserve
				enough information. bgtrap work-a-round will work after you step
				once if the handler was set by bgtrap.
			"
			contentFile="-"
		fi

	else
		contentStr=""
		contentFile="$(fsExpandFiles -f "$srcFile")"
	fi


	# ### Create the Header line
	local headerLine; printf -v headerLine "${highlightedCodeFont}%s${codeSectionFont} {... from [%s]: "  "$functionName" "$srcFile"

	printf "${codeSectionFont}${csiBkWhite}"

	# this awk script paints the code area in one pass. Its ok to ask it to scroll down too far -- it will stop of the last page.
	awk -v headerLine="$headerLine" \
		-v startLineNo="${!srcWinStartLineNoVar}" \
		-v endLineNo="$((${!srcWinStartLineNoVar} + viewLineHeight -1 ))" \
		-v focusedLineNo="$srcFocusedLineNo" \
		-v cursorLineNo="${!srcCursorLineNoVar}" \
		-v winX1="$winX1" \
		-v winY1="$winY1" \
		-v winX2="$winX2" \
		-v winY2="$winY2" \
		-v simpleCommand="${simpleCommand//\\/\\\\}" \
		-v codeSectionFont="$codeSectionFont" \
		-v highlightedCodeFont="$highlightedCodeFont" \
		-v highlightedCodeFont2="$highlightedCodeFont2" \
		-i bg_cui.awk '
			function getIndentCount(s                ,indentI) {
				# first char may be space. Then the line number. Then the indent and start of code
				# nnn              <code...>
				indentI=2
				while ((indentI < length(s)) && substr(s, indentI,1)!=" ") indentI++
				while ((indentI < length(s)) && substr(s, indentI,1)==" ") indentI++
				return indentI-1
			}
			function normalizeSimpleCommand(normSmpCmd, codeLine) {
				# these are a couple of replacements that are antidotal based on stepping through my code and seeing how bash formats
				if (normSmpCmd ~ /^[(][(]/  && normSmpCmd ~ /[)][)]$/ )
					normSmpCmd=substr(normSmpCmd,3,length(normSmpCmd)-4)
				gsub("&> /","&>/", normSmpCmd)
				normSmpCmd=gensub("([^1])>&2","\\11>\\&2", "g", normSmpCmd)
				gsub("[[:space:]][[:space:]]*"," ", normSmpCmd)

				# foo 2>/dev/null becomes foo 2> /dev/null
				if (normSmpCmd ~ /> / && codeLine !~ /> / )
					normSmpCmd=gensub(/> /, ">","g", normSmpCmd)
				return normSmpCmd
			}
			function normalizeCodeLine(normSmpCmd, codeLine) {
				codeLine=gensub("([^[:space:]])[[:space:]][[:space:]]*","\\1 ","g", codeLine)
				# foo=( $bar ) becomes foo=($bar)
				if (codeLine ~ /[(] [^)]* [)]/ && normSmpCmd !~ /[(] [^)]* [)]/ )
					codeLine=gensub(/[(] ([^)]*) [)]/, "(\\1)","g", codeLine)

				# [[ "$this" =~ some\ thing ]] becomes [[ "$this" =~ some thing ]]
				if (codeLine ~ /\\/ && normSmpCmd !~ /\\/ )
					codeLine=gensub(/\\/, "","g", codeLine)

			}
			function matchSimpleCommandInCodeLine(codeLine, simpleCommand, retCoords) {
				if (0==index(codeLine, simpleCommand)) {
					simpleCommand=normalizeSimpleCommand(simpleCommand, codeLine)
				}
				if (0==index(codeLine, simpleCommand)) {
					codeLine=normalizeCodeLine(simpleCommand, codeLine)
				}
				if (idx=index(codeLine, simpleCommand)) {
					retCoords["start"]=idx
					retCoords["end"]=idx+length(simpleCommand)
				}
			}
			function printFullSimpleCommand(codeLine, simpleCommand                       ,i,smpCmdArray, indentCount) {
				indentCount=getIndentCount(csiStrip(codeLine))
				gsub(/[\t]/,"    ",simpleCommand)
				split(simpleCommand, smpCmdArray, "\n")
				for (i=1; i<=length(smpCmdArray); i++) {
					winWriteLine(srcWin, sprintf("%*s"highlightedCodeFont2"%s"codeSectionFont, indentCount,"", smpCmdArray[i]))
				}
			}
			BEGIN {
				# we start collecting the output up to a page early in case the file ends before we get a full page worth
				collectStart=startLineNo-(endLineNo-startLineNo)
				startLineNoOffset=(endLineNo-startLineNo)
				arrayCreate(out)

				# remove the leading and trailing whitespace from the simpleCommand
				gsub("^[[:space:]]*|[[:space:]]*$","",simpleCommand)

				# the terminal colors passed to us are escaped strings so we need to render the escapes
				codeSectionFont=sprintf("%s",codeSectionFont)
				highlightedCodeFont=sprintf("%s",highlightedCodeFont)
				highlightedCodeFont2=sprintf("%s",highlightedCodeFont2)
			}

			{
				# expand tabs to spaces
				gsub(/[\t]/,"    ",$0)
				fullSrc[NR]=$0
				codeLine=$0
				out[NR]=((NR==cursorLineNo)?">":" ")""NR" "
			}

			NR==(focusedLineNo) {
				codeLine=$0

				# when the DEBUG trap enters a function the first time, it stops on the openning '{' and its hard to see where the
				# dugger is stopped at.
				if (codeLine ~ /^[[:space:]]*[{][[:space:]]*$/) {
					simpleCommandDone="1"
					out[NR]=highlightedCodeFont2""csiSubstr(codeLine, 1, 130, "--pad")""codeSectionFont
					next
				}

				arrayCreate(hlCoords)
				matchSimpleCommandInCodeLine(codeLine, simpleCommand, hlCoords)

				if (hlCoords["start"]) {
					out[NR]=out[NR]""substr(codeLine,1,hlCoords["start"]-1)""highlightedCodeFont2""substr(codeLine,hlCoords["start"],hlCoords["end"]-hlCoords["start"])""codeSectionFont""substr(codeLine,hlCoords["end"])
					simpleCommandDone="1"
				} else {
					out[NR]=out[NR]""highlightedCodeFont""codeLine""codeSectionFont
					simpleCommandDone=""
				}

				next
			}

			NR>=(collectStart) { out[NR]=out[NR]""$0 }

			NR>(endLineNo)      {exit}

			END {
				winCreate(srcWin, winX1,winY1,winX2,winY2)
				winWriteLine(srcWin, headerLine)

				# if the source file was not available the error msg that we get instead will be short
				if (NR < collectStart) {
					j=0; for (i=startLineNo; i<=endLineNo; i++)
						winWriteLine(srcWin, sprintf("%s%s", ((j==cursorLineNo)?">":" "), fullSrc[j++]) )
					winPaint(srcWin)
					exit 0
				}

				# if we reached the EOF before filling the window, calculate the offset to startLineNo that would be a perfect fit
				# we allow one extra blank line like editors do
				offset=0; if ((endLineNo-NR-1)>0 && startLineNo>1) {
					offset=( ((endLineNo-NR) < startLineNo-1)?(endLineNo-NR-1):(startLineNo-1) )
					startLineNo-=offset
					endLineNo-=offset
					if (cursorLineNo>endLineNo) cursorLineNo=endLineNo
				}

				### paint the lines
				for (i=startLineNo; i<=endLineNo; i++) {
					winWriteLine(srcWin, out[i] )
					if ((i==focusedLineNo) && !simpleCommandDone)
						printFullSimpleCommand(out[i], simpleCommand)
				}
				winPaint(srcWin)


				# if we had to adjust startLineNo, tell the caller by how much so it can adjust it permanently
				exit( offset )
			}
		'  $contentFile <<<"$contentStr" 2>>$_bgtraceFile; local offset=$?

	# if the awk script is asked to display past the end of file, it displays the last page and returns the number of lines that it
	# had to adjust the view windo. This blocks adjusts our srcWinStartLineNoVar and srcCursorLineNoVar to match
	if [ ${offset:-0} -gt 0 ]; then
		local fileSize=$((${!srcWinStartLineNoVar} + viewLineHeight -2 - offset))
		varOutput -R "$srcWinStartLineNoVar" $((fileSize-viewLineHeight+2))
		(( ${!srcCursorLineNoVar} >  fileSize+1 )) && varOutput -R "$srcCursorLineNoVar" $((fileSize+1))
	fi
	printf "${csiNorm}"
}

# usage: debugWatchWindow
function debugWatchWindow()
{
	import bg_cuiWin.sh ;$L1;$L2
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local dbgCmd="$1"; shift

	local cuiWinID="${bgTermID:-$$}.debug.watch"

	# if this is the first call in this shell and there is saved data, restore it
	local cntrFile; cuiWinCntr -R cntrFile $cuiWinID getCntrFile
	declare -ga debugWatchWindowData debugWatchWindowTransient debugWatchWindowTTY
	if [ ! "${debugWatchWindowData+exists}" ] && [ -f "$cntrFile.watchData" ]; then
		mapfile -t debugWatchWindowData < "$cntrFile.watchData"
		debugWatchWindowTransient=""
	fi


	local stateChanged
	case ${dbgCmd:-open} in
		open)   cuiWinCntr -R debugWatchWindowTTY $cuiWinID open ;;
		close)  cuiWinCntr $cuiWinID close; debugWatchWindowTTY=""; return ;;
		clear)  debugWatchWindowData=(); stateChanged="1" ;;
		remove)
			local i; for i in "${!debugWatchWindowData[@]}"; do
				[ "${debugWatchWindowData[$i]}" == "$1" ] && unset debugWatchWindowData[$i]
			done
			stateChanged="1"
			;;
		softRefresh)
			debugWatchWindowTransient=("$@")
			;;
		add|*)
			[ "$dbgCmd" != "add" ] && debugWatchWindowData+=($dbgCmd)
			debugWatchWindowData+=($*)
			stateChanged="1"
			;;
	esac

	cuiWinCntr $cuiWinID isOpen || return 0

	[ "$debugWatchWindowTTY" ] || cuiWinCntr -R debugWatchWindowTTY $cuiWinID open

	# shorten the tty var name
	local tty="$debugWatchWindowTTY"

	### paint the terminal screen
	local maxLines maxCols; cuiGetScreenDimension maxLines maxCols < $tty
	cuiClrScr > $tty

	printf "==== Watch Vars =====\n" > $tty
	local vwidth=0
	local v; for v in "${debugWatchWindowData[@]}"; do
		((vwidth= (vwidth<${#v}) ? ${#v} : vwidth ))
	done
	printfVars -w$vwidth "${debugWatchWindowData[@]}" > $tty

	printf "==== Local Function Scope =====\n" > $tty
	vwidth=0
	for v in "${debugWatchWindowTransient[@]}"; do
		((vwidth= (vwidth<${#v}) ? ${#v} : vwidth ))
	done
	printfVars -w$vwidth "${debugWatchWindowTransient[@]}" > $tty

	### save the list of watched variables if they changed
	if [ "$stateChanged" ]; then
		echo -n "" > "$cntrFile.watchData"
		local i; for i in "${!debugWatchWindowData[@]}"; do
			echo "${debugWatchWindowData[$i]}" >> "$cntrFile.watchData"
		done
	fi
}

# usage: debugStackWindow
function debugStackWindow()
{
	local curFrameNo="${1:-0}"
	import bg_cuiWin.sh ;$L1;$L2
	local cuiWinID="${bgTermID:-$$}.debug.stack"
	local tty; cuiWinCntr -R tty $cuiWinID open

	cuiClrScr > $tty
	local maxLines maxCols; cuiGetScreenDimension maxLines maxCols < $tty

	### Call Stack Section
	local highlightedFrameFont="${csiBlue}"

	echo "===============  BASH call stack    ====================="  >$tty
	local frameNo; for ((frameNo=bgStackSize-1; frameNo>=0; frameNo--)); do
		local lineColor=""; ((frameNo==curFrameNo )) && lineColor="${highlightedFrameFont}"
		printf "${lineColor}%s${csiNorm}\n" "${bgStackLine[$frameNo]:0:$maxCols}"  >$tty
	done
	echo "===============  end of call stack  ====================="  >$tty

	printf "[%s]:" "${bgSTK_cmdFile[$curFrameNo]}" > $tty

	# local cline ccol; cuiGetCursor cline ccol < $tty
	# local linesLeft=$((maxLines-cline))
	# awk -v linesLeft="$linesLeft" -v focusedLineNo="${bgSTK_cmdLineNo[$curFrameNo]}" -v maxCols="$maxCols" '
	# 	BEGIN {startLineNo=focusedLineNo-int((linesLeft-0.1)/2); endLineNo=startLineNo+linesLeft}
	# 	NR>(endLineNo)     {exit}
	# 	NR==(focusedLineNo) { printf("\n>'"${csiYellow}"'%s %s'"${csiNorm}"'",  NR, $0 ); next }
	# 	NR>(startLineNo)    { printf("\n %s %s",  NR, $0 ) }
	# ' $(fsExpandFiles -f "${bgSTK_cmdFile[$curFrameNo]}")  &> $tty
}


function intDbg_installKeyMap()
{
	## move this into the reader coproc
	set -o emacs;
	# to find new key codes, run 'xev' in term, click in the term, press a key combination.

	# step navigation
	bgbind --shellCmd '\e[15~'    "simulateCmdlineinput stepIn"                           # F5
	bgbind --shellCmd '\e[17~'    "simulateCmdlineinput stepOver"                         # F6
	bgbind --shellCmd '\e[18~'    "simulateCmdlineinput stepOut"                          # F7
	bgbind --shellCmd '\e[19~'    "simulateCmdlineinput stepToCursor"                     # F8
	bgbind --shellCmd '\e[20~'    "simulateCmdlineinput resume"                           # F9
	bgbind --shellCmd '\e[20;2~'  "simulateCmdlineinput rerun"                            # shift-F9
	bgbind --shellCmd '\e[17;2~'  "simulateCmdlineinput skipOver"                         # shift-F6
	bgbind --shellCmd '\e[18;2~'  "simulateCmdlineinput skipOut"                          # shift-F7

	# codeView navigation
	bgbind --shellCmd '\e[1;3A'   "simulateCmdlineinput scrollCodeView -1"                # alt-up
	bgbind --shellCmd '\e[1;3B'   "simulateCmdlineinput scrollCodeView  1"                # alt-down
	bgbind --shellCmd '\e[5;3~'   "simulateCmdlineinput scrollCodeView -${dbgPgSize:-10}" # alt-pgUp
	bgbind --shellCmd '\e[6;3~'   "simulateCmdlineinput scrollCodeView  ${dbgPgSize:-10}" # alt-pgDown
	bgbind --shellCmd '\e[1;3H'   "simulateCmdlineinput scrollCodeView "                  # alt-home

	# stackView navigation
	bgbind --shellCmd '\e[1;5A'   "simulateCmdlineinput stackViewSelectFrame +1"          # cntr-up
	bgbind --shellCmd '\e[1;5B'   "simulateCmdlineinput stackViewSelectFrame -1"          # cntr-down
	bgbind --shellCmd '\e[1;5H'   "simulateCmdlineinput stackViewSelectFrame  0"          # cntr-home
	bgbind --shellCmd '\e[1;5C'   "simulateCmdlineinput toggleStackArgs"                  # cntr-left
	bgbind --shellCmd '\e[1;5D'   "simulateCmdlineinput toggleStackArgs"                  # cntr-right

	if [ "$bgdbPageFlipFlag" ]; then
		# 'read<enter>alt-z' shows '\e[z' but looking at "bind -P" I saw that alt-f was '\ef' so I tried '\ez' and it worked
		bgbind --shellCmd '\ez'  "simulateCmdlineinput toggleAltScreen"                  # alt-z
	fi

	# read -e only does the default filename completion and ignores compSpecs. we must override <tab>
	#complete -D -o bashdefault
	#complete -A arrayvar -A builtin -A command -A function -A variable -D
}


##################################################################################################################################
### TTY Functions

# usage: _initDedicatedTTY
# A dedicated TTY is one that is not shared with the script (e.g. a cuiWin is dedicated)
function _initDedicatedTTY()
{
	# make sure the cui vars are rendered to the terminal that we are printing to -- this should be kept separate from the app but
	# not sure how to do that effeciently. Maybe we will need to do this in _debugEnterDebugger each time and set local variables their
	local -g $(cuiRealizeFmtToTerm <&$bgdbttyFD)

	# added to try to fix risize problem in that lines reflow when the terminal width changes. did not work. have not investigated why.
	printf "${csiLineWrapOff}" >&$bgdbttyFD

	# clear any pending input on the debug terminal
	local char scrap; while read -t0 <&$bgdbttyFD; do read -r -n1 char <&$bgdbttyFD; scrap+="$char"; done
	[ "$scrap" ] && bgtrace "found starting scraps from debugger tty '${scrap}'"

	# 2022-10 bobg: I cant remember why we switch a dedicated tty to its Alt Page
	printf "${csiSwitchToAltScreenAndBuffer}"
}

function _enterTTYAltPage()
{

	[ ! "$bgdbPageFlipFlag" ] && return 0
	if ((bgdbTTYRefCount++ == 0)); then
		# make sure the cui vars are rendered to the terminal that we are printing to -- this should be kept separate from the app but
		# not sure how to do that effeciently. Maybe we will need to do this in _debugEnterDebugger each time and set local variables there
		local -g $(cuiRealizeFmtToTerm <&$bgdbttyFD)

		# added to try to fix resize problem in that lines reflow when the terminal width changes. did not work. have not investigated why.
		#printf "${csiLineWrapOff}" >&$bgdbttyFD

		# clear any pending input on the debug terminal
		local char scrap; while read -t0 <&$bgdbttyFD; do read -r -n1 char <&$bgdbttyFD; scrap+="$char"; done
		[ "$scrap" ] && bgtrace "found starting scraps from debugger tty '$scrap'"

	#	printf "${csiSwitchToAltScreenAndBuffer}${csiClrSavedLines}"
		printf "${csiSwitchToAltScreenAndBuffer}"
	fi
}

function _leaveTTYAltPage()
{
	[ ! "$bgdbPageFlipFlag" ] && return 0
	if ((--bgdbTTYRefCount <= 0)); then
		cuiResetScrollRegion
		printf "${csiSwitchToNormScreenAndBuffer}${csiShow}"
		stty echo 2>/dev/null # suppressed error msg b/c i got 'stty: 'standard input': Input/output error' when 'exit' in self mode
	fi
}

function _toggleTTYAltPage()
{
	[ ! "$bgdbPageFlipFlag" ] && return 0
	if [ ${bgdbTTYRefCount:-0} -eq 0 ]; then
		_enterTTYAltPage
		debugBreakPaint
	else
		_leaveTTYAltPage
	fi
}
