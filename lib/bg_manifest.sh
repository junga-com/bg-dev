

manifestProjPath=".bglocal/manifest"


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

# usage: manifestListKnownAssetTypes
# print a list of known asset types to stdout
function manifestListKnownAssetTypes()
{
	local assetTypeFn; for assetTypeFn in $( { compgen -c bg-dev-install; compgen -A function install; } | sort -u); do
		local assetType="${assetTypeFn#bg-dev-install}"
		assetType="${assetType#install}"
		printf "%s " "$assetType"
	done
	printf "\n"
}


function manifestSummary()
{
	manifestBuild | awk '
		{
			pkg=$1; type=$2; file=$3
			types[pkg][type]++
		}
		END {
			for (pkg in types) {
				printf("%s contains:\n", pkg)
				for (type in types[pkg]) {
					printf("   %4s %s\n", types[pkg][type], type)
				}
			}
		}
	'
}

# usage: manifestUpdate
# This saves the results of manifestBuild in a temporary file and replaces .bglocal/manifest with it if they are not identical.
function manifestUpdate()
{
	local verbosity=${verbosity}
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local tmpFile="$(mktemp)"
	manifestBuild | sort > "$tmpFile"
	if [ ! -e $manifestProjPath ] || ! diff -q "$tmpFile" "$manifestProjPath" >/dev/null; then
		[ ! -e "${manifestProjPath%/*}" ] && mkdir -p "${manifestProjPath%/*}"
		cat "$tmpFile" > $manifestProjPath
		[ ${verbosity:-0} -ge 1 ] && echo "$manifestProjPath was updated"
		rm "$tmpFile"
		return 0
	fi
	[ ${verbosity:-0} -ge 1 ] && echo "$manifestProjPath is already up to date"
	rm "$tmpFile"
	return 1
}


function _findAssetsOfType()
{
	local assetType="$1"; shift
	local -A fileList=()
	fsExpandFiles -S fileList "$@"
	local filename; for filename in "${!fileList[@]}"; do
		printf "%-20s %-20s %s\n" "$pkgName" "$assetType"  "$filename"
	done
}

function _findCmdAssets()
{
	local -A fileList=()
	fsExpandFiles -S fileList * -perm /a+x -type f ! -name "*.*" ! -name Makefile
	local filename; for filename in "${!fileList[@]}"; do
		local mimeType="$(file -ib "$filename")"
		if [[ "$mimeType" =~ charset=binary ]]; then
			assetType="cmd.binary"
		else
			case $(file "$filename") in
				*Bourne-Again*) assetType="cmd.script.bash" ;;
				*) assetType="cmd.script" ;;
			esac
		fi

		printf "%-20s %-20s %s\n" "$pkgName" "$assetType"  "$filename"
	done
}

# usage: manifestBuild
# This scans the project folder and writes to stdout a line for each found asset. Each line has <pkgName> <assetType> <fileOrFolder>
# It has builtin scanners for many common asset types and works with discoverable plugins to support new types.
function manifestBuild()
{
	local -A fileList=();

	# commands are executables without an extension in the project root folder.
	# script libraries of various types are identified by their extension and can reside in any sub folder (but typically ./lib/)

	# these are the builtin asset types
	# TODO: all these builtin asset scanners could be combined into one bgfind invocation which would be more efficient. So far its
	#       very fast even making mutiple scans but if it gets noticably slower on big projects, we could make that change.
	_findCmdAssets
	_findAssetsOfType "lib.script.bash"  -R  *  -type f   -name "*.sh"
	_findAssetsOfType "lib.script.awk"   -R  *            -type f  -name "*.awk"
	_findAssetsOfType "unitTest" -R  unitTests/*  -type f  -perm /a+x -name "*.ut"
	_findAssetsOfType "manpage"  -R  man[1-9] .bglocal/funcman -type f  -path "*man*/*.[1-9]*"
	_findAssetsOfType "etc"      -R  etc/         -type f
	_findAssetsOfType "opt"      -R  opt/         -type f
	_findAssetsOfType "data"     -R  data/        -type f
	_findAssetsOfType "doc"      -R  readme.md README.md doc/ -type f
	_findAssetsOfType "cron"     -R  cron.d/      -type f
	_findAssetsOfType "sysVInit" -R  init.d/      -type f
	_findAssetsOfType "sysDInit" -R  systemd/     -type f
	_findAssetsOfType "syslog"   -R  rsyslog.d/   -type f
	_findAssetsOfType "globalBashCompletion" -R  * -name "*.globalBashCompletion" -type f

	_findAssetsOfType "bashplugin.creqConfig"     -R  * -type f  -name "*.creqConfig"
	_findAssetsOfType "bashplugin.standard"       -R  * -type f  -name "*.standard"
	_findAssetsOfType "bashplugin.collect"        -R  * -type f  -name "*.collect"
	_findAssetsOfType "bashplugin.bgGitFeature"   -R  * -type f  -name "*.bgGitFeature"
	_findAssetsOfType "bashplugin.rbacPermission" -R  * -type f  -name "*.rbacPermission"


	# export things for helper plugins to use
	export pkgName

	# now invoke any plugins available
	local findAssetCmd; for findAssetCmd in $({ compgen -c bg-dev-findAsset; compgen -A function findAsset; } | sort -u); do
		$findAssetCmd
	done
}
