import Project.sh  ;$L1;$L2
import bg_json.sh  ;$L1;$L2

DeclareClass NodejsProject PackageProject

function NodejsProject::__construct()
{
	[ ! -f "${this[absPath]}/package.json" ] && assertError -v this[absPath] "package.json is missing from this project"

	# read the package.json if it exists
	Object::fromJSON "${this[absPath]}/package.json"
	#read -r this[displayName] this[type] this[version] < <(getProjectNameTypeAndVersion "${this[absPath]}/package.json")
}


function NodejsProject::depsInstall()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		npm install | gawk '{print "   "$0}'
	)
}

function NodejsProject::depsUpdate()
{
	(
		echo "${this[name]}:"
		Project::cdToRoot
		npm update | gawk '{print "   "$0}'
	)
}
