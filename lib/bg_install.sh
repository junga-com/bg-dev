
import bg_manifest.sh ;$L1;$L2

### define the built-in helper functions for all the known asset types. Each of these are discovered by the builtin section of the
# manifestBuild function
# note that an install* function does not have to use _installFilesToDst. It can do anything it wants to represent its assets in
# the destination file system. See man(1) bg-dev-install and the _installFilesToDst function as a model to build a custom helper.
function installUnitTest()   { : ; } # unittests are not installed
#                                                                    <type>      <pkgPath>      <dstPath>
function installCmd()        { _installFilesToDst --flat             "cmd"       ""             "/usr/bin"; }
function installBashLib()    { _installFilesToDst --flat             "bashLib"   ""             "/usr/lib"; }
function installAwkLib()     { _installFilesToDst --flat             "awkLib"    ""             "/usr/share/awk"; }
function installEtc()        { _installFilesToDst                    "etc"       "etc/"         "/etc"; }
function installOpt()        { _installFilesToDst                    "opt"       "opt/"         "/opt"; }
function installData()       { _installFilesToDst                    "data"      "data/"        "/usr/share/$pkgName"; }
function installDoc()        { _installFilesToDst -z "doc/changelog" "doc"       "doc/"         "/usr/share/$pkgName"; }
function installManpage()    { _installFilesToDst -z "^"             "manpage"   ".bglocal/funcman" "/usr/share/man"; }
function installCron()       { _installFilesToDst                    "cron"      "cron.d/"      "/etc/cron.d"; }
function installSysVInit()   { _installFilesToDst                    "sysVInit"  "init.d/"      "/etc/init.d"; }
function installSysDInit()   { _installFilesToDst                    "sysDInit"  "systemd/"     "/etc/systemd/system"; }
function installSyslog()     { _installFilesToDst                    "syslog"    "rsyslog.d/"   "/etc/rsyslog.d"; }
function installGlobalBashCompletion() { _installFilesToDst --flat   "globalBashCompletion" ""  "/etc/bash_completion.d"; }

# usage: _installFilesToDst <type> <pkgPath> <dstPath> [<file1>...<fileN>]
# This is a helper function typicaly used by asset install functions to copy their asset files to tree structure under a system folder.
# The nature of this helper function is that the relative path of the asset is preserved under the <dstPath>
# Params:
#    <type>    : the asset type. (e.g. cmd, bashLib, awkLib, manpage, etc...). This is the 2nd column of the manifest file
#    <pkgPath> : the path prefix of the asset in the project folder. This part of the asset path will not be reproduced in the <dstPath>
#    <dstPath> : the destination folder where assets of this type are installed. The asset path structure will be reproduced here
#    <fileN>   : filenames of assets of this type to install. Note that if no <fileN> are passed to this function, the manifest file
#                will be read to get the list of asset files to process.
# Options:
#    -z|--zipSpec=<regex> : Any <fileN> that matches this expression will be compressed into a .gz file instead of copied as is.
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

	local type="$1"; shift
	local pkgPath="$1"; shift
	local dstPath="${DESTDIR}$1"; shift

	local files=(); [ $# -eq 0 ] && { manifestReadOneType files "$type" || assertError; }
	for file in "$@" "${files[@]}"; do
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

		# write this asset to the HOSTMANIFEST
		printf "%-20s %-20s %s\n" "$pkgName" "$type" "${dstFile#${DESTDIR}}" | $PRECMD tee -a  $HOSTMANIFEST >/dev/null

		echo "rmFile $recurseRmdir '$dstFile' || assertError" | $PRECMD tee -a  "${UNINSTSCRIPT}" >/dev/null
	done
}



function bgInstall()
{
	local verbosity=${verbosity} DESTDIR dstSystem
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--pkg*)
			bgOptionGetOpt val: dstSystem "$@" && shift
			dstSystem="${dstSystem:-deb}"
			DESTDIR=".bglocal/pkgStaging-$dstSystem"
			;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	[ ! "$dstSystem" ] && which apt &>/dev/null && dstSystem="deb"
	[ ! "$dstSystem" ] && which rpm &>/dev/null && dstSystem="rpm"
	[ ! "$dstSystem" ] && dstSystem="deb"

	[ "$DESTDIR" ] && [ ! -e "$DESTDIR/" ] && mkdir -p "$DESTDIR"
	local PRECMD; [ ! -w "$DESTDIR" ] && PRECMD="sudo "

	local UNINSTSCRIPT="${DESTDIR}/var/lib/bg-core/$pkgName/uninstall.sh"
	local HOSTMANIFEST="${DESTDIR}/var/lib/bg-core/$pkgName/hostmanifest"
	$PRECMD truncate -s0 "$HOSTMANIFEST"

	[ ${verbosity:-0} -ge 1 ] && printf "installing to %s\n" "${DESTDIR:-host filesystem}"

	export DESTDIR PRECMD UNINSTSCRIPT pkgName manifestProjPath
	#export -f manifestReadOneType bgOptionsEndLoop varSet printfVars varIsA

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
	local -A types; manifestReadTypes types
	local type; for type in "${!types[@]}"; do
		assertNotEmpty type
		[ ${verbosity:-0} -ge 1 ] && printf "installing %4s %s\n" "${types[$type]}" "$type"
		local files=(); manifestReadOneType files "$type"
		local helperFnCandidatesNames="bg-dev-install${type^}_${dstSystem} install${type^}_${dstSystem} bg-dev-install${type^} install${type^}"
		local helperFnName found=''; for helperFnName in $helperFnCandidatesNames; do
			if which $helperFnName &>/dev/null || [ "$(type -t $helperFnName)" == "function" ]; then
				$helperFnName "${files[@]}"
				found="1"
				break;
			fi
		done
		[ "$found" ] || assertError -v helperFnCandidatesNames -v assetType:type -v pkgName "
			No install helper command found for asset type '${type^}'. You might need to install
			a plugin to handle this type of asset. This asset is listed in the project's .bglocal/manifest"
	done

	_installFilesToDst --flat manifest "" "/var/lib/bg-core/$pkgName" "$manifestProjPath"

	### Finish the $UNINSTSCRIPT script
	$PRECMD bash -c 'cat >>"'"${UNINSTSCRIPT}"'"  <<-EOS
		rmFile -r '${HOSTMANIFEST}'
		rmFile -r '${UNINSTSCRIPT}'
		true
		EOS' || assertError "error writing the final uninstall script file contents"
	$PRECMD chmod a+x "${UNINSTSCRIPT}"
}


# usage: bg-dev bgUninstall [-v|-q] [--pkg=deb|rpm]
function bgUninstall()
{
	local verbosity=${verbosity} DESTDIR dstSystem
	while [ $# -gt 0 ]; do case $1 in
		-v|--verbose) ((verbosity++)) ;;
		-q|--quiet) ((verbosity--)) ;;
		--pkg*)
			bgOptionGetOpt val: dstSystem "$@" && shift
			dstSystem="${dstSystem:-deb}"
			DESTDIR="${PWD}/.bglocal/pkgStaging-$dstSystem"
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
