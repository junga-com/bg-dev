
import bg_objects.sh    ;$L1;$L2
import bg_devGit.sh     ;$L1;$L2

# usage: ConstructObject Project[::<type>] <oidVar> [ <path> ]
# Project is the base class for the hierarchy of classes that represents project folders. This class uses dynamic construction
# which means you can "ConstructObject Project <oidVar> <path>" and it will examine <path> to determine its <type> and actually
# create an instance of the class derived from Project that represents the discovered <type>. If <type> is specified and <path>
# is a folder of a different type the constructor will assert an error.
#
# Typically, commands that operate on any type of project will leave <path> empty so that it will construct which ever project
# the user's PWD is in. This works even if the PWD is a subfolder of the project's root folder. If <type> is specified as 'sandbox'
# and <path> is not specified, it will skip over the first containing project if needed to find the sandbox folder.
#
# If <path> is specified it will create an instance for that specific folder or assert an error if it is not a project folder or
# <type> was specified as a different type.
#
# Examples:
#     declare -gA project; ConstructObject Project project                     # nearest enclosing project to PWD of either type
#     declare -gA sandbox; ConstructObject Project::sandbox sandbox            # nearest enclosing sandbox project to PWD
#     declare -gA package; ConstructObject Package::package package            # nearest enclosing package project to PWD
#     declare -gA package; ConstructObject Package package ./myProject         # create any type that ./myProject is
#     declare -gA package; ConstructObject Package::nodjs package ./myProject  # create a NodejsProject for ./myProject (if it is one)
#
# Member Vars:
#   displayName     : the simple name of the projectFolder suitable for display to the user to identify this project
#   type            : one of sandbox|package|nodejs|atomPlugin
#   path            : the path that was specified in the construction or $PWD if none was specified
#   absPath         : absolute version of <path>. This remains valid even if a script changes directories
#   userPwd         : the absolute path of the folder that was the PWD when this object was created (typically the user where the
#                     user invoked a command)
#   version         : the latest version of this project
#   versionDspl     : the version number annotate for display. a "v" is prepended and if there has been changes to the project since
#                     this version was made, a + is appended
#   lastRelease     : the latest version number that is a tag in the current branch. The difference between this and version is that
#                     the actual project version is stored in the project and may have been incremenmted already in preparation for
#                     the next release. In practice they are only different between the time publishing starts and finishes.
#   releasePending  : true(1) or false("") to indicate if there is have been changes to the repo since the version tag was made
#                     (this is the same condition that the + at the end of version represents)
#   <attributes about git repo> : See man(3) gitProj::loadAttributes. gitFolderOpt, etc...
#
# See Also:
#    Project::ConstructObject()  (implements the dynamc construction of Project objects)
DeclareClass Project

declare -gA project

# usage: ConstructObject Project[::sandbox|package|nodejs|atomPlugin] <oidVar> [ <path> ]
# This static constructor method implements dynamic construction of Project objects.
# The <path> identifies a folder that may be any type of project. This dynamic constructor examines the folder to determine what
# type is is and then invokes the ctor for the derived class that corresponds to that type.
#
# It also implements the feature that if <path> is not specified, it will determine the nearest enclosing project to $PWD to use as
# path. This enables the user running project commands from a sub-folder of a project.
#
# Dynamic Construction:
# When a static method by this name exists, the object mechanism will delegate constructing the object instances of this class to
# this function. This function is reponsible for creating the OID and setting up the <oidVar> (which may be the associative array
# itself or a objRef string pointing to it). Typically it does this by identifying the derived class type from the construction
# parameters and then calling ConstructObject with that class instead of the generic base class.
function Project::ConstructObject()
{
	# the first param will be the suffix specified in the classname like Project::<type>|sandbox|package|nodejs|atomPlugin
	local targetType="${1,,}"; shift
	local myOIDRef="$1"; shift

	# now for the constructor arguments passed by the user
	local path="${1}"; shift

	# if not specified, glean <path> from the $PWD
	if [ ! "$path" ]; then
		# <path> might be a subfolder of the project's root folder. This happens when the user runs a project command in a subfolder.
		# relProjPath will be the path that when added to <path> (like <path>/<relProjPath>) will point to the project root
		local relProjPath="." sandOpt=""; [ "$targetType" == "sandbox" ] && sandOpt="--sandbox"
		static::Project::findEnclosingProjectRelPath $sandOpt "${path:-.}" relProjPath
		[ "$relProjPath" ] || assertError -v path "path is not within a bg-dev Project folder of any type"
		path="$relProjPath"
	fi

	local type
	if [ -f "$gitFolder/package.json" ]; then
		if gawk '/["]engines["]:/ {
			s=$0; while (s !~ /[}][[:space:]]*,?[[:space:]]*$/ && (getline >0)) s=s" "$0
			if (s~/["]atom["]/) projectType="atomPlugin"
			} END {exit (projectType)?0:1}' "$gitFolder/package.json"; then
			type="atomPlugin"
		else
			type="nodejs"
		fi
	else
		iniParamGet -R type "${path}/.bg-sp/config" . projectType
	fi

	[[ ! "$type" =~ ^(package|sandbox|nodejs|atomPlugin)$ ]] && assertError -v type -v path "Unknown project type. Expected one of package|sandbox|nodejs|atomPlugin"

	if [ "$targetType" ] && [ "$targetType" != "$type" ]; then
		assertError -v targetType -v type -v path "Expected a <targetType> project but found a <type> project at this path"
	fi

	case ${type} in
		sandbox)    ConstructObject SandboxProject    "$myOIDRef" "$path"  ;;
		package)    ConstructObject PackageProject    "$myOIDRef" "$path"  ;;
		nodejs)     ConstructObject NodejsProject     "$myOIDRef" "$path"  ;;
		atomPlugin) ConstructObject AtomPluginProject "$myOIDRef" "$path"  ;;
	esac

	return 0
}


# usage: $Project::findEnclosingProjectPath <path> <retVar>
# Returns the path relative to <path> that contains the nearest enclosing project.
#
# If the --sandbox options is specified, the found folder will have an .bg-sp/config file that contains the projectType=sandbox attribute
# Otherwise it will be the first found that has either .bg-sp/config or package.json files.
#
# Options:
#    -s|--sandbox : look for only an enclosing sandbox (ignore any enclosing package projects)
#
# Return Value:
# If the returned value is not empty, it will be a relative path consisting of '.', '..', or '../.. ...' that can be joined with
# <path> to make a path that points to the enclosing project.
#    "" (empty string) : there is no enclosing project
#    "."   : <path> is, itself, a project folder
#    "..", "../..[... /..]"
function static::Project::findEnclosingProjectRelPath()
{
	local sandboxFlag
	while [ $# -gt 0 ]; do case $1 in
		-s|--sandbox) sandboxFlag="-s" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local _relProjPath="${!2}"

	local _workingPath; pathGetCanonStr -e "$1/$_relProjPath" "_workingPath"
	while [ "${_workingPath}" ] \
		&& { \
			{ [ ! -f "$_workingPath/.bg-sp/config" ] && [ ! -f "$_workingPath/package.json" ]; } \
			|| { \
				[ "$sandboxFlag" ] \
				&& [ "$(iniParamGet "$_workingPath/.bg-sp/config" . projectType)" != "sandbox" ]; \
			}; \
		}; do
		_workingPath="${_workingPath%/*}"
		_relProjPath="${_relProjPath}/.."
	done
	_relProjPath="${_relProjPath#./}"
	[ ! -f "$_workingPath/.bg-sp/config" ] && _relProjPath=""
	returnValue "$_relProjPath" "$2"
}

# usage: $Project::getProjectPath <projName> [<retVar>]
# return the path of a <projName> that is either virtually installed or contained in the sandbox that the PWD is currently in
# if not found, the returned value is empty
function static::Project::getProjectPath()
{
	local projName="$1"

	local _projPathGPP
	if [ "$projName" == "sandbox" ] && [ "$bgVinstalledSandbox" ]; then
		_projPathGPP="$bgVinstalledSandbox"
	elif [[ :"$bgVinstalledPaths": =~ :([^:]*$projName): ]]; then
		_projPathGPP="${BASH_REMATCH[1]}"
	elif [[ "$bgVinstalledSandbox" =~ (^|[/])$projName$ ]]; then
		_projPathGPP="$bgVinstalledSandbox"
	else
		local _sandPathGPP
		static::Project::findEnclosingProjectRelPath -s . _sandPathGPP
		if [ "$_sandPathGPP" ] && [ -d "$_sandPathGPP/$projName" ]; then
			_projPathGPP="$_sandPathGPP/$projName"
		fi
	fi
	returnValue "$_projPathGPP" "$2"
	[ "$_projPathGPP" ]
}

# usage: $Project::cdToProject <projName> [<retVar>]
# change the PWD to the path of a <projName> that is either virtually installed or contained in the sandbox that the PWD is currently in
function static::Project::cdToProject()
{
	local projName="$1"
	local projPath; static::Project::getProjectPath "$projName" projPath
	[ "$projPath" ] && cd "$projPath" || assertError -v projName "<projName> is neither a virtually installed project nor is it a project in an enclosing sandbox"
}

# usage: static::Project::createPkgProj [--pkgName=<pkgName>] [--companyName=<companyName>] [--targetDists=<targetDists>] [--defaultDebRepo=<defaultDebRepo>] [--projectType=<projectType>] <projectName>
function static::Project::createPkgProj()
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
	local -x year="$(date +"%Y")"
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










# usage: ConstructObject Project[::<type>] <oidVar> [ <path> ]
# This is the constructor for the Project class which is the base class of a hierarchy of classes that represent different types
# of projects. This class uses dynamic construction. See man(7) Project.
#
# This __construct function fills in the generic project attributes that are common to all project types.
#
# Params:
#    <type>  : (default == <empty>) Note that <type> is a dynamic construction parameter that is optionally appended to the Project
#              class name. If specified, it will only construct a project of the specified type or assert an error if <path> is a
#              project folder of a different type.
#              <type> is the derived class name converted to lower case and with the 'Project' suffix removed
#              At the time of this writing it can have the values sanbox|package|nodejs|atomPlugin
#    <path>  : (default == find nearest) a path to a folder which to create the object instance for. If specified, the instance
#              will be for that exact <path> or fail if it can not. If not specified, it starts with the $PWD and while the folder
#              is not a project folder it moves up through the parent chain until a valid project folder is found. If <type> is
#              specified as 'sandbox', it will not stop on a valid project folder of another type so that it finds the enclosing
#              sandbox if any.
#
# See Also:
#    Project::ConstructObject()  (implements the dynamc construction of Project objects)
function Project::__construct()
{
	local path="$1"
	this[path]="$path"
	pathGetCanonStr -e "$path" this[absPath]

	# record where the user invoked us from
	this[userPwd]="$PWD"

	# load the entire .bg-sp/config file if it exists
	if [ -f "${this[absPath]}/.bg-sp/config" ]; then
		iniParamGetAll -A "${_this[_OID]}" "${this[absPath]}/.bg-sp/config"
		if [ ! "${this[type]}" ] && [ "${this[projectType]}" ]; then
			this[type]="${this[projectType]}"
		fi
		unset this[projectType]
	fi

	# all projects should be git folders so get some git repo information
	gitProj::loadAttributes

	# construction continues in postConstruct... (after the derived __construct have been called)
}

# usage: ConstructObject Project[::<type>] <oidVar> [ <path> ]
# This function continues the Project::__construct function after the constructors of the the derived classes have run
function Project::postConstruct()
{
	# a name is a name but where is the name?
	this[name]="${this[name]:-${this[projectName]:-${this[gitName]}}}"

	# assert that we expect the derived class to fill in some attrubutes...
	local attribName
	for attribName in displayName version ; do
		[ ! "${this[$attribName]+exits}" ] && assertError -v this -v _CLASS -v $attribName "A required attribute was not set during the construction of this object"
	done

	# The .+ appended to the versionDspl means that the displayed version is the last one released but
	# there has been changes to it since being released so its not really that version anymore.
	[ "${this[version]}" ] && this[versionDspl]="v${this[version]}"
	if [ "${this[releasePending]}" ] && git ${this[gitFolderOpt]} rev-parse --verify -q "v${this[version]}" &>/dev/null; then
		[ "${this[version]}" ] && this[versionDspl]+="+"
	fi
}

# usage: $obj.cdToRoot
# change the PWD to the project's root folder.
function Project::cdToRoot()
{
	cd "${this[absPath]}"
	this[path]="."
}

# usage: Project::printLine <retAttribArrayVar>
# TODO: consider if we need another command to show the details of the whole repo folder. This print focuses on the checked out
#       branch and the only consequent of other dirty branches is that when the current branch is syncd, the syncState will be
#       'dirtyBranches' instead of 'syncd'
function Project::printLine()
{
	local maxNameLen=0
	while [ $# -gt 0 ]; do case $1 in
		--maxNameLen*)  bgOptionGetOpt val: maxNameLen "$@" && shift ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done
	local branchDetailsLength=0
	local branchDetails=""
	local warningText=""

	printf " %s %*s: %*s %*s %*s %*s ${csiHiRed}%*s${csiNorm}\n" \
		"${this[dirtyIndicator]}" \
		-$maxNameLen          "${this[name]}" \
		 -9                   "${this[versionDspl]}" \
		-$branchDetailsLength "$branchDetails" \
		-11                   "${this[syncState]}" \
		-25                   "${this[changesStatus]}" \
		  0                   "$warningText"
	if ((${verbosity:-0} >= 2)) && [ ${this[changesCount]:-0} -gt 0 ]; then
		echo "${this[changes]}" | gawk '{print "       "$0}'
	fi
	if ((${verbosity:-0} >= 3)) && [ ${this[commitsAhead]:-0} -gt 0 ]; then
		echo "${this[commitsAheadStr]}" | gawk '{print "       "substr($0,1,130)}'
	fi
}


function Project::checkout()
{
	:
}

function Project::push()
{
	git ${this[gitFolderOpt]} push
}

function Project::pull()
{
	git ${this[gitFolderOpt]} pull
}


function Project::status()
{
	Project::printLine -v "$@"
}

function Project::commit()
{
	// if there are changes to commit, launch the git gui tool for the user to interactively commit
	if [ "$(git -C "$subFolder" status -uall --porcelain --ignore-submodules=dirty | head -n1)" ]; then
		(cd "$this[absPath]" || assertError; git gui citool)&
	fi
}



function devIsPkgName()
{
	[[ ":$bgInstalledPkgNames:" =~ :$1: ]] && return 0
	[ -d "/var/lib/bg-core/$1" ] && return 0
	manifestIsPkgName "$1" && return 0
	return 1
}

function normalizePkgName() {
	local pkgNameVal="$1"; shift
	local pkgNameVar="$1"; shift
	pkgNameVal="${pkgNameVal,,}"
	#pkgNameVal="${pkgNameVal//-/_}"
	returnValue "$pkgNameVal" "$pkgNameVar"
}
