#!/bin/bash


# Library bg_debugger.sh
# This library provides an interactive debugger for stepping through and examining the state of bash scripts
#
# This library is not typically loaded by default or explicitly. bgtraceBreak and the configuration set by bg-debugCntr will cause
# it and the selected driver library to be loaded on demand only when debugger is invoked by one of those features and the the host
# environment allows it.
#
# This library contains only the core components that is required to manage a DEBUG trap handler that monitors execution and enters
# the deugger when the specified condition is met.
#
# The rest of the debugger code that is embedded in a script is implemented as a driver mechanism. The code that is specific to a
# particular driver is dynamically loaded in a library named bg_debugger_<driverID>.sh. At the time of this writing, there are two
# drivers 'integrated' and 'remote'. Which driver gets loaded is determined by the bgDebuggerDestination=<driverName>:<driverParam>
# ENV variable which is typically configured by bg_debugCntr.
#
# Debugger API:
#    debuggerOn        : load the debugger into the script and set the initial break condition.
#    debugOff          : disconnect the debugger from this script.
#    debuggerIsActive  : is a debugger connected to the running script?    Note: this can be called when the bg_debugger is not loaded
#    debuggerIsInBreak : is the script currently stopped in the debugger?  Note: this can be called when the bg_debugger is not loaded
#    bgtraceBreak      : when inserted into a script, it will invoke the debugger and stop at the next line of code.
#    debugBreakAtFunction: dynamically patch a loaded function to insert a bgtraceBreak statement
#    bg-debugCntr      : external command that configures the debugger environment
#
# See Also:
#    man(3) bgtraceBreak
#    man(1) bg-debugCntr-debugger


# function debuggerIsActive() moved to bg_libCore.sh
# function debuggerIsInBreak() moved to bg_libCore.sh


# usage: debuggerOn [--driver=<driver>[:<destination>]] [<stepType>|firstLine|libInit|resume]
# This will cause the configured debugger driver to be loaded and the initial break condition to be set. In most cases this means
# that after this command, a DEBUG trap handler will be set in the proccess and every subsequent script command will be tested to
# see if the condition is met to invoke the interactive debugger at that point.
#
# Params:
#    <stepType> : this is passed through to the _debugSetTrap function. See that function for details.
#
# Options:
#    --driver=<driver>:<destination> : override the driver and destination. The driver determines the code that is loaded in the
#           script's process to handle debugger events and actions. The <destination> is a driver specific token that specifies
#           where the debugger UI will be displayed.  At the time of this writing, there are two drivers,
#           'integrated'  and 'remote'. See man(7) bg_debugger_integrated.sh and man(7) bg_debugger_remote.sh
#
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

	local logicalFrameStart=1 dbgID="${bgDebuggerDestination:-integrated:win}"
	while [ $# -gt 0 ]; do case $1 in
		--driver*) bgOptionGetOpt val: dbgID "$@" && shift ;;
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		--) shift; break ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

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

	_debugSetTrap --logicalStart+${logicalFrameStart:-1} "$@"
}


# usage: _debugEnterDebugger [<dbgContext>]
# This enters the main loop of an interactive debugger. It must only be called from a DEBUG trap because it assumes that environment.
# The DEBUG trap handler is set by _debugSetTrap which creates a handler that calls this function whenever the condition hard coded
# into the trap handler is met. Each time this function returns, it calls _debugSetTrap to setup the condition that will return to
# the debugger when met. Typically that means that a DEBUG trap with the condition embedded will be installed but if the step action
# is 'resume', then no DEBUG trap will be set so that the script will continue running unmonitored until it ends or a bgtraceBreak
# command in the script is reached.
#
# Stub and Drivers:
# This function is part of the debugger stub that is ran inside the script being debugged. It is a coreOnDemand library so it is
# only loaded if the script calls bgtraceBreak or the debugger is actived in another way. It will refuse to load in a production
# environment that implements security constraints on installed scripts.
#
# This function implements what happens when the DEBUG trap decides that its time break for the debugger. It mainly derfers to the
# loaded driver.
#
# Params:
#    <dbgContext> : this informs us what is calling us.
function _debugEnterDebugger()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35
	debuggerIsActive || { builtin trap - DEBUG; return -1; }

	local dbgContext="$1"; shift

	# if there are any gloabl vars that we dont wnat to disturb, declare them as local here
	local L1 L2

	local assertErrorContext="--allStack"

	# this function should only be called as a result of the DEBUG trap handler installed by _debugSetTrap
	case $dbgContext in
		!DEBUG-852!) : ;;
		scriptEnding)
			bgtrace "debugger received the script ending message"
			_debugDriverScriptEnding

			# this call to remove the DEBUG trap before the script exits was added to suppress a segfault I was getting when the program ended
			# in ubuntu 19.04, the segfault seems not to happen -- not sure if some code change fixed it or if the newer bash version fixed it.
			builtin trap - DEBUG
			return
			;;
		*) assertError --critical --allStack "_debugEnterDebugger should only be called from the DEBUG trap set by _debugSetTrap function" ;;
	esac

	touch "${assertOut}.stoppedInDbg"

	# since we can not debug the debugger, when can capture the entire trace of each break and analyze them
	#bgtraceXTrace marker "> entering debugger"
	#bgtraceXTrace on

	### collect the  current state of the interrupted script. A few vars have already been set because they have to be set in the
	#   handler before it invokes this function

	# init the logical call stack variables which is our take on the BASH function scope stack turning
	# it into an actual 'call stack' instead of a 'function scope stack'
	bgStackMakeLogical

	# make a cp with the bgBASH_debugTrap* name
	local bgBASH_debugTrapStk=("${bgStack[@]}")

	local bgBASH_debugTrapCMD="$BASH_COMMAND"

	# examine the interrupted state to assemble a list of variables that are being used in the current context.
	# in bash 5.1, local -p will gives us the list of variables in the local function. Maybe we will have to run that in the intr
	# handler before it calls this function. In meantime, we will glean what we can.
	local -a bgBASH_debugTrapCmdVarList bgBASH_debugTrapFuncVarList
	extractVariableRefsFromSrc "${BASH_COMMAND}"  bgBASH_debugTrapCmdVarList
	[ "$bgBASH_debugTrapFUNCNAME" ] && extractVariableRefsFromSrc --exists "$(type $bgBASH_debugTrapFUNCNAME)"  bgBASH_debugTrapFuncVarList
	bgBASH_debugTrapFuncVarList="argv:bgBASH_debugArgv $bgBASH_debugTrapFuncVarList"
	#bgtraceVars "${bgBASH_debugTrapFuncVarList[@]}"

	_debugDriverEnterDebugger "$@"

	#bgtraceXTrace off
	#bgtraceXTrace marker "< leaving debugger"
	unset bgBASH_funcDepthDEBUG
	rm "${assertOut}.stoppedInDbg"
	return ${dbgResult:-0}
}

# usage: _debugSetTrap <stepType> [<optionsForStepType>]
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
#                          when calling _debugSetTrap
function _debugSetTrap()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35

	local currentReturnAction=0 futureNonMatchReturnAction=0 breakCondition="true"  logicalFrameStart=2 traceStepFlag
	while [ $# -gt 0 ]; do case $1 in
		--traceStep) traceStepFlag="--traceStep" ;;
		--futureNonMatchReturnAction*) bgOptionGetOpt val: futureNonMatchReturnAction "$@" && shift ;;
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local stepType="$1"; shift

	# when called by the DEBUG trap, bgBASH_funcDepthDEBUG is set to indicate the code being debugged.
	# when called by something that starts the debugger (debuggerOn or bgtraceBreak, typically) they use --logicalStart+1 pattern
	# to some up all the calles between the script code and here.
	local scriptFuncDepth="${bgBASH_funcDepthDEBUG:-$(( ${#BASH_SOURCE[@]} - logicalFrameStart ))}"

	# We can avoid stepping into traps by checking that bgBASH_trapStkFrm_funcDepth is empty. This wont prevent stopping on the
	# trap handler's first line which calls BGTRAPEntry which sets bgBASH_trapStkFrm_funcDepth but at this time there seems no way
	# to do that and this works pretty well. See how its used in utfRunner_execute for testcases.
	if [ "$bgDebuggerStepOverPlumbing" ]; then
		breakCondition='{ [ ${#bgBASH_trapStkFrm_funcDepth[@]} -eq 0 ] && [[ ! "$FUNCNAME" =~  ^(_bgclassCall|ConstructObject)$ ]] && [ ${bgDebuggerPlumbingCode:-0} -eq 0 ]; }'
	elif [ "$bgDebuggerStepOverTraps" ]; then
		breakCondition='[ ${#bgBASH_trapStkFrm_funcDepth[@]} -eq 0 ]'
	fi
	breakCondition="${breakCondition:-true}"


	case $stepType in
		stepIn|step) : ;;                                                                          # F5
		stepOver)     breakCondition='[ ${#BASH_SOURCE[@]} -le '"${scriptFuncDepth}"' ] && '"$breakCondition"'' ;;         # F6
		stepOut)                                                                                    # F7
			if [ "$bgBASH_trapStkFrm_funcDepth" == "$scriptFuncDepth" ]; then
				# if we are in the top level of a trap handler its at the same funDepth as the function it interupted so we need to
				# stop at the same level but after the trap is finished
				breakCondition='[ ! "$bgBASH_trapStkFrm_funcDepth" ] && [ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}))"' ]'
			else
				breakCondition='[ ${#BASH_SOURCE[@]} -le '"$((${scriptFuncDepth}-1))"' ]'
			fi
			;;
		skipOver)     currentReturnAction=1 ;;                                                      # shift-F6
		skipOut)      currentReturnAction=2 ;;                                                      # shift-F7
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

	if [ "$traceStepFlag" ]; then
		bgtrace "DBGTRAP: condition='$breakCondition'"
		traceStepFlag='bgtrace "DBGTRAP: lineno=$bgBASH_debugTrapLINENO depth=${#BASH_SOURCE[@]} func='\''$bgBASH_debugTrapFUNCNAME'\'' cmd='\''$BASH_COMMAND'\''"'
	fi

	# note that if this is being called from the debugger UI, we are inside the last a DEBUG trap so setting it here will not cause
	# a new trap to hit until the current function stack unwinds back up to that handler code string and it finishes.
	# if this is called from bgtraceBreak or debuggerOn to enter the debugger, then it will start trapping on the next line in this
	# function but we rely on the breakCondition in those cases being set so that the trap wont do anything until it hits that condition
	bgBASH_debugSkipCount=0
	#bgtraceVars -1 -l"_debugSetTrap: " breakCondition
	builtin trap 'bgBASH_debugTrapExitCode=$?; bgBASH_debugTrapLINENO=$((LINENO)); bgBASH_debugTrapFUNCNAME=$FUNCNAME
		'"$traceStepFlag"'

		# integrate with the unit test debugtrap _ut_debugTrap filters based on bgBASH_debugTrapFUNCNAME so its ok to call it too often
		[ "$_utRun_debugHandlerHack" ] && _ut_debugTrap

		# the first condition prevents stopping on the fist line of a trap in which we dont know anything about the trap yet.
		# After that first line, the BGTRAPEnter call will set things right.
		#       bgBASH_debugTrapLINENO!=1 : when LINENO is 1 we are more than likely beginning a trap
		#bgtrace "!!! bgBASH_funcDepthDEBUG=${#BASH_SOURCE[@]}  breakCondition='"$breakCondition"'"
		#		if '"$breakCondition"'; then
		if ((bgBASH_debugTrapLINENO!=1)) && '"$breakCondition"'; then
			bgBASH_debugTrapResults=0
			bgBASH_debugArgv=($0 "$@")
			bgBASH_funcDepthDEBUG=${#BASH_SOURCE[@]}
			bgBASH_debugIFS="$IFS"; IFS=$'\'' \t\n'\''

			_debugEnterDebugger "!DEBUG-852!"; bgBASH_debugTrapResults="$?"

			IFS="$bgBASH_debugIFS"; unset bgBASH_debugIFS
			unset bgBASH_debugTrapLINENO bgBASH_debugTrapFUNCNAME bgBASH_debugArgv bgBASH_funcDepthDEBUG
		else
			bgBASH_debugTrapResults=0
		fi
		[ $bgBASH_debugTrapResults -gt 0 ] && { bgtrace "############# SKIPPING exitcode=|$bgBASH_debugTrapResults| BASH_COMMAND=|$BASH_COMMAND|  breakCondition='"$breakCondition"'"; }
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
