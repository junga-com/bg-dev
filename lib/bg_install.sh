
import bg_manifestScanner.sh ;$L1;$L2

### define the built-in helper functions for all the known asset types. Each of these are discovered by the builtin section of the
# manifestBuild function
# note that an install* function does not have to use _installFilesToDst. It can do anything it wants to represent its assets in
# the destination file system. See man(1) bg-dev-install and the _installFilesToDst function as a model to build a custom helper.
function bgInstall_unitTest()   { : ; } # unittests are not installed
#                                                                       <pkgPath>      <dstPath>                   <pass thru type plus filepaths>
function bgInstall_cmd()        { _installFilesToDst --flat             ""             "/usr/bin"                  "$@" ; }
function bgInstall_lib()        { _installFilesToDst --flat             ""             "/usr/lib"                  "$@" ; }
function bgInstall_etc()        { _installFilesToDst                    "etc/"         "/etc"                      "$@" ; }
function bgInstall_opt()        { _installFilesToDst                    "opt/"         "/opt"                      "$@" ; }
function bgInstall_data()       { _installFilesToDst                    "data/"        "/usr/share/$pkgName"       "$@" ; }
function bgInstall_template()   { _installFilesToDst                    "templates/"   "/usr/share/$pkgName"       "$@" ; }
function bgInstall_doc()        { _installFilesToDst -z "doc/changelog" "doc/"         "/usr/share/$pkgName"       "$@" ; }
function bgInstall_manpage()    { _installFilesToDst -z "^"             ".bglocal/funcman" "/usr/share/man"        "$@" ; }
function bgInstall_cron()       { _installFilesToDst                    "cron.d/"      "/etc/cron.d"               "$@" ; }
function bgInstall_sysVInit()   { _installFilesToDst                    "init.d/"      "/etc/init.d"               "$@" ; }
function bgInstall_sysDInit()   { _installFilesToDst                    "systemd/"     "/etc/systemd/system"       "$@" ; }
function bgInstall_syslog()     { _installFilesToDst                    "rsyslog.d/"   "/etc/rsyslog.d"            "$@" ; }
function bgInstall_globalBashCompletion() { _installFilesToDst --flat   ""             "/etc/bash_completion.d"    "$@" ; }
function bgInstall_lib_script_awk()       { _installFilesToDst --flat   ""             "/usr/share/awk"            "$@" ; }

# usage: _installFilesToDst <pkgPath> <dstPath>   <type> [<fileOrFolder1>...<fileOrFolderN>]
# This is a helper function typically used by asset install helper functions to copy their asset files to the DESTDIR.
# It can support several common patterns based on what options are specified. Typically a new function following the naming convention
# described in `man(5) bgInstallHelpCmdProtocol` is created that just calls this function, hard coding the first two parameters and
# passing through the parameters it is called with.
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
function _installFilesToDst() {
	local zipSpec="^$" # default is to match no files
	local flatFlag recurseRmdir="-r" removePrefix
	while [ $# -gt 0 ]; do case $1 in
		-z*|--zipSpec*) bgOptionGetOpt val: zipSpec "$@" && shift ;;
		-f|--flat)  flatFlag="-f"; recurseRmdir="" ;;
		-r*|--removePrefix*) bgOptionGetOpt val: removePrefix "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	local pkgPath="$1"; shift
	local dstPath="${DESTDIR}$1"; shift

	local type="$1"; shift

	local files=(); [ $# -eq 0 ] && { manifestReadOneType --file="$manifestProjPath" files "$type" || assertError; }
	for file in "$@" "${files[@]}"; do
		{ [ ! "$file" ] || [ ! -f "$file" ]; } &&  assertError -v type -v file "file does not exist in the project"
		local dstFile="${dstPath}/${file#$pkgPath}"
		[ "$flatFlag" ] && dstFile="${dstPath}/${file##*/}"
		local dstFolder="${dstFile%/*}"
		[ ! -e "$dstFolder" ] && { $PRECMD mkdir -p "$dstFolder" || assertError; }

		if [[ "$file" =~ $zipSpec ]] && [[ ! "$file" =~ [.]gz$ ]]; then
			dstFile="${dstFile}.gz"
			gzip -n -f -9  < "$file" | $PRECMD tee "$dstFile" >/dev/null || assertError
		else
			$PRECMD cp "$file" "$dstFile" || assertError
		fi

		# TODO: it would be more correct to pass through the assetName from the package manifest file but the current install helper
		#       call protocol only sends the assetType for a group and then the filePaths in that group. Currently this just means that
		#       any assetType that uses names that are not derived from the filename should not use this function but instead register
		#       a specific helper that ignores the
		local assetName="${dstFile%/}"
		assetName="${assetName##*/}"
		[[ ! "$dstFile" =~ /$ ]] && assetName="${assetName%%.*}"

		# write this asset to the HOSTMANIFEST
		printf "%-20s %-20s %-20s %s\n" "$pkgName" "$type" "$assetName" "${dstFile#${DESTDIR}}" | $PRECMD tee -a  $HOSTMANIFEST >/dev/null

		echo "rmFile $recurseRmdir '$dstFile' || assertError" | $PRECMD tee -a  "${UNINSTSCRIPT}" >/dev/null
	done
}


# man(5) bgInstallHelpCmdProtocol
# bgInstall uses helper commands (or functions) to install each asset type that it finds in a project's manifest file. The bg_install.sh
# library provides the helper functions for the builtin asset types. An external package can provide support for additional asset
# types.
#
# The package the introduces an asset type must provide an external command or function as the helper function that knows how to
# install files or folders of that asset type. Functions are provided in plugins that are sourced into the installers's bash process.
#
# Helper Command or Function Names:
# The helper function used is the first one that exists in the following list.
#   * bg-dev-install_<assetSuffix>__<installType>      # external command, specific to <installType>
#   * bgInstall<assetSuffix>__<installType>            # sourced function, specific to <installType>
#   * bg-dev-install<assetSuffix>                      # external command that works for any <installType>
#   * bgInstall<assetSuffix>                           # sourced function that works for any <installType>
#   * if asset name conatins a qualification, the last qualification is removed and the above names with the modified <assetSuffix>
#     are queried. That is repeated until <assetSuffix> is empty.
#
# This naming scheme allows one generic helper to handle all assets of a base type and all install types or for separate helpers,
# to be created that handle a particular asset qualification or install type.  A generic handler can query the INSTALLTYPE Environment
# variable to conditionally repsond to different types. If a generic handler needs to know the quaified asset type, it must query
# the project's manifest file because that information is not passed to the handler directly.
#
# <assetSuffix> is the asset type with '.' replaced with '_'.  Asset names can be qualified with periods. For example `lib` is a
# generic library asset that on deb systems will be installed to `/usr/lib/`. `lib.bash` is a `lib` that is written in bash. The
# installer might not need to know that the asset is written in bash but it might or it might be useful to other tools. Since
# function names can not contain periods, periods are replaced with '_'.
#
# Notice that if the <installType> is included in the helper name, it is proceeded with two '_'. That makes it so that that
#  <installType> can always be distinguished from the last qulification part of the asset type.
#
# Params:
# An install helper function is invoked by bgInstall like this...
#      <helperCmd> <assetType> <fileOrFolder1>[..<fileOrFolderN>]
# where...
#    <assetType>     : the specific asset type that may include qualifications (like lib.bash) that the following files or folders
#                      belong to.
#    <fileOrFolderN> : a file object to install.
#
# Environment Available to Helpers:
# The following environment variables are available to helper commands or functions.
#
#    * DESTDIR          : the top of the path where the project is being installed. Empty means its being installed in the root filesystem
#    * INSTALLTYPE      : deb|rpm. Determines the standard of the target filesystem. Others may be added in the future.
#    * PRECMD           : this is meant to prefix commands that modify the DESTDIR. If the user does not have permissions to modify
#                         DESTDIR, this will conatin the sudo command that gives the user sufficient permissions. It will be empty
#                         if the useer does have sufficient permission. It assumes that permissions to modify the root of DESTDIR
#                         is sufficient to modify any path relative to DESTDIR
#    * UNINSTSCRIPT     : The path of the uninstall script that is being built up by the installation. For each action the helper
#                         does to modify DESTDIR, it should append a line to this script that undoes it. The script provides the
#                         `rmFile [-r] <target>` function that can be used to undo the action of copying a file. If -r is specified,
#                         if it removes the last file in a folder, that folder will aslo be removed.
#    * pkgName          : The name of the package being installed.
#    * manifestProjPath : The path of the package's manifest file relative to the prject root. The list of files or folders sent to
#                         the helper came from this file. On rare ocassions, the helper may want to query the manifest to see what
#                         other related assets are being installed.


# usage: bgInstall [--pkg=deb|rpm] [-v] [-q]
# Installs the assets from the project. If --pkg is specified, it installs the assets to a staging folder at ./.bglocal/pkgStaging-<deb|rpm>
# If not, it installs the assets to the root filesystem which is typically the local host's root filesystem. The type of package (deb|rpm)
# can affect how the assets are installed so when the --pkg option is not specified, the installation type (deb|rpm) is gleaned
# by querying the local host to see if `apt` or `rpm` commands are available. If both are available, 'deb' is used.
#
# Helper Commands or Functions:
# This function iterates the asset types in the project's manifest file and for each found, it looks for a helper command or function
# that matches the asset type name and install type (deb|rpm or generic) and executes that helper with the list of files or folders
# of that asset type present in the project. Each file or folder is relattive to the project's root folder. The helper is responsible
# to install the asset and also to append to the UNINSTSCRIPT a command that will undo the installation of each asset.
#
# See Also:
#    man(5) bgInstallHelpCmdProtocol
function bgInstall()
{
	local verbosity=${verbosity} DESTDIR INSTALLTYPE
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--pkg*)
			bgOptionGetOpt val: INSTALLTYPE "$@" && shift
			INSTALLTYPE="${INSTALLTYPE:-deb}"
			DESTDIR=".bglocal/pkgStaging-$INSTALLTYPE"
			;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	[ ! "$INSTALLTYPE" ] && which apt &>/dev/null && INSTALLTYPE="deb"
	[ ! "$INSTALLTYPE" ] && which rpm &>/dev/null && INSTALLTYPE="rpm"
	[ ! "$INSTALLTYPE" ] && INSTALLTYPE="deb"

	[ "$DESTDIR" ] && [ ! -e "$DESTDIR/" ] && mkdir -p "$DESTDIR"
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="sudo "

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"
	local HOSTMANIFEST="${DESTDIR}/var/lib/bg-core/$pkgName/hostmanifest"
	# fsTouch can not use $PRECMD b/c its a function (sudo only does files) but fsSudo will prompt sudo as needed
	fsTouch --existOnly -p "$HOSTMANIFEST"
	$PRECMD truncate -s0 "$HOSTMANIFEST"

	[ ${verbosity:-0} -ge 1 ] && printf "installing to %s\n" "${DESTDIR:-host filesystem}"

	export DESTDIR INSTALLTYPE PRECMD UNINSTSCRIPT pkgName manifestProjPath
	#export -f manifestReadOneType --file="$manifestProjPath" bgOptionsEndLoop varSet printfVars varIsA

	# if there is a $UNINSTSCRIPT installed, call it to remove the last version before we install the current version.
	# this makes it clean when we remove or rename files in this library so that we dont leave obsolete files in the system
	[ -x "${UNINSTSCRIPT}" ] && { "${UNINSTSCRIPT}" || assertError -v UNINSTSCRIPT "
		The uninstall script from the previous installation ended with an error.
		You can edit that script to get around the error and try again. If you
		remove or rename that script this step will be skipped by the installer.
		There may or may not be steps in the uninstall script that need to complete
		before this package will install correctly so if you remove it, make a copy"; }

	### Start the $UNINSTSCRIPT script
	$PRECMD mkdir -p "${DESTDIR}/var/lib/bg-core/$pkgName"
	$PRECMD bash -c 'cat >"'"${UNINSTSCRIPT}"'"  <<-EOS
		#!/usr/bin/env bash
		#(its better to create a bespoke assertError) # [ -f /usr/lib/bg_core.sh ] && source /usr/lib/bg_core.sh
		[ "\$(type -t assertError)" != "function" ] && function assertError() {
		   printf "uninstall script failed: \n\tlocation:\$0(\${BASH_LINENO[0]})\n\tline: \$(awk 'NR=='"\${BASH_LINENO[0]}"'' \$0)\n"
		   exit 2
		}
		function rmFile() {
		   local recurseFlag; [ "\$1" == "-r" ] && { recurseFlag="-r"; shift; }
		   [ -e "\$1" ]        && { \$preUninstCmd rm -f "\$1" || return; }
		   [ "\$recurseFlag" ] && { \$preUninstCmd rmdir --ignore-fail-on-non-empty -p  "\${1%/*}" &>/dev/null; true; }
		   true
		}
		preUninstCmd=""; [ ! -w "\$0" ] && preUninstCmd="sudo "; true
		EOS' || assertError "error writing the initial uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}" || assertError

	manifestUpdate
	local -A types; manifestReadTypes --file="$manifestProjPath" types
	local type; for type in "${!types[@]}"; do
		assertNotEmpty type
		[ ${verbosity:-0} -ge 1 ] && printf "installing %4s %s\n" "${types[$type]}" "$type"
		local files=(); manifestReadOneType --file="$manifestProjPath" files "$type"

		local typeSuffix="${type//./_}"
		local helperCmdCandidatesNames=""
		while [ "$typeSuffix" ]; do
			helperCmdCandidatesNames+=" bg-dev-install_${typeSuffix}__${INSTALLTYPE} bgInstall_${typeSuffix}__${INSTALLTYPE} bg-dev-install_${typeSuffix} bgInstall_${typeSuffix}"
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
		rmFile -r '${HOSTMANIFEST}'
		rmFile -r '${UNINSTSCRIPT}'
		true
		EOS' || assertError "error writing the final uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}"

	# if installing to the local host, run the posinstall scripts
	if [ ! "$DESTDIR" ]; then
		# TODO: create a standard for post install scripts and call them here if the pkg has any
		manifestUpdateInstalledManifest
	fi
}


# usage: bg-dev bgUninstall [-v|-q] [--pkg=deb|rpm]
function bgUninstall()
{
	local verbosity=${verbosity} DESTDIR INSTALLTYPE
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--pkg*)
			bgOptionGetOpt val: INSTALLTYPE "$@" && shift
			INSTALLTYPE="${INSTALLTYPE:-deb}"
			DESTDIR="${PWD}/.bglocal/pkgStaging-$INSTALLTYPE"
			;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	[ "$DESTDIR" ] && [ ! -e "$DESTDIR/" ] && mkdir -p "$DESTDIR"
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="sudo "

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"

	# if there is a $UNINSTSCRIPT installed, call it to remove the last version before we install the current version.
	# this makes it clean when we remove or rename files in this library so that we dont leave obsolete files in the system
	[ -x "${UNINSTSCRIPT}" ] && { "${UNINSTSCRIPT}" || assertError -v UNINSTSCRIPT "
		The uninstall script from the previous installation ended with an error.
		You can edit that script to get around the error and try again. If you
		remove or rename that script this step will be skipped by the installer.
		There may or may not be steps in the uninstall script that need to complete
		before this package will install correctly so if you remove it, make a copy"; }
}
