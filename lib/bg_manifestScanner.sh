
import bg_manifest.sh ;$L1;$L2
import bg_plugins.sh ;$L1;$L2

manifestProjPath=".bglocal/manifest"

# usage: manifestAddNewAsset <assetType> <assetName>
function manifestAddNewAsset()
{
	local assetType="$1"; shift; assertNotEmpty assetType
	local assetName="$1"; shift; assertNotEmpty assetName

	import PackageAsset.PluginType  ;$L1;$L2

	case $assetType in
		cmd.*|cmd)   addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./$assetName" ;;
		lib.*)       addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./lib/$assetName" ;;
		cron.*)      addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./cron/$assetName" ;;
		sysDInit.*)  addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./init/$assetName" ;;
		template.*)  addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./templates/$assetName" ;;
		unitTest.*)  addNewAssetFromTemplate "newAsset.$assetType" "$assetName" "./untiTests/$assetName" ;;
		plugin.*)
			local pluginType="${assetType#plugin.}"
			local -n pt; $Plugin::get PluginType:$pluginType pt
			$pt::addNewAsset "$assetName"
			;;
		*)	local -n assetP; $Plugin::get PackageAsset:$assetType assetP

			import bg_template.sh  ;$L1;$L2

			$assetP.addNewAsset "$assetName"
			;;
	esac
}

# usage: manifestListKnownAssetTypes
# print a list of known asset types to stdout
function manifestListKnownAssetTypes()
{
	printf "  "

	Try:
		$Plugin::loadAllOfType PackageAsset
	Catch: { : }

	local assetTypeFn; for assetTypeFn in $( { compgen -A command bg-dev-install_; compgen -A function bgAssetInstall_; } | sort -u); do
		local assetType="${assetTypeFn#bg-dev-install_}"
		assetType="${assetType#bgAssetInstall_}"
		assetType="${assetType%__*}"
		assetType="${assetType//_/.}"
		printf "%s " "$assetType"
	done
	printf "\n"
}


# usage: manifestList
function manifestList()
{
	local verbosity=${verbosity}
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	assertNotEmpty manifestProjPath

	[ ! -e $manifestProjPath ] && manifestUpdate

	import bg_awkDataQueries.sh  ;$L1;$L2

	awkData_query --awkDataID="manifest|${manifestProjPath}-|" "$@"
}


# usage: manifestUpdate
# This saves the results of manifestBuild in a temporary file and replaces $manifestProjPath with it if they are not identical.
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


# usage: _findAssetsOfType [--rmSuffix=<suffix>] [--template=<nameTemplate>] <assetType> <findTerms...>
# Search the PWD for assets matching the <findTerms...> criteria passed in.
# Options:
#    --rmSuffix=<suffix>       : when making the assetName from the found filename, remove this suffix from the filename
#    --template=<nameTemplate> : use this template to make the assetName. The variable %name% can be used in the template and will
#                                have the value that assetName would have had if this option was not specified
# Params:
#    <assetType>     : The type of asset being found by this invocation
#    <findTerms...>  : the terms passed through to fsExpandFiles (similar to gnu find utility) that match only asset files of
#                      <assetType>
function _findAssetsOfType()
{
	local rmSuffix nameTemplate
	while [ $# -gt 0 ]; do case $1 in
		--rmSuffix*) bgOptionGetOpt val: rmSuffix "$@" && shift ;;
		--template*) bgOptionGetOpt val: nameTemplate "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local assetType="$1"; shift
	local -A fileList=()
	local templateExcludeExpr=(); [ "$assetType" != "template" ] && templateExcludeExpr=( --exclude=/templates )
	fsExpandFiles -S fileList --gitignore "${templateExcludeExpr[@]}" "$@"
	local filename; for filename in "${!fileList[@]}"; do
		local assetName="${filename%/}"
		assetName="${assetName##*/}"
		if [[ ! "$filename" =~ /$ ]] && [[ "$assetName" =~ $rmSuffix$ ]]; then
			assetName="${assetName%${BASH_REMATCH[0]}}"
		fi
		[ "$nameTemplate" ] && assetName="${nameTemplate//%name%/$assetName}"
		printf "%-20s %-20s %-20s %s\n" "${pkgName:---}" "${assetType:---}"  "${assetName:---}"  "${filename:---}"
	done
}

function _findPluginAssets()
{
	# pre-populate the list with some known types so that assets of those types will be found even if something is wrong
	local -A pluginTypeSet=([PluginType]= [Config]= [Standards]= [Collect]= [BgGitFeature]= [RBACPermission]= )
	$Plugin::types -a -S pluginTypeSet

	local pluginType findTerm orTerm
	for pluginType in "${!pluginTypeSet[@]}"; do
		findTerm+=" $orTerm -name *.${pluginType} "
		orTerm=" -o "
	done

	local -A fileList=(); fsExpandFiles -f -S fileList --gitignore --exclude=/templates --exclude=/pkgControl -R -- ./* -type f \( $findTerm \)
	local pluginType pluginID filename
	while read -r pluginType pluginID filename; do
		[[ "$filename" =~ templates/ ]] && continue
		printf "%-20s %-20s %-20s %s\n" "${pkgName:---}" "plugin"  "${pluginType}:${pluginID}"  "${filename}"
	done < <(awk --include="bg_core.awk" '
		$1=="DeclarePlugin" {print $2 " " $3 " " FILENAME}
		$1=="DeclarePluginType" {print "PluginType " $2 " " FILENAME}
	' "${!fileList[@]}")
}


function _findCmdAssets()
{
	local -A fileList=()
	fsExpandFiles -S fileList --gitignore --exclude=/templates --exclude=/pkgControl -- ./* -perm /a+x -type f '!' -name "*.*" '!' -name Makefile
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

		local assetName="${filename%/}"
		assetName="${assetName##*/}"
		[[ ! "$filename" =~ /$ ]] && assetName="${assetName%%.*}"

		printf "%-20s %-20s %-20s %s\n" "${pkgName:---}" "${assetType:---}"  "${assetName:---}"  "${filename:---}"
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
	_findAssetsOfType --rmSuffix="[.]sh"     "lib.script.bash"           -R  --exclude=/unitTests -- ./*                       -type f  -name "*.sh"
	_findAssetsOfType --rmSuffix="[.]awk"    "lib.script.awk"            -R  --exclude=/unitTests -- ./                        -type f  -name "*.awk"
	_findAssetsOfType --rmSuffix="[.]ut"     "unitTest"                  -R  -- unitTests/*               -type f  -perm /a+x -name "*.ut"
	_findAssetsOfType --rmSuffix=""          "manpage"                   -R  -- man[1-9] .bglocal/funcman -type f  -path "*man*/*.[1-9]*"
	_findAssetsOfType --rmSuffix=""          "etc"                       -R  -- etc/                      -type f
	_findAssetsOfType --rmSuffix=""          "opt"                       -R  -- opt/                      -type f
	_findAssetsOfType --rmSuffix=""          "data"                      -R  -- data/                     -type f
	_findAssetsOfType --rmSuffix="[.]btpl"   "template"                  -R  -- templates/                -type f
	_findAssetsOfType --rmSuffix=""          "doc"                       -R  -- readme.md README.md doc/  -type f
	_findAssetsOfType --rmSuffix=""          "cron"                      -R  -- cron.d/                   -type f
	_findAssetsOfType --rmSuffix=""          "sysVInit"                  -R  -- init.d/                   -type f
	_findAssetsOfType --rmSuffix=""          "sysDInit"                  -R  -- systemd/                  -type f
	_findAssetsOfType --rmSuffix=""          "syslog"                    -R  -- rsyslog.d/                -type f
	_findAssetsOfType --rmSuffix=""          "globalBashCompletion"      -R  -- ./*                       -type f  -name "*.globalBashCompletion"
	_findAssetsOfType --rmSuffix="[.]awkDataSchema" "data.awkDataSchema" -R  -- ./* -type f  -name "*.awkDataSchema"

	_findPluginAssets
	# _findAssetsOfType --rmSuffix="[.]PluginType"     --temlate="PluginType:%name%"     "plugin"  -R  -- * -type f  -name "*.PluginType"
	# _findAssetsOfType --rmSuffix="[.]Config"         --temlate="Config:%name%"         "plugin"  -R  -- * -type f  -name "*.Config"
	# _findAssetsOfType --rmSuffix="[.]Standards"      --temlate="Standards:%name%"      "plugin"  -R  -- * -type f  -name "*.Standards"
	# _findAssetsOfType --rmSuffix="[.]Collect"        --temlate="Collect:%name%"        "plugin"  -R  -- * -type f  -name "*.Collect"
	# _findAssetsOfType --rmSuffix="[.]BgGitFeature"   --temlate="BgGitFeature:%name%"   "plugin"  -R  -- * -type f  -name "*.BgGitFeature"
	# _findAssetsOfType --rmSuffix="[.]RBACPermission" --temlate="RBACPermission:%name%" "plugin"  -R  -- * -type f  -name "*.RBACPermission"

	# load any PackageAsset plugins avaialble so that their find functions will be found and executed
	Try:
		$Plugin::loadAllOfType PackageAsset
	Catch: { : }

	# export things for helper plugins to use
	export pkgName

	# now invoke any plugins available
	local findAssetCmd; for findAssetCmd in $({ compgen -A command bg-dev-findAsset; compgen -A function bgAssetFind; } | sort -u); do
		$findAssetCmd #>> $_bgtraceFile
	done
}

# usage: manifestUpdateInstalledManifestVinstall
# this is called by "bg-debugCntr vinstall" to create/update a virtual host manifest file. It sets the path in $bgVinstalledManifest
# and this function creates/updates it by starting with the actual installed manifest and then replacing any vinstalled projects
function manifestUpdateInstalledManifestVinstall() {
	### vinstall support
	if [ "$bgVinstalledManifest" ]; then
		local IFS=:; local vinstalledManifestFiles=($bgVinstalledPaths); IFS="$bgWS"
		vinstalledManifestFiles=("${vinstalledManifestFiles[@]/%/\/$manifestProjPath}")
		if fsGetNewerDeps --array=dirtyDeps "$bgVinstalledManifest" "$manifestInstalledPath" "${vinstalledManifestFiles[@]}"; then
			fsTouch "$bgVinstalledManifest" || assertError
			# the following awk script is passed the installed hostmanifest first and then the manifest of each vinstalled project.
			# The installed manifest is read directly into arrays collating by packagename. Then for each vinstalled project, its
			# array is reset if present from the installed manifest data and then added from the vinstalled project manaifest. The
			# net result is that any installed packages that are not vinstalled, will remain in the new manifest plus entries from
			# each vinstalled package.
			awk -v manifestProjPath="$manifestProjPath" '
				@include "bg_core.awk"
				BEGIN {arrayCreate(linesByPkg)}
				BEGINFILE {
					filePosition++
					if (filePosition>1) {
						basePath=gensub("/"manifestProjPath"$","","g",FILENAME)
					}

				}
				filePosition>1 && FNR==1 {
					# this will reset this pkgs array from the installed hostmanifest or create a new one if pkg was not in hostmanifest
					arrayCreate2(linesByPkg, $1)
				}
				{
					if (! ($1 in linesByPkg))
						arrayCreate2(linesByPkg, $1)
					sub($4"$",basePath"/"$4, $0)
					arrayPush(linesByPkg[$1], $0)
				}
				END {
					for (pkg in linesByPkg)
						for (i in linesByPkg[pkg])
							print linesByPkg[pkg][i];
				}
			' $(fsExpandFiles -f "$manifestInstalledPath") "${vinstalledManifestFiles[@]}" | sort > "$bgVinstalledManifest"
		fi
	fi


	if [ "$bgVinstalledPluginManifest" ]; then
		import bg_plugins.sh  ;$L1;$L2
		$Plugin::buildAwkDataTable | fsPipeToFile "$bgVinstalledPluginManifest"
	fi
}
