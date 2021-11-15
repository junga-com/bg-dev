
import bg_objects.sh ;$L1;$L2


DeclareClass Project

declare -gA project


# $Project::findEnclosingProjectPath <path> [<retVar>]
# Returns the path relative to <path> that contains the nearest enclosing project.
# Return Value:
# If the <retVar> value is not empty, it will be a relative path consisting of '.', '..', or '../.. ...' that can be joined with
# <path> to make a path that points to the enclosing project.
#    "" (empty string) : there is no enclosing project
#    "."   : <path> is, itself, a project folder
#    "..", "../..[... /..]"
function static::Project::findEnclosingProjectRelPath()
{
	local _relProjPath="${!2}"
	local _workingPath; pathGetCanonStr -e "$1/$_relProjPath" "_workingPath"
	while [ "${_workingPath}" ] && [ ! -f "$_workingPath/.bg-sp/config" ]; do
		_workingPath="${_workingPath%/*}"
		_relProjPath="${_relProjPath}/.."
	done
	_relProjPath="${_relProjPath#./}"
	[ ! -f "$_workingPath/.bg-sp/config" ] && _relProjPath=""
	returnValue "$_relProjPath" "$2"
}

# usage: ConstructObject Project <oidVar> [ <path> [package|sandbox] ]
# Constructs an object that represents the project specified by <path> and the optional project type. This class uses dynamic
# construction so the constructed object will always be a either PackageProject or SandboxProject depending on the type found in
# <path> or one of its parent folders.
# Typically, commands that operate on both package and snadbox projects will leave <path> and [package|sandbox] empty so that it
# will construct which ever project the user's PWD is in. If a command only operates on sandbox's then it can specify 'sandbox' as
# the second argument and even if the PWD is inside a package folder within a sandbox, it will construct the sandbox project.
# If the command only operates on packages, specifying 'package' as the second argument will prevent it from returning a sandbox
# if the PWD is not in a package folder.
# Examples:
#     declare -gA project; ConstructObject Project                      # nearest enclosing project to PWD of either type
#     declare -gA sandbox; ConstructObject Sandbox . sandbox            # nearest enclosing sandbox project to PWD
#     declare -gA package; ConstructObject Package .  package           # nearest enclosing package project to PWD
#     declare -gA package; ConstructObject Package ./myProject          # specify the path to the project folder.
# Params:
#    <path>  : (default == $PWD) a path to a folder which can be a project folder's root or a sub-path below the root. If its not
#              a project root, its parents will be checked until a project satisfying the optional [package|sandbox] type is found.
#    [package|sandbox] : if specified, it will only construct a project of the specified type.
# See Also:
#    Project::ConstructObject()  (implements the dynamc construction of Project objects)
function Project::__construct()
{
	:
}

# usage: ConstructObject Project <oidVar> [ <path> [package|sandbox] ]
# This static constructor method implements dynamic construction of Project objects.
# The <path> identifies a folder that may be PackageProject or a SandboxProject. This dynamic constructor peaks inside at the
# projectType setting inside the <path>/.bg-sp/config file to determine the derived class type and then constructs that specific
# type of project instance.
# It also implements the features that <path> can be a subtree path underneath the project folder. This enables the user running
# package and sandbox project commands from a su-folder of a project.
# Dynamic Construction:
# When a static method by this name exists,
# the object mechanism will delegate constructing the object instances of this class to this function. This function is reponsible
# for creating the OID and setting up the <oidVar> (which may be the associative array itself or a objRef string pointing to it).
# Typically it does this by identifying the derived class type from the construction parameters and then calling ConstructObject
# with that class instead of the generic base class.
function Project::ConstructObject()
{
	# the first param will be the suffix specified in the classname like Project::<type>
	local classSuffix="$1"; shift  # not used by Project classes
	local myOIDRef="$1"; shift

	# now for the constructor arguments passed by the user
	local path="${1:-.}"; shift
	local targetType="$1"; shift

	local relProjPath="."
	static::Project::findEnclosingProjectRelPath "$path" relProjPath
	[ "$relProjPath" ] || assertError -v path "path is not within a bg-dev Project folder of any type"

	local type; iniParamGet -R type "${path}/$relProjPath/.bg-sp/config" . projectType
	[[ ! "$type" =~ ^(package|sandbox)$ ]] && assertError -v type -v projectConfigFile:"$(pathGetCanonStr "${path}/$relProjPath/.bg-sp/config")" "The project config file does not contain a valid projectType setting. It should be set to 'package' or 'sandbox'"

	[ "$targetType" == "package" ] && [ "$type" != "package" ] && assertError "This command operates on a 'package' project but the PWD is in the sandbox project root"

	if [ "$targetType" == "sandbox" ] && [ "$type" == "package" ]; then
		relProjPath="${relProjPath}/.."
		static::Project::findEnclosingProjectRelPath "$path" relProjPath
		[ "$relProjPath" ] || assertError -v path "a 'sandbox' project is required by this command but the 'package' project specified is not contained in a 'sandbox'"
		iniParamGet -R type "${path}/$relProjPath/.bg-sp/config" projectType
		[[ ! "$type" =~ ^(package|sandbox)$ ]] || assertError -v projectConfigFile:"$(pathGetCanonStr "${path}/$relProjPath/.bg-sp/config")" "The project config file does not contain a valid projectType setting. It should be set to 'package' or 'sandbox'"
	fi

	local foundPath; pathGetCanonStr "$path/$relProjPath" foundPath

	case ${type} in
		sandbox) ConstructObject SandboxProject "$myOIDRef" "$foundPath"  ;;
		package) ConstructObject PackageProject "$myOIDRef" "$foundPath"  ;;
	esac

	return 0
}

DeclareClass PackageProject Project

function PackageProject::__construct()
{
	local path="$1"

	[ ! -f "${path}/.bg-sp/config" ] && assertError -v path "<path> is not a project folder because it does not contain a ./.bg-sp/config file"

	iniParamGetAll -A "${this[_OID]}" "${path}/.bg-sp/config"
	[ "${this[projectType]}" != "package" ] && assertError -v "projectConfigFile:-l${path}/.bg-sp/config" "Expected the project at this path to be a 'package' but its config file says its a '${this[projectType]}'"
	[ ! "${this[packageName]}" ] && assertError -v "projectConfigFile:-l${path}/.bg-sp/config" "The project config file is missing the 'packageName' setting"

	this[path]="$path"
	pathGetCanonStr -e "$path" this[absPath]
}

function PackageProject::cdToRoot()
{
	cd "${this[path]}"
	this[path]="."
}

# usage: $proj.make <pkgType>
function PackageProject::makePackage()
{
	$this.cdToRoot
	local runLintianFlag makeChangesFlag
	while [ $# -gt 0 ]; do case $1 in
		--lintian) runLintianFlag=1 ;;
		--changes) makeChangesFlag=1 ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local pkgType="${1:-deb}"
	local pkgName="${this[packageName]}"

	# scan for assets to make sure the list of assets is up-to-date
	manifestUpdate

	# make sure that the funcman assets are up-to-date. funcman manintains the manifest file if any manpages are added or removed.
	funcman_runBatch -q

	this[version]="$(dpkg-parsechangelog -ldoc/changelog | sed -n -e 's/^Version:[ \t]*//p')"

 	case $pkgType in
		deb|both)
			echo "making deb package..."
			assertFileExists pkgControl/debControl "pkgControl/debControl is required to build a deb package. See 'control' file in debian policy documentation"

			local stagingFolder=".bglocal/pkgStaging-deb"

			### Install the package's assets into the stagingFolder
			bgInstallAssets --no-update "deb" "$stagingFolder"

			### Make the DEBIAN pkg control folder in the stagingFolder from the shared pkgControl folder
			mkdir -p $stagingFolder/DEBIAN
			if [ -e pkgControl/lintianOverrides ]; then
				mkdir -p $stagingFolder/usr/share/lintian/overrides/
				mv pkgControl/lintianOverrides $stagingFolder/usr/share/lintian/overrides/${this[packageName]}
				chmod 0644 $stagingFolder/usr/share/lintian/overrides/${this[packageName]}
			fi
			for i in preinst postinst prerm postrm; do
				if [ -f "pkgControl/$i" ]; then
					cp "pkgControl/$i" $stagingFolder/DEBIAN/
					chmod 775 $stagingFolder/DEBIAN/$i
				fi
			done
			chmod -R g-w $stagingFolder/

			### Create the binary control file for the pkg from the source control file
			dpkg-gencontrol -cpkgControl/debControl -ldoc/changelog -fpkgControl/files -P$stagingFolder/

			### Make the deb file from the staging folder
			fakeroot dpkg-deb -Zgzip --build $stagingFolder/ ${this[packageName]}_${this[version]}_all.deb

			## run lintian to check for issues
			if [ "$runLintianFlag" ]; then
				printf "${csiBold}lintian:${csiNorm} %s\n" "${this[packageName]}_${this[version]}_all.deb"
				if ! lintian ${this[packageName]}_${this[version]}_all.deb; then
					echo "stopping because package contains lintian issues."
					return 1
				fi
			fi

			### Create the .changes file which will be used to upload the package to repositories
			if [ "$makeChangesFlag" ]; then
				local pubishUser="$(gawk '/^Maintainer:/ {gsub("^.*<|>.*$",""); print}' pkgControl/debControl)"
				dpkg-genchanges -b  -cpkgControl/debControl -ldoc/changelog -fpkgControl/files -u. -O${this[packageName]}_${this[version]}_all.changes.unsigned
				if gpg -k "<$pubishUser>" &>/dev/null; then
					rm -f ${this[packageName]}_${this[version]}_all.changes
					if gpg --use-agent --clearsign --batch -u "<$pubishUser>" -o ${this[packageName]}_${this[version]}_all.changes -- ${this[packageName]}_${this[version]}_all.changes.unsigned; then
						printf "${csiBold}gpg :${csiNorm} signed changes file with %s's key\n" "$pubishUser"
						rm ${this[packageName]}_${this[version]}_all.changes.unsigned
					else
						printf "${csiBold}gpg :${csiRed} FAILED to sign changes file with %s's key. changes file is unsigned${csiNorm}\n" "$pubishUser"
						mv ${this[packageName]}_${this[version]}_all.changes.unsigned ${this[packageName]}_${this[version]}_all.changes
					fi
				else
					echo "The maintainer user specified in the pkgControl/debControl file, '$pubishUser' does not have a gpg key to sign the changes file."
					echo "The .changes file will not be signed"
					mv ${this[packageName]}_${this[version]}_all.changes.unsigned ${this[packageName]}_${this[version]}_all.changes
				fi
				chmod 644 ${this[packageName]}_${this[version]}_all.changes
			fi

			# report finish
			echo "built package '${this[packageName]}_${this[version]}_all.deb'"
			;;&

		rpm|both)
			echo "making rpm package..."
			assertFileExists pkgControl/rpmControl "pkgControl/rpmControl is required to build a deb package. See 'control' file in debian policy documentation"
			local stagingFolder=".bglocal/rpmbuilding/pkgStaging-rpm"
			mkdir -p ".bglocal/rpmbuilding"

			bgInstallAssets --no-update "rpm" "$stagingFolder"
			chmod -R g-w $stagingFolder/

			rpmbuild --define "_topdir .bglocal/rpmbuilding/rpmbuild"  --buildroot "${PWD}/$stagingFolder"   -bb pkgControl/rpmControl
			mv .bglocal/rpmbuilding/rpmbuild/RPMS/noarch/*.rpm .
			;;&
	esac
}

DeclareClass SandboxProject Project

function SandboxProject::__construct()
{
	local path="$1"

	[ ! -f "${path}/.bg-sp/config" ] && assertError -v path "<path> is not a project folder because it does not contain a ./.bg-sp/config file"

	iniParamGetAll -A "${this[_OID]}" "${path}/.bg-sp/config"
	[ "${this[projectType]}" != "sandbox" ] && assertError -v "projectConfigFile:-l${path}/.bg-sp/config" "Expected the project at this path to be a 'sandbox' but its config file says its a '${this[projectType]}'"
}

function SandboxProject::make()
{
	echo "sandbox makeing"
}



# usage: devGetPkgName [<retVar>]
# a lot of functions in the dev environment need to know the pkgName that is being operated on. in cmds like bg-dev, pkgName is set
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
