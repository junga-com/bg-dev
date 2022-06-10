
import bg_cuiWin.sh ;$L1;$L2

# scraps to account for...


# Since this library is meant to control a CUI Win, we can assume we have the global env to ourselves.

# Debugger Member Vars
dbgInBreak=""                     # true if the remote script is stopped in the debugger (not runing)


# usage: cuiWinCntr --class Debugger <cuiWinID> open
# usage: cuiWinCntr <cuiWinID> <cmd> [<arg1> .. <argN>]
# This implements a debugger UI in a separate terminal from the script being debugged
# Scope Vars Provided by Caller:
#    bgdCntrFile : the path of the cntr pipe file
#    winTitle    : string that will be the title of the window
function cuiWinDebuggerClassHandler()
{
	echo "starting $bgdCntrFile"
	bgDebuggerOn=""
	source /usr/lib/bg_core.sh
	import bg_cui.sh ;$L1;$L2
	import bg_debuggerCUIWin.sh ;$L1;$L2

	trap -n cuiWinDebugger '
		[ "$bgdCntrFile" ] && [ -p "$bgdCntrFile" ] && [ "$dbgScriptState" != "ended" ] && {
			echo debuggerEnding | timeout 1 tee  "$bgdCntrFile.ret" >/dev/null
		}
		rm -f "$bgdCntrFile" "$bgdCntrFile.lock" "$bgdCntrFile.ret" "$bgdCntrFile.ret.lock"
	' EXIT

	builtin trap - SIGINT

	local tty="$(tty)"
	cuiSetTitle "$winTitle $tty"

	# the proc with the createLock lock is waiting on the tty msg to signal that we are started
	tty >$bgdCntrFile

	local $(debugBreakPaint --declareVars)
	debugBreakPaint --init

	dbwinReadUserInputLoop --init

	# do the msg loop
	while true; do
		local cmd="<error>"; read -r cmd args <$bgdCntrFile
		local result=$?; (( result > 128)) && result=129
		case $result in
			0) 	;;
			129) ;;  # timeout (if we give read the -t <n> option)
			*)	bgtrace "CUIWIN($(tty)) read from bgdCntrFile exit code '$result'"
				echo "CUIWIN read from bgdCntrFile exit code '$result'"
				sleep 5
				;;
		esac
#bgtrace "WIN: received cmd on cntr pipe '$cmd' '$args'"
		Try:
		case $cmd in
			gettty) tty >$bgdCntrFile ;;
			close)  return ;;
			youUp)  echo "youBet" >$bgdCntrFile ;;
			ident)
				which pstree >/dev/null && pstree -p $$
				tty
				echo "pid='$$'  BASHPID='$BASHPID'   SHLVL='$SHLVL'  tailPID='$tailPID'"
				;;

			enterBreak)
				dbgScriptState="stopped"
				local stoppedScriptName="$args"
				dbgInBreak="1"
				dbgStackStart="$bgStackLogicalFramesStart"
				dbgStackSize=$((bgStackSize - dbgStackStart))

				debugBreakPaint
				dbwinReadUserInputLoop "[${stoppedScriptName##*/}] bgdb> "
				;;

			leaveBreak)
				dbgScriptState="running"
				dbgInBreak=""
				debugBreakPaint --leavingDebugger
				;;

			scriptEnding)
				dbgScriptState="ended"
				debugBreakPaint --scriptEnding
				dbwinReadUserInputLoop "[no script] bgdb> "
				;;

			marshalVar)
				varUnMarshalToGlobal "${args## }"
				;;

			### commands prefixed with USRCMD: are ones entered at the terminal by the user. The dbwinReadUserInputLoop function
			# runs in the background and relays the typed commands to the $bgdCntrFile so we  can process them in the global $$ scope.
			# they are all synchronous so we need to echo a reply to signal that thread that it can read the TTY again. The paint
			# alogorithms sometimes need to read the TTY to get the cursor position so we need this synchronization so there is only
			# one reader at a time

			USRCMD:stackViewSelectFrame) debugBreakPaint --stackViewSelectFrame $args; echo > "$bgdCntrFile" ;;
			USRCMD:scrollCodeView)       debugBreakPaint --scrollCodeView       $args; echo > "$bgdCntrFile" ;;

			USRCMD:emptyLine) debugBreakPaint; echo > "$bgdCntrFile" ;;

			USRCMD:dbgRun)
				eval $args
				echo > "$bgdCntrFile"
				;;

			USRCMD:*)
				dbwinEvalInTarget "${cmd#USRCMD:} $args"
				echo > "$bgdCntrFile"
				;;


			*)	echo "unknown cmd '$cmd $args' received from debugger in the script"
		esac
		Catch: && { printf "\nException caught in CUI Win Handler\n"  ;cat $assertOut; echo;  }
	done
}


function dbwinEvalInTarget()
{
	echo "$*" > "$bgdCntrFile.ret"
	while read -r -t 2 line; do
		echo "$line"
	done < "$bgdCntrFile.ret"

}

function dbwinReadUserInputLoop()
{
	local method
	while [ $# -gt 0 ]; do case $1 in
		--*) method="${1#--}" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	case ${method:-default} in
		runLoop) ;; # drop through to the main function
		stop)
			[ "$dbwinReadUserPID" ] && bgkillTree "$dbwinReadUserPID"; dbwinReadUserPID=""
			return
			;;

		init)
			declare -g dbwinReadUserPID dbwinPrompt
			trap -n dbwinReadUserInputLoop '
				kill $dbwinReadUserPID
			' EXIT
			return
			;;

		# a call with no method makes sure that a dbwinReadUserPID is running and has the current prompt
		default)
			# if any of the global vars that the loop depends on are out of date, restart it
			if [ "$1" != "$dbwinPrompt" ]; then
				dbwinPrompt="$1"
				[ "$dbwinReadUserPID" ] && bgkillTree "$dbwinReadUserPID"; dbwinReadUserPID=""
			fi

			if [ ! "$dbwinReadUserPID" ] || pidIsDone "$dbwinReadUserPID"; then
				dbwinReadUserInputLoop --runLoop <&0 &
				dbwinReadUserPID=$!
			else
				# tell it to redraw the prompt
				bgkillTree -SIGUSR1 "$dbwinReadUserPID"
			fi
			return
			;;

		*) assertError -v method "unknown method name. call like --<methodName>" ;;
	esac


	trap ": bgtrace used to wake up the read tty" SIGUSR1

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
	bgbind --shellCmd '\e[5;3~'   "dbgDoCmd scrollCodeView pgUp"        # alt-pgUp
	bgbind --shellCmd '\e[6;3~'   "dbgDoCmd scrollCodeView pgDown"      # alt-pgDown
	bgbind --shellCmd '\e[1;3H'   "dbgDoCmd scrollCodeView "            # alt-home

	# stackView navigation
	bgbind --shellCmd '\e[1;5A'   "dbgDoCmd stackViewSelectFrame +1"   # cntr-up
	bgbind --shellCmd '\e[1;5B'   "dbgDoCmd stackViewSelectFrame -1"   # cntr-down
	# bgbind --shellCmd '\e[1;5H'   "dbgDoCmd stackViewSelectFrame  0"   # cntr-home
	# bgbind --shellCmd '\e[1;5C'   "dbgDoCmd toggleStackArgs"           # cntr-left
	# bgbind --shellCmd '\e[1;5D'   "dbgDoCmd toggleStackArgs"           # cntr-right

	# read -e only does the default filename completion and ignores compSpecs. we must override <tab>
	#complete -D -o bashdefault
	#complete -A arrayvar -A builtin -A command -A function -A variable -D

	function dbgDoCmd() { printf "${csiToSOL}$dbwinPrompt${csiClrToEOL}">&0; echo " $*"; exit; }

	# we want to be able to handle the cmds generated by key mappings the same as those entered by the
	# user but we don't want those to show up like commands actually entered -- no scrolling the cmd area.
	# But There seems to be no way to get bind to accept the command without sending a linefeed to the tty.
	# This pattern makes it so anything written to std out in the () sub shell will be the collected
	# command. (note that readline echos typed chars to the tty identified by stdin). Our dbgDoCmd
	# echos the cmd it wants and then ends the subshell with exit so readline does not get a chance to
	# send a linefeed. Normally typed cmds entered by the user pressing <enter> will be collected in 's'
	# and readline will send a linefeed and then we echo s to stdout.
	local dbgResult dbgDone; while [ ! "$dbgDone" ]; do   #  && [ ${dbgResult:-0} -eq 0 ]

		stty echo
		history -r ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history

		local dbgCmdlineValue; dbgCmdlineValue="$(
			printf "${csiToSOL}$dbwinPrompt${csiClrToEOL}" >&0
			cuiShowCursor

			read -e s || exit
			echo "$s"
		)"; dbgResult=$?

		stty -echo; cuiHideCursor
		# only put cmds that the user typed into the history. The commands from dbgDoCmd macro have leading spaces.
		([[ ! "$dbgCmdlineValue" =~ ^[[:space:]] ]]) && { history -s "$dbgCmdlineValue"; history -a ${bgdbCntrFile:-.bglocal/${bgTermID:-$$}}.history; }
		dbgCmdlineValue="${dbgCmdlineValue## }"

		# parse the dbgCmd
		local dbgCmd="${dbgCmdlineValue%%[; ]*}"
		local dbgArgs="${dbgCmdlineValue#$dbgCmd}"

		case ${dbgCmd:-emptyLine} in
			# CRITICALTODO: need to get read lock on the pipe to make sure another client is not reading a return value at this moment
			*)	echo "USRCMD:${dbgCmdlineValue:-emptyLine}" > "$bgdCntrFile"
				read -r syncReply < "$bgdCntrFile"
				;;
		esac
	done
	return $result
}


# View Member Vars

function debugBreakPaint()
{
	local method; ([[ "$1" =~ ^-- ]]) && { method="$1"; shift; }

	case $method in
		--declareVars)
			# these are the varnames of our 'member vars' that will be declared at the caller's scope
			# so that they will be persistent each time that scope calls this function
			echo "
				stackViewCurFrame stackViewLastFrame stackArgFlag stackViewStartLine stackViewEndLine
				codeViewSrcWinStart
				codeViewSrcCursor codeViewOffsetsByStackFrame codeViewStartLine codeViewEndLine
				cmdViewStartLine cmdViewEndLine cmdAreaSize
			"
			return
			;;
		--init)
			# construction. init the member vars
			stackViewCurFrame=0
			stackViewLastFrame=-1
			stackArgFlag="argValues"
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
			cuiMoveTo $((maxLines-1)) 1
			return
			;;

		--scriptEnding)
			local maxLines maxCols; cuiGetScreenDimension maxLines maxCols
			cuiMoveTo $((maxLines)) 1
			printf "${csiClrToEOL}${csiBlack}${csiBkYellow}  script ended. press cntr-c to close this terminal or restart a script to debug in the other terminal${csiNorm}${csiClrToEOL}"
			cuiMoveTo $((maxLines-1)) 1
			return
			;;

		# scroll the code view section up(-n) or down(+n)
		# note that we don't have to to clip is to start/end bounds of the file because the codeView
		# will clip it and update this value so that each cycle it will start in bounds.
		# default value. view will center the focused line
		--scrollCodeView)
		 	case ${1:-empty} in
				empty) codeViewSrcCursor="" ;;
				[0-9]*) ((codeViewSrcCursor+=$1)) ;;
				pgUp)   ((codeViewSrcCursor-=$dbgPgSize)) ;;
				pgDown) ((codeViewSrcCursor+=$dbgPgSize)) ;;
			esac
			;;

		# change the selected stack frame up(-1) or down(+1)
		--stackViewSelectFrame)
			case ${1:-0} in
				[+-]*) (( stackViewCurFrame+=${1:- 1} )) ;;
				*)     stackViewCurFrame="$1" ;;
			esac; shift
			(( stackViewCurFrame < 0 )) && stackViewCurFrame=0
			(( stackViewCurFrame > dbgStackSize-1 )) && stackViewCurFrame="$((dbgStackSize-1))"
			;;

		--toggleStackArgs) stackArgFlag="$(varToggle "$stackArgFlag"  argValues srcCode)" ;;
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
	debuggerPaintStack --maxWinHeight $((maxLines*7/20)) --linesWrittenVar stackViewEndLine "$stackViewCurFrame" "$stackArgFlag"
	#cuiGetCursor stackViewEndLine


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

	debuggerPaintCodeView \
		"${bgStackSrcFile[$((stackViewCurFrame+dbgStackStart))]}" \
		codeViewSrcWinStart \
		codeViewSrcCursor \
		"${bgStackSrcLineNo[$((stackViewCurFrame+dbgStackStart))]}" \
		"$((codeViewEndLine - codeViewStartLine))" "$codeViewWidth" \
		"${bgStackFunction[$((stackViewCurFrame+dbgStackStart))]}"

	### Cmd Area Section
	cmdViewStartLine="$codeViewEndLine"
	cmdViewEndLine="$((maxLines+1))" # (*ViewEndLines are all one past the last line in that region)

	# write the status/help line on the last line
	# TODO: use dbgScriptState to indicate more -- see also --leavingDebugger/--scriptEnding these status
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
	#cuiShowCursor

	bgBASH_debugViewWin="${codeViewSrcWinStart:-0}"
}

# usage: debuggerPaintStack <highlightedFrameNo> <stackArgFlag>
# Paint the current logical stack to stdout which is assumed to be a tty used in the context of debugging
# Params:
#     <highlightedFrameNo>  : if specified, the line corresponding to this stack frame number will be highlighted
# Options:
#    --maxWinHeight <numLinesHigh> : constrain the window to be at most this many lines tall
function debuggerPaintStack()
{
	local maxWinHeight=9999 linesWrittenVar
	while [ $# -gt 0 ]; do case $1 in
		--maxWinHeight*)      bgOptionGetOpt val: maxWinHeight "$@" && shift ;;
		--linesWrittenVar*)   bgOptionGetOpt val: linesWrittenVar "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local highlightedFrameNo="${1:-0}"
	local stackArgFlag="${2:-"argValues"}"

	local framesToDisplay=$(( (dbgStackSize+2 <= maxWinHeight)?dbgStackSize:(maxWinHeight-2) ))
	local framesStart=$(( (highlightedFrameNo < framesToDisplay)?0:(highlightedFrameNo-framesToDisplay+1) ))
	local framesEnd=$((   framesStart+framesToDisplay ))

	if (( framesStart > 0 )); then
		printf "${csiClrToEOL}-------------  ... $((framesStart)) frames above  ---------------------\n"
	else
		printf "${csiClrToEOL}===============  BASH call stack    =====================\n"
	fi

	local highlightedFrameFont="${_CSI}48;2;62;62;62;38;2;210;210;210m"
#	local frameNo; for ((frameNo=framesStart; frameNo<framesEnd; frameNo++)); do
	local frameNo; for ((frameNo=framesEnd-1; frameNo>=framesStart; frameNo--)); do
		local bashStkFrm=""; [ "$stackArgFlag" != "argValues" ] && bashStkFrm="${bgStackBashStkFrm[$frameNo+dbgStackStart]}"
		local lineColor=""; ((frameNo==highlightedFrameNo )) && lineColor="${highlightedFrameFont}"
		local stackFrameLine="${bgStackLineWithSimpleCmd[$frameNo+dbgStackStart]}"; # [ "$stackArgFlag" != "argValues" ] && stackFrameLine="${bgStackLine[$frameNo+dbgStackStart]}"
		printf "${lineColor}${csiClrToEOL}${lineColor}%s %-85s %s${csiNorm}\n"  "${bgStackFrameType[$frameNo+dbgStackStart]}"  "${stackFrameLine/$'\n'*/...}" "$bashStkFrm"  #| sed 's/^\(.\{1,'"$maxCols"'\}\).*$/\1/'
	done
	if (( framesEnd < dbgStackSize )); then
		printf "${csiClrToEOL}-------------  ... $((dbgStackSize-framesEnd)) frames below  ---------------------\n"
	else
		printf "${csiClrToEOL}===============  end of call stack  =====================\n"
	fi
	returnValue "$linesWrittenVar" "$((framesToDisplay+2))"
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
		varOutput -R "$srcCursorLineNoVar"    "$((srcFocusedLineNo))"
		varOutput -R "$srcWinStartLineNoVar"  "$(( (srcFocusedLineNo-viewLineHeight*9/20 >0)?(srcFocusedLineNo-viewLineHeight*9/20):1))"
	fi

	# user cursor can not be moved less than 1
	(( ${!srcCursorLineNoVar} <  1 )) && varOutput -R "$srcCursorLineNoVar" 	"1"

	# scroll the viewport up or down if needed based on where the cursor is
	(( ${!srcCursorLineNoVar} < ${!srcWinStartLineNoVar} )) && varOutput -R "$srcWinStartLineNoVar" "${!srcCursorLineNoVar}"
	(( ${!srcCursorLineNoVar} > (${!srcWinStartLineNoVar} + viewLineHeight -1) )) && varOutput -R "$srcWinStartLineNoVar" "$((${!srcCursorLineNoVar} - viewLineHeight+1))"

	local simpleCommand="${BASH_COMMAND}"

	# typically we are displaying a real src file but if its a TRAP, we get the text of the handler and display it
	local contentStr contentFile
	if [[ "$srcFile" =~ ^\<TRAP:([^>]*)\> ]]; then
		signal="${BASH_REMATCH[1]}"
		if [[ "$signal" =~ DEBUG$ ]]; then
			contentStr="$(dbwinEvalInTarget builtin trap -p $signal)"
			contentStr="${contentStr#*\'}"
			contentStr="${contentStr%\'*}"
			contentStr="${contentStr//"'\''"/\'}"
			[ ! "$contentStr" ] && contentStr="DEBUG handler script is not available. Its common practive to clear the DEBUG trap in the trap"
			contentFile="-"
		elif [[ "$signal" =~ USR2$ ]] && [ "$bgBASH_tryStackPID" ]; then
			contentStr="$(dbwinEvalInTarget 'bgTrapStack peek "USR2"')"
			contentFile="-"
		elif [[ "$signal" =~ ' ' ]]; then
			contentStr='
				We could not determine which TRAP handler is being ran.
				Often this will resolve itself after the next step.
				The text of each of the signal handlers that might be it
				apear below.

			'
			contentStr+=$'\n'"$(dbwinEvalInTarget builtin trap -p $signal)"

		else
			contentStr="$(dbwinEvalInTarget builtin trap -p $signal)"
			contentStr="${contentStr#*\'}"
			contentStr="${contentStr%\'*}"
			contentStr="${contentStr//"'\''"/\'}"
			contentFile="-"
		fi

	elif [[ "$srcFile" =~ ^\<bash:([0-9]*)\> ]]; then
		# when bg_core.sh is sourced some top level, global code records the cmd line that invoked in bgLibExecCmd
		local v simpleCommand=""
		for (( v=0; v <=${#bgLibExecCmd[@]}; v++ )); do
			local quotes=""; [[ "${bgLibExecCmd[v]}" =~ [[:space:]] ]] && quotes="'"
			simpleCommand+=" ${quotes}${bgLibExecCmd[v]}${quotes}"
		done
		contentStr="$USER@$HOSTNAME:$PWD\$ ${simpleCommand}"$'\n\n'
		contentStr+=$(dbwinEvalInTarget 'ps --forest $$')$'\n\n'
		contentStr+=$(dbwinEvalInTarget 'pstree -psa $$')
		contentFile="-"

	else
		contentStr=""
		contentFile="$(fsExpandFiles -f "$srcFile")"
	fi

	# this awk script paints the file area in one pass. Its ok to ask it to scroll down too far -- it will stop of the last page.
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
		varOutput -R "$srcWinStartLineNoVar" $((fileSize-viewLineHeight+2))
		(( ${!srcCursorLineNoVar} >  fileSize+1 )) && varOutput -R "$srcCursorLineNoVar" $((fileSize+1))
	fi
	printf "${csiClrToEOL}${csiNorm}"
}
