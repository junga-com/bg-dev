
import bg_manifestScanner.sh ;$L1;$L2


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
