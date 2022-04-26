
# Library
# analyze bash scripts depedencies

# usage: bparse_build [<project>]
# parse the scripts for vinstalled projects to build a cyjs data file for visualizing the graph of project, file and function
# dependencies
# Params:
#    <project> : limit to only scripts in this project instead of all installed scripts
function bparse_build()
{
	local outFile
	while [ $# -gt 0 ]; do case $1 in
		-o*|--output*)  bgOptionGetOpt val: outFile "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local project="$1"; shift

	[ "$outFile" == "-" ] && outFile="/dev/stdout"

	if [ "$project" ]; then
		local path
		if static::Project::getProjectPath "$project" path; then
			cd "$path"
		else
			assertError -v project "unknown project"
		fi
	fi
	gawk '@include "bg_bashParse.awk"' < <(bparse_raw) >${outFile:-./.bglocal/dependencies.bgDeps}
}


# usage: bparse_raw
# print the raw bash parse output for all scripts in the sandbox
# Params:
#    <project> : limit to only scripts in this project instead of all installed scripts
function bparse_raw()
{
	local outFile manifestFilter
	while [ $# -gt 0 ]; do case $1 in
		-o*|--output*)  bgOptionGetOpt val: outFile "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local project="$1"; shift

	[ "$outFile" == "-" ] && outFile="/dev/stdout"

	if [ "$project" ]; then
		local path
		if static::Project::getProjectPath "$project" path; then
			cd "$path"
		else
			assertError -v project "unknown project"
		fi
	fi

	case $(iniParamGet ./.bg-sp/config "." "projectType") in
		sandbox)  manifestFilter=() ;;
		package)  manifestFilter=(--pkg=$(iniParamGet ./.bg-sp/config "." "packageName")) ;;
	esac

	while read -r pkgName assetType assetName filePath; do
		printf "\n[AssetInfo] $pkgName $assetType $assetName $filePath\n"
		cat "$filePath"
		printf "?!?"  # insert a tokan which can not be valid bash so that the awk script can detect the start of the parser output
		bashParse --parse-tree-print "$filePath" || assertError
	done < <(
		manifestGet  "${manifestFilter[@]}" ".*bash" ".*"
	) >${outFile:-/dev/stdout}
}
