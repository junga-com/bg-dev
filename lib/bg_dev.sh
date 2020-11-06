
manifestProjPath=".bglocal/manifest"

# usage: devGetPkgName [<retVar>]
# a lot of function in the dev environment need to know the pkgName that is being operated on. in cmds like bg-dev, pkgName is set
# at the start and the script asserts that it is being run in a valid project folder. But library function can not be certain that
# has been done. Library functions can call this to ensure that the pkgName is set before relying on $pkgName.
function devGetPkgName() {
	local quietFlag
	while [ $# -gt 0 ]; do case $1 in
		-q) quietFlag="-q" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	[ "$pkgName" ] && { returnValue $quietFlag "$pkgName" $1; return; }
	declare -gA pkgName
	if [ ! "${pkgName[$PWD]:+exists}" ]; then
		iniParamGet -R pkgName[$PWD] .bg-sp/config . "pkgName"
		[ ! "${pkgName[$PWD]:+exists}" ] && [ -f .bg-sp/config ] && pkgName[$PWD]="${PWD##*/}"
	fi
	[ ! "${pkgName[$PWD]:+exists}" ] && assertError -v PWD "could not determine the package name for this folder. "
	# when accessed as a scalar, bash uses pkgName[0]
	pkgName="${pkgName[$PWD]}"
	returnValue $quietFlag "$pkgName" $1
}

function devIsPkgName()
{
	local pwdPkg; devGetPkgName pwdPkg
	[ "$1" == "$pwdPkg" ] && return 0
	[[ ":$bgInstalledPkgNames:" =~ :$1: ]] && return 0
	[ -d "/var/lib/bg-core/$1" ] && return 0
	return 1
}

# usage: manifestReadTypes [-f|--file=<manifestFile>] [<typesRetVar>]
# get the list of asset types present in the project's manifest file
# Params:
#    <typesRetVar>  : the variable name of an array to return the asset type names in
# Options:
#    -f|--file=<manifestFile> : by default the manifest file in <projectRoot>/.bglocal/manifest is used
function manifestReadTypes()
{
	local manifestFile="$manifestProjPath"
	while [ $# -gt 0 ]; do case $1 in
		-f*|--file*) bgOptionGetOpt val: manifestFile "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local typesVar="$1"
	local type count
	while read -r type count; do
		[ "$type" == "<error>" ] && assertError -v manifestFile -v pkgName "The manifest file does not exist."
		mapSet $typesVar "$type" "$count"
	done < <(awk '
		{types[$2]++}
		END {
			for (type in types)
				printf("%s %s\n", type, types[type])
		}
	' "$manifestFile" || echo '<error>')
}

# usage: manifestReadOneType [-f|--file=<manifestFile>] <filesRetVar> <assetType>
# get the list of files and folders that match the given <assetType> from the manifset
# Params:
#    <filesRetVar>  : the variable name of an array to return the file and folder names in
#    <assetType>    : the type of asset to return
# Options:
#    -f|--file=<manifestFile> : by default the manifest file in <projectRoot>/.bglocal/manifest is used
function manifestReadOneType()
{
	local manifestFile="$manifestProjPath"
	while [ $# -gt 0 ]; do case $1 in
		-f*|--file*) bgOptionGetOpt val: manifestFile "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local filesVar="$1"
	local type="$2"

	local file
	while read -r file; do
		varSet "$filesVar[$((i++))]" "$file"
	done < <(awk -v type="$type" '
		$2==type {print $3}
	' "$manifestFile")
}
