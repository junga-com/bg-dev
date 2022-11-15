
# Library
# This bash script library provides functions to operate on nodejs style javascript projects



function jsNode_status()
{
	jsmoduleSymlinksStatus "$@"
}

function jsNode_install()
{
	local nodeLibFolder atomPluginFolder

	for nodeLibFolder in "${folderByLibrary[@]}"; do
		(
			echo "$nodeLibFolder:"
			cd "$nodeLibFolder" || assertError
			npm install | gawk '{print "   "$0}'
		)
	done

	for atomPluginFolder in "${folderByPlugin[@]}"; do
		(
			echo "$atomPluginFolder:"
			cd "$atomPluginFolder" || assertError
			apm install | gawk '{print "   "$0}'
		)
	done

	jsmoduleMakeSymlinksForLocalModules all
}

function jsNode_update()
{
	local nodeLibFolder atomPluginFolder

	for nodeLibFolder in "${folderByLibrary[@]}"; do
		(
			cd "$nodeLibFolder" || assertError
			npm update
		)
	done

	for atomPluginFolder in "${folderByPlugin[@]}"; do
		(
			cd "$atomPluginFolder" || assertError
			apm update
		)
	done

	jsmoduleMakeSymlinksForLocalModules all
}


function jsmoduleMakeSymlinksForLocalModules()
{
	[[ "$1" =~ ^(|all)$ ]] && set -- "${libraryByFolder[@]}"

	while [ $# -gt 0 ]; do
		local nodePkg nodePkgFolder; normLibraryParam "$1" nodePkg nodePkgFolder; shift
		local actionCount=0
		local type="" depFolder=""
		while read -r type depFolder; do
			local relPath="$(echo "${depFolder}" |awk '{gsub(/[^/]+[/]/,"../"); print}')"
			if [ "$type" == "d" ]; then
				echo "replacing '${depFolder}' with a symlink"
				rm -rf "${depFolder}" || assertError
				ln -s "${relPath}" "${depFolder}" || assertError
				((actionCount++))
			elif [ "$type" == "l" ] && [ ! -d "$depFolder/" ]; then
				echo "fixing bad symlink at '${depFolder}'"
				rm "$depFolder" || assertError
				ln -s "${relPath}" "${depFolder}" || assertError
				((actionCount++))
			fi
		done < <(find -H * -wholename "*/node_modules/${nodePkgFolder%/}" -printf "%y %p\n")
		((actionCount==0)) && echo "$nodePkg 'sall goodman"
	done
}

function jsmoduleSymlinksStatus()
{
	local library; for library in "${libraryByFolder[@]}"; do
		printfVars library
		local projectFolder; for projectFolder in "${folderByPlugin[@]}" "${folderByLibrary[@]}"; do
			local type="" version="<not installed>"
			if [ -h "$projectFolder"/node_modules/"$library" ]; then
				type="link"
			elif [ -d "$projectFolder"/node_modules/"$library" ]; then
				type="published"
			fi

			if [ -e "$projectFolder"/node_modules/"$library" ]; then
				version="$(getNodePkgVersion "$projectFolder"/node_modules/"$library")"
				if [ -e "$projectFolder"/node_modules/"$library"/.git ] && { [ "$(git -C "$projectFolder"/node_modules/"$library" log "v$version"... 2>&1)" ] || [ "$(git -C "$projectFolder"/node_modules/"$library" status -s)" ]; }; then
					version="${version}+"
				fi
			fi
			[ "$type" ] && type="($type)"
			printf "   %-23s : %-8s %s\n" "${pluginByFolder[$projectFolder]:-${libraryByFolder[$projectFolder]}}" "$version" "$type"
		done
	done
}


function atomPluginPkgStatus()
{
	echo "These plugins are installed in the --dev version of atom. (Contents of ~/.atom/dev/packages/)"
	ls -l ~/.atom/dev/packages/ | gawk '
		NR>1 { printf("   %-20s -> %s\n",$9, $11); count++ }
		END {if (!count) print("  <none>")}
	'
}

function atomPluginPkgInstallLink()
{
	local quietFlag
	while [ $# -gt 0 ]; do case $1 in
		-q) quietFlag="-q" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	[[ "$1" =~ ^(|all)$ ]] && set -- "${pluginByFolder[@]}"

	while [ $# -gt 0 ]; do
		local pluginName pluginPath; normPluginParam "$1" pluginName pluginPath; shift

		if [ ! -e /home/bobg/.atom/dev/packages/$pluginName ]; then
			ln -s "$PWD/$pluginPath" /home/bobg/.atom/dev/packages/$pluginName
			echo "   installed '$pluginName' in the --dev version of atom"
		elif [ ! -h /home/bobg/.atom/dev/packages/$pluginName ]; then
			assertError -v pluginName -v folder:"-l/home/bobg/.atom/dev/packages/$pluginName" "Could not create link because something else is at <folder>"
		fi
	done
	[ ! "$quietFlag" ] && atomPluginPkgStatus
}

function atomPluginPkgUninstallLink()
{
	local quietFlag
	while [ $# -gt 0 ]; do case $1 in
		-q) quietFlag="-q" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	[[ "$1" =~ ^(|all)$ ]] && set -- "${pluginByFolder[@]}"

	while [ $# -gt 0 ]; do
		local pluginName pluginPath; normPluginParam "$1" pluginName pluginPath; shift

		if [ -h /home/bobg/.atom/dev/packages/$pluginName ]; then
			rm /home/bobg/.atom/dev/packages/$pluginName || assertError
			echo "   uninstalled '$pluginName' from --dev version of atom"
		elif [ -e /home/bobg/.atom/dev/packages/$pluginName ]; then
			assertError -v pluginName -v folder:"-l/home/bobg/.atom/dev/packages/$pluginName" "Expected the folder to be a symlink but its something else"
		fi
	done
	[ ! "$quietFlag" ] && atomPluginPkgStatus
}




function makeListsOfProjects()
{
	declare -gA pluginByFolder
	declare -gA folderByPlugin
	declare -gA folderByLibrary
	declare -gA libraryByFolder

	for folder in $(fsExpandFiles -D */); do
		folder="${folder%/}"
		if [ -f "$folder/package.json" ]; then
			local projectName projectType projectVersion; read -r projectName projectType projectVersion < <(getProjectNameTypeAndVersion "$folder/package.json")
			if [ "$projectType" == "atomPlugin" ]; then
				folderByPlugin["$projectName"]="$folder"
				pluginByFolder["$folder"]="$projectName"
			else
				folderByLibrary["$projectName"]="$folder"
				libraryByFolder["$folder"]="$projectName"
			fi
		fi
	done

	#printfVars pluginByFolder folderByPlugin folderByLibrary libraryByFolder
}

function normLibraryParam()
{
	local _jsNodePkgIDValue="$1"; shift
	assertNotEmpty _jsNodePkgIDValue "the node package library name is a required argument"
	if [ "${libraryByFolder["$_jsNodePkgIDValue"]+exists}" ]; then
		setReturnValue "$1" "${libraryByFolder["$_jsNodePkgIDValue"]}"
		setReturnValue "$2" "$_jsNodePkgIDValue"
	elif [ "${folderByLibrary["$_jsNodePkgIDValue"]+exists}" ]; then
		setReturnValue "$1" "$_jsNodePkgIDValue"
		setReturnValue "$2" "${folderByLibrary["$_jsNodePkgIDValue"]}"
	else
		assertError "'$_jsNodePkgIDValue' does not seem to identify a node library project (by name or by folder name)"
	fi
}

function normPluginParam()
{
	local _pluginNameValue="$1"; shift
	assertNotEmpty _pluginNameValue "the atom plugin name is a required argument"
	if [ "${pluginByFolder["${_pluginNameValue:-<empty>}"]+exists}" ]; then
		setReturnValue "$1" "${pluginByFolder["$_pluginNameValue"]}"
		setReturnValue "$2" "$_pluginNameValue"
	elif [ "${folderByPlugin["${_pluginNameValue:-<empty>}"]+exists}" ]; then
		setReturnValue "$1" "$_pluginNameValue"
		setReturnValue "$2" "${folderByPlugin["$_pluginNameValue"]}"
	else
		assertError "'$_pluginNameValue' does not seem to identify an atom plugin project (by name or by folder name)"
	fi
}

function getProjectNameTypeAndVersion()
{
	local packageJsonPath="$1"
	gawk -i bg_core.awk '
		BEGIN {projectType="nodejs"}
		/["]name["]:/ {
			projectName=gensub(/^.*:[[:space:]]*["]|["].*$/,"","g",$0)
		}
		/["]version["]:/ {
			projectVersion=gensub(/^.*:[[:space:]]*["]|["].*$/,"","g",$0)
		}
		/["]engines["]:/ {
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

function getNodePkgVersion()
{
	local _pkgFolderValue="$1"
	local _versionValue="$(gawk '
		/^[[:space:]]*["]version["][[:space:]]*:[[:space:]]*/ {
			match($0,/["]version["][[:space:]]*:[[:space:]]*["](.*)["],?$/, rematch)
			print(rematch[1])
		}
	' $(fsExpandFiles -f "$_pkgFolderValue/package.json"))"
	returnValue "$_versionValue" "$2"
}
