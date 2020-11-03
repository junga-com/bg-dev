#!/bin/bash

# TODO: factor debuggerOn out of the Impl files, move this into debuggerOn, make it like a loadable driver
# if [ "$bgUseNewDebugger" ]; then
# 	import bg_debuggerRemoteImpl.sh ;$L1;$L2
# 	bgUseNewDebugger=""
# else
# 	import bg_debuggerIntegratedImpl.sh ;$L1;$L2
# fi


# Library bg_debugger.sh
# This library provides an interactive debugger for stepping through and examining the state of scripts
# that source /usr/lib/bg_core.sh.
#
# This library is not typically loaded by default. bgtraceBreak and the bg-debugCntr will cause it and the selected driver library
# to be loaded on demand only when debugging is asked for by the user using one of those features.
#
# The debugger code that is embedded in a script is implemented as a driver mechanism. The bg_debugger.sh library contains the code
# that is common to all drivers. The code that is specific to a particular driver is dynamically loaded in a library named
# bg_debugger_<driverID>.sh. At the time of this writing, there are two drivers 'integrated' and 'remote'
#
# Debugger Interfaace:
#    debuggerOn        : connect a debugger to this script
#         Note that debuggerOn is not typically called directly. See man(3) bgtraceBreak and man(1) 'bg-debugCntr debugger on|off|status'
#    debugOff          : disconnect the debugger from this script.
#    debuggerIsActive  : is a debugger connected to the running script?    Note: this can be called when the bg_debugger is not loaded
#    debuggerIsInBreak : is the script currently stopped in the debugger?  Note: this can be called when the bg_debugger is not loaded
#
# See Also:
#    man(3) bgtraceBreak
#    man(1) 'bg-debugCntr debugger on|off|status'


# function debuggerIsActive() moved to bg_libCore.sh
# function debuggerIsInBreak() moved to bg_libCore.sh


# usage: debuggerOn <dbgID> [firstLine|libInit]
# active the interactive debugger. This debugger requires that the target script source /usr/lib/bg_core.sh. You typically do not
# call debuggerOn directly in a script. There are three patterns that result in this function being called to activate the debugger.
#
# First, you can use the bgtraceBreak function to cause that line in the script to stop in the debugger, activating the debugger
# if needed. When the debugger is already active, bgtraceBreak bypasses this function and calls debugSetTrap. You can pass the dbgID
# through bgtraceBreak or more commonly, rely on the default dbgID set for that terminal with bg-debugCntr.
#
# The second way is to enable the debugger with the 'bg-debugCntr debugger on[:<dbgID>]' which will cause any script that runs in
# that terminal to automaticaly stop in the debugger right after the line that sources bg_core.sh
#
# The third way is to press cntr-c while a stript is running. This is usefull if the script is in an infinite loop. Activating bgtracing
# installs a SIGINT signal handler that will check to see if the script is already stopped in a debugger and invoke bgtraceBreak if not
# and exit the script like normal if it is.
#
#
# Debugger Implementation Drivers:
# The bg_debugger.sh library provides the common interface to the debugger and depending on the environment variable 'bgUseNewDebugger',
# it will source one of the two implementations. At the time of this writing there are two implementations and that might be all
# that is needed. Eventually it is expected that the <dbgID> param will grow in syntax and the implementation will be choosen
# automatically based on it.
#
# Original Terminal Driven Implentation:
# The original run the debugger code in the target script's process and only needs a tty to read and write to. The default <dbgID>
# in 'win' which uses bg_cuiWin.sh to a new terminal window associated with the bash terminal that you are working in and uses the
# /dev/pts/<n> for that window as the actual terminal device. If you create a terminal device in another way you can pass that in
# and the debugger UI will use it.
#
# This implementation is very stable and fast.
#
# New Pipe Oriented Implementation:
# The second implementation still uses cuiWin to create a second terminal but it puts the debugger code in that separate terminal
# process and leaves just a stub of the debugger in the target script's process. It uses two FIFO pipes to communicate between the
# two. The advantage of this implement is that the remote part could be anything including a GUI application or a integration with
# an IDE.  The cuiWin Remote uses the same cUI code from the first implementation so they look identical. There is a bit more
# latency in the remote version since on each break, the stack data structures have to be marshaled over the pipe but its not too
# bad.
#
# The next step will be to write a plugin for the IDE I use, atom, that uses the same stub/pipe implementation. The debugger stub
# the side of the pipes that live within the script being debugged. The UI end of the pipes are not in the same process so they don't
# have to be written in bash even though the first one happens to be because a debugger UI already existed in bash.
#
#
# Params:
#    <dbgID> : The syntax for <dbgID> is <driver>:<driverSpecificID>. At the time of this writing, there are two drivers, 'integrated'
#              and 'remote'. See the debuggerOnImpl man page in the
#
#    firstLine|libInit : default is firstLine. This determines whether the debugger will break immediately
#          upon initiallization so that the user can step through the library initialization code or
#          whether it will break on the the first line of the invoked script
# Options:
#    --logicalStart+<n>  : this adjusts where the debugger should stop in the script. By default it will stop at the line of code
#                          immediately following the debuggerOn call. However, if debuggerOn is called in another library function
#                          it might not want to stop inside that function but instead at the line following whatever called it.
#                          <n> represents the number of functions to skip. +1 means go up one function from where debuggerOn is
#                          called.
# See Also:
#    debuggerOff   : releases the connection between the script and the active debugger. It can be reconnected with debuggerOn.
#    bgtraceBreak  : this will call debuggerOn if a debugger is not already active in hte script
#    debuggerIsActive : reports on the debuggerOn / debuggerOff state
#    debuggerIsInBreak : reports if the script's process is currently stopped in the debugger. A DEBUF trap is active and the only
#                   running code is the debugger
function debuggerOn()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35

	local logicalFrameStart=1
	while [ $# -gt 0 ]; do case $1 in
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local dbgID="${1:-integrated:win}"; shift

	[[ ! "$dbgID" =~ : ]] && dbgID="integrated:${dbgID}"

	local driverID="${dbgID%%:*}"
	local driverSpecificID="${dbgID#*:}"

	import bg_debugger_${driverID}.sh ;$L1;$L2 || assertError -v dbgID -v driverID -v driverSpecificID "unknown debugger driver"

	${driverID}Debugger_debuggerOn "$driverSpecificID"

	shopt -s extdebug
	set -o functrace # redundant. extdebug included it
	# extdebug turns this on but our debugger does not use ERR traps and unit tests need errtrace off, so turn it back off
	set +o errtrace

	# set a EXIT trap to give the debugger a chance to clean up and change its view to indicate that the script has ended.
	trap -n debuggerOn '_debugEnterDebugger scriptEnding' EXIT

	bgtrace "Debugger started. on '$bgdbtty' for script $(basename $0)($$) using dbgID '${dbgID:-win}'"

	debugSetTrap --logicalStart+${logicalFrameStart:-1} "$@"
}


# usage: debugSetTrap <stepType> [<optionsForStepType>]
# This sets the DEBUG trap with a particular condition for when it will call _debugEnterDebugger
#
# Function Depth:
# The step conditions operate on the function depth that the script is executing at. The depth is represented by the number of
# elements in the BASH_SOURCE array.
#
# If bgBASH_funcDepthDEBUG is set, this function uses it as the target source frame that step and skip commands should be relative to.
# bgBASH_funcDepthDEBUG is only set by the DEBUG trap handler so when this function is used to start the debugger, it is not available.
# In those cases the --logicalFrameStart option is used to determine how many functions on the stack above this call should be ignored.
# The target source will be the current stack depth that this function is running at minus the value of the --logicalFrameStart
# option.
#
# Params:
#    <stepType> : this defines the condition that will be embeded in the trap function.
#       stepIn|step         : break on the next time the DEBUG trap is called. This will descend into a bash function call
#       stepOver            : break when the functionDepth is equal to the current logical funcDepth which should be the line after
#                             the current line. This will step over a bash function call
#       stepOut             : break when the functionDepth is equal to 1 minus the current logical funcDepth which should be the
#                             line after the current function returns.
#       skipOver|skipOut    : similar to the stepOver and stepOut commands except that the current BASH_COMMAND and subsequent
#                             BASH_COMMANDs until the break are not excecuted.
#       stepToLevel <level> : break on the next line whose stack depth is <level>. stepToLevel 1 would go to the top level script
#                             code
#       stepToCursor        : break when the functionDepth is equal to the current logical funcDepth and the LINENO is greater than
#                             or equal to codeViewSrcCursor. codeViewSrcCursor is a variable that should be in scope from the caller
#       resume              : dont set a DEBUG trap. Let the code run until it either ends or it executes a bgtraceBreak that will
#                             call us to set a new DEBUG trap
# Options:
#    --logicalStart+<n>  : This is only observed when not being called from the DEBUG trap handler (when bgBASH_funcDepthDEBUG is not set)
#                          This adjusts where the step* and skip* commands are relative to in the stack. Functions that call this
#                          function should also support this --logicalFrameStart function and pass its value on by using this option
#                          when calling debugSetTrap
function debugSetTrap()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35

	local currentReturnAction=0 futureNonMatchReturnAction=0 breakCondition="true"  logicalFrameStart=2
	while [ $# -gt 0 ]; do case $1 in
		--futureNonMatchReturnAction*) bgOptionGetOpt val: futureNonMatchReturnAction "$@" && shift ;;
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local stepType="$1"; shift

	# when called by the DEBUG trap, bgBASH_funcDepthDEBUG is set to indicate the code being debugged.
	# when called by something that starts the debugger (debuggerOn or bgtraceBreak, typically) they use --logicalStart+1 pattern
	# to some up all the calles between the script code and here.
	local scriptFuncDepth="${bgBASH_funcDepthDEBUG:-$(( ${#BASH_SOURCE[@]} - logicalFrameStart ))}"

	case $stepType in
		stepIn|step)  breakCondition="true" ;;                                                      # F5
		stepOver)     breakCondition='[ ${#BASH_SOURCE[@]} -le '"${scriptFuncDepth}"' ]' ;;         # F6
		stepOut)                                                                                    # F7
			if [ "$bgBASH_trapStkFrm_funcDepth" == "$scriptFuncDepth" ]; then
				# if we are in the top level of a trap handler its at the same funDepth as the function it interupted so we need to
				# stop at the same level but after the trap is finished
				breakCondition='[ ! "$bgBASH_trapStkFrm_funcDepth" ] && [ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}))"' ]'
			else
				breakCondition='[ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}-1))"' ]'
			fi
			;;
		skipOver)     breakCondition="true"; currentReturnAction=1 ;;                               # shift-F6
		skipOut)      breakCondition="true"; currentReturnAction=2 ;;                               # shift-F7
		stepToCursor)                                                                               # F8
			breakCondition='[ "${BASH_SOURCE[0]}" == "'"${bgStackSrcFile[$((stackViewCurFrame+dbgStackStart))]}"'"  ] && [ ${bgBASH_debugTrapLINENO:-0} -ge '"${codeViewSrcCursor:-0}"' ]'
			;;
		stepToLevel)
			local stepToLevel="$1"
			if ([[ "$stepToLevel" =~ ^[+-] ]]); then
				local op=${stepToLevel:0:1}; stepToLevel="${$stepToLevel:1}"
				((stepToLevel = scriptFuncDepth $op stepToLevel ))
			fi
			breakCondition='[ ${#BASH_SOURCE[@]} -eq '"$stepToLevel"' ]'
			;;
		#stepToScript) breakCondition='[ ${#BASH_SOURCE[@]} -eq 1 ]' ;;
		# 2020-11 changed "trap -" to "trap ''" b/c resume was acting like step when debugging unit test
		resume)       builtin trap '' DEBUG; return ;;
	esac

	bgBASH_debugSkipCount=0
	builtin trap '
		bgBASH_debugTrapLINENO=$((LINENO-1))
		bgBASH_debugTrapFUNCNAME=$FUNCNAME
		if '"$breakCondition"'; then
			bgBASH_debugTrapResults=0
			bgBASH_debugArgv=("$@")
			bgBASH_funcDepthDEBUG=${#BASH_SOURCE[@]}
			bgBASH_debugIFS="$IFS"; IFS=$'\'' \t\n'\''

			# integrate with the unit test debugtrap _ut_debugTrap filters based on bgBASH_debugTrapFUNCNAME
			[ "$_utRun_debugHandlerHack" ] && _ut_debugTrap

			_debugEnterDebugger "!DEBUG-852!"; bgBASH_debugTrapResults="$?"
			if ((bgBASH_debugTrapResults < 0 || bgBASH_debugTrapResults > 2)); then
				builtin trap - DEBUG
				bgBASH_debugTrapResults=0
			fi

			IFS="$bgBASH_debugIFS"; unset bgBASH_debugIFS
			unset bgBASH_debugTrapLINENO bgBASH_funcDepthDEBUG
		else
			bgBASH_debugTrapResults=0
		fi
		[ $bgBASH_debugTrapResults -gt 0 ] && { echo "############# SKIPPING exitcode=|$bgBASH_debugTrapResults| BASH_COMMAND=|$BASH_COMMAND|  breakCondition='"$breakCondition"'" >> /tmp/bgtrace.out; }
		setExitCode $bgBASH_debugTrapResults
	' DEBUG
	unset bgBASH_funcDepthDEBUG
	return $currentReturnAction
}



# usage: debugBreakAtFunction <functionNameSpec>
function debugBreakAtFunction()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35

	declare -gA bgBASH_debugBPInfo
	local functionNameSpec="$1"; shift

	local functionNames functionName; while IFS="" read -r functionName; do
		functionNames+=("$functionName")
	done < <(declare -F | awk '$3~/'^"$functionNameSpec"'$/ {print $3}')

	[ ${#functionNames[@]} -eq 0 ] && { assertError -c -v functionNameSpec "no functions found matching this spec"; return; }

	for functionName in "${functionNames[@]}"; do
		# get the information on this function
		local origFile origLineNo; bgStackGetFunctionLocation "$functionName" origFile origLineNo
		local functionText="$(awk -v origLineNo="$origLineNo" '
			# detect the function <name>() line and start recording
			NR==origLineNo {
				inFunc="1"
			}

			# identify and install the function start breakpoint
			NR==(origLineNo+1) {
				if ($0 !~ /^{[[:space:]]*$/) {
					error=1; exit
				}
				print $0" bgtraceBreak "
				next
			}

			# pass the lines through to the output while inFunc is true
			inFunc {print $0}

			# detect the ending '}'. We rely on the function braces being in column 1 (for now)
			/^}[[:space:]]*$/ {
				error=0; exit
			}

			END {
				exit error
			}
		' "$origFile")"

		# source the modified function
		eval "$functionText"
		local newLineNo="$((LINENO-1))"  # -1 to refer to the line before this one which will corespond to the "function <name>()" line.

		# record the srcFile:srcLineno mapping for the bgStackMakeLogical function to use
		bgBASH_debugBPInfo["$functionName"]="$origLineNo $newLineNo $origFile"

		echo "breakpoint install at start of '$functionName'"
#bgtraceVars "" functionText  "  " functionName origLineNo newLineNo origFile bgBASH_debugBPInfo
	done
}
