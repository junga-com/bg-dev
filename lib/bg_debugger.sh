
bglogOn dbg


# Library bg_debugger.sh
# This library provides a debugger stub that is embedded in scripts so that they can be debugged with an interactive debugger.
#
# This library is not typically loaded by default or explicitly. bgtraceBreak and the configuration set by bg-debugCntr will cause
# it to be loaded on demand only when debugger is invoked by one of those features and the the host environment allows it. If the
# host environment is not in development mode (/etc/bgHostProductionMode contains mode=development) this library will refues to load
#
# This library contains only the core 'stub' code of the debugger. This code is independent of the debugger front end and manages
# the DEBUG trap that will 'enter' the debugger when a condition is met. _debugSetTrap() will install the DEBUG trap with a
# particular condition. _debugEnterDebugger() is the function that is called when the DEBUG Trap condition decides to enter the
# debugger. It has a loop that implements messages that an interactive debugger can send to the embedded stub to perform actions
# and query state.
#
# This library will identify and load a front end driver that provides for debugger UI. Two drivers are provided at this time (circa
# 2022-10).
#
# Activating the Debugger:
# First of all, the script must be running on a host that is authorized for development by having the file /etc/bgHostProductionMode
# contain the line 'mode=development' in order for the debugger to be available.
#
# There are several ways to activate the debugger.
#       bgtraceBreak  : inserting a call to bgtraceBreak is like hard coding a breakpoint in the script. When it is executed the
#                       debugger will be started using the driver configured in the bgDebuggerDestination environment variable.
#       bgdb <scriptname> [<p1>..<pN>] : When bg-debugCntr is active in a terminal, adding the 'bgdb' prefix when launching the
#                       scipt will cause it to invoke the debugger and stop on the first command of the script (after libraries are
#                       loaded)
#       cntr-c        : You can use 'bg-debugCntr debugger cntr-C:on' to make it so that pressing cntr-c during the scripts
#                       run will cause it to stop in the debugger on the next bash command. Note that if the script is blocked in
#                       an external command, it wont work because bash never gets to the next command.
#       stopOnAssert  : You can use 'bg-debugCntr debugger stopOnAssert:on' to make it so that the script will stop in the debugger
#                       if an unhandled assertError is 'thrown'
#
# Integrated Driver:
# The integrated debugger front end driver implements a debugger UI entirely in bash. It only needs a TTY on which to display the
# UI and accept user input. Its configuration parameter (dbg destination ID is 'integrated:<param>') specifies which TTY to use.
# Typically it will create a new cuiWin ('integrated:<param>') or it will use the alt page of the TTY the script is running in
# ('integrated:self')
# Use 'bg-debugCntr debugger destination integrated:self|cuiWin' to select this destination.
# See man(7) bg_debugger_integrated.sh
#
# Atom Driver:
# (not related to Kylo Ren). The Atom debugger front end driver interfaces with the bg_bash_debugger Atom package (i.e. plugin) to
# provide the UI in the Atom code editor.
# When the plugin starts in a Atom window, if the 1) it was launched from a terminal where a sandbox is vinstalled and 2) that
# sandbox folder is openned as an Atom project node, it will create name pipe at /tmp/bgAtomDebugger-$USER/<sandboxFolder>-toAtom
# Then if the debugger is activated in a script which was launched in a folder where that same snadbox folder in vinstalled, it
# will see that Atom window as an available debugger destination.
# Use 'bg-debugCntr debugger destination atom:' to select this destination.
#
# Debugger Front End API:
# A driver is a bash library that is named bg_debugger-<driverName>.sh and implements the following required functions.
#    _dbgDrv_debuggerOn <terminalID> : initialize the front end. <terminalID> is the parameter part of the debugger destination
#                                      .e.g. <driverName>:<terminalID>
#    _dbgDrv_debuggerOff             : clean up resources used by the debugger.
#    _dbgDrv_enter                   : initiate a 'breakSession' which exists for the duration that the script is stopped at a
#                                      particular location.
#    _dbgDrv_leave                   : end the 'breakSession'. The script will resume until the next break or it ends.
#    _dbgDrv_getMessage              : while stopped in a breakSession the stup loops calling this funtion. The driver's implementation
#                                      typically blocks waiting for user input an then returns the msg to the stub. If the message
#                                      indicates that the script should continue, the stub will then call the leave API.
#    _dbgDrv_scriptEnding            : indicates that the script is exitting. This is typically sent while there is not a break session.
#
# See Also:
#    man(3) bgtraceBreak
#    man(1) bg-debugCntr-debugger
#    man(7) bg-debugger-integrated.sh
#    man(7) bg-debugger-atom.sh


# function debuggerIsActive() moved to bg_libCore.sh
# function debuggerIsInBreak() moved to bg_libCore.sh

# this is a list of functions that we do not want to stop in by default because they are low level that the user is not interested in
# the value is not (yet) used but we could make the value show up in the bgtrace traces if we want to
declare -gA _bgdb_plumbingFunctionNames=(
	[import]=F
	[_postImportProcessing]=F
	[_bgclassCall]=F
	[ConstructObject]=F
	[bgtrace]=F
	[bgtraceVars]=F
	[bgtraceParams]=F
	[bgtimerLapTrace]=F
	[bgtimerTrace]=F
	[bgtraceCntr]=F
	[bgtraceIsActive]=F
	[bgtracePSTree]=F
	[bgtraceTurnOff]=F
	[bgtraceXTrace]=F
	[bgtimerStart]=F
	[bgtrace]=F
	[bgtracef]=F
	[bgtraceLine]=F
	[bgtraceRun]=F
	[bgtraceTurnOn]=F
	[bgtimerStartTrace]=F
	[bgtraceBreak]=F
	[bgtraceParams]=F
	[bgtraceStack]=F
	[bgtraceVars]=F
	[BGTRAPEntry]=F
	[BGTRAPExit]=F
	[utfDirectScriptRun]=F
)
# similar to _bgdb_plumbingFunctionNames but these are command names that we dont want to stop in.
# for example, import <script> ;$L1;$L2; when the db is stopped on import, stepOver will not stop on $L1 or $L2
declare -gA _bgdb_plumbingCommandNames=(
	['$L1']="CMD"
	['$L2']="CMD"
	['Catch']="CMD"
	['Catch:']="CMD"
	['utfDirectScriptRun']="CMD"
)

# code can set an element of this associative array to non-empty to cause the debugger to skip code until no element exists
# The idea of using an assoc array is that multiple things can ask to be skipped and as long as at least one still has an element,
# code will be skipped
declare -gA bgDebuggerGlobalDisable


# debugger config settings that affect the debugger's behaivior. The Atom driver sets asyncBreaks to 'yes' because it can handle concurrent
# breaks from multiple threads
declare -gA _bgdb_config=(
	[asyncBreaks]="no"
)


#declare -g bgDebuggerStepIntoPlumbing="1"

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

	local logicalFrameStart=1 dbgID="${bgDebuggerDestination}"
	while [ $# -gt 0 ]; do case $1 in
		--driver*) bgOptionGetOpt val: dbgID "$@" && shift ;;
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		--) shift; break ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# set default destination. if its a remote terminal use self (page flipping)
	if [ ! "$dbgID" ]; then
		if [ "$DISPLAY" ]; then
			dbgID="integrated:win"
		else
			dbgID="integrated:self"
		fi
	fi

	# remove the cnt-c trap because now that we are in the debugger, we want cntr-c to exit the process like normal.
	# install a new trap on SIGUSR1 to break. For example if stepping the the script, a step takes a long time, the debugger can
	# send it SIGUSR1 to get it to stop where ever its at
	bgtrap -n debugger --remove SIGINT
	bgtrap -n debugger '
		if debuggerIsInBreak; then
			bgtrace "debugger signaled to break but the debugger is already stopped"
		else
			bgtrace "debugger signaled to break -- breaking..."
			bgtraceBreak
		fi
	' SIGUSR1

	local driverID="${dbgID%%:*}"
	local driverSpecificID; [[ "$dbgID" =~ : ]] && driverSpecificID="${dbgID#*:}"

	import -q bg_debugger_${driverID}.sh ;$L1;$L2 || assertError -v dbgID -v driverID -v driverSpecificID "unknown debugger driver"

	_dbgDrv_debuggerOn "$driverSpecificID"

	# make sure these important bash options are set correctly (they may already be set this way)
	# TODO: save the options state and reset them when debugger is turned off
	shopt -s extdebug
	set -o functrace # redundant. extdebug included it
	# extdebug turns this on but our debugger does not use ERR traps and unit tests need errtrace off, so turn it back off
	set +o errtrace

	# set a EXIT trap to give the debugger a chance to clean up and change its view to indicate that the script has ended.
	trap -n debuggerOn '_debugScriptExitting' EXIT

	bgtrace "Debugger started for script $(basename $0)($$) using dbgID '${dbgID:-win}'"

	_debugSetTrap --logicalStart+${logicalFrameStart:-1} "$@"
}

# usage: debuggerOff
# release the debugger front end from debugging this script and resume the script so that it runs to completion.
# There is not much reason to turn off debugging. Issuing the 'resume' command to the debugger front end or sending 'resume'
# directly to the debugger stub in the script will make the script run to the end at which time the debugger front end will be released.
# The only difference is that 'debuggerOff' will release the debugger front end first so that it could potentially be used for
# something else before the script ends.
function debuggerOff()
{
	_dbgDrv_debuggerOff "$@"

	bgtrap -n debugger --remove SIGUSR1
	_debugInstallCntrHandler

	# these should probably be reset to their values when _dbgDrv_debuggerOn overwrote them. I think bg_core.sh style scipts have
	# extdebug on all the time now fro better stack traces
	builtin trap - DEBUG
	shopt -u extdebug
	set +o functrace
	#2020-10 i think this was a mistake. debugger does not use ERR trap and it interfers with unit tests # set +o errtrace
}

# usage: _debugEnterDebugger
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
# Break Sessions:
# This function implements what happens when the DEBUG trap decides that its time break for the debugger. The duration of this
# function is a 'break session'.
#
# This function interacts with the debugger front end (which is defined by the debug driver identified and loaded during debuggerOn())
# by calling _dbgDrv_enter(), then looping on _dbgDrv_getMessage(), and then when the loop finishes_dbgDrv_leave before returning
# which ends the DEBUG trap that called this function, letting the script continue to run.
#
# The handling of msgs returned by _dbgDrv_getMessage() define the actions that the front end can control in the script.
#
# Back End (script side) Commands:
# Commands use the format of any shell command -- <cmdName> [<p1>..<pN>]
# Newlines in parameters should be avoided or escaped as some drivers assume one line commands in this direction.
#
# Commands that control execution of the script
#    stepIn      : if the current command is a bash function call, descend into it and break at the top of the function
#                  if the current command is a bash builtin call, attach gdb and step into the builtin
#    stepIntoBash: attach gdb and step into the bash C code that
#    stepOver    : run the current command and then break again
#    stepOut     : run until the current function returns
#    skipOver    : move execution pointer to the next command without executing the current command
#    skipOut     : do not execute the remaining cmmands in the current function and stop at the line following the function call
#    resume      : run the script until it either concludes or executes an embeded bgtraceBreak call
#    rerun       : cause the script to exit immediately but then restart the script to continue debugging at its start
#    endScript   : cause the script to exit prematurely
#
# Commands that configure the debugger state
#    stepOverPlumbing : cause the break logic set by _debugSetTrap to not break on commands that are considered 'plumbing'. For
#                       example, when stepping into an object method call, plumping is the _bgclassCall function which identifies
#                       and eventually calls the method's bash function. When stepOverPlumbing is configured, it will skip the
#                       _bgclassCall and all of its logic and step right into the method function.
#                       stepOverPlumbing is the default state.
#    stepIntoPlumbing : disable the stepOverPlumbing mechanism.
#
# Commands that mess with the script's state
#    reload : cause the script to reload itself or any bash libraries that are now newer. This may or may not work depending on
#             what changed in the scripts but often there is no harm in trying it if you are at a location that would take work to
#             get back too. The more robust way is to 'rerun' and then execute back to the desired point.
#
#    eval : run a command in the script's process space. For example 'eval myVar=5' will set the state of 'myVar' in the script to 5.
#
#    setFunctionBreakPoint <functionNameSpec> : dynamically patch all functions in the script process memory that match <functionNameSpec>
#           so that there is a call to bgtraceBreak as the first command in the function.
#           The step* family of commands install a custom DEBUG trap and then resumes the script. Before each simplae command the
#           trap code runs and determines if it time to break. That could work to stop when a function is called but the script
#           will run very slow until the break is found. The setFunctionBreakPoint is much faster because the script resumes without
#           any DEBUG trap installed and only stops if it executes a bgtraceBreak.
function _debugEnterDebugger()
{
	[ "$bgDevModeUnsecureAllowed" ] || return 35
	debuggerIsActive || {
		builtin trap - DEBUG
		bglog dbg "refusing to _debugEnterDebugger because the debugger is no longer connected"
		return 0
	}

	# since we are called from inside a DEBUG handler, assertError can not use the DEBUG trap to unwind
	# continuing is not ideal because it does not stop the remainder of the code after the assert from executing, but we will call
	# the driver's entry point in a separate subshell and change it to use the subshell as the catch mechanism
	bgBASH_tryStackAction=(   "continue"              "${bgBASH_tryStackAction[@]}"   )

	# if there are any global vars that we dont want to disturb, declare them as local here.
	# Any import statement in the debugger will reset L1,L2 have to protect
	local _L1="$L1" L1
	local _L2="$L2" L2

	# bgStackFreeze vars
	local bgFUNCNAME=(       "${bgFUNCNAME[@]}"       )
	local bgBASH_SOURCE=(    "${bgBASH_SOURCE[@]}"    )
	local bgBASH_LINENO=(    "${bgBASH_LINENO[@]}"    )
	local bgBASH_ARGC=(      "${bgBASH_ARGC[@]}"      )
	local bgBASH_ARGV=(      "${bgBASH_ARGV[@]}"      )
	local bgSTK_cmdName=(    "${bgSTK_cmdName[@]}"    )
	local bgSTK_cmdLineNo=(  "${bgSTK_cmdLineNo[@]}"  )
	local bgSTK_argc=(       "${bgSTK_argc[@]}"       )
	local bgSTK_argv=(       "${bgSTK_argv[@]}"       )
	local bgSTK_caller=(     "${bgSTK_caller[@]}"     )
	local bgSTK_cmdFile=(    "${bgSTK_cmdFile[@]}"    )
	local bgSTK_frmCtx=(     "${bgSTK_frmCtx[@]}"     )
	local bgSTK_cmdLine=(    "${bgSTK_cmdLine[@]}"    )
	local bgSTK_argOff=(     "${bgSTK_argOff[@]}"     )
	local bgSTK_cmdLoc=(     "${bgSTK_cmdLoc[@]}"     )
	local bgSTK_frmSummary=( "${bgSTK_frmSummary[@]}" )
	local bgSTK_cmdSrc=(     "${bgSTK_cmdSrc[@]}"     )


	bgStackFreeze "2" "$bgBASH_COMMAND" "$bgBASH_debugTrapLINENO"


	# this function should only be called as a result of the DEBUG trap handler installed by _debugSetTrap
	# if someone tries calling this function without the secret parameter, they will get this message
	[ "$1" == "!DEBUG-852!" ] || assertError --critical "_debugEnterDebugger should only be called from the DEBUG trap set by _debugSetTrap function"

	# serialize entry into the deugger because when stepping through a statement with a pipeline, the debugger forks.
	# Initially this serialization makes it not crash from fighting over the UI but it may be confusing when steps switch back and forth between
	# the sub shells. Maybe we can add a notion of detecting and having the multiple PIDs cooperate in displaying multiple threads
	# in the UI.
	if [ "${_bgdb_config[asyncBreaks]}" == "no" ]; then
		local dbgUILock; startLock -u dbgUILock -w 600 "${assertOut}"
	fi
	touch "${assertOut}.stoppedInDbg"

	# since we can not debug the debugger, when can capture the entire trace of each break and analyze them
	#bgtraceXTrace marker "> entering debugger"
	#bgtraceXTrace on

	### collect the  current state of the interrupted script. A few vars have already been set because they have to be set in the
	#   handler before it invokes this function

	# examine the interrupted state to assemble a list of variables that are being used in the current context.
	# in bash 5.1, local -p will gives us the list of variables in the local function. Maybe we will have to run that in the intr
	# handler before it calls this function. In meantime, we will glean what we can.
	local -a bgBASH_debugTrapCmdVarList bgBASH_debugTrapFuncVarList
	extractVariableRefsFromSrc "${BASH_COMMAND}"  bgBASH_debugTrapCmdVarList
	[ "$bgBASH_debugTrapFUNCNAME" ] && [ "$bgBASH_debugTrapFUNCNAME" != "main" ] && extractVariableRefsFromSrc --func="$bgBASH_debugTrapFUNCNAME" --exists "$(type $bgBASH_debugTrapFUNCNAME)"  bgBASH_debugTrapFuncVarList
	bgBASH_debugTrapFuncVarList="argv:bgBASH_debugArgv $bgBASH_debugTrapFuncVarList"
	#bgtraceVars "${bgBASH_debugTrapFuncVarList[@]}"

	# WIP: this is meant to show the function call in bgBASH_debugTrapCmdVarList when stopped on the first line in a function
	[ "${bgSTK_cmdSrc[0]}" == "{" ] && [ ${#bgBASH_debugTrapCmdVarList[@]} -eq 0 ] && bgBASH_debugTrapCmdVarList="BASH_COMMAND"

	_dbgDrv_enter

	local cmdStr dbgTrapAction
	while _dbgDrv_getMessage cmdStr; do
		local cmdTokens; utUnEsc cmdTokens $cmdStr
		bglog dbg "stub loop got msg='${cmdTokens[@]}'"

		local msgID
		if [[ "${cmdTokens[0]}" == "msgID:"* ]]; then
			msgID="${cmdTokens[0]#msgID:}"
			cmdTokens=( "${cmdTokens[@]:1}" )
		fi

		case ${cmdTokens[0]} in
			# step*, skip*, resume actions call _debugSetTrap
			step*|skip*|resume|rerun|endScript)
				_debugSetTrap "${cmdTokens[@]}"
				dbgTrapAction=$?
				break
			;;

			stepOverPlumbing) bgDebuggerStepIntoPlumbing="";   ;;
			stepIntoPlumbing) bgDebuggerStepIntoPlumbing="1";  ;;

			reload) importCntr reloadAll ;;

			setFunctionBreakPoint)
				debugBreakAtFunction "${cmdTokens[@]:1}"
			;;

			getFrmVars)
				local varsJsonText; varContextToJSON "${cmdTokens[1]}" "varsJsonText" "${bgBASH_debugArgv[@]:1}"
				_dbgDrv_sendBrkSesMsg "${msgID:+msgID:$msgID }vars ${varsJsonText}"
			;;

			eval)
				if [[ "${cmdTokens[1]}" == *=* ]]; then
					eval "${cmdTokens[@]:1}"
				else
					"${cmdTokens[@]:1}"
				fi
				;;

			*)	printfVars "warning: debugger issued an unknown command to the script" "   " cmdStr cmdTokens actionCmd:cmdTokens
				break
			;;
		esac
	done

	_dbgDrv_leave

	# clean up any trap handler files bgStackFreeze might have made
	rm -f "/tmp/bgDbg"*/*"_${BASHPID}_handler.sh"

	# pop the 'continue' action that we pushed earlier
	bgBASH_tryStackAction=(    "${bgBASH_tryStackAction[@]:1}"   )

	#bgtraceXTrace off
	#bgtraceXTrace marker "< leaving debugger"
	unset bgBASH_funcDepthDEBUG
	rm "${assertOut}.stoppedInDbg"
	if [ "${_bgdb_config[asyncBreaks]}" == "no" ]; then
		endLock -u dbgUILock
	fi
	return ${dbgTrapAction:-0}
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

	local currentReturnAction=0 futureNonMatchReturnAction=0  logicalFrameStart=2 traceStepFlag
	while [ $# -gt 0 ]; do case $1 in
		--traceStep) traceStepFlag="2" ;;
		--traceHit) traceStepFlag="1" ;;
		--futureNonMatchReturnAction*) bgOptionGetOpt val: futureNonMatchReturnAction "$@" && shift ;;
		--logicalStart*) ((logicalFrameStart= 1 + ${1#--logicalStart?})) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local stepType="$1"; shift


	# when called by the DEBUG trap, bgBASH_funcDepthDEBUG is set to indicate the code being debugged.
	# when called by something that starts the debugger (debuggerOn or bgtraceBreak, typically) they use --logicalStart+1 pattern
	# to some up all the calles between the script code and here.
	local scriptFuncDepth="${bgBASH_funcDepthDEBUG:-$(( ${#BASH_SOURCE[@]} - logicalFrameStart ))}"

	# this is the trace line that prints when --traceStep or --traceHit are specified. This is a general format. We might consider
	# a flag that causes the code that builds up breakCondition to build a simple version which only prints the values used in the
	# breakCondition.
	# BRK_CTX: |FN00| d=2 import() bg_coreImport.sh(296): 'import bg_objects.sh'   stk=import main
	local breakCondVars='$bgBASH_isPlumbing| d=${#BASH_SOURCE[@]} $bgBASH_debugTrapFUNCNAME() ${BASH_SOURCE##*/}($bgBASH_debugTrapLINENO): '\''$BASH_COMMAND'\''   stk=${FUNCNAME[*]}'


	# set the base break condition (used as is for stepIn, others will AND conditions to it)
	# We can avoid stepping into traps by checking that bgBASH_trapStkFrm_funcDepth is empty. This wont prevent stopping on the
	# trap handler's first line which calls BGTRAPEntry which sets bgBASH_trapStkFrm_funcDepth but at this time there seems no way
	# to do that and this works pretty well. See how its used in utfRunner_execute for testcases.
	local breakCondition
	if [ "$bgDebuggerStepIntoTraps" ]; then
		breakCondition=' [ ! "$bgBASH_isPlumbing" -o "$bgBASH_isPlumbing" == "inTrap" ] '
	elif [ ! "$bgDebuggerStepIntoPlumbing" ]; then
		breakCondition=' [ ! "$bgBASH_isPlumbing" ] '
	elif [ "$bgDebuggerStepOverTraps" ]; then
		# TODO: (this might be obsolete) unit tests set bgDebuggerStepOverTraps to make sure that we dont stop on traps but I think
		#       that we have improved that with the bgDebuggerStepIntoPlumbing that the user can control in the debugger
		breakCondition=' [ "$bgBASH_isPlumbing" != "inTrap" ] '
	else
		breakCondition=" [ "true" ] "
	fi


	case $stepType in
		# F5 stepIn stops at the next trap (cond==true) but the bgDebuggerStepIntoPlumbing might be in effect but we dont restrict it further
		stepIn|step)
			# detect stepping into the signal interrupted script choice
			if [ ! "$bgDebuggerStepIntoPlumbing" ] && [ "$bgDebuggerFirstTrapLineDetected" ]; then
				bgDebuggerStepIntoTraps="1"
				breakCondition=' [ ! "$bgBASH_isPlumbing" -o "$bgBASH_isPlumbing" == "inTrap" ] '
			fi

			# detect stepping into a builtin via gdb
			if [[ "$(type -t "${bgBASH_COMMAND%% *}" 2>/dev/null)" == "builtin"* ]]; then
				debuggerAttachToGdb "func:${bgBASH_COMMAND%% *}_builtin"
			fi
			;;

		stepIntoBash)
			debuggerAttachToGdb
			;;

		# F6 step over stops the next time the call stack is the same or smaller. smaller happens when we return from a function
		stepOver)
			# detect stepping over the signal interrupted script choice
			if [ "$bgDebuggerStepIntoTraps" ] && [ "$bgDebuggerFirstTrapLineDetected" ]; then
				bgDebuggerStepIntoTraps=""
				breakCondition=' [ ! "$bgBASH_isPlumbing" ] '
			fi
			breakCondition='[ ${#BASH_SOURCE[@]} -le '"${scriptFuncDepth}"' ] && '"$breakCondition"''
			;;

		# (F7) what stepOut does depends on where we are stopped. The default algorithm is simply to stop the next time the stack
		# has fewer elements.
		stepOut)
			local condStr
			# if we are stopped in a trap function, stepOut should just stop at the next non-trap even if its at the same level
			# Since we are in the trap, stepIntoPlumbing must be active. If not, the stepOverPlumbing condition make it redundant.
			# Note: that due to bash limitations, we often stop on the first line of the trap before we know we are in the a trap.
			#       Entering the debugger freezes the stack and finds out we are in a trap. freezing the stack is too much work
			#       to do in the break condition. Eventually we can add a mechanism to auto resume for these false hits.
			# TODO: make a state to stepOverPlumbing but not traps
			if [ "$bgBASH_trapStkFrm_funcDepth" == "$scriptFuncDepth" ]; then
				printf -v condStr='[ "$bgBASH_isPlumbing" != "inTrap" ] && [ ${#BASH_SOURCE[@]} -le %s ]' "$scriptFuncDepth"

			# if we are stopped in the global code of sourcing a script we may not even be in any function so we need to watch
			# the BASH_SOURCE stack instead of the FUNCNAME stack.
			elif [ "${bgFUNCNAME[0]}" == "source" ]; then
			#if [ ${bgFUNCNAME[@]: -2:1} == "source" ]; then
				printf -v condStr ' { ((${#BASH_SOURCE[@]} < %s)) || [ "%s" != "${BASH_SOURCE[@]: -%s:1}" ]; } '  "$scriptFuncDepth" "${bgBASH_SOURCE[@]: -$scriptFuncDepth:1}" "$scriptFuncDepth"

			# if we are stopped in a dynamic Object ctor, stepOut should stop at the next ctor, but that will actually be at a lower
			# stack level because a "::ConstructObject" function typically calls ConstructObject to create the instance of the class
			# that it identifies.
			elif [ "${bgBASH_debugTrapFUNCNAME: -17}" == "::ConstructObject" ]; then
				printf -v condStr ' { ((${#BASH_SOURCE[@]} < %s)) || [ "${bgBASH_debugTrapFUNCNAME: -13}" == "::__construct" ]; } ' "$scriptFuncDepth"

			# if we are not in a function (in global code of the script or of a lib sourced from the script global code)
			elif [ ! "$bgBASH_debugTrapFUNCNAME" ]; then
				printf -v condStr ' ((${#BASH_SOURCE[@]} < %s)) '  "$scriptFuncDepth"

			# this is the default stepOut
			else
				# The second condition watches to see when the function we are stopped in changes at its position from the top.
				# note the -%s:1 is the element %s positions from the top of the stack so when the function call other functions
				# and the actual index of that position changes, counting from the end of the array will still be consistent.
				# That second condition was put there for the case of constructs which are called by a plumbing function. stepOut
				# will leave the current ctor, not stop and the higher level b/c its plumbing and then when the next ctor is called
				# it will be at the same level but with a different ctor at the position we are watching.
				# TODO: if the second condition hits places where it should not, remove it and add a new case for when we are in a ctor
				printf -v condStr ' { ((${#BASH_SOURCE[@]} < %s)) || [ "%s" != "${FUNCNAME[@]: -%s:1}" ]; }'  "$scriptFuncDepth" "$bgBASH_debugTrapFUNCNAME" "$scriptFuncDepth"
			fi
			printf -v breakCondition '%s && %s' "$condStr" "$breakCondition"
		;;

		# shift-F6
		skipOver)     currentReturnAction=1 ;;

		# shift-F7
		skipOut)      currentReturnAction=2 ;;

		# OBSOLETE:
		# F8
		# TODO: stepToCursor will have to change before its useful. The current cli UIs cant dont really provide easy code navigation
		#       anyway but when we have an Atom IDE UI it will be worth refactoring this. We need to pass in both sourceFile and linenumber.
		#       and we should try using a method like debugBreakAtFunction() that rewrites the code in memory to add a real breakpoint.
		stepToCursor)
			breakCondition='[ "${BASH_SOURCE[0]}" == "'"${bgSTK_cmdFile[$((stackViewCurFrame))]}"'"  ] && [ ${bgBASH_debugTrapLINENO:-0} -ge '"${codeViewSrcCursor:-0}"' ]'
		;;

		# 'stepToLevel 1' is used when we launch a script using 'bgdb' to get to the first line in the script after "source /usr/lib/bg_core.sh"
		stepToLevel)
			local stepToLevel="$1"
			if [ "${stepToLevel:0:1}" == "+" ] || [ "${stepToLevel:0:1}" == "-" ]; then
				local op=${stepToLevel:0:1}; stepToLevel="${$stepToLevel:1}"
				((stepToLevel = scriptFuncDepth $op stepToLevel ))
			fi
			breakCondition='[ ${#BASH_SOURCE[@]} -eq '"$stepToLevel"' ] && '"$breakCondition"''
		;;

		# 2020-11 changed "trap -" to "trap ''" b/c resume was acting like step when debugging unit test
		resume)
			builtin trap '' DEBUG
			return
		;;

		# shift-F9 This cooperates with bg-debugCntr to end and then relaunch the script's command so that the debugger resets to
		# the start of the script. We cant go backward, but at least we can start over easily.
		rerun)
			msgPut /tmp/bg-debugCntr-$bgTermID.msgs bgdbRerun
			builtin trap '' DEBUG
			bgExit --complete --msg="ending script in preparation of rerunning it in the debugger"
			return
		;;

		# endScript is like executing exit. no more code will be executed. This is as opposed to resume which will run the code to
		# completion.
		endScript)
			builtin trap '' DEBUG
			bgExit --complete --msg="terminating at the direction of the debugger"
			return
		;;
	esac

	# uncomment this to get an unconditional trace on bgtrace
	#traceStepFlag=2

	local traceStepStatment traceBreakHit
	if [ "$traceStepFlag" == "2" ]; then
		bgtrace "BRK_TEST: '$breakCondition'"
		traceStepStatment="bgtrace \"BRK_CTX: $breakCondVars\""
		traceBreakHit="bgtrace \"!!!BRK_HIT: $breakCondVars\"; bgtrace 'HIT_COND: $breakCondition' "
	elif [ "$traceStepFlag" == "1" ]; then
		bgtrace "BRK_TEST: '$breakCondition'"
		traceBreakHit="bgtrace \"!!!BRK_HIT: $breakCondVars\"; bgtrace \"HIT_COND: $breakCondition \" "
	fi

	# note that if this is being called from the debugger UI, we are inside the last a DEBUG trap so setting it here will not cause
	# a new trap to hit until the current function stack unwinds back up to that handler code string and it finishes.
	# if this is called from bgtraceBreak or debuggerOn to enter the debugger, then it will start trapping on the next line in this
	# function but we rely on the breakCondition in those cases being set so that the trap wont do anything until it hits that condition
	bgBASH_debugSkipCount=0
	builtin trap 'bgBASH_debugTrapExitCode=$?; bgBASH_debugTrapLINENO=$((LINENO)); PS4="#DEBUGGER:$PS4"; bgBASH_debugTrapFUNCNAME=$FUNCNAME; bgBASH_COMMAND=$BASH_COMMAND

		'"$traceStepStatment"'

		# integrate with the unit test debugtrap _ut_debugTrap filters based on bgBASH_debugTrapFUNCNAME so its ok to call it too often
		[ "$_utRun_debugHandlerHack" ] && _ut_debugTrap

		# calculate the plumbing state of the current instruction
		bgBASH_isPlumbing=""
		bgBASH_isPlumbing="${_bgdb_plumbingFunctionNames[${bgBASH_debugTrapFUNCNAME:-empty}]+knownFn}${_bgdb_plumbingCommandNames[${BASH_COMMAND%% *}]+knownCMD}"
		[ ${bgDebuggerPlumbingCode:-0} -gt 0 ] && bgBASH_isPlumbing="codeOn"
		[ "${bgDebuggerGlobalDisable[*]}" ]     && bgBASH_isPlumbing="gblSw"
		[ ${#bgBASH_trapStkFrm_funcDepth[@]} -gt 0 ] && bgBASH_isPlumbing="inTrap"

		if '"$breakCondition"'; then
			# in bash5.1 and on, if we dont clear the trap before we create a subshell, it will loop infinately. we dont do it earlier
			# than this because if we dont hit the break condition, we would have to save the trap and reinstall it at the end.
			# inide the break, we know that we wont need this trap anymore because _debugSetTrap will install a new one if needed.
			builtin trap '' DEBUG
			bgPID="$BASHPID"
			bgDebuggerSavedXState="${-//[^x]}"; set +x
			'"$traceBreakHit"'
			bgBASH_debugTrapRetAction=0
			bgBASH_debugArgv=($0 "$@")
			bgBASH_funcDepthDEBUG=${#BASH_SOURCE[@]}
			bgBASH_debugIFS="$IFS"; IFS=$'\'' \t\n'\''
			declare -gA bgTraps
			bgTrapUtils "getAll" "bgTraps"

			_debugEnterDebugger "!DEBUG-852!"; bgBASH_debugTrapRetAction="$?"

			unset bgBASH_debugArgv bgBASH_funcDepthDEBUG
			IFS="$bgBASH_debugIFS"; unset bgBASH_debugIFS
			[ "$bgDebuggerSavedXState" ] && set -x
		else
			bgBASH_debugTrapRetAction=0
		fi
		[ $bgBASH_debugTrapRetAction -gt 0 ] && { bgtrace "############# SKIPPING exitcode=|$bgBASH_debugTrapRetAction| BASH_COMMAND=|$BASH_COMMAND|  breakCondition='"$breakCondition"'"; }
		unset bgBASH_debugTrapExitCode bgBASH_debugTrapLINENO bgBASH_debugTrapFUNCNAME bgBASH_COMMAND
		PS4="${PS4#\#DEBUGGER:}"
		setExitCode $bgBASH_debugTrapRetAction
	' DEBUG

	unset bgBASH_funcDepthDEBUG
	return $currentReturnAction
}

# usage: _debugScriptExitting
# The debugger sets an exit trap to call this while the debugger is turned on so that the front end will get notified if the script
# ends whether its expected or not
function _debugScriptExitting()
{
	bglog dbg "the script's EXIT trap is notifying the debugger that the script is ending"
	_dbgDrv_scriptEnding
	# # this call to remove the DEBUG trap before the script exits was added to suppress a segfault I was getting when the program ended
	# # in ubuntu 19.04, the segfault seems not to happen -- not sure if some code change fixed it or if the newer bash version fixed it.
	# builtin trap - DEBUG
}

# usage: debuggerAttachToGdb
# attach to gdb to step through bash source code
# There are two ways that users typically trigger this.
#    * insert 'bgtraceBreak --inBashSource' in your script. The --inBashSource option specifies to stop in gdb instead of the bash
#      script level debugger. You can use both debuggers at the same time.
#    * when stopped in the bash script level debugger at a line that invokes a builtin, issue the stepIn command.
#
# Requirements:
#    1) the bash you are executing should be built like 'make CFLAGS="-g -O0"' (or symbols should be available in a way that gdb understands)
#       use 'bg-debugCntr vinstall devBash <bashExePath>' to config a terminal to use a specific bash executable
#    2) only the atom front end driver supports this (circa 2022-10)
#       use 'bg-debugCntr debugger destination atom:'
#    3) the source folder should be available in Atom
#       option a) use 'Add Project Folder' in atom's tree view righ-click menu and browse to source folder
#       option b) include the bash project in the sanbox you are using
#
# See Also:
#    bg-debugCntr vinstall devBash <bashExePath>
function debuggerAttachToGdb()
{
	debuggerIsActive || assertError "a debugger is not active"

	type -t _dbgDrv_attachToGdb &>/dev/null || assertError "
		the selected front end debugger driver does not support the _dbgDrv_attachToGdb API.
		Try 'bg-debugCntr debugger destination atom:'"

	_dbgDrv_attachToGdb "$@"
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
		local functionText="$(gawk -v origLineNo="$origLineNo" '
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

		# record the srcFile:srcLineno mapping for the bgStack code to use
		bgBASH_debugBPInfo["$functionName"]="$origLineNo $newLineNo $origFile"

		echo "breakpoint install at start of '$functionName'"
	done
}
