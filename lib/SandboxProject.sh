import Project.sh  ;$L1;$L2
import bg_json.sh  ;$L1;$L2

DeclareClass SandboxProject Project

# we provide a static method for status so that its easier to call from arbitrary places that might not create the project instance.
function static::SandboxProject::status()
{
	local -A sand; ConstructObject Project::sandbox sand
	$sand.startLoadingSubs
	$sand.status "$@"
}

# The Sandbox ctor restores the list of sub projects and some light information each sub project and sets up th queues needed to
# asynchronously load each of them completely but does not trigger the loading. The idea is to be able to load the sandbox quicker
# for operations that do not need the full sub project objects to be built. This optimization is not as important anymore since
# the bgCore loadable bash builtin makes it much faster to load all the projects. (mainly the fast toJSON and fromJSON makes the
# parallelization more efficient)
function SandboxProject::__construct()
{
	local quickFlag
	while [ $# -gt 0 ]; do case $1 in
		--quickFlag) quickFlag="--quickFlag" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# sandbox projects are not being released yet so the version does not matter much
	this[version]="0.0.0"

	$_this.subs=new Map
	$_this.subOIDs=new Map
	$_this.subsInfo=new Map; local -n subsInfo; GetOID ${this[subsInfo]} subsInfo

	# this is a map that returns the sub folder name given either the sub's name or folder. Its useful for canonicalizing input
	$_this.subsIndex=new Map

	if [ -f "${this[absPath]}/.gitmodules" ]; then
		local subName subFolder
		local -n subsIndex; GetOID ${this[subsIndex]} subsIndex
		local -n subInfo
		this[maxNameLen]=0
		while read -r subName subFolder; do
			((this[maxNameLen]=(${#subFolder} > this[maxNameLen])?${#subFolder}:this[maxNameLen]))

			subsIndex[$subName]="$subFolder"
			subsIndex[$subFolder]="$subFolder"

			$this.subsInfo[$subFolder]=new Object
			unset -n subInfo; local -n subInfo; GetOID ${subsInfo[$subFolder]} subInfo
			subInfo[folder]="$subFolder"
			subInfo[projectName]="$subFolder"

			if [ -f "${subFolder}/.bg-sp/config" ]; then
				read -r subInfo[name] subInfo[projectType] subInfo[version] < <(gawk -i bg_ini.awk '
					iniSection="" && iniParamName="packageName" {packageName=iniValue}
					iniSection="" && iniParamName="projectType" {projectType=iniValue}
					iniSection="" && iniParamName="version" {version=iniValue}
					END {print ((packageName)?packageName:"--")" "((projectType)?projectType:"--")" "((version)?version:"--")}
				' "${subFolder}/.bg-sp/config")
				varUnescapeContents subInfo[name] subInfo[projectType] subInfo[version]
			fi

			if [ -f "${subFolder}/package.json" ]; then
				read -r subInfo[name] subInfo[projectType] subInfo[version] < <(static::SandboxProject::getProjectNameTypeAndVersionFromPkgJSON "${subFolder}/package.json")
			fi
			[ "${subInfo[name]}" ] && subsIndex[${subInfo[name]}]="$subFolder"
			subInfo[name]="${subInfo[name]:-${subInfo[projectName]}}"

		done < <(gawk '
			{
				# [submodule "bg-core"]
				# 	path = bg-core
				# 	url = git@github.com:junga-com/bg-core.git
				if (match($0,/^[[:space:]]*[[]submodule[[:space:]]+["](.*)["].*$/, rematch))
					subName=rematch[1]
				if (match($0,/^[[:space:]]*path[[:space:]]*=[[:space:]]*([^[:space:]]*)$/, rematch))
					subs[subName]["path"]=rematch[1]
			}
			END {
				for (subName in subs)
					print subName" "subs[subName]["path"]
			}
		' "${this[absPath]}/.gitmodules")
	fi

	# setup the context for asynchronously loading the sub project information.
	newHeapVar -a _this[_subLoad_todo] "${!subsInfo[@]}"  # _subLoad_todo starts with a list of all subs
	newHeapVar -A _this[_subLoad_pids]                    # _subLoad_pids: as childs are started, a sub is moved from todo into here
	newHeapVar -A _this[_subLoad_results]                 # _subLoad_results: as childs finish a sub is moved from pids into here
	fsTouch "${this[absPath]}/.bglocal/run/"              # we use this folder for the temp files used to pass the info back to parent
	_this[_maxChildren]="$(grep processor /proc/cpuinfo | wc -l)" # This determines how many simultaneous children are allowed
}

function SandboxProject::make()
{
	echo "sandbox making"
}


function SandboxProject::loadSubs()
{
	while [ ${#_subLoad_todo[@]} -gt 0 ]; do
		local subFolder="${_subLoad_todo[0]}"; _subLoad_todo=("${_subLoad_todo[@]:1}")
		$this.subs[$subFolder]=new Project "${this[absPath]}/$subFolder/"
		_subLoad_results[$subFolder]=$?
	done
}


# usage: $obj.startLoadingSubs
# create as many children (one per sub project) as is allowed by _this[_maxChildren] and then return.
# After calling this, waitForLoadingSub [subFolder|all] should be called.
function SandboxProject::startLoadingSubs()
{
	# Flow...
	#    _subLoad_todo=(sub1 sub2 ..)   == array of subs waiting to have a child created to load it
	#    _subLoad_pids[<pid>]=<subName> == subs being loaded in a child  (or recently finished waiting to be acknowledged)
	#    _subLoad_results[<subName>]    == subs that have completed being loaded

	# while there are slots available (child count < core count), start some children to load subs
	# we dont have to complete this because waitForLoadingSub will keep calling us after a child finishes if there are more to do
	while [ ${#_subLoad_todo[@]} -gt 0 ] && [ ${#_subLoad_pids[@]} -lt ${_this[_maxChildren]} ]; do
		local subFolder="${_subLoad_todo[0]}"; _subLoad_todo=("${_subLoad_todo[@]:1}")
		(
			local -n subProj; ConstructObject Project subProj "${this[absPath]}/$subFolder/"

			$subProj.toJSON --all > "${this[absPath]}/.bglocal/run/$subFolder.$$.json"
		)&
		_subLoad_pids[$subFolder]=$!
	done
}

# usage: $obj.waitForLoadingSub [all]
# usage: $obj.waitForLoadingSub any <subFolderVar>
# usage: $obj.waitForLoadingSub <subFolder>
# Call this before accessing the subs[] array which contains the Project object for each sub project. This function supports three
# patterns for using it.
#
# Note that startLoadingSubs can and should be called as soon as possible in a script so that the work can get started, but it does
# not need to be called before calling this function because this function calls startLoadingSubs if needed.
#
# Form 1 'all':
# When called with the argument 'all' or no arguments, this function will return only after all sub project have been loaded and
# are ready to use. This is the simplest form because after it returns, the entire snadbox state is loaded and no further action is
# needed to access anything.
#
# Form 2 'any':
# When called with the first argument 'any' this function will return as soon as one project has completed loading. The second
# argument is required to receive the folder name of the sub project that is now ready to use. This allows work on the next step to
# begin asap but but does not guaranty any order of processing so for example, the status command uses the third form instead of
# this form so that the status for sub projects are always printed in the same order. When there are no more subprojects to wait
# for it returns false(1) and <subFolderVar> is set to the empty string
#
# Form 3 'subFolder':
# When called passing in the name of one of the subfolders, this function will return only after that particular sub project is
# complete and ready to use. Other subs may finish and become ready while waiting for this one. The idea is that you can iterate
# the subs calling this function and the order will be preserved and it may or may not perform better than waiting for 'all'.
function SandboxProject::waitForLoadingSub()
{
	local sub="${1:-all}"

	# note that when sub is 'all' or 'any' this first while condition will always be true and the loop ends when either the second
	# condition becomes true (no more subs to process) in the case of 'all' or in the case of 'any' the condition inside the loop
	# breakss the loop by returning from the function.
	while [ ! "${_subLoad_results[$sub]:+exists}" ] && (( (${#_subLoad_pids[@]} + ${#_subLoad_todo[@]} ) > 0 )); do
		# if there are more subs that need to be started, let startLoadingSubs see if we can start anymore
		[ ${#_subLoad_todo[@]} -gt 0 ] && $this.startLoadingSubs

		local -A childResult=()
		if bgwait --maxChildCount="${_this[_maxChildren]}" --leftToSpawn="${#_subLoad_todo[@]}" "_subLoad_pids" "childResult"; then
			if [ ${childResult[exitCode]:-0} -gt 0 ]; then
				echo "ERROR: loading sub project information for '${childResult[name]}'  exitcode='${childResult[exitCode]}'" >&2
				gawk '{print "   "$0}' "${this[absPath]}/.bglocal/run/${childResult[name]}.$$.json"
			else
				ConstructObjectFromJson subs[${childResult[name]}]  "${this[absPath]}/.bglocal/run/${childResult[name]}.$$.json"
				${subs[${childResult[name]}]}.getOID subOIDs[${childResult[name]}]
			fi
			_subLoad_results[${childResult[name]}]="${childResult[exitCode]}"
			if [ "$sub" == "any" ]; then
				returnValue -q "${childResult[name]}" "$2"
				return 0
			fi
		fi
	done

	# if we get here when 'any' is specified, its because there were no more to wait for so return false to indicate that we can not
	# return another sub
	if [ "$sub" == "any" ]; then
		returnValue -q "${childResult[name]}" "$2"
		return 1
	fi
	return 0
}


function SandboxProject::status()
{
	bgtimerLapTrace -T tStatus "starting status"
	# an empty options loop stil processes verbosity options
	while [ $# -gt 0 ]; do case $1 in
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local subName subFolder maxNameLen=0
	local -n info

	bgtimerLapTrace -T tStatus "after loadSubsAsync"
	local sub
	for sub in "${!subsInfo[@]}"; do
		$this.waitForLoadingSub "$sub"
		${subs[$sub]}.printLine --maxNameLen="${this[maxNameLen]}"
	done
	bgtimerLapTrace -T tStatus "all done"
}


function SandboxProject::fetch()
{
	SandboxProject::waitForLoadingSub "all"

	local failCount=0
	local -A pids=() childResult=()
	local -n sub; for sub in "${subOIDs[@]}"; do
		$sub.fetch  &>.bglocal/run/${sub[name]}.$$ &
		pids[${sub[name]}]=$!
	done
	while bgwait pids childResult; do
		if [ ${childResult[exitCode]} -ne 0 ]; then
			((failCount++))
			printf "   %*s: fetch failed\n" "-${this[maxNameLen]}" "${childResult[name]}"
			gawk '{printf("      |%s\n", $0)}' .bglocal/run/${childResult[name]}.$$
		fi
		rm -f .bglocal/run/${childResult[name]}.$$
	done
	return $failCount
}


function SandboxProject::push()
{
	SandboxProject::waitForLoadingSub "all"

	local sub; for sub in "${subs[@]}"; do
		$sub.push --maxNameLen="${this[maxNameLen]}"
	done
}



function SandboxProject::commit()
{
	local dryRunFlag
	while [ $# -gt 0 ]; do case $1 in
		--dry-run) dryRunFlag="--dry-run" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local subFolder
	for subFolder in "${!subsInfo[@]}"; do
		if [ "$(git -C "$subFolder" status -uall --porcelain --ignore-submodules=dirty | head -n1)" ]; then
			[ "$dryRunFlag" ] && return 1
			(cd "$subFolder"; git gui citool)&
		fi
	done
	return 0
}

function SandboxProject::publish()
{
	SandboxProject::waitForLoadingSub "all"

	if [ $(fsGetAge -M .bglocal/run/fetch.last) -gt 10 ]; then
		printf "Fetching latest from remotes\n"
		if $this.fetch; then
			touch .bglocal/run/fetch.last
		fi
	fi

	printf "Checking commit and merge state\n"
	local failCount=0
	local -a subsToPublish=()
	local -n sub; for sub in "${subOIDs[@]}"; do
		if [ ${sub[changesCount]:-0} -gt 0 ]; then
			printf "   %*s: contains uncommitted changes\n" "-${this[maxNameLen]}" "${sub[name]}"
			((failCount++))

		elif [ "${sub[needsMerge]}" ]; then
			printf "   %*s: needs merging with upstream\n" "-${this[maxNameLen]}" "${sub[name]}"
			((failCount++))

		elif [ ! "${sub[releasePending]}" ]; then
			printf "   %*s: no changes to publish\n" "-${this[maxNameLen]}" "${sub[name]}"
			continue

		elif [ "${sub[lastRelease]}" == "v${sub[version]}" ]; then
			printf "   %*s: needs version bumped\n" "-${this[maxNameLen]}" "${sub[name]}"
			((failCount++))
		fi
		subsToPublish+=("$($sub.getOID)")
	done
	[ $failCount -gt 0 ] && return 1

bgtraceVars --noObjects --plain --noNest subsToPublish

	local -n sub; for sub in "${subsToPublish[@]}"; do
		$sub.publishCommit
	done

	return 0
}




function SandboxProject::depsInstall()
{
	local subFolder
	for subFolder in "${!subsInfo[@]}"; do
		local -A sub=(); ConstructObject Project sub "${this[absPath]}/$subFolder"
		$sub.depsInstall
	done
}

function SandboxProject::depsUpdate()
{
	local subFolder
	for subFolder in "${!subsInfo[@]}"; do
		local -A sub=(); ConstructObject Project sub "${this[absPath]}/$subFolder"
		$sub.depsUpdate
	done
}



function static::SandboxProject::getProjectNameTypeAndVersionFromPkgJSON()
{
	local packageJsonPath="$1"
	gawk -i bg_core.awk '
		BEGIN {
			projectType="nodejs"
			nestLevel=0
			found=0
		}
		/[{][[:space:]]*$/ {nestLevel++}
		/^[[:space:]]*[}][[:space:]]*,?[[:space:]]*$/ {nestLevel--}

		nestLevel==1 && /["]name["]:/ {
			projectName=gensub(/^.*:[[:space:]]*["]|["].*$/,"","g",$0)
		}
		nestLevel==1 && /["]version["]:/ {
			projectVersion=gensub(/^.*:[[:space:]]*["]|["].*$/,"","g",$0)
		}
		nestLevel==1 && /["]engines["]:/ {
			statement=$0
			while (statement !~ /[}][[:space:]]*,?[[:space:]]*$/ && (getline >0))
				statement=statement" "$0
			if (statement~/["]atom["]/)
				projectType="atomPlugin"
		}
		END {
			print(projectName" "projectType" "projectVersion)
		}
	' $(fsExpandFiles -f "$packageJsonPath")
}
