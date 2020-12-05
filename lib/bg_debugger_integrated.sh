#!/bin/bash

import bg_strings.sh ;$L1;$L2
import bg_cui.sh ;$L1;$L2
import bg_ipc.sh ;$L1;$L2

# Library bg_debugger.sh
# This library provides an interactive debugger for stepping through and examining the state of scripts
# that source /usr/lib/bg_core.sh.
#
# This debugger driver implementation runs a UI written in bash from inside the script being debugged.  The UI needs a tty that it
# will use to display the UI and read user input. By default, that tty will be created on demand using the cuiWin subsystem to
# open a new terminal using gnome-terminal or other configured terminal emulation program.
#


##################################################################################################################
### debugger functions
# This section contains functions that implement an interactive debugger.

# usage: debuggerOnImpl <terminalID>
# This is specific to the integrated bash debugger that uses a tty device file for input and output for the debugger. It is called
# by the generic debuggerOn function when the dbgID matches intregrated:<terminalID>. This function identifies the terminal device
# file that will be used and creates it if needed. If successful, the bgdbtty variable will contain the tty device file and
# bgdbttyFD will be an open file descriptor that can be written to and read from.
# Params:
#    <terminalID> : tty|bgtrace|win|win<n>|/dev/pts/<n>  Typically you just use the default, 'win' which will use a cuiWin with the
#           name $$.debug . Because this name contains the bash PID ($$), the effect is that a debugger terminal window will be
#           openned that is specific to that terminal. Each script you debug in that terminal will re-use that same debugger instance
#           and will create it if needed.
function integratedDebugger_debuggerOn()
{
	local terminalID="$1"; shift

	declare -gx bgdbtty=""  bgdbttyFD="" bgdbCntrFile=""

	case ${terminalID:-win} in
		win|cuiWin)
			type -t cuiWinCntr>/dev/null || import bg_cuiWin.sh ;$L1;$L2
			local cuiWinID="${bgTermID:-$$}.debug"
			cuiWinCntr -R bgdbtty $cuiWinID open
			cuiWinCntr -R bgdbCntrFile $cuiWinID getCntrFile
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
		tty)    bgdbtty="/dev/tty" ;;
		/dev/*) bgdbtty="$terminalID" ;;
		*) assertError -v terminalID "terminalID not yet implemented or is unknown"
	esac

	# open file descriptors to the debug tty
	exec {bgdbttyFD}<>"$bgdbtty"
	cuiClrScr >&$bgdbttyFD
	echo "starting debugger" >&$bgdbttyFD

	[ -t $bgdbttyFD ] || assertError -v terminalID -v bgdbtty -v bgdbttyFD "The specified terminalID for a debugger session is not a terminal device"

	# make sure the cui vars are rendered to the terminal that we are printing to -- this should be kept separate from the app but
	# not sure how to do that effeciently. Maybe we will need to do this in _debugEnterDebugger each time and set local variables their
	local -g $(cuiRealizeFmtToTerm <&$bgdbttyFD)

	# clear any pending input on the debug terminal
	local char scrap; while read -t0 <&$bgdbttyFD; do read -r -n1 char <&$bgdbttyFD; scrap+="$char"; done
	[ "$scrap" ] && bgtrace "found starting scraps from debugger tty '$scrap'"
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
	bgdbtty=""
	[ "$bgdbttyFD" ] && exec {bgdbttyFD}<&-
	bgdbttyFD=""
	bgdbCntrFile="" # should we close the cuiWin if we openned it?
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
	local dbgStackStart="$bgStackLogicalFramesStart"; [ "$bgBASH_debugToggleAllStack" ] && dbgStackStart=0
	local dbgStackSize=$((bgStackSize - dbgStackStart))

	# Construct the View (debugBreakPaint)
	# give the View (debugBreakPaint) a chance to declare variables at this scope so that they live
	# from one debugBreakPaint call to another but are not global (like OO)
	# and then give it a chance to init those variables (has to be done in two steps).
	local $(debugBreakPaint --declareVars);
	debugBreakPaint --init  <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD;

	local dbgPrompt="[${0##*/}] bgdb> "
	DebuggerController "$dbgPrompt" <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD;
	local dbgResult="$?"
	debugBreakPaint --leavingDebugger <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD
}

function _debugDriverScriptEnding()
{
	debugBreakPaint --scriptEnding <&$bgdbttyFD >&$bgdbttyFD 2>&$bgdbttyFD
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
	local dbgPgSize="$((codeViewEndLine-codeViewStartLine -2))"
	local dbgScriptState="running"

	# restore the argv from the User function we are stopped in so that they can be examined
	set -- "${bgBASH_debugArgv[@]}"

	set -o emacs;
	# to find new key codes, run 'xev' in term, click in the term, press a key combination.

	# step navigation
	bgbind --shellCmd '\e[15~'    "dbgDoCmd stepIn"          # F5
	bgbind --shellCmd '\e[17~'    "dbgDoCmd stepOver"        # F6
	bgbind --shellCmd '\e[18~'    "dbgDoCmd stepOut"         # F7
	bgbind --shellCmd '\e[19~'    "dbgDoCmd stepToCursor"    # F8
	bgbind --shellCmd '\e[20~'    "dbgDoCmd resume"          # F9
	bgbind --shellCmd '\e[17;2~'  "dbgDoCmd skipOver"        # shift-F6
	bgbind --shellCmd '\e[18;2~'  "dbgDoCmd skipOut"         # shift-F7

	# codeView navigation
	bgbind --shellCmd '\e[1;3A'   "dbgDoCmd scrollCodeView -1"          # alt-up
	bgbind --shellCmd '\e[1;3B'   "dbgDoCmd scrollCodeView  1"          # alt-down
	bgbind --shellCmd '\e[5;3~'   "dbgDoCmd scrollCodeView -$dbgPgSize" # alt-pgUp
	bgbind --shellCmd '\e[6;3~'   "dbgDoCmd scrollCodeView  $dbgPgSize" # alt-pgDown
	bgbind --shellCmd '\e[1;3H'   "dbgDoCmd scrollCodeView "            # alt-home

	# stackView navigation
	bgbind --shellCmd '\e[1;5A'   "dbgDoCmd stackViewSelectFrame +1"   # cntr-up
	bgbind --shellCmd '\e[1;5B'   "dbgDoCmd stackViewSelectFrame -1"   # cntr-down
	bgbind --shellCmd '\e[1;5H'   "dbgDoCmd stackViewSelectFrame  0"   # cntr-home
	bgbind --shellCmd '\e[1;5C'   "dbgDoCmd toggleStackArgs"           # cntr-left
	bgbind --shellCmd '\e[1;5D'   "dbgDoCmd toggleStackArgs"           # cntr-right

	# read -e only does the default filename completion and ignores compSpecs. we must override <tab>
	#complete -D -o bashdefault
	#complete -A arrayvar -A builtin -A command -A function -A variable -D

	function dbgDoCmd() { echo -en "$dbgPrompt">&0; echo " $*"; exit; }

	debugWatchWindow softRefresh ${bgBASH_debugTrapFuncVarList[*]}

	# we want to be able to handle the cmds generated by key mappings the same as those entered by the
	# user but we don't want those to show up like commands actually entered -- no scrolling the cmd area.
	# But There seems to be no way to get bind to accept the command without sending a linefeed to the tty.
	# This pattern makes it so anything written to std out in the () sub shell will be the collected
	# command. (note that readline echos typed chars to the tty identified by stdin). Our dbgDoCmd
	# echos the cmd it wants and then ends the subshell with exit so readline does not get a chance to
	# send a linefeed. Normally typed cmds entered by the user pressing <enter> will be collected in 's'
	# and readline will send a linefeed and then we echo s to stdout.
	local dbgResult dbgDone; while [ ! "$dbgDone" ] && [ ${dbgResult:-0} -eq 0 ]; do
		# Try:  # Try/Catch cant unwind inside a DEBUG handler
		if [ "$dbgScriptState" != "ended" ] && pidIsDone $$; then
			dbgScriptState="ended"
			echo "script ($$) has ended. Use cntr-c to end this session"
		fi

		stty echo; cuiShowCursor
		history -r ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history
		local dbgCmdlineValue; dbgCmdlineValue="$(read -e -p "$dbgPrompt" s || exit; echo "$s" )"; dbgResult=$?; ((dbgResult>0)) && ((dbgResult=-dbgResult))
		stty -echo; cuiHideCursor
		# only put cmds that the user typed into the history. The commands from dbgDoCmd macro have leading spaces.
		([[ ! "$dbgCmdlineValue" =~ ^[[:space:]] ]]) && { history -s "$dbgCmdlineValue"; history -a ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history; }
		stringTrim -i dbgCmdlineValue

		# parse the dbgCmd
		local dbgCmd="${dbgCmdlineValue%%[; ]*}"
		local dbgArgs="${dbgCmdlineValue#$dbgCmd}"

		# any case that returns, will cause the script to continue. If it calls _debugSetTrap first,
		# then the debugger will continue to montitor the script and if the break condition is met,
		# we will get back to this loop at a different place in the script. If the _debugSetTrap is not
		# called before the return, the script will run to conclusion.

		case $dbgScriptState:${dbgCmd:-emptyLine} in
			*:close)                cuiWinCntr "$bgdbCntrFile" close; return 0 ;;
			*:stackViewSelectFrame) debugBreakPaint --stackViewSelectFrame $dbgArgs; dbgDone="" ;;
			*:scrollCodeView)       debugBreakPaint --scrollCodeView       $dbgArgs; dbgDone="" ;;
			*:watch)                debugWatchWindow $dbgArgs ; dbgDone="" ;;
			*:stack)                debugStackWindow $dbgArgs ; dbgDone="" ;;

			*:stepOverPlumbing) bgDebuggerStepOverPlumbing="1"; echo "will now step over plumbing code like object _bgclassCall" ;;
			*:stepIntoPlumbing) bgDebuggerStepOverPlumbing="0"; echo "will now step into plumbing code like object _bgclassCall" ;;

			ended:step*|ended:skip*|ended:resume)
									echo "the script ($$) has ended" ;;
			*:step*|*:skip*|*:resume)
				_debugSetTrap $dbgCmdlineValue; dbgResult=$?
				return $dbgResult
				;;

			*:toggleStackArgs)      debugBreakPaint --toggleStackArgs      $dbgArgs; dbgDone="" ;;
			*:toggleStackDebug)     debugBreakPaint --toggleStackDebug     $dbgArgs; dbgDone="" ;;
			*:toggleAllStack)
				varToggleRef bgBASH_debugToggleAllStack  "" "--allStack"
				dbgStackStart="$bgStackLogicalFramesStart"; [ "$bgBASH_debugToggleAllStack" ] && dbgStackStart=0
				dbgStackSize=$((bgStackSize - dbgStackStart))
				# adjust the current stack cursor  so that it points to the same frame
				if [ "$bgBASH_debugToggleAllStack" ]; then ((stackViewCurFrame+=bgStackLogicalFramesStart)); else ((stackViewCurFrame-=bgStackLogicalFramesStart)); fi
				# clear the saved code window positions since the offsets changed
				codeViewOffsetsByStackFrame=(); stackViewLastFrame=-1
				debugBreakPaint
				dbgDone=""
				;;

			*:breakAtFunction)
				debugBreakAtFunction $dbgArgs
				;;

			*:emptyLine)            debugBreakPaint ;;

			*)	[ "$bgDevModeUnsecureAllowed" ] || return 35
				eval "$dbgCmdlineValue" ;;
		esac
		# (Try/Catch cant unwind inside a DEBUG handler)# Catch: && { bgtrace "in catch '$dbgCmd'"; echo "exception caught"; cat "$assertOut"; }
	done
	unset dbgDoCmd
	return $dbgResult
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
	local method; ([[ "$1" =~ ^-- ]]) && { method="$1"; shift; }

	case $method in
		--declareVars)
			# these are the varnames of our 'member vars' that will be declared at the caller's scope
			# so that they will be persistent each time that scope calls this function
			echo "
				stackViewCurFrame stackViewLastFrame stackArgFlag stackDebugFlag stackViewStartLine stackViewEndLine
				codeViewSrcWinStart
				codeViewSrcCursor codeViewOffsetsByStackFrame codeViewStartLine codeViewEndLine
				cmdViewStartLine cmdViewEndLine cmdAreaSize
			"
			return
			;;
		--init)
			# construction. init the member vars
			stackViewCurFrame=0; [ "$bgBASH_debugToggleAllStack" ] && stackViewCurFrame=$bgStackLogicalFramesStart
			stackViewLastFrame=-1
			stackArgFlag="srcCode"
			stackDebugFlag=""
			stackViewStartLine=0    stackViewEndLine=0
			codeViewSrcWinStart="${bgBASH_debugViewWin:-0}"
			codeViewSrcCursor=0     codeViewOffsetsByStackFrame=()
			codeViewStartLine=""    codeViewEndLine=0
			cmdViewStartLine=0      cmdViewEndLine=0
			;;

		# --paint does nothing and drops through. Other method cases can drop through or return to skip painting
		--paint) ;;

		--leavingDebugger)
			local maxLines maxCols; cuiGetScreenDimension maxLines maxCols
			cuiMoveTo $((maxLines)) 1
			printf "${csiClrToEOL}${csiBlack}${csiBkYellow}  script running ...${csiNorm}${csiClrToEOL}"
			return
			;;

		--scriptEnding)
			local maxLines maxCols; cuiGetScreenDimension maxLines maxCols
			cuiMoveTo $((maxLines)) 1
			printf "${csiClrToEOL}${csiBlack}${csiBkYellow}  script ended. press cntr-c to close this terminal or restart a script to debug in the other terminal${csiNorm}${csiClrToEOL}"
			return
			;;

		# scroll the code view section up(-n) or down(+n)
		# note that we don't have to to clip is to start/end bounds of the file because the codeView
		# will clip it and update this value so that each cycle it will start in bounds.
		# default value. view will center the focused line
		--scrollCodeView) [ ! "$1" ] && codeViewSrcCursor="" || ((codeViewSrcCursor+=${1:- 1})); shift ;;

		# change the selected stack frame up(-1) or down(+1)
		--stackViewSelectFrame)
			case ${1:-0} in
				[+-]*) (( stackViewCurFrame+=${1:- 1} )) ;;
				*)     stackViewCurFrame="$1" ;;
			esac; shift
			(( stackViewCurFrame < 0 )) && stackViewCurFrame=0
			(( stackViewCurFrame > dbgStackSize-1 )) && stackViewCurFrame="$((dbgStackSize-1))"
			;;

		--toggleStackArgs|--toggleStackCode)
			stackArgFlag="$(  varToggle "$stackArgFlag"    argValues srcCode)"
			;;
		--toggleStackDebug) stackDebugFlag="$(varToggle "$stackDebugFlag"  "" "--debugInfo")" ;;

	esac

	# every time we are called, we want to notice if the terminal dimensions have changed because there
	# is not (always) a reliable event for terminal resizing in all supported bash versions (see SIGWINCH
	# and checkwinsize in man bash)
	local maxLines maxCols; cuiGetScreenDimension maxLines maxCols

	# the cmd view is a fixed size proportion of the terminal height.
	# Define these first so that the code view can use it
	cmdAreaSize=$((maxLines/4)); ((cmdAreaSize<2)) && cmdAreaSize=2

	cuiHideCursor
	stackViewStartLine=1
	cuiMoveTo $stackViewStartLine 1

	### Call Stack Section
	debuggerPaintStack --maxWinHeight $((maxLines*7/20)) $stackDebugFlag  --argsType=$stackArgFlag "$stackViewCurFrame"

	# write the values of the variables referenced in the current line
	local contextLine; dbgPrintfVars contextLine "${bgBASH_debugTrapCmdVarList[@]}"
	if [ "$contextLine" ]; then
		printf "${csiBkCyan}${csiWhite}${csiClrToEOL}%s${csiClrToEOL}${csiNorm}\n" "$contextLine"
	else
		printf "${csiClrToEOL}"
	fi

	cuiGetCursor --preserveRematch stackViewEndLine

	### Code View Section
	# we maintiain a separate codeViewSrcCursor for each stack frame so that as the user goes up and
	# down the stack, it remembers where they scrolled to in each frame's src file. when the stack changes
	# b/c _debugEnterDebugger is called from a new spot, all the codeViewSrcCursor are reset
	if ((stackViewCurFrame+dbgStackStart != stackViewLastFrame)); then
		codeViewSrcCursor="${codeViewOffsetsByStackFrame[$((stackViewCurFrame+dbgStackStart))]}"
		stackViewLastFrame="$((stackViewCurFrame+dbgStackStart))"
	else
		codeViewOffsetsByStackFrame[$((stackViewCurFrame+dbgStackStart))]="$codeViewSrcCursor"
	fi
	# begin the code view region where the stack view region ended. End it where the cmd region starts.
	codeViewStartLine="$stackViewEndLine"
	codeViewEndLine="$((maxLines-cmdAreaSize))"

	local codeViewWidth=$(( maxCols *3/2 ))

	local srcFile="${bgStackSrcFile[$((stackViewCurFrame+dbgStackStart))]}"
	[ "$srcFile" == "<handler>" ] && srcFile="<${bgStackFrameType[$((stackViewCurFrame+dbgStackStart))]}>"

	debuggerPaintCodeView \
		"$srcFile" \
		codeViewSrcWinStart \
		codeViewSrcCursor \
		"${bgStackSrcLineNo[$((stackViewCurFrame+dbgStackStart))]}" \
		"$((codeViewEndLine - codeViewStartLine))" "$codeViewWidth" \
		"${bgStackFunction[$((stackViewCurFrame+dbgStackStart))]}"

	### Cmd Area Section
	cmdViewStartLine="$codeViewEndLine"
	cmdViewEndLine="$((maxLines+1))" # (*ViewEndLines are all one past the last line in that region)

	# write the status/help line on the last line
	cuiMoveTo $((cmdViewEndLine-1)) 1
	if [ "$method" == "--leavingDebugger" ]; then
		printf "${csiClrToEOL}${csiBlack}${csiBkYellow}  script running ...${csiNorm}${csiClrToEOL}"
	else
		# write the key binding help line at the last line *within* our region
		local keybindingData="${csiBlack}${csiBkCyan}"
		local shftKeyColor="${csiBlack}${csiBkGreen}"
		printf "${csiClrToEOL}${keybindingData}F5-stepIn${csiNorm} ${keybindingData}F6-stepOver${shftKeyColor}+shft=skip${csiNorm} ${keybindingData}F7-stepOut${shftKeyColor}+shft=skip${csiNorm} ${keybindingData}F8-stepToCursor${csiNorm} ${keybindingData}cntr+nav=stack${csiNorm} ${keybindingData}alt+nav=code${csiNorm} ${keybindingData}watch add ...${csiNorm}"
	fi

	# set the scroll region to our start up to but not including the help line
	cuiSetScrollRegion "$cmdViewStartLine" "$((cmdViewEndLine-2))"
	# set the cursor to the last line of the scroll region so that the prompt will be performed there
	cuiMoveTo "$((cmdViewEndLine-2))" 1
	cuiShowCursor

	bgBASH_debugViewWin="${codeViewSrcWinStart:-0}"
}


# usage: dbgPrintfVars
function dbgPrintfVars()
{
	local _pvRetVar="$1"; shift
	local  _pvTmp
	printf -v "$_pvRetVar" "%s" ""
	while [ $# -gt 0 ]; do
		local _pvTerm="$1"; shift

		case $_pvTerm in
			+*) continue ;;
			-*) continue ;;
		esac

		local _pvType; varGetAttributes "${_pvTerm}" _pvType

		if [[ "$_pvTerm" =~ ^[0-9]$ ]]; then
			printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvTerm}" "${bgBASH_debugArgv[$_pvTerm]}"
		elif [ ! "$_pvType" ]; then
			printf -v "$_pvRetVar" "%s %s=<ND>" "${!_pvRetVar}" "${_pvTerm}"
		elif [[ "$_pvType" =~ [aA] ]]; then
			arraySize "${_pvTerm}" _pvTmp
			printf -v "$_pvRetVar" "%s %s=array(%s)" "${!_pvRetVar}" "${_pvTerm}" "$_pvTmp"
		else
			printf -v "$_pvRetVar" "%s %s=%s" "${!_pvRetVar}" "${_pvTerm}" "${!_pvTerm}"
		fi

	done
}


# usage: debuggerPaintStack [<options>] <highlightedFrameNo>
# Paint the current logical stack to stdout which is assumed to be a tty used in the context of debugging
# Params:
#     <highlightedFrameNo>  : if specified, the line corresponding to this stack frame number will be highlighted
# Options:
#    --maxWinHeight <numLinesHigh> : constrain the window to be at most this many lines tall
#    --debugInfo : append the raw stack data at the end of each frame
#    --argsType=argValues|srcCode  : does the frame show the simpleCmd with arg values or the source line from the script file
function debuggerPaintStack()
{
	local maxWinHeight=9999 debugInfoFlag argsTypeFlag
	while [ $# -gt 0 ]; do case $1 in
		--debugInfo) debugInfoFlag="--debugInfo" ;;
		--argsType*) bgOptionGetOpt val: argsTypeFlag "$@" && shift ;;
		--maxWinHeight*) bgOptionGetOpt val: maxWinHeight "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local highlightedFrameNo="${1:-0}"
	local stackArgFlag="${2:-"argValues"}"

	local framesToDisplay=$(( (dbgStackSize+2 <= maxWinHeight)?dbgStackSize:(maxWinHeight-2) ))
	local framesStart=$(( (highlightedFrameNo < framesToDisplay)?0:(highlightedFrameNo-framesToDisplay+1) ))
	local framesEnd=$((   framesStart+framesToDisplay ))

	if (( framesEnd < dbgStackSize )); then
		printf -- "${csiClrToEOL}------ ^  $((dbgStackSize-framesEnd)) frames above ($argsTypeFlag) ${csiBlack}${csiBkCyan}<cntr-left/right>${csiNorm}  ^ ----------------------\n"
	else
		printf "${csiClrToEOL}=====   Call Stack showing:$argsTypeFlag ${csiBlack}${csiBkCyan}<cntr-left/right>${csiNorm}  =====================\n"
	fi

	local highlightedFrameFont="${_CSI}48;2;62;62;62;38;2;210;210;210m"
#	local frameNo; for ((frameNo=framesStart; frameNo<framesEnd; frameNo++)); do
	local frameNo; for ((frameNo=framesEnd-1; frameNo>=framesStart; frameNo--)); do
		local bashStkFrm=""; [ "$debugInfoFlag" ] && bashStkFrm="${bgStackBashStkFrm[$frameNo+dbgStackStart]}"
		local lineColor=""; ((frameNo==highlightedFrameNo )) && lineColor="${highlightedFrameFont}"
		if [ "$argsTypeFlag" == "argValues" ]; then
			local stackFrameLine="${bgStackLineWithSimpleCmd[$frameNo+dbgStackStart]}"
		else
			local stackFrameLine="${bgStackLine[$frameNo+dbgStackStart]}"
		fi
		printf "${lineColor}${csiClrToEOL}${lineColor}%s %-85s %s${csiNorm}\n"  "${bgStackFrameType[$frameNo+dbgStackStart]}"  "${stackFrameLine/$'\n'*/...}" "$bashStkFrm"  #| sed 's/^\(.\{1,'"$maxCols"'\}\).*$/\1/'
	done

	if (( framesStart > 0 )); then
		printf -- "${csiClrToEOL}---------------\    $((framesStart)) frames below    /---------------------\n"
	else
		printf "${csiClrToEOL}===============  BOTTOM of call stack =====================\n"
	fi
}

# usage: debuggerPaintCodeView <srcFile> <srcWinStartLineNoVar> <srcCursorLineNoVar> <srcFocusedLineNo> <viewLineHeight> <viewColWidth>
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
#    <viewLineHeight>   : the height in lines of this view that will be painted. If not enough srcFile
#                         lines exist to fill the area, the remaining lines will be cleared of previous
#                         content.
#    <viewColWidth>     : the max width in columns of the code section that will be shown. lines longer
#                         will be truncated
function debuggerPaintCodeView()
{
	local srcFile="$1"
	local srcWinStartLineNoVar="$2"
	local srcCursorLineNoVar="$3"
	local srcFocusedLineNo="$4"
	local viewLineHeight="$5"
	local viewColWidth="$6"
	local functionName="$7"

	(( ${viewLineHeight:-0}<1 )) && return 1

	local codeSectionFont="${csiNorm}${csiBlack}${csiHiBkWhite}"
	local highlightedCodeFont="${csiNorm}${csiBlue}${csiHiBkWhite}"
	local highlightedCodeFont2="${csiBold}${csiBlue}${csiBkWhite}"

	### Display the Header line and subtract from the height left
	printf "${codeSectionFont}${csiBkWhite}"
	printf "${csiClrToEOL}[%s]: ${highlightedCodeFont}%s${codeSectionFont}\n" "$srcFile" " Executing $functionName() "
	((viewLineHeight--))

	# Init the viewport and cursor. The debugger inits srcCursorLineNoVar to "" at each new location.
	if [ "${!srcCursorLineNoVar}" == "" ]; then
		setRef "$srcCursorLineNoVar"    "$((srcFocusedLineNo))"
		setRef "$srcWinStartLineNoVar"  "$(( (srcFocusedLineNo-viewLineHeight*9/20 >0)?(srcFocusedLineNo-viewLineHeight*9/20):1))"
	fi

	# user cursor can not be moved less than 1
	(( ${!srcCursorLineNoVar} <  1 )) && setRef "$srcCursorLineNoVar" 	"1"

	# scroll the viewport up or down if needed based on where the cursor is
	(( ${!srcCursorLineNoVar} < ${!srcWinStartLineNoVar} )) && setRef "$srcWinStartLineNoVar" "${!srcCursorLineNoVar}"
	(( ${!srcCursorLineNoVar} > (${!srcWinStartLineNoVar} + viewLineHeight -1) )) && setRef "$srcWinStartLineNoVar" "$((${!srcCursorLineNoVar} - viewLineHeight+1))"

	local simpleCommand="${BASH_COMMAND}"

	# typically we are displaying a real src file but if its a TRAP, we get the text of the handler and display it
	local contentStr contentFile
	if [[ "$srcFile" =~ ^\<bash:([0-9]*)\> ]]; then
		# when bg_core.sh is sourced some top level, global code records the cmd line that invoked in bgLibExecCmd
		local v simpleCommand=""
		for (( v=0; v <=${#bgLibExecCmd[@]}; v++ )); do
			local quotes=""; [[ "${bgLibExecCmd[v]}" =~ [[:space:]] ]] && quotes="'"
			simpleCommand+=" ${quotes}${bgLibExecCmd[v]}${quotes}"
		done
		contentStr="$USER@$HOSTNAME:$PWD\$ ${simpleCommand}"$'\n\n'
		contentStr+=$(ps --forest $$ | sed 's/[?][?][?]/\n\t/g')
		contentFile="-"

	elif [[ "$srcFile" =~ ^\<([^>]*)\> ]]; then
		signal="${BASH_REMATCH[1]}"
		if [[ "$signal" =~ USR2$ ]] && [ "$bgBASH_tryStackPID" ]; then
			bgTrapStack peek "USR2" contentStr
			contentFile="-"

		elif signalNorm -q "$signal" signal; then
			contentStr="$(builtin trap -p $signal)"
			contentStr="${contentStr#*\'}"
			contentStr="${contentStr%\'*}"
			contentStr="${contentStr//"'\''"/\'}"
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


	# this awk script paints the code area in one pass. Its ok to ask it to scroll down too far -- it will stop of the last page.
	awk -v startLineNo="${!srcWinStartLineNoVar}" \
		-v endLineNo="$((${!srcWinStartLineNoVar} + viewLineHeight -1 ))" \
		-v focusedLineNo="$srcFocusedLineNo" \
		-v cursorLineNo="${!srcCursorLineNoVar}" \
		-v viewColWidth="$viewColWidth" \
		-v BASH_COMMAND="$simpleCommand" \
		-i bg_core.awk '
			function getNormLine(s) {
				gsub("[\t]","    ",s)
				s=substr(s,1,viewColWidth-7)
				if (length(s)==viewColWidth-7)
					s=s"+"
				return s
			}
			BEGIN {
				# we start collecting the output up to a page early in case the file ends before we get a full page worth
				collectStart=startLineNo-(endLineNo-startLineNo)
			}

			{fullSrc[NR]=$0;}

			NR==(focusedLineNo) {
				codeLine=$0

				# when the DEBUG trap enters a function the first time, it stops on the openning '{' and its hard to see where the
				# dugger is stopped at.
				if (codeLine ~ /^[[:space:]]*[{][[:space:]]*$/) {
					out[NR]=sprintf(" '"${highlightedCodeFont}${csiBkWhite}${csiClrToEOL}"'%s %s'"${codeSectionFont}${csiHiBkWhite}"'",  NR, getNormLine(codeLine) )
					next
				}

				gsub("^[[:space:]]*|[[:space:]]*$","",BASH_COMMAND)
				if (0==index(codeLine, BASH_COMMAND)) {
					# these are a couple of replacements that are antidotal based on steping through my code and seeing how bash
					# normalizes simple commands compared to mine. We should be able to build an algorithm that finds and anchors
					# the front, back, and middle of BASH_COMMAND. All we need to do is identify the best starting and ending points
					if (BASH_COMMAND ~ /^[(][(]/  && BASH_COMMAND ~ /[)][)]$/ )
				 		BASH_COMMAND=substr(BASH_COMMAND,3,length(BASH_COMMAND)-4)
					gsub("&> /","&>/", BASH_COMMAND)
					BASH_COMMAND=gensub("([^1])>&2","\\11>\\&2", "g", BASH_COMMAND)
					gsub("[[:space:]][[:space:]]*"," ", BASH_COMMAND)
					codeLine=gensub("([^[:space:]])[[:space:]][[:space:]]*","\\1 ","g", codeLine)
				}
				if (idx=index(codeLine, BASH_COMMAND)) {
					codeLine=sprintf("%s'"${highlightedCodeFont2}"'%s'"${highlightedCodeFont}"'%s",
						substr(codeLine,1,idx-1),
						BASH_COMMAND,
						substr(codeLine,idx+length(BASH_COMMAND)))
				# } else if (codeLine != "{") {
				# 	bgtrace("debugger:     codeLine=|"codeLine"|")
				# 	bgtrace("debugger: BASH_COMMAND=|"getNormLine(BASH_COMMAND)"|")
				}
				out[NR]=sprintf("'"${highlightedCodeFont}"'%s %s'"${codeSectionFont}${csiClrToEOL}"'",  NR, getNormLine(codeLine) )
				next
			}
			NR>=(collectStart)  { out[NR]=sprintf("%s %s'"${csiClrToEOL}"'",  NR, getNormLine($0) ) }
			NR>(endLineNo)      {exit}
			END {
				# somtimes we didnt get the the real souce so we have a short msg instead and our page was completly off the end
				if (NR < collectStart) {
					j=0
					for (i=startLineNo; i<=endLineNo; i++)
						printf("'"${csiClrToEOL}"'%s%s\n", (j==cursorLineNo)?">":" ", fullSrc[j++])
					printf "'"${csiNorm}"'"
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
				for (i=startLineNo; i<=endLineNo; i++)
					printf("'"${csiClrToEOL}"'%s%s\n", (i==cursorLineNo)?">":" ", out[i])
				printf "'"${csiNorm}"'"


				# if we had to adjust startLineNo, tell the caller by how much so it can adjust it permanently
				exit( offset )
			}
		'  $contentFile <<<"$contentStr"; local offset=$?

	# if the awk script is asked to display past the end of file, it displays the last page and returns the number of lines that it
	# had to adjust the view windo. This blocks adjusts our srcWinStartLineNoVar and srcCursorLineNoVar to match
	if [ ${offset:-0} -gt 0 ]; then
		local fileSize=$((${!srcWinStartLineNoVar} + viewLineHeight -2 - offset))
		setRef "$srcWinStartLineNoVar" $((fileSize-viewLineHeight+2))
		(( ${!srcCursorLineNoVar} >  fileSize+1 )) && setRef "$srcCursorLineNoVar" $((fileSize+1))
	fi
	printf "${csiClrToEOL}${csiNorm}"
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
	bgStackMakeLogical
	echo "===============  BASH call stack    ====================="  >$tty
	local frameNo; for ((frameNo=bgStackSize-1; frameNo>=0; frameNo--)); do
		local lineColor=""; ((frameNo==curFrameNo )) && lineColor="${highlightedFrameFont}"
		printf "${lineColor}%s${csiNorm}\n" "${bgStackLine[$frameNo]:0:$maxCols}"  >$tty
	done
	echo "===============  end of call stack  ====================="  >$tty

	printf "[%s]:" "${bgStackSrcFile[$curFrameNo]}" > $tty

	# local cline ccol; cuiGetCursor cline ccol < $tty
	# local linesLeft=$((maxLines-cline))
	# awk -v linesLeft="$linesLeft" -v focusedLineNo="${bgStackSrcLineNo[$curFrameNo]}" -v maxCols="$maxCols" '
	# 	BEGIN {startLineNo=focusedLineNo-int((linesLeft-0.1)/2); endLineNo=startLineNo+linesLeft}
	# 	NR>(endLineNo)     {exit}
	# 	NR==(focusedLineNo) { printf("\n>'"${csiYellow}"'%s %s'"${csiNorm}"'",  NR, $0 ); next }
	# 	NR>(startLineNo)    { printf("\n %s %s",  NR, $0 ) }
	# ' $(fsExpandFiles -f "${bgStackSrcFile[$curFrameNo]}")  &> $tty
}
