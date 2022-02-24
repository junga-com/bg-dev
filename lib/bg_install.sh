
# Library
# This library provides the ability to install assets contained in a bg-dev style project.
# This library provides the bgInstallAssets and bgUninstallAssets functions used by the bg-dev tool.
# bgInstallAssets iterates a bg-dev style project's manifest file and for each asset, invokes the install behavior defined by that
# assetType.  Some core assetTypes have builtin install functions but in general, each assetType has a PackageAsset plugin instance
# that must be installed on the dev-time host.
#
# As bgInstallAssets runs, it builds a host manifest file and an unistall script.
#
# Typically the "bg-dev buildPkg" command calls bgInstallAssets to create the staging folder that will go into the package.
# "bg-dev install" also calls bgInstallAssets to install directly into the developer's host, but that is not in the typical workflow.
#
# Not all OS use the same policy for where assets of a given type should be placed so the install behavior of a PackageAsset plugin
# can be subclassed to treat each supported OS differently. Typically, the default install follows the debian standard and is invoked
# when a deb package is built and a separate .rpm behavior is needed to correctly build an rom package to install on redhat derivitives.
#
# See Also:
#    man(3) bgInstallAssets
#    man(3) bgUninstallAssets
#    man(3) bg-dev-assets
#    man(3) PackageAsset
#    man(7) bg_manifestScanner.sh



# man(5) bgAssetInstallPluginProtocol
# bgAssetInstall uses an polymorphic system to install assets correctly given their assetType.
# bgAssetInstall is used by the bg-dev command when it needs to install assets into the target OS filesystem which could be a staging
# folder in preparation of building a deb or rpm package, or it could be a host's real filesystem when a project folder is directly
# installed.
#
# bgAssetInstall will iterate a project's assets listed in its manifest file and for each a set of assets of the same fully qualified
# assetType it will invoke a function that is specific to the assetType.
#
# Two mechanisms are avaiable to create the install function for a new assetType.
#
# PackageAsset Method:
# The newer and generally prefered method is to create a PackageAsset plugin instance in the package that provides the new assetType
# functionality. Use "bg-dev assets addNewAsset plugin.PackageAsset -- <newAssetTypeName>" to create a new assetType in a package
# project.  The plugins/<newAssetTypeName>.PackageAsset file that it creates has fucntions defined for scan, install, and addNewAsset
# with typical generic implementations that can then be modified to suite the behavior of the specific assetType.
#
# The plugin functions actually use the second, lower level method so we can think of the plugins as a convenient wrapper over that
# that method. The plugin's method functions must use the naming convention described in the next section.
#
# Function Naming Convention Method:
# The lower level method is used directly by the builtin assetTypes provided by bg-dev.  It is based on naming a bash function (or
# an external command) to identify the function as the install behavior for an specific assetType.
#
# An assetType built into bg-dev can define a function in this library with the correct name for the assetType. Because this librabry
# must be loaded to run bgInstallAssets, the helper functions defined in it will be automatically available.
#
# This naming convention also works for external commands as well as for functions but that is typically not used. With the advent
# of the PackageAsset plugin, using external command helper functions is not needed and if an external command helpwe is required,
# it can be invoked from the plugin's method (aka function).
#
# This naming convention also allows the install behavior for an assetType to be subclassed to handle the installation to different
# OS correctly. Two types of OS are initially supported -- 'deb' for installation into debian style OS and 'rpm' for installation
# into redhat style OS.
#
# The function or command used to install an assetType is the first one that exists in the following list.
#   * bg-dev-install_<assetTypeStr>__<installType>       # external command, specific to <installType>
#   * bgAssetInstall_<assetTypeStr>__<installType>       # sourced function, specific to <installType>
#   * bg-dev-install_<assetTypeStr>                      # external command that works for any <installType>
#   * bgAssetInstall_<assetTypeStr>                      # sourced function that works for any <installType>
#   * Note that <assetTypeStr> is the asset type with '.' replaced with '_'.
#   * Note that there are two '_' between <assetTypeStr> and <installType> two distinguish <installType> from an asstType subtype.
#   * if asset name contains a qualification (e.g. cmd.script.bash), if no function nor command is found, the last qualification
#     is removed and the above names checked again. This is repeated until a function or command is found or <assetTypeStr> is empty.
#
# Subclassing For OS and AssetType Qualifications:
# This naming scheme allows one generic helper to handle all assets of a base type installed to any OS but also if there are different
# install procedures for a specific subtype of that assetType or when that assetType is installed on a specific OS, a new function
# can be added to handle that case differently.
#
# For example...
#      bgAssetInstall_lib()              installs lib assetTypes into the /usr/lib/ folder.
#      bgAssetInstall_lib_script_awk()   installs lib.script.awk assetTypes into the /usr/share/awk/ folder.
#
# It is also possible to write the bgAssetInstall_lib() function to be aware that awk script libraries have to go to a different place.
# It can examine the actual fully qualified assetType name and also the INSTALLTYPE Environment variable and take appropriate action.
# The author of an assetType can decide which way to do it.
#
# Asset names can be qualified with periods. For example `lib` is a generic library asset that might be a bainary file or a script.
# 'lib.binary' is specifically a compiled library file and 'lib.script.bash' is specifically a bash script library.
#
#
# CAll Protocol - Params:
# An install helper function is invoked by bgInstallAssets like this...
#      <helperCmd> <assetType> <fileOrFolder1>[..<fileOrFolderN>]
# where...
#    <assetType>     : the specific asset type that may include qualifications (like lib.bash) that the following files or folders
#                      belong to.
#    <fileOrFolderN> : a file object to install.
#
# CAll Protocol - Environment Available:
# The following environment variables are available when helper commands or functions are called...
#    * DESTDIR          : the top of the path where the project is being installed. Empty means its being installed in the root filesystem
#    * INSTALLTYPE      : deb|rpm. Determines the standard of the target filesystem. Others may be added in the future.
#    * PRECMD           : this is meant to prefix commands that modify the DESTDIR. If the user does not have permissions to modify
#                         DESTDIR, this will contain the sudo command that gives the user sufficient permissions. It will be empty
#                         if the useer does have sufficient permission. It assumes that permissions to modify the root of DESTDIR
#                         is sufficient to modify any path relative to DESTDIR
#    * UNINSTSCRIPT     : The path of the uninstall script that is being built up by the installation. For each action the helper
#                         does to modify DESTDIR, it should append a line to this script that undoes it. The script provides the
#                         `rmFile [-r] <target>` function that can be used to undo the action of copying a file. If -r is specified,
#                         if it removes the last file in a folder, that folder will also be removed.
#    * pkgName          : The name of the package being installed.
#    * manifestProjPath : The path of the package's manifest file relative to the prject root. The list of files or folders sent to
#                         the helper came from this file. On rare ocassions, the helper may want to query the manifest to see what
#                         other related assets are being installed.

import bg_manifestScanner.sh ;$L1;$L2

# FUNCMAN_AUTOOFF

### define the built-in helper functions for all the known asset types. Each of these are discovered by the builtin section of the
# manifestBuild function
# note that an install* function does not have to use _installFilesToDst. It can do anything it wants to represent its assets in
# the destination file system. See man(1) bg-dev-install and the _installFilesToDst function as a model to build a custom helper.
function bgAssetInstall_unitTest()   { : ; } # unittests are not installed
#                                                                       <pkgPath>      <dstPath>                   <pass thru type plus filepaths>
function bgAssetInstall_cmd()        { _installFilesToDst --flat             ""             "/usr/bin"                  "$@" ; }
function bgAssetInstall_lib()        { _installFilesToDst --flat             ""             "/usr/lib"                  "$@" ; }
function bgAssetInstall_etc()        { _installFilesToDst                    "etc/"         "/etc"                      "$@" ; }
function bgAssetInstall_opt()        { _installFilesToDst                    "opt/"         "/opt"                      "$@" ; }
function bgAssetInstall_data()       { _installFilesToDst                    "data/"        "/usr/share/$pkgName"       "$@" ; }
function bgAssetInstall_template()   { _installFilesToDst                    "templates/"   "/usr/share/$pkgName"       "$@" ; }
function bgAssetInstall_template_folder() { _installFilesToDst --renameFile  "templates/"   "/usr/share/$pkgName"       "$@" ; }
function bgAssetInstall_doc()        { _installFilesToDst -z "doc/changelog" "doc/"         "/usr/share/doc/$pkgName"   "$@" ; }
function bgAssetInstall_manpage()    { _installFilesToDst -z "^"             ".bglocal/funcman" "/usr/share/man"        "$@" ; }
function bgAssetInstall_cron()       { _installFilesToDst                    "cron.d/"      "/etc/cron.d"               "$@" ; }
function bgAssetInstall_sysVInit()   { _installFilesToDst                    "init.d/"      "/etc/init.d"               "$@" ; }
function bgAssetInstall_sysDInit()   { _installFilesToDst                    "systemd/"     "/etc/systemd/system"       "$@" ; }
function bgAssetInstall_syslog()     { _installFilesToDst                    "rsyslog.d/"   "/etc/rsyslog.d"            "$@" ; }
function bgAssetInstall_globalBashCompletion() { _installFilesToDst --flat   ""             "/usr/share/$pkgName/bash_completion.d" "$@" ; }
function bgAssetInstall_lib_script_awk()       { _installFilesToDst --flat   ""             "/usr/share/awk"            "$@" ; }

# FUNCMAN_AUTOON


# usage: bgAssetInstall_plugin
# TODO: this function igores the filenames of the assets passed to it and iterates the manifest file so it can get the correct assetName
#       which is not easily derived from the filename. After the change to pass <assetName>|<assetFile>, we can use the generic _installFilesToDst
#       like most other builtin assets do
function bgAssetInstall_plugin() {
	local type="$1"; shift
	[ "$type" == "plugin" ] || assertError "logic error. bgAssetInstall_plugin called with the wrong asset type"

	local dstPath="${DESTDIR}/usr/lib"
	[ ! -e "$dstPath" ] && { $PRECMD mkdir -p "$dstPath" || assertError; }

	local assetPkg assetType assetName assetFile
	while read -r assetPkg assetType assetName assetFile; do
		{ [ ! "$assetFile" ] || [ ! -f "$assetFile" ]; } &&  assertError -v type -v assetFile "This file listed in the project manifest does not exist in the project"
		local dstFile="${dstPath}/${assetFile##*/}"
		local dstFolder="${dstFile%/*}"
		$PRECMD cp "$assetFile" "$dstFile" || assertError

		# write this asset to the HOSTMANIFEST
		printf "%-20s %-20s %-20s %s\n" "$assetPkg" "$assetType" "$assetName" "${dstFile#${DESTDIR}}" | $PRECMD tee -a  $HOSTMANIFEST >/dev/null

		echo "rmFile '$dstFile' || assertError" | $PRECMD tee -a  "${UNINSTSCRIPT}" >/dev/null
	done < <(manifestGet --manifest="$manifestProjPath" "plugin" ".*")
}



# usage: _installFilesToDst <pkgPath> <dstPath>   <type> [<fileOrFolder1>...<fileOrFolderN>]
# This is a helper function typically used by asset install helper functions to copy their asset files to the DESTDIR.
# It can support several common patterns based on what options are specified.
#
# bgInstallAssets() will bundle assets in a project into sets with the same assetType and call the install helper for that
# assetType passing in the specific assetType and a list of files or folders of assets of that type. If a helper function uses this
# function, it adds the first two arguments of this function and then passes through the assetType and filenames. This function also
# accepts several options that affect the way it installs the filenames.
#
# The <pkgPath> <dstPath> parameters allow this function to turn the relative project path of each asset into the absolute path
# in the destination filesystem. <pkgPath> is required because sometimes assets are put in a folder just to better organize the
# assets in the project and sometimes they are in a folder hierarchy that should be reproduced in the target filesystem. The
# general algorithm is to remove the <pkgPath> from the front and prepend <dstPath> but that can be changed with the --flat option.
# When --flat is specified, the entire projet path is ignored and all of these asset files are placed directly in <dstPath>.
#
# The --zipSpec option identifies destination files that should be compressed with gzip (such as copyright and changelog files)
#
# Install Helper Functions:
# To support a new assetType, a new function needs to be created specific to that assetType and many times all that function needs
# to do is call this function with the appropriate arguments.
# There are two mechanisms for to create an assetType install function. The typical way is to create a new PackageAsset plugin which
# will contain a function for installing as well as one for scanning and another to add a new asset of that type to a project.
# There is also an older convention that is still used by the builtin assets that is to create a function by the name
# bgAssetInstall_<assetType>.  Since that function needs to be loaded, that mechanism works well for builtin assetTypes but for
# assetTypes provided by thrid party packages, the PackageAsset method is required.
# The complete naming convention is documented in `man(5) bgAssetInstallPluginProtocol`
# An assetType install function does not need to use this function. `man(5) bgAssetInstallPluginProtocol`  descibes what the function
# has to do to install an asset correctly.
# Params:
#    <pkgPath> : the path prefix of the asset in the project folder. This part of the asset path will not be reproduced in the <dstPath>
#    <dstPath> : the destination folder where assets of this type are installed. The asset path structure will be reproduced here
#    <type>    : the asset type. (e.g. cmd, lib.bash, awkLib, manpage, etc...) of the list of files that follow
#                The bgInstaller may call the same helper multiple times with a different value of <type> because it could use the
#                same helper for multiple qualified asset types. e.g. if a handler handles any "lib" type it could be called with
#                "lib.bash" and "lib.python".
#    <fileOrFolderN>   : filenames of assets of this type to install. Note that if no <fileOrFolderN> are passed to this function, the manifest file
#                will be read to get the list of asset files to process.
# Options:
#    -z|--zipSpec=<regex> : Any <fileOrFolderN> that matches this expression will be compressed into a .gz file instead of copied as is.
#                           '^' matches all files. The motivation was the doc folder where the changelog file needs to be
#                           compressed but other doc files do not.
#    -f|--flat : causes all files to be placed in the root of <dstPath> regardless of the relative path of the file in the project
#    --renameFile : causes the destination filename to take the assetName instead of the original asset's filename
function _installFilesToDst() {
	local zipSpec="^$" # default is to match no files
	local flatFlag recurseRmdir="-r" renameFileFlag
	while [ $# -gt 0 ]; do case $1 in
		-z*|--zipSpec*) bgOptionGetOpt val: zipSpec "$@" && shift ;;
		-f|--flat)  flatFlag="-f"; recurseRmdir="" ;;
		--renameFile) renameFileFlag="--renameFile" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local pkgPath="$1"; shift
	local dstPath="${DESTDIR}$1"; shift

	local assetType="$1"; shift

	local files=(); [ $# -eq 0 ] && { manifestReadOneType --file="$manifestProjPath" files "$assetType" || assertError; }
	for file in "$@" "${files[@]}"; do
		# TODO: 2021-02-22: the original protocol only passed <assetFile> and not <assetName>|<assetFile> in each token so this
		#       code checks for the presense of a | to determine which is being sent. after the transition, we can remove that
		local assetName=""
		if [[ "$file" =~ [|] ]]; then
			assetName="${file%%|*}"
			file="${file#*|}"
		else
			# this is the old way that gleans the assetName from the filename, but its much better to use the name from the manifest
			assetName="${file%/}"
			assetName="${assetName##*/}"
			[[ ! "$file" =~ /$ ]] && assetName="${assetName%%.*}"
		fi

		# some assets were ending up with the useless './' prefix and that messes up the recursive folder removal in uninstallscript
		# its probably some ways that _findAssetsOfType() is called
		file="${file#./}"

		# sanity check...
		{ [ ! "$file" ] || [ ! -e "$file" ]; } &&  assertError -v assetType -v file "file does not exist in the project"

		### determine the full dstFile path. This is the main algorithm of this function based on <pkgPath>,<dstPath>, and <flatFlag>
		# start with the project filename
		local dstFile="$file"
		# replace the name part with the assetName if called for
		if [ "$renameFileFlag" ]; then
			if [[ "$dstFile" =~ [/] ]]; then
				dstFile="${dstFile%/*}/${assetName}"
			else
				dstFile="${assetName}"
			fi
		fi
		# now add the dstPath prefix.
		if [ "$flatFlag" ]; then
			dstFile="${dstPath}/${dstFile##*/}"
		else
			dstFile="${dstPath}/${dstFile#$pkgPath}"
		fi

		# make sure that the asset's parent folder exists in the destination
		local dstFolder="${dstFile%/*}"
		[ ! -e "$dstFolder" ] && { $PRECMD mkdir -p "$dstFolder" || assertError; }

		# copy to the destination, zipping if needed
		if [[ "$file" =~ $zipSpec ]] && [[ ! "$file" =~ [.]gz$ ]]; then
			dstFile="${dstFile}.gz"
			gzip -n -f -9  < "$file" | $PRECMD tee "$dstFile" >/dev/null || assertError
		else
			$PRECMD cp -r "$file" "$dstFile" || assertError
		fi

		# write this asset to the HOSTMANIFEST
		printf "%-20s %-20s %-20s %s\n" "$pkgName" "$assetType" "$assetName" "${dstFile#${DESTDIR}}" | $PRECMD tee -a  $HOSTMANIFEST >/dev/null

		# write the uninstall cmd to the UNINSTSCRIPT
		echo "rmFile $recurseRmdir '$dstFile' || assertError" | $PRECMD tee -a  "${UNINSTSCRIPT}" >/dev/null
	done
}




# usage: bgInstallAssets [-v] [-q] [--triggers=<trigObj>] <hostType> <destDir>
# Installs the assets from the project into <destDir> using the standard defined by <hostType>.
#
# Helper Commands or Functions:
# This function iterates the asset types in the project's manifest file and for each found, it looks for a helper command or function
# that matches the asset type name and install type (deb|rpm or generic) and executes that helper with the list of files or folders
# of that asset type present in the project. Each file or folder is relattive to the project's root folder. The helper is responsible
# to install the asset and also to append to the UNINSTSCRIPT a command that will undo the installation of each asset.
#
# Options:
#    --triggers=<trigObj> : <trigObj> is a bash object that implements methods for preinst,postinst,prerm,postrm events
#    -q : less output
#    -v : more output
# Params:
#    <hostType> : deb|rpm|detect : the type of the host system installing to. Assets are installed to the appropriate folders for
#                 the <hostType>. If the value is "detect" then the local host will be queried to determine the type of the host.
#    <destDir>  : the root folder of the system to install the project into. An empty value indicates that it will be installed
#                 into the local host's file system. When building a package for distribution, this should point to the staging
#                 folder for the package.
# See Also:
#    man(5) bgInstallHelpCmdProtocol
function bgInstallAssets()
{
	local verbosity=${verbosity} noUpdateFlag
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--no-update) noUpdateFlag=1 ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local -x INSTALLTYPE="$1"
	local -x DESTDIR="$2"

	if [ "$INSTALLTYPE" == "detect" ]; then
		INSTALLTYPE=""
		which apt &>/dev/null && INSTALLTYPE="deb"
		[ ! "$INSTALLTYPE" ] && which rpm &>/dev/null && INSTALLTYPE="rpm"
		[ ! "$INSTALLTYPE" ] && INSTALLTYPE="deb"
	fi
	[ "$DESTDIR" == "/" ] && DESTDIR=""

	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is already installed and change "install" to "upgrade"
		[ -f pkgControl/preinst ] && { sudo ./pkgControl/preinst "install" || assertError; }
	fi

	[ "$DESTDIR" ] && [ ! -e "$DESTDIR/" ] && mkdir -p "$DESTDIR"
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="bgsudo "

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"
	local HOSTMANIFEST="${DESTDIR}/var/lib/bg-core/$pkgName/hostmanifest"

	[ ${verbosity:-0} -ge 1 ] && printf "installing to %s\n" "${DESTDIR:-host filesystem}"

	export DESTDIR INSTALLTYPE PRECMD UNINSTSCRIPT pkgName manifestProjPath
	#export -f manifestReadOneType --file="$manifestProjPath" bgOptionsEndLoop varSet printfVars varIsA

	### if there is a previous installation, remove it
	if [ -f "$UNINSTSCRIPT" ]; then
		bgUninstallAssets "$INSTALLTYPE" "$DESTDIR"
	fi

	### Start the HOSTMANIFEST file
	# fsTouch can not use $PRECMD b/c its a function (sudo only does files) but fsSudo will prompt sudo as needed
	fsTouch -p "$HOSTMANIFEST"
	$PRECMD truncate -s0 "$HOSTMANIFEST"

	### Start the $UNINSTSCRIPT script
	$PRECMD mkdir -p "${DESTDIR}/var/lib/bg-core/$pkgName"
	$PRECMD bash -c 'cat >"'"${UNINSTSCRIPT}"'"  <<-EOS
		#!/usr/bin/env bash
		#(its better to create a bespoke assertError) # [ -f /usr/lib/bg_core.sh ] && source /usr/lib/bg_core.sh
		[ "\$(type -t assertError)" != "function" ] && function assertError() {
		   printf "uninstall script failed: \n\tlocation:\$0(\${BASH_LINENO[0]})\n\tline: \$(gawk 'NR=='"\${BASH_LINENO[0]}"'' \$0)\n"
		   exit 2
		}
		function rmFile() {
		   local recurseFlag; [ "\$1" == "-r" ] && { recurseFlag="-r"; shift; }
		   local dirFlag;     [ -d "\$1" ] && dirFlag="-r"
		   [ "\$dirFlag" ] && [[ "\$1" =~ ^(/[^/]*)$ ]] && { printf "uninstall script warning: refused to remove top level folder '%s'\n" "\$1" ; return; }
		   [ -e "\$1" ]        && { \$preUninstCmd rm \$dirFlag -f "\$1" || return; }
		   [ "\$recurseFlag" ] && { \$preUninstCmd rmdir --ignore-fail-on-non-empty -p  "\${1%/*}" &>/dev/null; true; }
		   true
		}
		preUninstCmd=""; [ ! -w "\$0" ] && preUninstCmd="sudo "; true
		EOS' || assertError "error writing the initial uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}" || assertError

	### Update the asset manifest
	[ ! "$noUpdateFlag" ] && manifestUpdate

	# load any PackageAsset plugins avaialble so that their install functions will be found and executed
	Try:
		$Plugin::loadAllOfType PackageAsset
	Catch: { : }

	# iterate the assetTypes present in the manifest
	local -A types; manifestReadTypes --file="$manifestProjPath" types
	local type; for type in "${!types[@]}"; do
		assertNotEmpty type
		[ ${verbosity:-0} -ge 1 ] && printf "      %4s %s\n" "${types[$type]}" "$type"
		local files=(); manifestReadOneType --names --file="$manifestProjPath" files "$type"

		local typeSuffix="${type//./_}"
		local helperCmdCandidatesNames=""
		while [ "$typeSuffix" ]; do
			helperCmdCandidatesNames+=" bg-dev-install_${typeSuffix}__${INSTALLTYPE} bgAssetInstall_${typeSuffix}__${INSTALLTYPE} bg-dev-install_${typeSuffix} bgAssetInstall_${typeSuffix}"
			[[ ! "$typeSuffix" =~ _ ]] && typeSuffix=""
			typeSuffix="${typeSuffix%_*}"
		done

		local helperFnName found=''; for helperFnName in $helperCmdCandidatesNames; do
			if which $helperFnName &>/dev/null || [ "$(type -t $helperFnName)" == "function" ]; then
				$helperFnName "$type" "${files[@]}"
				found="1"
				break;
			fi
		done
		[ "$found" ] || assertError -v "helper Cmd Names in order of preference:${helperCmdCandidatesNames// /$'\n'}" -v assetType:type -v pkgName "
			No install helper command found for asset type '${type}'. You might need to install a plugin
			to handle this type of asset. This asset is listed in the project's .bglocal/manifest"
	done

	_installFilesToDst --flat manifest "/var/lib/bg-core/$pkgName" "manifest" "$manifestProjPath"

	### Finish the $UNINSTSCRIPT script
	$PRECMD bash -c 'cat >>"'"${UNINSTSCRIPT}"'"  <<-EOS
		[ "$DESTDIR" ] && [ -d "$DESTDIR/DEBIAN" ] && { rm -f "$DESTDIR/DEBIAN/"*; rmdir  "$DESTDIR/DEBIAN/"; }
		rmFile -r '${HOSTMANIFEST}'
		rmFile -r '${UNINSTSCRIPT}'
		true
		EOS' || assertError "error writing the final uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}"

	# if installing to the local host, run the posinstall script
	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is already installed and change "install" to "upgrade"
		[ -f pkgControl/postinst ] && { sudo ./pkgControl/postinst "install"; }
	fi
}


# usage: bg-dev bgUninstallAssets [-v|-q] [--pkgType=deb|rpm]
function bgUninstallAssets()
{
	local verbosity=${verbosity}
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local -x INSTALLTYPE="$1"
	local -x DESTDIR="$2"

	if [ "$INSTALLTYPE" == "detect" ]; then
		INSTALLTYPE=""
		which apt &>/dev/null && INSTALLTYPE="deb"
		[ ! "$INSTALLTYPE" ] && which rpm &>/dev/null && INSTALLTYPE="rpm"
		[ ! "$INSTALLTYPE" ] && INSTALLTYPE="deb"
	fi
	[ "$DESTDIR" == "/" ] && DESTDIR=""

	# if the DESTDIR does not exist, the unistall is done by definition
	[ ! -e "$DESTDIR/" ] && return 0

	# see if we need sudo to modify DESTDIR
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="bgsudo "

	# if uninstalling from the local host, run the prerm script
	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is being upgraded and change "remove" to "upgrade"
		[ -f pkgControl/prerm ] && { sudo ./pkgControl/prerm "remove"; }
	fi

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"

	# if there is a $UNINSTSCRIPT installed, call it to remove the last version before we install the current version.
	# this makes it clean when we remove or rename files in this library so that we dont leave obsolete files in the system
	[ -x "${UNINSTSCRIPT}" ] && { "${UNINSTSCRIPT}" || assertError -v UNINSTSCRIPT "
		The uninstall script from the previous installation ended with an error.
		You can edit that script to get around the error and try again. If you
		remove or rename that script this step will be skipped by the installer.
		There may or may not be steps in the uninstall script that need to complete
		before this package will install correctly so if you remove it, make a copy"; }

	# if uninstalling from the local host, run the postrm script
	if [ ! "$DESTDIR" ]; then
		# TODO: detect if the project is being upgraded and change "remove" to "upgrade"
		[ -f pkgControl/postrm ] && { sudo ./pkgControl/postrm "remove"; }
	fi
}
