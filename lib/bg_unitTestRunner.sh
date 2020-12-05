
import bg_dev.sh ;$L1;$L2

# Library
# This library is used by "bg-dev tests" to implement batch running and reporting of unitstests (aka testcases) in a project or
# group of projects. When ran this way, the ut output file data is updated and a report of which of the executed test cases passed
# and failed in the run.
#
# For testing, unit tests can be executed directly by invoking their ut script file directly from the terminal prompt and that does
# not use this library. Each ut script file sources bg_unitTest.sh but not this library.
#
# The Pipeline:
# This library iterates over .ut scripts and for each one creates a pipeline to perform the update and report on the results.
#  (testcases from A.ut script) -> bg_unitTestRunner.awk -> bg_unitTestResultFormatter.awk
#  (testcases from B.ut script) -> bg_unitTestRunner.awk-'
#
# **bg_unitTestRunner.awk** is passed the name of the .ut script and it reads multiple files related to the script as well as the
# current run data received on stdin from the pipe.
#      unitTests/.<utFile>.ids      # contains the ordered list of testcases present in the script
#      unitTests/.<utFile>.run      # contains the last run of the test cases
#      unitTests/.<utFile>.plato    # contains the expected output of the testcases.
#
# The ids file lets the awk script no the complete list of testcase from the script. This makes it so that any particular run can
# run all the testcases or a subset of them (or just one) and it will not be confused that some are missing.
#
# For each testcase output seen on stdin, it compares it with the output from the .run file. If its different, it updates the run
# file. This step produces the <modState> for each testcase which is one of (new,unchanged,updated,removed)
#
# After updating the .run contetn if needed,  it compares the .run content with the .plato content. It ignores comments lines so
# only uncommented content in the test part of the output is considerd. This comparison produces the resultState for each testcase
# which is one of (pass|fail|error) error is when they differ but the footer of the testcase indicates that it failed in the setup.
#
# This script will write a new .run file as needed and on its stdout it writes a summary of each testcase processed.
#       <resultState> <modState> <utID>
#
# **bg_unitTestResultFormatter.awk** reads that output from bg_unitTestRunner.awk, collates them into lists based on <resultState>
# and <modState> and then displays either a summary of how many testcases are in each list or lists them based on the verbosity level.
#
# See Also:
#    man(7) bg_unitTest.sh  : the library used by ut script files.




# usage: utfIDParse <utIDSpec> <utPkgVar> <utFileVar> <utFuncVar> <utParamsVar>
# The first parameter is a string in the format of a utID or a supported shortcut. The purpose of this function is to interpret
# shortcut notation that does not contain all four parts by correctly identifying which part(s) was specified and filling in the
# missing parts to the left or right as required.
#
# Params:
#    <utIDSpec>     : The input spec to be parsed
#    <utPkgVar>     : variable name to receive the package part
#    <utFileVar>    : variable name to receive the file part
#    <utFuncVar>    : variable name to receive the function part
#    <utParamsVar>  : variable name to receive the parameter part
#
# utID Format:
#  <pkgName>:<fileName>:<functionName>:<parametersNames>
#  where...
#    <pkgName>         : is the name of the package (aka project) that the test is from
#    <fileName>        : is the *.ut file inside that package that the test is from
#         The fully qualified filename is unitTests/<baseName>.ut Only <basName> needs to be included. Either or both of the leading
#         path or trailing ut extension can be ommitted. If <baseName> does not conatin a '.', then adding the .ut can be usefull
#         to ensure that its interpretted as a filename part if the shortcut notation is used.
#    <functionName>    : is the function inside that file that implements the test
#    <parametersNames> : is the key of an array with the same name as the function defined in that file whose value contains the
#                        parameters that the function will be invoked with when this utID runs.
# Shortcut Format:
# A utIDSpec can have fewer that four parts. If a pkgName or or fileName is recognized, the missing parts are filled in on the right.
# If no token is recognized as a pkg or file, the missing parts are filled in on the left.
# Examples...
#    bg-core       # all testcases in bg-core pkg
#    bg_ini.sh     # all testcases in the unitTests/bg_ini.sh.ut script in the current pkg (when PWD is the root of the pkg).
#    getIniParam:  # all testcases using a function named ut_getIniParam in any ut script in the current pkg. Note that the trailing
#                    : is needed to distinguish it from a parameter part with the same name
#    :1            # all testcase in the current pkg whose parameter key name is '1'
#
# Wildcards:
# This function will return the wildcard expression. It does not expand them. If a part is missing, the empty string will be returned
# for that part.
# The utfExpandIDSpec uses this function to identify the parts, and then it interprets the wildcards and returns all the utID that
# match the wildcards.
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

	# if the first part is a pkgName fix it up
	if [ ${#parts[@]} -lt 4 ] && devIsPkgName "${parts[0]}"; then
		while [ ${#parts[@]} -lt 4 ]; do parts=("${parts[@]}" ""); done

	# if the first part is a utFile, fix it up
	elif [ ${#parts[@]} -lt 4 ] && { [ -e "unitTests/${parts[0]}.ut" ] || [[ "${parts[0]}" =~ [.] ]] ; }; then
		parts=("" "${parts[@]}")
		while [ ${#parts[@]} -lt 4 ]; do parts=("${parts[@]}" ""); done

	# if the second part is a utFile, fix it up
	elif [ ${#parts[@]} -lt 4 ] && { [ -e "unitTests/${parts[1]}.ut" ] || [[ "${parts[1]}" =~ [.] ]] ; }; then
		while [ ${#parts[@]} -lt 4 ]; do parts=("${parts[@]}" ""); done
	fi

	# if none of the parts were recognized as utPkg or utFile, assume fill in leading missing parts
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

# usage: completeUtIDSpec <cur>
# a bash completion routine that completes the multipart utID syntax
function completeUtIDSpec()
{
	local cur="$1"; shift
	if [[ ! "$cur" =~ : ]]; then
		fsExpandFiles -b unitTests/*.ut | sed 's/\.ut$/:%3A/g'
		return 0
	fi

	local utFile="${cur%%:*}"
	cur="${cur#*:}"
	local utFilePath="unitTests/${utFile}.ut"

	echo "\$(cur:$cur)"
	if [ -x "$utFilePath" ]; then
		$utFilePath -hbOOBCompGen 2 "$utFile" run "$cur"
	fi
	return 0
}

# usage: utfExpandIDSpec <idSpec1> [... <idSpecN>]
function utfExpandIDSpec()
{
	local namePrefix outSpecs=("--echo" "")
	while [ $# -gt 0 ]; do case $1 in
		-f|--fullyQualyfied) namePrefix="$pkgName:" ;;
		-A|--array) bgOptionGetOpt val: outSpecs "$@" && shift; outSpecs=(--array -a "$outSpecs") ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	while [ $# -gt 0 ]; do
		if [ "$1" == "all" ]; then
			local utFiles=(); manifestReadOneType utFiles "unitTest"
			varSetRef "${outSpecs[@]}" $(awk -v fullyQualyfied="${namePrefix:-1}" '@include "bg_unitTest.awk"' "${utFiles[@]}")
		else
			local utPkgID utFileID utFuncID utParamsID; utfIDParse "$1" utPkgID utFileID utFuncID utParamsID
			[ "$utPkgID" ] && [ "$utPkgID" != "$pkgName" ] && assertError "unit test IDs with package specifiers are not yet supported. Run tests from a project's root folder"
			utFileID="${utFileID:-"*"}"
			utFuncID="${utFuncID:-"*"}"
			utParamsID="${utParamsID:-"*"}"
			local utFiles
			fsExpandFiles -A utFiles unitTests/* \( -name "$utFileID" -o -name "${utFileID}.ut" \) -type f
			local utID; while read -r utID; do
				if [[ "$utID" == $namePrefix*:$utFuncID:$utParamsID ]]; then
					varSetRef "${outSpecs[@]}" "$utID"
				fi
			done < <(awk -v fullyQualyfied="${namePrefix:-1}" '@include "bg_unitTest.awk"' "${utFiles[@]}")
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
		mapSet -a -d " " "$mapVar" "$firstPart" "$theRest"
		shift
	done
}


# usage: utfList [all]
# usage: utfList <utIDSpec1> [...<utIDSpecN>]
# List the testcases that match the specs. This is the exact same algorithm as used by utfRun so it can be used to see which
# testcases would be ran if these specs were passed to utfRun
function utfList()
{
	# we might use $pkgName
	devGetPkgName -q

	local fullyQualyfiedFlag
	while [ $# -gt 0 ]; do case $1 in
		-f|--fullyQualyfied) fullyQualyfiedFlag="-f" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	[ $# -eq 0 ] && set -- "all"
	while [ $# -gt 0 ]; do
		utfExpandIDSpec $fullyQualyfiedFlag "$1"
		shift
	done
}


# usage: utfProcessOutput  <utFilePath>
# This function and the bg_unitTestRunner.awk awk script it uses are the heart of the unit test record keeping.
# It can operate in two different modes -- one for use by utfRun and the other by utfReport.
#
# utfRun Mode:
# utfRun invokes a ut script file to run one or more testcases and pipes the output through this function which passes it on to the
# bg_unitTestRunner.awk script. That awk script reads the .ids, .run, and .plato information for that script, merges the new output
# and writes are a new version of the .run file if needed. While merging the new data, it determines each testcase's modification
# state (new, updated, unchanged) and result state (pass,fail,error,uninit) and writes a one line record on stdout for each testcase.
#
# utfReport Mode:
# utfReport pipes a stream to this function that is just a list of utIDs to report on.bg_unitTestRunner.awk reads the .ids, .run,
# and .plato files, determines the result state of each utID in that list and then writes out the same record to stdout that the
# utfRun mode writes. The modification status will always be 'unchanged' in these records.
#
# ids File:
# This function makes sures that the .ids file associated with the ut script is updated to contain the current list of testcases.
# The bg_unitTestRunner.awk awk script will read that file so that it knows the complete, ordered list of testcases contained in
# the ut script.
function utfProcessOutput()
{
	local verbosity=0
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local utFilePath="$1"; shift
	[ -x "$utFilePath" ] || assertError -v utFilePath "utFilePath must be a path to a .ut script that exists and is executable"

	local orderFile="${utFilePath//unitTests\//unitTests\/.}"; orderFile="${orderFile%.ut}.ids"
	fsIsNewer "$utFilePath" "$orderFile" && $utFilePath list > "$orderFile"

	gawk -v utFilePath="$utFilePath" '
		@include "bg_unitTestRunner.awk"
	'
}


# usage: utfRun [all]
# usage: utfRun <utIDSpec1> [...<utIDSpecN>]
# Runs the specified set of testcases, updating the results and reporting on the outcome
# Result Files:
# When this function runs a ut script, it mainatins several hidden files next to the script file.  The utfProcessOutput filter function
# maintains thes files correctly regardless of whether all the testcases in a script are ran or only a subset is ran.
#    unitTests/.<utFile>.ids   : this file contains the cached output of "unitTests/<utFile>.ut list". It is the definitive ordered
#                                list of testcases (aka utIDs) contained in the script.
#    unitTests/.<utFile>.run   : this file contains the output of the testcase script run. Its possible that a testcase's output
#                                could be missing from this file if it has not yet completed without a setup error. When only a
#                                subset of the testcases listed in .ids is ran, those outputs are merged with the existing output.
#    unitTests/.<utFile>.plato : This file contains the expected output of the testcases. The .run file is compared to this file
#                                to determine if the testcases passed or failed. If a testcase does not have any output in .plato
#                                its pass/fail state is set to "uninit" (unitializaed)
# See Also:
#    man(3) utfProcessOutput
function utfRun()
{
	local verbosity="$verbosity"
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# we might use $pkgName
	devGetPkgName -q

	[ $# -eq 0 ] && set -- "all"
	local  utIDsToRun=()
	while [ $# -gt 0 ]; do
		utfExpandIDSpec --fullyQualyfied -A utIDsToRun "$1"
		shift
	done

	# b/c with specified --fullyQualyfied to utfExpandIDSpec, utIDsToRun has all fully qualified IDs, each with 4 parts
	# - pkg:file:func:params. Each _collateUTList call removes the fist part and puts in the the key of a map and the remainder
	# in a space separated string value which preserves the order of the list.  This allows us to iterate by pkg first so that we
	# need to setup the pkg environment once per pkg, then by files so that we need to source each file only once and then by func,params
	# in the order that they were originall specified with respect to that ut script.

	progress -s "tests" "running unit tests" "${#utIDsToRun[@]}"
	local count=0


	local -A utIDByPkg=()
	_collateUTList utIDByPkg "${utIDsToRun[@]}"
	local utPkg; for utPkg in "${!utIDByPkg[@]}"; do
		[ "$pkgName" == "$utPkg" ] || assertError -v pkgName -v utPkgID -v utID "running test cases from outside the project's folder is not yet supported. "

		local -A utIDByFile=()
		_collateUTList utIDByFile ${utIDByPkg["$utPkg"]}
		local utFile; for utFile in "${!utIDByFile[@]}"; do
			local utFilePath="unitTests/${utFile}.ut"
			[ -f "$utFilePath" ] || assertError -v utFilePath  "the unit test file does not exist or is not a regular file"

			(
				progress -s "$utFile" "running unit tests" "$(strSetCount "${utIDByFile["$utFile"]}")"
				declare -gx bgUnitTestScript="$utFilePath"
				import "bg_unitTest.sh" ;$L1;$L2
				import "$utFilePath" ;$L1;$L2
				local utTestcase; for utTestcase in ${utIDByFile["$utFile"]}; do
					local utFunc="${utTestcase%%:*}"
					local utParams="${utTestcase#*:}"
					progress "$utTestcase" "+$(strSetCount "$utParams")"
					utfRunner_execute "$utFilePath" "$utFunc" "$utParams"
				done
				progress -e "$utFile"

			) | utfProcessOutput  "$utFilePath"

			progress "$utFile" "$((count+=$(strSetCount "${utIDByFile["$utFile"]}")))"
		done

	done | gawk -v verbosity="$verbosity" '
		@include "bg_unitTestResultFormatter.awk"
	'

	progress -s "tests" "finished"
}

function utfReport()
{
	local verbosity="$verbosity"
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# we might use $pkgName
	devGetPkgName -q

	[ $# -eq 0 ] && set -- "all"
	local  utIDsToRun=()
	while [ $# -gt 0 ]; do
		utfExpandIDSpec --fullyQualyfied -A utIDsToRun "$1"
		shift
	done


	local -A utIDByPkg=()
	_collateUTList utIDByPkg "${utIDsToRun[@]}"
	local utPkg; for utPkg in "${!utIDByPkg[@]}"; do
		[ "$pkgName" == "$utPkg" ] || assertError -v pkgName -v utPkgID -v utID "running test cases from outside the project's folder is not yet supported. "

		local -A utIDByFile=()
		_collateUTList utIDByFile ${utIDByPkg["$utPkg"]}
		local utFile; for utFile in "${!utIDByFile[@]}"; do
			local utFilePath="unitTests/${utFile}.ut"
			[ -f "$utFilePath" ] || assertError -v utFilePath  "the unit test file does not exist or is not a regular file"

			{
				echo REPORT-ONLY
				for utID in ${utIDByFile["$utFile"]}; do
					echo "$utFile:$utID"
				done
			} | utfProcessOutput "$utFilePath"
		done

	done | gawk  -v verbosity="$verbosity" -v mode="report" '
		@include "bg_unitTestResultFormatter.awk"
	'
}


function utfShow()
{
	local verbosity="$verbosity"
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# we might use $pkgName
	devGetPkgName -q

	[ $# -eq 0 ] && set -- "all"
	local  utIDsToRun=()
	while [ $# -gt 0 ]; do
		utfExpandIDSpec --fullyQualyfied -A utIDsToRun "$1"
		shift
	done


	local -A utIDByPkg=()
	_collateUTList utIDByPkg "${utIDsToRun[@]}"
	local utPkg; for utPkg in "${!utIDByPkg[@]}"; do
		[ "$pkgName" == "$utPkg" ] || assertError -v pkgName -v utPkgID -v utID "running test cases from outside the project's folder is not yet supported. "

		local -A utIDByFile=()
		_collateUTList utIDByFile ${utIDByPkg["$utPkg"]}
		local utFile; for utFile in "${!utIDByFile[@]}"; do
			local utFilePath="unitTests/${utFile}.ut"
			local runFile="unitTests/.${utFile}.run"
			local platoFile="unitTests/.${utFile}.plato"
			[ -f "$utFilePath" ] || assertError -v utFilePath  "the unit test file does not exist or is not a regular file"

 			if [ -f "$runFile" ] && { [ ${verbosity:-0} -gt 1 ] || fsIsDifferent "$runFile" "$platoFile"; }; then
				[ ! -e "$platoFile" ] && touch "$platoFile"
				$(getUserCmpApp) --newtab "$runFile" "$platoFile" &
			fi
		done

	done
}
