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
	set -- "${bgBASH_debugArgv[@]}"

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



### 2020-11 found this appearently dupe function and commented it out. Its in the bg_debugger.sh library now and does not seem to be any different for remote
# # usage: _debugSetTrap <stepType> [<optionsForStepType>]
# # This sets the DEBUG trap with a particular condition for when it will call _debugEnterDebugger
# #
# # Function Depth:
# # The step conditions operate on the function depth that the script is executing at. The depth is represented by the number of
# # elements in the BASH_SOURCE array.
# #
# # If bgBASH_funcDepthDEBUG is set, this function uses it as the target source frame that step and skip commands should be relative to.
# # bgBASH_funcDepthDEBUG is only set by the DEBUG trap handler so when this function is used to start the debugger, it is not available.
# # In those cases the --logicalFrameStart option is used to determine how many functions on the stack above this call should be ignored.
# # The target source will be the current stack depth that this function is running at minus the value of the --logicalFrameStart
# # option.
# #
# # Params:
# #    <stepType> : this defines the condition that will be embeded in the trap function.
# #       stepIn|step         : break on the next time the DEBUG trap is called. This will descend into a bash function call
# #       stepOver            : break when the functionDepth is equal to the current logical funcDepth which should be the line after
# #                             the current line. This will step over a bash function call
# #       stepOut             : break when the functionDepth is equal to 1 minus the current logical funcDepth which should be the
# #                             line after the current function returns.
# #       skipOver|skipOut    : similar to the stepOver and stepOut commands except that the current BASH_COMMAND and subsequent
# #                             BASH_COMMANDs until the break are not excecuted.
# #       stepToLevel <level> : break on the next line whose stack depth is <level>. stepToLevel 1 would go to the top level script
# #                             code
# #       stepToCursor        : break when the functionDepth is equal to the current logical funcDepth and the LINENO is greater than
# #                             or equal to codeViewSrcCursor. codeViewSrcCursor is a variable that should be in scope from the caller
# #       resume              : dont set a DEBUG trap. Let the code run until it either ends or it executes a bgtraceBreak that will
# #                             call us to set a new DEBUG trap
# # Options:
# #    --logicalStart+<n>  : This is only observed when not being called from the DEBUG trap handler (when bgBASH_funcDepthDEBUG is not set)
# #                          This adjusts where the step* and skip* commands are relative to in the stack. Functions that call this
# #                          function should also support this --logicalFrameStart function and pass its value on by using this option
# #                          when calling _debugSetTrap
# function _debugSetTrap()
# {
# 	[ "$bgDevModeUnsecureAllowed" ] || return 35
#
# 	local currentReturnAction=0 futureNonMatchReturnAction=0 breakCondition="true"  logicalFrameStart=2
# 	while [ $# -gt 0 ]; do case $1 in
# 		--futureNonMatchReturnAction*) bgOptionGetOpt val: futureNonMatchReturnAction "$@" && shift ;;
# 		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
# 		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
# 	done
# 	local stepType="$1"; shift
#
# 	# when called by the DEBUG trap, bgBASH_funcDepthDEBUG is set to indicate the code being debugged.
# 	# when called by something that starts the debugger (debuggerOn or bgtraceBreak, typically) they use --logicalStart+1 pattern
# 	# to some up all the calles between the script code and here.
# 	local scriptFuncDepth="${bgBASH_funcDepthDEBUG:-$(( ${#BASH_SOURCE[@]} - logicalFrameStart ))}"
#
# 	case $stepType in
# 		stepIn|step)  breakCondition="true" ;;                                                      # F5
# 		stepOver)     breakCondition='[ ${#BASH_SOURCE[@]} -le '"${scriptFuncDepth}"' ]' ;;         # F6
# 		stepOut)                                                                                    # F7
# 			if [ "$bgBASH_trapStkFrm_funcDepth" == "$scriptFuncDepth" ]; then
# 				# if we are in the top level of a trap handler its at the same funDepth as the function it interupted so we need to
# 				# stop at the same level but after the trap is finished
# 				breakCondition='[ ! "$bgBASH_trapStkFrm_funcDepth" ] && [ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}))"' ]'
# 			else
# 				breakCondition='[ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}-1))"' ]'
# 			fi
# 			;;
# 		skipOver)     breakCondition="true"; currentReturnAction=1 ;;                               # shift-F6
# 		skipOut)      breakCondition="true"; currentReturnAction=2 ;;                               # shift-F7
# 		stepToCursor)                                                                               # F8
# 			breakCondition='[ "${BASH_SOURCE[0]}" == "'"${bgStackSrcFile[$((stackViewCurFrame+dbgStackStart))]}"'"  ] && [ ${bgBASH_debugTrapLINENO:-0} -ge '"${codeViewSrcCursor:-0}"' ]'
# 			;;
# 		stepToLevel)
# 			local stepToLevel="$1"
# 			if ([[ "$stepToLevel" =~ ^[+-] ]]); then
# 				local op=${stepToLevel:0:1}; stepToLevel="${$stepToLevel:1}"
# 				((stepToLevel = scriptFuncDepth $op stepToLevel ))
# 			fi
# 			breakCondition='[ ${#BASH_SOURCE[@]} -eq '"$stepToLevel"' ]'
# 			;;
# 		#stepToScript) breakCondition='[ ${#BASH_SOURCE[@]} -eq 1 ]' ;;
# 		# 2020-11 changed "trap -" to "trap ''" b/c resume was acting like step when debugging unit test
# 		resume)       builtin trap '' DEBUG; return ;;
# 	esac
#
# 	bgBASH_debugSkipCount=0
# 	builtin trap '
# 		bgBASH_debugTrapLINENO=$((LINENO-1))
# 		bgBASH_debugTrapFUNCNAME=$FUNCNAME
# 		if '"$breakCondition"'; then
# 			bgBASH_debugTrapResults=0
# 			bgBASH_debugArgv=("$@")
# 			bgBASH_funcDepthDEBUG=${#BASH_SOURCE[@]}
# 			bgBASH_debugIFS="$IFS"; IFS=$'\'' \t\n'\''
#
# 			# integrate with the unit test debugtrap _ut_debugTrap filters based on bgBASH_debugTrapFUNCNAME
# 			[ "$_utRun_debugHandlerHack" ] && _ut_debugTrap
#
# 			_debugEnterDebugger "!DEBUG-852!"; bgBASH_debugTrapResults="$?"
# 			if ((bgBASH_debugTrapResults < 0 || bgBASH_debugTrapResults > 2)); then
# 				builtin trap - DEBUG
# 				bgBASH_debugTrapResults=0
# 			fi
#
# 			IFS="$bgBASH_debugIFS"; unset bgBASH_debugIFS
# 			unset bgBASH_debugTrapLINENO bgBASH_funcDepthDEBUG
# 		else
# 			bgBASH_debugTrapResults=0
# 		fi
# 		[ $bgBASH_debugTrapResults -gt 0 ] && { echo "############# SKIPPING exitcode=|$bgBASH_debugTrapResults| BASH_COMMAND=|$BASH_COMMAND|  breakCondition='"$breakCondition"'" >> /tmp/bgtrace.out; }
# 		setExitCode $bgBASH_debugTrapResults
# 	' DEBUG
# 	unset bgBASH_funcDepthDEBUG
# 	return $currentReturnAction
# }




### 2020-11 found this appearently dupe function and commented it out. Its in the bg_debugger.sh library now and does not seem to be any different for remote
# # usage: debugBreakAtFunction <functionNameSpec>
# function debugBreakAtFunction()
# {
# 	[ "$bgDevModeUnsecureAllowed" ] || return 35
#
# 	declare -gA bgBASH_debugBPInfo
# 	local functionNameSpec="$1"; shift
#
# 	local functionNames functionName; while IFS="" read -r functionName; do
# 		functionNames+=("$functionName")
# 	done < <(declare -F | awk '$3~/'^"$functionNameSpec"'$/ {print $3}')
#
# 	[ ${#functionNames[@]} -eq 0 ] && { assertError -c -v functionNameSpec "no functions found matching this spec"; return; }
#
# 	for functionName in "${functionNames[@]}"; do
# 		# get the information on this function
# 		local origFile origLineNo; bgStackGetFunctionLocation "$functionName" origFile origLineNo
# 		local functionText="$(awk -v origLineNo="$origLineNo" '
# 			# detect the function <name>() line and start recording
# 			NR==origLineNo {
# 				inFunc="1"
# 			}
#
# 			# identify and install the function start breakpoint
# 			NR==(origLineNo+1) {
# 				if ($0 !~ /^{[[:space:]]*$/) {
# 					error=1; exit
# 				}
# 				print $0" bgtraceBreak "
# 				next
# 			}
#
# 			# pass the lines through to the output while inFunc is true
# 			inFunc {print $0}
#
# 			# detect the ending '}'. We rely on the function braces being in column 1 (for now)
# 			/^}[[:space:]]*$/ {
# 				error=0; exit
# 			}
#
# 			END {
# 				exit error
# 			}
# 		' "$origFile")"
#
# 		# source the modified function
# 		eval "$functionText"
# 		local newLineNo="$((LINENO-1))"  # -1 to refer to the line before this one which will corespond to the "function <name>()" line.
#
# 		# record the srcFile:srcLineno mapping for the bgStackMakeLogical function to use
# 		bgBASH_debugBPInfo["$functionName"]="$origLineNo $newLineNo $origFile"
#
# 		echo "breakpoint install at start of '$functionName'"
# #bgtraceVars "" functionText  "  " functionName origLineNo newLineNo origFile bgBASH_debugBPInfo
# 	done
# }
