
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

# usage: devCreatePkgProj [--pkgName=<pkgName>] [--companyName=<companyName>] [--targetDists=<targetDists>] [--defaultDebRepo=<defaultDebRepo>] [--projectType=<projectType>] <projectName>
function devCreatePkgProj()
{
	local -x packageName
	local -x companyName
	local -x targetDists="$(lsb_release -cs)"
	local -x defaultDebRepo
	local -x creationDate
	local -x projectType="packageProject"
	while [ $# -gt 0 ]; do case $1 in
		--packageName*)      bgOptionGetOpt val: packageName     "$@" && shift ;;
		--companyName*)     bgOptionGetOpt val: companyName    "$@" && shift ;;
		--targetDists*)     bgOptionGetOpt val: targetDists    "$@" && shift ;;
		--defaultDebRepo*)  bgOptionGetOpt val: defaultDebRepo "$@" && shift ;;
		--projectType*)     bgOptionGetOpt val: projectType    "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local -x projectName="$1"; shift; assertNotEmpty projectName
	[ ! "$packageName" ] && normalizePkgName "$projectName" packageName;
bgtraceVars packageName

	local -x newProjectName="$projectName"
	local -x creationDate_rfc_email="$(date --rfc-email)"
	local -x creationDate_rfc_3339="$(date --rfc-3339=seconds)"
	local -x creationDate="$creationDate_rfc_3339"
	local -x createdBy="${USER}"
	local -x fullUsername="$(git config user.name)"
	local -x userEmail="$(git config user.email)"

	[ -e "./$projectName" ] && assertError "A file object already exists at './$projectName'"

	import bg_template.sh  ;$L1;$L2

	local templateFolder="${pkgDataFolder}/projectTemplates/$projectType"

	templateExpandFolder "$templateFolder" "./$projectName"

	(
		cd "./$projectName" 2>$assertOut || assertError
		git init
		git add .
		git commit -m"created with 'bg-dev newProj'"
	)
}

function normalizePkgName() {
	local pkgNameVal="$1"; shift
	local pkgNameVar="$1"; shift
	pkgNameVal="${pkgNameVal,,}"
	pkgNameVal="${pkgNameVal//-/_}"
	returnValue "$pkgNameVal" "$pkgNameVar"
}
