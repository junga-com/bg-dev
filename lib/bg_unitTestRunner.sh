
import bg_dev.sh ;$L1;$L2

# usage: utfIDParse <utID> <utPkgVar> <utFileVar> <utFuncVar> <utParamsVar>
# The first parameter is a string in the format of a utID. The remainder of the parameters are the variable names of the components
# that will be set. If one of those names is the empty string "" is will be ignored.
# utID Format:
#  <pkgName>:<fileName>:<functionName>:<parametersNames>
#  where...
#    <pkgName>         : is the name of the package (aka project) that the test is from
#    <fileName>        : is the *.ut file inside that package that the test is from
#    <functionName>    : is the function inside that file that implements the test
#    <parametersNames> : is the key of an array with the same name as the function defined in that file whose value contains the
#                        parameters that the function will be invoked with when this utID runs.
# A utID can have 1 to 4 parts filled in from the right. A one part utID has only the utParams component. A two part has the utFunc
# and utParams, and so on.
# Any part can contain wildcards that will match against the actual test cases that are present in the sandbox or project where the
# command is running.
# Examples:
#    These could all refer to the same test...
#       bg-dev:bg_funcman.sh.ut:parseCmdScript:1    # fully qualified
#       bg_funcman.sh.ut:parseCmdScript:1           # suficiently qualified when run from the bg-dev project folder
#       parseCmdScript:1                            # suficiently qualified in the conext of the bg_funcman.sh.ut file
#    *:*:*                 # all tests in the current project
#    bg_funcman.sh.ut:*:*  # all the tests in that file
#    bg_*:doIt:*           # all tests with the function doIt in any utFiles starting with bg_
function utfIDParse()
{
	local printToStdoutFlag
	while [ $# -gt 0 ]; do case $1 in
		-t) printToStdoutFlag="-t:" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local utID="$1"; shift

	# use the bash native () word splitting with IFS set to :  Note that we need to set -f so that bash does not expand * to the files
	# in the current folder
	local undoSet=""; [[ ! "$-" =~ f ]] && undoSet='set +f'
	local saveIFS="$IFS"
	set -f; local IFS=:; local parts=($utID); IFS="$saveIFS"; $undoSet;
	[[ "$utID" =~ :$ ]] && parts=("${parts[@]}" "") # b/c a trailing : by itself does not create an element ('func:' is the same as 'func')
	[ ${#parts[@]} -gt 4 ] && assertError -v utID -v parts "malformed utID. too many parts. should be <pkg>:<file>:<function>:<parameterKey>"
	while [ ${#parts[@]} -lt 4 ]; do parts=("" "${parts[@]}"); done
	if [ "$printToStdoutFlag" ]; then
		printfVars parts
	else
		returnValue -q "${parts[0]}" $1
		returnValue -q "${parts[1]}" $2
		returnValue -q "${parts[2]}" $3
		returnValue -q "${parts[3]}" $4
	fi
}

function utfList()
{
	devGetPkgName -q
	local namePrefix
	while [ $# -gt 0 ]; do case $1 in
		-f|--fullyQualyfied) namePrefix="$pkgName:" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local utFiles=(); manifestReadOneType utFiles "unitTest"
	local utPath; for utPath in "${utFiles[@]}"; do
		local utFile="${utPath#unitTests/}"
		utFile="${utFile%.ut}"
		$utPath list | awk '{print "'"${namePrefix}${utFile}"':" $0}'
	done
}

# usage: utfExpandIDSpec <idSpec1> [... <idSpecN>]
function utfExpandIDSpec()
{
	local namePrefix ids outSpecs="-A ids"
	while [ $# -gt 0 ]; do case $1 in
		-f|--fullyQualyfied) namePrefix="$pkgName:" ;;
		-S|--set) bgOptionGetOpt val: outSpecs "$@" && shift; outSpecs="--set $outSpecs" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	while [ $# -gt 0 ]; do
		if [ "$1" == "all" ]; then
			varSetRef $outSpecs $(utfList --fullyQualyfied)
		else
			local utPkgID utFileID utFuncID utParamsID; utfIDParse "$1" utPkgID utFileID utFuncID utParamsID
			[ "$utPkgID" ] && assertError "unit test IDs with package specifiers are not yet supported. Run tests from a project's root folder"
			utFileID="${utFileID:-"*"}"
			utFuncID="${utFuncID:-"*"}"
			utParamsID="${utParamsID:-"*"}"
			if [ "$utFileID" ]; then
				local utFiles
				fsExpandFiles -A utFiles unitTests/* \( -name "$utFileID" -o -name "${utFileID}.ut" \) -type f
				local utPath; for utPath in "${utFiles[@]}"; do
					local utFile="${utPath#unitTests/}"
					utFile="${utFile%.ut}"
					local utFunParam; while read -r utFunParam; do
						[[ "$utFunParam" == $utFuncID:$utParamsID ]] && varSetRef $outSpecs "${namePrefix}${utFile}:$utFunParam"
					done < <($utPath list)
				done
			fi
		fi
		shift
	done
}

# usage: _collateUTList <mapVar> [<utID1> ...<utIDN>]
function _collateUTList()
{
	local mapVar="$1"; shift
	while [ $# -gt 0 ]; do
		local firstPart="${1%%:*}"
		local theRest="${1#*:}"
		mapSet -a "$mapVar" "$firstPart" "$theRest"
	done
}


function utfRun()
{
	# set the default action to run all tests in the project
	[ $# -eq 0 ] && set -- all

	local -A utIDsToRun=()
	while [ $# -gt 0 ]; do
		utfExpandIDSpec -f -S utIDsToRun "$1"
		shift
	done

	# b/c with specified -f to utfExpandIDSpec, utIDsToRun has all fully qualified IDs, each with 4 parts - pkg:file:func:params
	# each _collateUTList call removes the fist part and puts in the the key of a map and the remainder in a space separated string
	# value.  This allows us to iterate by pkg first so that we need to setup the pkg environment once per pkg, then by files so that
	# we need to source each file only once and then by func,params

	local tmpOut; bgmktemp tmpOut

	local -A utIDByPkg=()
	_collateUTList utIDByPkg "${!utIDsToRun[@]}"
	local utPkg; for utPkg in "${!utIDByPkg[@]}"; do
		[ "$pkgName" == "$utPkg" ] || assertError -v pkgName -v utPkgID -v utID "running test cases from outside the project's folder is not yet supported. "

		local -A utIDByFile=()
		_collateUTList utIDByFile ${utIDByPkg["$utPkg"]}
		local utFile; for utFile in "${!utIDByFile[@]}"; do
			[ -f "$utFile" ] || assertError -v utFile  "the unit test file does not exist or is not a regular file"

			(
				source "$utFile"
				utfRunner_execute "$utFunc" ${utIDByFile["$utFile"]}

			) > "$tmpOut"
		done
	done

	bgmktemp --release tmpOut
}



function utfReport()
{
	echo "i am utfReport, here me!!!"
}


# usage: utfRunner_loadAndExectute <utFile> <utFunc> <utParams>
function utfRunner_loadAndExectute()
{
	local utFile="$1"; shift
	local utFunc="ut_${1#ut_}"; shift
	local utParams="$1"; shift
	assertFileExists "$utFile" "The unit test file '$utFile' does not exist"
	[ -f "$utFile" ] || assertError -v utFile -v utFunc -v utParams "the unit test file does not exist or is not a regular file"
	(
		source "$utFile"
		utfRunner_execute "$utFunc" "$utParams"
	)
}








function FROM_FIRST_VERSION_utRunScript2()
{
	local verboseExitCodes
	while [ $# -gt 0 ]; do case $1 in
		--verboseExitCodes) verboseExitCodes="1" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local testScript="$(stringRemoveLeadingIndents "$1")"; shift
	[ $# -gt 0 ] && assertError "script error. The <script> was not passed in as one parameter. Check to see if you have unintentional single or double quotes somewhere in the script"

	local tmpStdOutFile="$(mktemp)"
	local tmpStdErrFile="$(mktemp)"

	# this is like a try .. catch block to catch exits in the test script
	(
		echo "##START ################################################"

		# parse the test script into its components
		local section="test" testDecription
		local lineNum=1
		local line; while read -r line; do
			if [[ "$line" =~ ^[[:space:]]*[#][[:space:]]*[Dd]escription[:[:space:]]*([^[:space:]].*)?$ ]]; then
				section="description"
				testDecription="${BASH_REMATCH[1]}"
				echo "$testDecription" > "${tmpStdErrFile}.description"
				echo "# $testDecription"
			elif [[ "$line" =~ ^[[:space:]]*[#][[:space:]]*[Ss]etup[:[:space:]]*([^[:space:]].*)?$ ]]; then
				section="setup"
				[ "${BASH_REMATCH[1]}" ] && echo "$line"
			elif [[ "$line" =~ ^[[:space:]]*[#][[:space:]]*[Tt]est[:[:space:]]*([^[:space:]].*)?$ ]]; then
				section="test"
				[ "${BASH_REMATCH[1]}" ] && echo "$line"
			else
				echo "$section $lineNum" >> "${tmpStdErrFile}.state"
				case $section in
					description)
						[[ "$line" =~ ^([[:space:]]*)(.*)$ ]]; line="${BASH_REMATCH[2]}"
						testDecription+="${testDecription:+$'\n'}$line"
						echo "$line" >> "${tmpStdErrFile}.description"
						echo "# $line"
						;;
					setup)
						printf "${line:+##setup : cmd> }%s\n" "$line"
						eval "$line" >$tmpStdOutFile 2>$tmpStdErrFile || exit
						[ -s "$tmpStdErrFile" ] && exit 1
						__utRunScript2_processOutputStream "##setup:" "$tmpStdOutFile"
						;;
					test)
						printf "${line:+\$cmd> }%s\n" "$line"
						eval "$line" 2>$tmpStdErrFile; exitCode=$?
						{ [ "$verboseExitCodes" ] || [ $exitCode -gt 0 ]; } && printf "exit code = '%s'\n" "$exitCode"
						[ -s "$tmpStdErrFile" ] && __utRunScript2_processOutputStream "stderr:" "$tmpStdErrFile"
						;;
				esac
			fi
			((lineNum++))
		done <<<"$testScript"

		echo "##END ##"
		echo "#"
		echo "#"
		echo "#"

		# rm state file and return true to indicate that we got through the whole script without
		# any command exitting
		rm -f "${tmpStdErrFile}.state"
		true
	); local exitCode=$?

	# if state file exists, some command called exit which means that the script filed unless its the
	# the last line of the script in a test section
	if [ -f "${tmpStdErrFile}.state" ]; then
		# this block catches exit errors. The individual script lines are not run in a subshell so they
		# end the script and end up here. The last line in the ${tmpStdErrFile}.state tells us whether
		# to process as test or setup. Errors in setup are passed through, errors in test are part of the test
		local section lineNum s l; while read -r s l; do section="$s"; lineNum="$l"; done < "${tmpStdErrFile}.state"
		if [ "$section" == "setup" ]; then
			__utRunScript2_processOutputStream "##setup:" "$tmpStdOutFile"
			printf "exit code = '%s'\n" "$exitCode"
			[ -s "$tmpStdErrFile" ] && __utRunScript2_processOutputStream "##stderr:" "$tmpStdErrFile"
			echo "!! setup preconditions failed. unit test result unknown"
		else
			printf "exit code = '%s'\n" "$exitCode"
			[ -s "$tmpStdErrFile" ] && __utRunScript2_processOutputStream "stderr:" "$tmpStdErrFile"
			# if it was the last line in the script that exitted, its not an error
			local line scriptLinecount=1; while read -r line; do ((scriptLinecount++)); done <<<"$testScript"
			if [ ${lineNum:-0} -lt ${scriptLinecount:-0} ]; then
				echo "!! script terminated early on line $lineNum of $scriptLinecount in '$section' section!!"
			else
				exitCode=0
			fi
		fi
	fi
	rm -f "$tmpStdOutFile" "$tmpStdErrFile" "${tmpStdErrFile}.state" "${tmpStdErrFile}.description"
	return $exitCode
}

# usage: __utRunScript2_processOutputStream <prefix> <outfile>
function FROM_FIRST_VERSION___utRunScript2_processOutputStream()
{
	local prefix="$1"
	local outfile="$2"
	local line; while IFS="" read -r line; do
		if [ "$utmode" != "debug" ] && [[ "$line" =~ ^([^:]*: line [0-9]*:)(.*)$ ]]; then
			echo "${prefix} <scriptError>: line $lineNum: ${BASH_REMATCH[2]}"
		else
			echo "${prefix} $line"
		fi
	done < "$outfile"
}
